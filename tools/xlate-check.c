/* xlate-check.c: a function of an ELF file translated to a blob by the
 * assembly translator (fnscan.S, blob.S, xlate.S, mvex.S over decode.S)
 * and written out, with the rip map, for reading and for the card:
 *
 *   as --64 -I host/asm/phi512 -o /tmp/x.o host/asm/phi512/{decode,fnscan,mvex,xlate,blob}.S   (one each)
 *   gcc -O2 -o xlate-check tools/xlate-check.c /tmp/blob.o /tmp/xlate.o /tmp/mvex.o /tmp/fnscan.o /tmp/decode.o
 *   xlate-check FILE FUNCTION [OUT.bin]
 *
 * Prints the function's size, the blob's size, the constants, and the
 * map (original offset -> blob offset) or the refusal and where; with
 * OUT.bin writes the blob (code, padding, constants) to the file, which
 * `objdump -D -b binary -m i386:x86-64 OUT.bin` reads (the MVEX
 * instructions come out as EVEX nonsense there; the scalar parts and the
 * structure read fine). The scratch area's fs offset is given as
 * SCRATCH_TPOFF (0x1000 for reading). See xlate-check.md. */
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

struct obj { uint64_t lo, hi, plt_lo, plt_hi; };
struct fn {
	uint64_t addr, size, name;
	uint32_t ninsn, flags;
	uint64_t insns;
	uint32_t counts[16];
	uint8_t pad[128 - 104];
};
struct blob {
	uint8_t *code, *code_lim, *out;
	uint8_t *consts;
	uint32_t nconst, const_cap;
	void *fix;
	uint32_t nfix, fix_cap;
	uint32_t *map;
	uint32_t nmap, pad0;
	void *brfix;
	uint32_t nbrfix, brfix_cap;
	struct fn *fn;
	const char *refused;
	uint32_t refused_off;
	int32_t scratch;
	uint8_t pad[128 - 112];
};
extern uint64_t fn_scan(const void *bytes, uint64_t size, uint64_t addr, struct fn *out, const struct obj *ob, void *index);
extern uint64_t blob_build(struct blob *bl, struct fn *fn, const void *bytes, const struct obj *ob);
/* blob.S's lazy sites of the last build: the offset, the exit kind (10
 * X_HOST: the host runs it; 5 X_REFUSED), the reason. */
extern uint64_t blob_lazy_n;
extern struct lazy { uint32_t off, kind; const char *why; } blob_lazy[];
/* main.S sets it from PHI512_INCALL; 0 here: blobs as the preload builds them by default (in-card calls) */
uint64_t incall_off = 0;
/* the code is translated from the file, not mapped at its addresses: plt_resolve must not read call targets */
extern uint64_t plt_resolve_off;
/* elf.S names PLT stubs in the running process; never reached here (plt_resolve_off) */
const char *plt_name(const void *stub) { (void)stub; return 0; }
extern uint64_t x86_decode(const void *bytes, uint64_t avail, void *out, uint64_t addr);

#define SCRATCH_TPOFF 0x1000

int main(int argc, char **argv)
{
	plt_resolve_off = 1;
	if (argc < 3) {
		fprintf(stderr, "usage: xlate-check FILE FUNCTION [OUT.bin]\n");
		return 2;
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
	const Elf64_Sym *s = NULL;
	for (int i = 0; i < nsyms; i++)
		if (ELF64_ST_TYPE(syms[i].st_info) == STT_FUNC && syms[i].st_size && !strcmp(strtab + syms[i].st_name, argv[2])) s = &syms[i];
	if (!s) { fprintf(stderr, "no function %s\n", argv[2]); return 1; }
	const Elf64_Shdr *sec = &sh[s->st_shndx];
	const uint8_t *bytes = f + sec->sh_offset + (s->st_value - sec->sh_addr);
	void *index = malloc(s->st_size * 16);
	struct fn fn;
	uint64_t rc = fn_scan(bytes, s->st_size, s->st_value, &fn, &ob, index);
	printf("%s: %llu bytes at %llx, %u instructions, scan flags %x rc %llu\n", argv[2], (unsigned long long)s->st_size,
		(unsigned long long)s->st_value, fn.ninsn, fn.flags, (unsigned long long)rc);
	if (rc) return 1;
	struct blob bl;
	memset(&bl, 0, sizeof bl);
	size_t cap = s->st_size * 64 + 65536;
	bl.code = malloc(cap);
	bl.code_lim = bl.code + cap;
	bl.consts = malloc(64 * 256);
	bl.const_cap = 256;
	bl.fix = malloc(16 * 1024);
	bl.fix_cap = 1024;
	bl.map = malloc(4 * fn.ninsn);
	bl.brfix = malloc(16 * 4096);
	bl.brfix_cap = 4096;
	bl.scratch = SCRATCH_TPOFF;
	rc = blob_build(&bl, &fn, bytes, &ob);
	if (rc) {
		struct { uint8_t b[72]; const struct x86_ent *ent; uint64_t pad[2]; } in;
		uint64_t n = x86_decode(bytes + bl.refused_off, s->st_size - bl.refused_off, &in, s->st_value + bl.refused_off);
		printf("REFUSED at +%u: %s (%s)\n", bl.refused_off, bl.refused, n && in.ent ? x86_mnem_str + x86_mnem_off[in.ent->mnem] : "?");
		return 1;
	}
	size_t len = bl.out - bl.code;
	printf("blob %zu bytes, %u constants, %u constant fixups, %u branch fixups\n", len, bl.nconst, bl.nfix, bl.nbrfix);
	for (uint64_t i = 0; i < blob_lazy_n && i < 256; i++) {
		struct { uint8_t b[72]; const struct x86_ent *ent; uint64_t pad[2]; } in;
		uint32_t off = blob_lazy[i].off;
		uint64_t n = x86_decode(bytes + off, s->st_size - off, &in, s->st_value + off);
		printf("LAZY at +%u (%s): %s: %s\n", off, n && in.ent ? x86_mnem_str + x86_mnem_off[in.ent->mnem] : "?",
			blob_lazy[i].kind == 10 ? "the host runs it" : "refused where the card reaches it", blob_lazy[i].why);
	}
	for (uint32_t i = 0; i < fn.ninsn; i++) {
		const uint8_t *ix = (const uint8_t *)index + i * 16;
		uint32_t off = *(const uint32_t *)ix;
		printf("  +%u -> blob +%u (len %u kind %u)\n", off, bl.map[i], ix[4], ix[5]);
	}
	if (argc > 3) {
		FILE *o = fopen(argv[3], "wb");
		if (!o) { perror(argv[3]); return 1; }
		fwrite(bl.code, 1, len, o);
		fclose(o);
		printf("wrote %s\n", argv[3]);
	}
	return 0;
}
