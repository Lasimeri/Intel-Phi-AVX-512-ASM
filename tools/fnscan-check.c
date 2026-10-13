/* fnscan-check.c: fnscan.S over every function of an ELF file: the
 * census line per function (name, address, size, instructions, and the
 * counts by kind), the totals, and with `--function NAME` the index of
 * one function (offset, length, kind, flags, target) to read against
 * objdump. The file is mapped, not loaded: the bytes are read at their
 * file offsets and the addresses are the file's virtual addresses, which
 * is what fn_scan takes.
 *
 *   as --64 -I host/asm/phi512 -o /tmp/decode.o host/asm/phi512/decode.S
 *   as --64 -I host/asm/phi512 -o /tmp/fnscan.o host/asm/phi512/fnscan.S
 *   gcc -O2 -o /tmp/fnscan-check tools/fnscan-check.c /tmp/fnscan.o /tmp/decode.o
 *   /tmp/fnscan-check libggml-cpu.so [--function NAME] [--evex]
 *
 * `--evex` lists only the functions with EVEX instructions. See
 * fnscan-check.md. */
#include <elf.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

struct obj { uint64_t lo, hi, plt_lo, plt_hi; };
struct fn {
	uint64_t addr, size, name;
	uint32_t ninsn, flags;
	uint64_t insns;
	uint32_t nevex, nvex, ncall, nplt, nicall, nijmp, nbrout, nlock, ntrap, nfs, nunk, nrip, fail_off, nlabel, nbrin, nret;
	uint8_t pad[128 - 104];
};
struct ix { uint32_t off; uint8_t len, kind, flags, pad; uint64_t tgt; };
extern uint64_t fn_scan(const void *bytes, uint64_t size, uint64_t addr, struct fn *out, const struct obj *ob, void *index);

