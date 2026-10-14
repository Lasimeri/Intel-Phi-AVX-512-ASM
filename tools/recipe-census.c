/* recipe-census.c: which vector instructions of an ELF object the
 * translator has a recipe for, counted by the decoder's own mnemonic id
 * (decode.S over x86tab.inc, the recipe table of xlate.S), so the port
 * is driven by what the target's code holds:
 *
 *   gcc -O2 -o recipe-census tools/recipe-census.c host/asm/out/p512_{decode,xlate,mvex,fnscan,blob}.o
 *   recipe-census [-f FUNCTION] [-a] ELF...
 *
 * Every instruction of .text (or of one function, -f, by .symtab) that
 * blob.S would hand to a recipe (a VEX or EVEX encoding, or a legacy
 * instruction with an xmm operand) is counted under its mnemonic; the
 * mnemonics with no recipe are listed by count (-a lists the covered
 * ones too). The tally per object and the grand total come last. See
 * recipe-census.md. */
#include <elf.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "../host/asm/phi512/x86tab.h"

struct insn {
	uint8_t len, enc, map, pp, op, pfx, rex, w, l, modrm, has, mod, reg, rm, base, index, scale, vvvv, aaa, z, b, flow;
	uint8_t imm_off, imm_sz, disp_off, disp_sz, op_off, modrm_off, opsize, imm2, n, pad;
	uint32_t entry, pad2;
	int64_t disp;
	uint64_t imm, target, next;
	const struct x86_ent *ent;
	uint64_t pad3[2];
};
extern uint64_t x86_decode(const void *bytes, uint64_t avail, struct insn *out, uint64_t addr);
extern void xl_init(void);
extern void *xl_tab[];

static uint64_t count[4096], total[4096];
static int all;

static int vector_kind(uint8_t k)
{
	/* xmm/ymm/zmm _or_mem 20..22, xmm 48..53, ymm 54..58, zmm 59..63, k 24, 42..45 */
	return (k >= 20 && k <= 22) || (k >= 48 && k <= 63) || k == 24 || (k >= 42 && k <= 45);
}

static void census(const uint8_t *p, const uint8_t *end, uint64_t addr)
{
	struct insn in;
	while (p < end) {
		uint64_t n = x86_decode(p, end - p, &in, addr);
		if (!n) { p++; addr++; continue; }
		if (in.ent) {
			int vec = in.enc != 0;
			for (int i = 0; !vec && i < in.ent->nops; i++) vec = vector_kind(in.ent->ops[i]);
			if (vec) count[in.ent->mnem]++;
		}
		p += n;
		addr += n;
	}
}

static int bycount(const void *a, const void *b)
{
	uint64_t x = total[*(const uint16_t *)a], y = total[*(const uint16_t *)b];
	return x < y ? 1 : x > y ? -1 : 0;
}

static void report(const char *name, uint64_t *c)
{
	uint64_t vec = 0, miss = 0, kinds = 0, misskinds = 0;
	for (int i = 0; i < 4096; i++) {
		if (!c[i]) continue;
		vec += c[i];
		kinds++;
		if (!xl_tab[i]) { miss += c[i]; misskinds++; }
	}
	printf("%s: %llu vector instructions of %llu mnemonics; no recipe: %llu instructions of %llu mnemonics\n",
	       name, (unsigned long long)vec, (unsigned long long)kinds, (unsigned long long)miss, (unsigned long long)misskinds);
}

int main(int argc, char **argv)
{
	const char *fn = NULL;
	int i = 1;
	for (; i < argc && argv[i][0] == '-'; i++) {
		if (!strcmp(argv[i], "-f") && i + 1 < argc) fn = argv[++i];
		else if (!strcmp(argv[i], "-a")) all = 1;
		else { fprintf(stderr, "usage: recipe-census [-f FUNCTION] [-a] ELF...\n"); return 2; }
	}
	if (i >= argc) { fprintf(stderr, "usage: recipe-census [-f FUNCTION] [-a] ELF...\n"); return 2; }
	xl_init();
	for (; i < argc; i++) {
		int fd = open(argv[i], O_RDONLY);
		if (fd < 0) { perror(argv[i]); continue; }
		struct stat st;
		fstat(fd, &st);
		const uint8_t *f = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
		close(fd);
		if (f == MAP_FAILED) { perror("mmap"); continue; }
		const Elf64_Ehdr *eh = (const Elf64_Ehdr *)f;
		const Elf64_Shdr *sh = (const Elf64_Shdr *)(f + eh->e_shoff);
		const char *shstr = (const char *)(f + sh[eh->e_shstrndx].sh_offset);
		memset(count, 0, sizeof count);
		if (fn) {
			const Elf64_Shdr *symtab = NULL, *text = NULL;
			for (int s = 0; s < eh->e_shnum; s++)
				if (sh[s].sh_type == SHT_SYMTAB) symtab = &sh[s];
			if (!symtab) { fprintf(stderr, "%s: no .symtab\n", argv[i]); continue; }
			const Elf64_Sym *sym = (const Elf64_Sym *)(f + symtab->sh_offset);
			const char *str = (const char *)(f + sh[symtab->sh_link].sh_offset);
			int found = 0;
			for (uint64_t s = 0; s < symtab->sh_size / sizeof *sym; s++) {
				if (ELF64_ST_TYPE(sym[s].st_info) != STT_FUNC || strcmp(str + sym[s].st_name, fn) || !sym[s].st_shndx) continue;
				text = &sh[sym[s].st_shndx];
				const uint8_t *p = f + text->sh_offset + (sym[s].st_value - text->sh_addr);
				census(p, p + sym[s].st_size, sym[s].st_value);
				found = 1;
				break;
			}
			if (!found) { fprintf(stderr, "%s: no function %s\n", argv[i], fn); continue; }
		} else {
			for (int s = 0; s < eh->e_shnum; s++) {
				if (!(sh[s].sh_flags & SHF_EXECINSTR) || sh[s].sh_type != SHT_PROGBITS) continue;
				if (strcmp(shstr + sh[s].sh_name, ".text")) continue;
				census(f + sh[s].sh_offset, f + sh[s].sh_offset + sh[s].sh_size, sh[s].sh_addr);
			}
		}
		report(argv[i], count);
		for (int m = 0; m < 4096; m++) total[m] += count[m];
		munmap((void *)f, st.st_size);
	}
	uint16_t order[4096];
	int n = 0;
	for (int m = 0; m < 4096; m++) if (total[m]) order[n++] = m;
	qsort(order, n, sizeof *order, bycount);
	printf("-- by mnemonic (* = no recipe)\n");
	for (int k = 0; k < n; k++) {
		int m = order[k];
		if (xl_tab[m] && !all) continue;
		printf("%c %-20s %llu\n", xl_tab[m] ? ' ' : '*', x86_mnem_str + x86_mnem_off[m], (unsigned long long)total[m]);
	}
	report("total", total);
	return 0;
}