static const char *kinds[] = { "copy", "evex", "vex", "br-in", "br-out", "call", "plt", "icall", "ijmp", "ret", "trap", "far" };

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: fnscan-check ELF [--function NAME] [--evex]\n");
		return 2;
	}
	const char *want = NULL;
	int evex_only = 0;
	for (int i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "--function") && i + 1 < argc) want = argv[++i];
		else if (!strcmp(argv[i], "--evex")) evex_only = 1;
	}
	int fd = open(argv[1], O_RDONLY);
	if (fd < 0) { perror(argv[1]); return 1; }
	struct stat st;
	fstat(fd, &st);
	const uint8_t *f = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (f == MAP_FAILED) { perror("mmap"); return 1; }
	const Elf64_Ehdr *eh = (const Elf64_Ehdr *)f;
	const Elf64_Shdr *sh = (const Elf64_Shdr *)(f + eh->e_shoff);
	const char *shstr = (const char *)(f + sh[eh->e_shstrndx].sh_offset);
	const Elf64_Shdr *symtab = NULL, *plt = NULL, *pltsec = NULL;
	struct obj ob = { 0, 0, 0, 0 };
	for (int i = 0; i < eh->e_shnum; i++) {
		const char *n = shstr + sh[i].sh_name;
		if (sh[i].sh_type == SHT_SYMTAB) symtab = &sh[i];
		if (!strcmp(n, ".plt")) plt = &sh[i];
		if (!strcmp(n, ".plt.sec")) pltsec = &sh[i];
		if ((sh[i].sh_flags & SHF_ALLOC) && sh[i].sh_addr + sh[i].sh_size > ob.hi) ob.hi = sh[i].sh_addr + sh[i].sh_size;
	}
	if (!symtab) { fprintf(stderr, "no .symtab\n"); return 1; }
	if (pltsec) { ob.plt_lo = pltsec->sh_addr; ob.plt_hi = pltsec->sh_addr + pltsec->sh_size; }
	else if (plt) { ob.plt_lo = plt->sh_addr; ob.plt_hi = plt->sh_addr + plt->sh_size; }
	const Elf64_Sym *syms = (const Elf64_Sym *)(f + symtab->sh_offset);
	int nsyms = symtab->sh_size / sizeof(Elf64_Sym);
	const char *strtab = (const char *)(f + sh[symtab->sh_link].sh_offset);
	static char out[1 << 16];
	setvbuf(stdout, out, _IOFBF, sizeof out);
	struct fn tot;
	memset(&tot, 0, sizeof tot);
	int nfn = 0, nfail = 0, nbad = 0;
	void *index = NULL;
	size_t index_cap = 0;
	for (int i = 0; i < nsyms; i++) {
		const Elf64_Sym *s = &syms[i];
		if (ELF64_ST_TYPE(s->st_info) != STT_FUNC || s->st_size == 0 || s->st_shndx == SHN_UNDEF) continue;
		const char *name = strtab + s->st_name;
		if (want && strcmp(name, want)) continue;
		/* an alias of a function already scanned (two names at one address) */
		int dup = 0;
		for (int j = 0; j < i && !dup; j++)
			if (ELF64_ST_TYPE(syms[j].st_info) == STT_FUNC && syms[j].st_size && syms[j].st_value == s->st_value) dup = 1;
		if (dup) continue;
		const Elf64_Shdr *sec = &sh[s->st_shndx];
		const uint8_t *bytes = f + sec->sh_offset + (s->st_value - sec->sh_addr);
		if (index_cap < s->st_size * 16) {
			index_cap = s->st_size * 16;
			index = realloc(index, index_cap);
		}
		struct fn fn;
		uint64_t rc = fn_scan(bytes, s->st_size, s->st_value, &fn, &ob, index);
		nfn++;
		if (fn.flags & 1) nfail++;
		if (fn.flags & 2) nbad++;
		tot.ninsn += fn.ninsn; tot.nevex += fn.nevex; tot.nvex += fn.nvex; tot.ncall += fn.ncall; tot.nplt += fn.nplt;
		tot.nicall += fn.nicall; tot.nijmp += fn.nijmp; tot.nbrout += fn.nbrout; tot.nlock += fn.nlock; tot.ntrap += fn.ntrap;
		tot.nfs += fn.nfs; tot.nunk += fn.nunk; tot.nrip += fn.nrip; tot.nlabel += fn.nlabel; tot.nbrin += fn.nbrin; tot.nret += fn.nret;
		if (evex_only && !fn.nevex) continue;
		printf("%s %llx %llu insn %u evex %u vex %u call %u plt %u icall %u ijmp %u brin %u brout %u ret %u lock %u trap %u fs %u unk %u rip %u label %u flags %x rc %llu\n",
			name, (unsigned long long)s->st_value, (unsigned long long)s->st_size, fn.ninsn, fn.nevex, fn.nvex, fn.ncall, fn.nplt,
			fn.nicall, fn.nijmp, fn.nbrin, fn.nbrout, fn.nret, fn.nlock, fn.ntrap, fn.nfs, fn.nunk, fn.nrip, fn.nlabel, fn.flags, (unsigned long long)rc);
		if (want) {
			const struct ix *ix = index;
			for (uint32_t k = 0; k < fn.ninsn; k++)
				printf("  %llx +%u len %u %s%s%s%s%s%s%s%s\n", (unsigned long long)(s->st_value + ix[k].off), ix[k].off, ix[k].len, kinds[ix[k].kind],
					(ix[k].flags & 1) ? " label" : "", (ix[k].flags & 2) ? " rip" : "", (ix[k].flags & 4) ? " lock" : "",
					(ix[k].flags & 8) ? " fs" : "", (ix[k].flags & 16) ? " unk" : "", (ix[k].flags & 32) ? " cond" : "",
					ix[k].tgt ? " -> " : "");
		}
	}
	printf("TOTAL functions %d failed %d badtarget %d insn %u evex %u vex %u call %u plt %u icall %u ijmp %u brin %u brout %u ret %u lock %u trap %u fs %u unk %u rip %u label %u\n",
		nfn, nfail, nbad, tot.ninsn, tot.nevex, tot.nvex, tot.ncall, tot.nplt, tot.nicall, tot.nijmp, tot.nbrin, tot.nbrout, tot.nret, tot.nlock, tot.ntrap, tot.nfs, tot.nunk, tot.nrip, tot.nlabel);
	fflush(stdout);
	return 0;
}
