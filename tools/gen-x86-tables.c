/* gen-x86-tables.c: the x86-64 decoder's tables, from the listing
 * tools/x86-opcodes.txt (one line per instruction code iced-x86 knows,
 * written by `avx512-xlate --gen-opcodes`) into the assembly include
 * host/asm/phi512/x86tab.inc that decode.S reads, and the C header
 * host/asm/phi512/x86tab.h that tools/decode-check.c reads:
 *
 *   tcc -run tools/gen-x86-tables.c tools/x86-opcodes.txt host/asm/phi512/x86tab.inc host/asm/phi512/x86tab.h host/asm/phi512/x86mnem.inc
 *
 * Two tables come out. The length table (x86_len_tab, eight maps of 256
 * entries of 4 bytes: legacy one-byte, 0F, 0F38, 0F3A, then the VEX/EVEX
 * 0F, 0F38, 0F3A) says per opcode byte whether a ModRM byte follows, how
 * many immediate bytes at each operand size, the flow class, and whether
 * the answer depends on ModRM.reg (then a subtable of eight entries in
 * x86_grp_tab). The entry table (x86_ent, 24 bytes each) holds every
 * code: W, L, the ModRM.reg group, a fixed r/m value (the two-byte
 * opcodes like 0F AE E8), register-only or memory-only, the disp8*N scale
 * without and with broadcast, flags, the operand size, the operand kinds
 * in iced's numbering, and the indexes of the code's and mnemonic's names
 * in the string tables; x86_idx (encoding, map, prefix, opcode) gives the
 * first entry of a key, the entries of one key are consecutive and the
 * last carries EF_LAST. See gen-x86-tables.md. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* iced's OpCodeOperandKind, in its numbering (docs.rs/iced-x86 1.21). */
static const char *opkind_names[] = {
	"None", "farbr2_2", "farbr4_2", "mem_offs", "mem", "mem_mpx", "mem_mib", "mem_vsib32x", "mem_vsib64x",
	"mem_vsib32y", "mem_vsib64y", "mem_vsib32z", "mem_vsib64z", "r8_or_mem", "r16_or_mem", "r32_or_mem",
	"r32_or_mem_mpx", "r64_or_mem", "r64_or_mem_mpx", "mm_or_mem", "xmm_or_mem", "ymm_or_mem", "zmm_or_mem",
	"bnd_or_mem_mpx", "k_or_mem", "r8_reg", "r8_opcode", "r16_reg", "r16_reg_mem", "r16_rm", "r16_opcode",
	"r32_reg", "r32_reg_mem", "r32_rm", "r32_opcode", "r32_vvvv", "r64_reg", "r64_reg_mem", "r64_rm",
	"r64_opcode", "r64_vvvv", "seg_reg", "k_reg", "kp1_reg", "k_rm", "k_vvvv", "mm_reg", "mm_rm", "xmm_reg",
	"xmm_rm", "xmm_vvvv", "xmmp3_vvvv", "xmm_is4", "xmm_is5", "ymm_reg", "ymm_rm", "ymm_vvvv", "ymm_is4",
	"ymm_is5", "zmm_reg", "zmm_rm", "zmm_vvvv", "zmmp3_vvvv", "cr_reg", "dr_reg", "tr_reg", "bnd_reg", "es",
	"cs", "ss", "ds", "fs", "gs", "al", "cl", "ax", "dx", "eax", "rax", "st0", "sti_opcode", "imm4_m2z",
	"imm8", "imm8_const_1", "imm8sex16", "imm8sex32", "imm8sex64", "imm16", "imm32", "imm32sex64", "imm64",
	"seg_rSI", "es_rDI", "seg_rDI", "seg_rBX_al", "br16_1", "br32_1", "br64_1", "br16_2", "br32_4", "br64_4",
	"xbegin_2", "xbegin_4", "brdisp_2", "brdisp_4", "sibmem", "tmm_reg", "tmm_rm", "tmm_vvvv",
};
#define NOPKINDS (sizeof opkind_names / sizeof opkind_names[0])

enum {
	OK_mem_offs = 3, OK_mem = 4, OK_mem_vsib32x = 7, OK_mem_vsib64z = 12, OK_r8_or_mem = 13, OK_k_or_mem = 24,
	OK_r8_reg = 25, OK_r8_opcode = 26, OK_r16_reg = 27, OK_r16_rm = 29, OK_r16_opcode = 30, OK_r32_reg = 31,
	OK_r32_rm = 33, OK_r32_opcode = 34, OK_r64_reg = 36, OK_r64_rm = 38, OK_r64_opcode = 39, OK_seg_reg = 41,
	OK_k_reg = 42, OK_kp1_reg = 43, OK_k_rm = 44, OK_mm_reg = 46, OK_mm_rm = 47, OK_xmm_reg = 48, OK_xmm_rm = 49,
	OK_xmm_is4 = 52, OK_xmm_is5 = 53, OK_ymm_reg = 54, OK_ymm_rm = 55, OK_ymm_is4 = 57, OK_ymm_is5 = 58,
	OK_zmm_reg = 59, OK_zmm_rm = 60, OK_cr_reg = 63, OK_dr_reg = 64, OK_tr_reg = 65, OK_bnd_reg = 66,
	OK_sti_opcode = 80, OK_imm4_m2z = 81, OK_imm8 = 82, OK_imm8_const_1 = 83, OK_imm8sex16 = 84,
	OK_imm8sex32 = 85, OK_imm8sex64 = 86, OK_imm16 = 87, OK_imm32 = 88, OK_imm32sex64 = 89, OK_imm64 = 90,
	OK_br16_1 = 95, OK_br32_1 = 96, OK_br64_1 = 97, OK_br16_2 = 98, OK_br32_4 = 99, OK_br64_4 = 100,
	OK_xbegin_2 = 101, OK_xbegin_4 = 102, OK_brdisp_2 = 103, OK_brdisp_4 = 104, OK_sibmem = 105,
	OK_tmm_reg = 106, OK_tmm_rm = 107,
};

/* Length table flags and layout (decode.S mirrors these in x86dec.inc). */
#define LT_MODRM 1
#define LT_GROUP 2
#define LT_D64 4
#define LT_INVALID 8
#define LT_PFX 16
#define LT_ESC 32
#define LT_F64 64
#define LT_X87 128
#define LI_REL 0x10	/* LT_IMM64 high nibble: the immediate is a branch displacement */
#define LI_MOFFS 0x20	/* a 64-bit memory offset (32 under a 67 prefix) */
/* Flow classes. */
enum { FL_NEXT, FL_JCC, FL_JMP, FL_CALL, FL_RET, FL_JMPI, FL_CALLI, FL_TRAP, FL_LOOP, FL_FAR };
/* Entry flags. */
#define EF_B 1
#define EF_Z 2
#define EF_K 4
#define EF_KREQ 8
#define EF_RC 16
#define EF_SAE 32
#define EF_LOCK 64
#define EF_LAST 128
/* Entry byte 15: the address size (bits 0 and 1: 0 any, 1 32-bit, 2 64-bit) and the operand-size defaults. */
#define EX_D64 4
#define EX_F64 8

struct code {
	int enc;		/* 0 legacy, 1 VEX, 2 EVEX */
	int map;		/* 0 one-byte, 1 0F, 2 0F38, 3 0F3A */
	int pp;			/* 0 none, 1 66, 2 F3, 3 F2 */
	int op;			/* the opcode byte */
	int grp;		/* ModRM.reg or -1 */
	int rmfix;		/* ModRM.rm when the second opcode byte fixes it, else -1 */
	int modreq;		/* 0 any, 1 register, 2 memory */
	int w, l;		/* 0/1, 2 = any; 0/1/2, 3 = any */
	int n, nb;		/* disp8 scale without and with broadcast */
	int flags;
	int opsize;		/* 0 any, 2, 4, 8 bytes */
	int asize;		/* 0 any, 1 32-bit addressing, 2 64-bit */
	int nops;
	int ops[5];
	int immbytes;		/* bytes of immediates */
	int rel, moffs, d64, f64;
	int flow;
	int code, mnem;		/* string table indexes */
	int order;
	int has_modrm;
	int is_mvex_src;	/* unused */
};

static struct code codes[16384];
static int ncodes;
static char *names[16384];
static int nnames;
static char *mnems[4096];
static int nmnems;

static int intern(char **tab, int *n, const char *s)
{
	for (int i = 0; i < *n; i++)
		if (!strcmp(tab[i], s))
			return i;
	tab[*n] = strdup(s);
	return (*n)++;
}

static int opkind(const char *s)
{
	for (unsigned i = 0; i < NOPKINDS; i++)
		if (!strcmp(opkind_names[i], s))
			return i;
	fprintf(stderr, "gen-x86-tables: unknown operand kind %s\n", s);
	exit(1);
}

static int is_modrm_kind(int k)
{
	if (k == OK_mem || k == OK_mem_offs) return k == OK_mem;
	if (k >= 5 && k <= OK_k_or_mem) return 1;		/* mem_mpx .. k_or_mem */
	if (k == OK_r8_reg || k == OK_r16_reg || k == 28 || k == OK_r16_rm || k == OK_r32_reg || k == 32 ||
	    k == OK_r32_rm || k == OK_r64_reg || k == 37 || k == OK_r64_rm || k == OK_seg_reg || k == OK_k_reg ||
	    k == OK_kp1_reg || k == OK_k_rm || k == OK_mm_reg || k == OK_mm_rm || k == OK_xmm_reg || k == OK_xmm_rm ||
	    k == OK_ymm_reg || k == OK_ymm_rm || k == OK_zmm_reg || k == OK_zmm_rm || k == OK_cr_reg ||
	    k == OK_dr_reg || k == OK_tr_reg || k == OK_bnd_reg || k == OK_sibmem || k == OK_tmm_reg || k == OK_tmm_rm)
		return 1;
	return 0;
}

static int is_mem_only(int k)
{
	return k == OK_mem || (k >= 5 && k <= OK_mem_vsib64z) || k == OK_sibmem;
}

static int is_reg_only(int k)
{
	return k == OK_r16_rm || k == OK_r32_rm || k == OK_r64_rm || k == OK_k_rm || k == OK_mm_rm ||
	       k == OK_xmm_rm || k == OK_ymm_rm || k == OK_zmm_rm || k == OK_tmm_rm;
}

static int is_rm_any(int k)
{
	return k >= OK_r8_or_mem && k <= OK_k_or_mem;
}

static int tuple_n(const char *t, int *nb)
{
	int n, b = 0;
	if (sscanf(t, "N%db%d", &n, &b) < 1) {
		fprintf(stderr, "gen-x86-tables: tuple %s\n", t);
		exit(1);
	}
	*nb = b;
	return n;
}

static int flow_of(const char *mnem, const struct code *c)
{
	int hasrel = c->rel;
	if (!strcmp(mnem, "Jmp")) return hasrel ? FL_JMP : (c->ops[0] == OK_mem || c->ops[0] == 1 || c->ops[0] == 2 ? FL_FAR : FL_JMPI);
	if (!strcmp(mnem, "Call")) return hasrel ? FL_CALL : (c->ops[0] == OK_mem || c->ops[0] == 1 || c->ops[0] == 2 ? FL_FAR : FL_CALLI);
	if (!strncmp(mnem, "Ret", 3)) return c->code >= 0 && strstr(names[c->code], "Retf") ? FL_FAR : FL_RET;
	if (!strcmp(mnem, "Jrcxz") || !strcmp(mnem, "Jecxz") || !strncmp(mnem, "Loop", 4)) return FL_LOOP;
	if (mnem[0] == 'J' && hasrel) return FL_JCC;
	if (!strcmp(mnem, "Syscall") || !strcmp(mnem, "Int3") || !strcmp(mnem, "Int") || !strcmp(mnem, "Into") ||
	    !strcmp(mnem, "Hlt") || !strcmp(mnem, "Ud2") || !strcmp(mnem, "Ud0") || !strcmp(mnem, "Ud1") ||
	    !strcmp(mnem, "Int1"))
		return FL_TRAP;
	if (!strncmp(mnem, "Iret", 4) || !strncmp(mnem, "Sysret", 6) || !strcmp(mnem, "Sysexit") || !strcmp(mnem, "Sysenter"))
		return FL_FAR;
	return FL_NEXT;
}

static void parse_line(char *line)
{
	char *f[18];
	int nf = 0;
	for (char *p = strtok(line, "\t\n"); p && nf < 18; p = strtok(NULL, "\t\n"))
		f[nf++] = p;
	if (nf < 16) {
		fprintf(stderr, "gen-x86-tables: short line: %s\n", f[0]);
		exit(1);
	}
	struct code c;
	memset(&c, 0, sizeof c);
	c.grp = -1;
	c.rmfix = -1;
	if (!strcmp(f[0], "Legacy")) c.enc = 0;
	else if (!strcmp(f[0], "VEX")) c.enc = 1;
	else if (!strcmp(f[0], "EVEX")) c.enc = 2;
	else return;
	if (!strcmp(f[1], "Normal")) c.map = 0;
	else if (!strcmp(f[1], "T0F")) c.map = 1;
	else if (!strcmp(f[1], "T0F38")) c.map = 2;
	else if (!strcmp(f[1], "T0F3A")) c.map = 3;
	else return;					/* MAP5/MAP6: AVX512-FP16, not decoded */
	if (!strcmp(f[2], "None") || !strcmp(f[2], "PNP")) c.pp = 0;
	else if (!strcmp(f[2], "P66")) c.pp = 1;
	else if (!strcmp(f[2], "PF3")) c.pp = 2;
	else if (!strcmp(f[2], "PF2")) c.pp = 3;
	else { fprintf(stderr, "gen-x86-tables: prefix %s\n", f[2]); exit(1); }
	int opcode = (int)strtol(f[3], NULL, 16);
	int oplen = atoi(f[4]);
	c.grp = atoi(f[5]);
	c.w = f[7][0] == 'W' ? 2 : atoi(f[7]);
	c.l = f[8][0] == 'L' ? 3 : atoi(f[8]);
	c.n = tuple_n(f[9], &c.nb);
	for (const char *p = f[10]; *p; p++) {
		switch (*p) {
		case 'b': c.flags |= EF_B; break;
		case 'z': c.flags |= EF_Z; break;
		case 'k': c.flags |= EF_K; break;
		case 'K': c.flags |= EF_KREQ; break;
		case 'r': c.flags |= EF_RC; break;
		case 'e': c.flags |= EF_SAE; break;
		case 'l': c.flags |= EF_LOCK; break;
		case 'D': c.d64 = 1; break;
		case 'F': c.f64 = 1; break;
		default: break;
		}
	}
	if (!(c.flags & EF_B)) c.nb = 0;
	int os = atoi(f[11]);
	c.opsize = os == 16 ? 2 : os == 32 ? 4 : os == 64 ? 8 : 0;
	int as = atoi(f[12]);
	c.asize = as == 32 ? 1 : as == 64 ? 2 : 0;
	int plus_r = 0, has_is4 = 0;
	if (strcmp(f[13], "-")) {
		char *ops = strdup(f[13]);
		for (char *p = strtok(ops, ","); p; p = strtok(NULL, ",")) {
			int k = opkind(p);
			if (c.nops < 5) c.ops[c.nops++] = k;
			if (is_modrm_kind(k)) c.has_modrm = 1;
			if (is_mem_only(k)) c.modreq = 2;
			if (is_reg_only(k) && c.modreq == 0) c.modreq = 1;
			if (k == OK_r8_opcode || k == OK_r16_opcode || k == OK_r32_opcode || k == OK_r64_opcode) plus_r = 1;
			switch (k) {
			case OK_imm8: case OK_imm8sex16: case OK_imm8sex32: case OK_imm8sex64: c.immbytes += 1; break;
			case OK_imm16: c.immbytes += 2; break;
			case OK_imm32: case OK_imm32sex64: c.immbytes += 4; break;
			case OK_imm64: c.immbytes += 8; break;
			case OK_br16_1: case OK_br32_1: case OK_br64_1: c.immbytes += 1; c.rel = 1; break;
			case OK_br16_2: case OK_xbegin_2: case OK_brdisp_2: c.immbytes += 2; c.rel = 1; break;
			case OK_br32_4: case OK_br64_4: case OK_xbegin_4: case OK_brdisp_4: c.immbytes += 4; c.rel = 1; break;
			case OK_mem_offs: c.immbytes += 8; c.moffs = 1; break;
			case OK_xmm_is4: case OK_xmm_is5: case OK_ymm_is4: case OK_ymm_is5: case OK_imm4_m2z: has_is4 = 1; break;
			default: break;
			}
		}
		free(ops);
	}
	if (has_is4) c.immbytes += 1;
	if (c.grp >= 0) c.has_modrm = 1;
	if (oplen == 2) {
		int second = opcode & 0xff;
		opcode >>= 8;
		if (second < 0xc0) { fprintf(stderr, "gen-x86-tables: two-byte opcode %04x not a ModRM form (%s)\n", opcode << 8 | second, f[15]); exit(1); }
		c.has_modrm = 1;
		c.modreq = 1;
		c.grp = (second >> 3) & 7;
		int sti = 0;
		for (int i = 0; i < c.nops; i++) if (c.ops[i] == OK_sti_opcode) sti = 1;
		c.rmfix = sti ? -1 : second & 7;
	}
	if (c.enc == 0 && c.map == 0 && opcode >= 0xd8 && opcode <= 0xdf) c.has_modrm = 1;
	c.code = intern(names, &nnames, f[15]);
	c.mnem = intern(mnems, &nmnems, f[14]);
	c.flow = flow_of(f[14], &c);
	int count = plus_r ? 8 : 1;
	for (int i = 0; i < count; i++) {
		c.op = (plus_r ? (opcode & ~7) : opcode) + i;
		c.order = ncodes;
		codes[ncodes++] = c;
	}
}

static int specificity(const struct code *c)
{
	int s = 0;
	if (c->rmfix >= 0) s += 16;
	if (c->grp >= 0) s += 8;
	if (c->modreq) s += 4;
	if (c->opsize) s += 2;
	if (c->asize) s += 2;
	if (c->w != 2) s += 1;
	if (c->l != 3) s += 1;
	return s;
}

static int key_of(const struct code *c)
{
	return ((c->enc * 4 + c->map) * 4 + c->pp) * 256 + c->op;
}

static int cmp_codes(const void *a, const void *b)
{
	const struct code *x = a, *y = b;
	int kx = key_of(x), ky = key_of(y);
	if (kx != ky) return kx - ky;
	int sx = specificity(x), sy = specificity(y);
	if (sx != sy) return sy - sx;
	return x->order - y->order;
}

/* The length table: per (map index 0..6, opcode) the union of the codes. */
struct lt { int flags, imm16, imm32, imm64, rel, moffs, flow, grp; int seen; int sub; int subseen; };
static struct lt lt[7][256];
static struct lt grp[256][8];
static int ngrp;

static void lt_add(struct lt *t, const struct code *c)
{
	t->seen = 1;
	if (c->has_modrm) t->flags |= LT_MODRM;
	if (c->d64) t->flags |= LT_D64;
	if (c->f64) t->flags |= LT_F64;
	int ib = c->immbytes;
	if (c->opsize == 0 || c->opsize == 2) { if (t->imm16 >= 0 && t->imm16 != ib && t->imm16 != 0) {} t->imm16 = ib > t->imm16 ? ib : t->imm16; }
	if (c->opsize == 0 || c->opsize == 4) t->imm32 = ib > t->imm32 ? ib : t->imm32;
	if (c->opsize == 0 || c->opsize == 8) t->imm64 = ib > t->imm64 ? ib : t->imm64;
	if (c->rel) t->rel = 1;
	if (c->moffs) t->moffs = 1;
	if (c->flow != FL_NEXT && (t->flow == FL_NEXT || t->flow == c->flow)) t->flow = c->flow;
	else if (c->flow != FL_NEXT && t->flow != c->flow) t->flow = c->flow;	/* the group resolves it */
}

static int main_(int argc, char **argv)
{
	if (argc != 5) {
		fprintf(stderr, "usage: gen-x86-tables LISTING OUT.inc OUT.h MNEM.inc\n");
		return 2;
	}
	FILE *in = fopen(argv[1], "r");
	if (!in) { perror(argv[1]); return 1; }
	char line[4096];
	while (fgets(line, sizeof line, in)) {
		if (line[0] == '#' || line[0] == '\n') continue;
		parse_line(line);
	}
	fclose(in);
	qsort(codes, ncodes, sizeof codes[0], cmp_codes);

	/* The length tables. Map index: legacy map 0..3 = 0..3; VEX/EVEX map 1..3 = 4..6. */
	for (int m = 0; m < 7; m++) for (int o = 0; o < 256; o++) { lt[m][o].imm16 = lt[m][o].imm32 = lt[m][o].imm64 = 0; lt[m][o].flow = FL_NEXT; }
	for (int i = 0; i < ncodes; i++) {
		const struct code *c = &codes[i];
		int m = c->enc == 0 ? c->map : 3 + c->map;
		if (c->enc != 0 && c->map == 0) continue;
		struct lt *t = &lt[m][c->op];
		lt_add(t, c);
	}
	/* Where the codes of one opcode differ by ModRM.reg in immediate bytes, flow,
	 * or default size, a group subtable. Decided per opcode by comparing the
	 * per-group unions. */
	for (int m = 0; m < 7; m++) for (int o = 0; o < 256; o++) {
		struct lt *t = &lt[m][o];
		if (!t->seen || !(t->flags & LT_MODRM)) continue;
		struct lt g[8];
		memset(g, 0, sizeof g);
		for (int r = 0; r < 8; r++) g[r].flow = FL_NEXT;
		int any_grp = 0;
		for (int i = 0; i < ncodes; i++) {
			const struct code *c = &codes[i];
			int cm = c->enc == 0 ? c->map : 3 + c->map;
			if (cm != m || c->op != o) continue;
			if (c->grp < 0) { for (int r = 0; r < 8; r++) lt_add(&g[r], c); }
			else { any_grp = 1; lt_add(&g[c->grp], c); }
		}
		if (!any_grp) continue;
		int differ = 0;
		for (int r = 1; r < 8; r++)
			if (g[r].imm16 != g[0].imm16 || g[r].imm32 != g[0].imm32 || g[r].imm64 != g[0].imm64 ||
			    g[r].flow != g[0].flow || g[r].rel != g[0].rel || (g[r].flags & (LT_D64 | LT_F64)) != (g[0].flags & (LT_D64 | LT_F64)))
				differ = 1;
		if (!differ) continue;
		t->flags |= LT_GROUP;
		t->sub = ngrp;
		for (int r = 0; r < 8; r++) { grp[ngrp][r] = g[r]; grp[ngrp][r].flags |= LT_MODRM; }
		ngrp++;
	}
	/* The one-byte map's bytes that are prefixes or escapes. */
	static const int pfx[] = { 0x26, 0x2e, 0x36, 0x3e, 0x64, 0x65, 0x66, 0x67, 0xf0, 0xf2, 0xf3 };
	for (unsigned i = 0; i < sizeof pfx / sizeof pfx[0]; i++) lt[0][pfx[i]].flags |= LT_PFX;
	for (int i = 0x40; i <= 0x4f; i++) lt[0][i].flags |= LT_PFX;
	lt[0][0x0f].flags |= LT_ESC;
	lt[0][0xc4].flags |= LT_ESC;
	lt[0][0xc5].flags |= LT_ESC;
	lt[0][0x62].flags |= LT_ESC;
	lt[1][0x38].flags |= LT_ESC;
	lt[1][0x3a].flags |= LT_ESC;
	for (int o = 0xd8; o <= 0xdf; o++) lt[0][o].flags |= LT_X87 | LT_MODRM;
	for (int m = 0; m < 7; m++) for (int o = 0; o < 256; o++)
		if (!lt[m][o].seen && !(lt[m][o].flags & (LT_PFX | LT_ESC | LT_X87))) lt[m][o].flags |= LT_INVALID;

	/* The index: first entry per key. */
	static int idx[3 * 4 * 4 * 256];
	for (int i = 0; i < 3 * 4 * 4 * 256; i++) idx[i] = -1;
	for (int i = 0; i < ncodes; i++) {
		int k = key_of(&codes[i]);
		if (idx[k] < 0) idx[k] = i;
	}

	FILE *out = fopen(argv[2], "w");
	if (!out) { perror(argv[2]); return 1; }
	fprintf(out, "# x86tab.inc: the decoder's tables, generated by tools/gen-x86-tables.c from\n");
	fprintf(out, "# tools/x86-opcodes.txt (%d codes, %d entries, %d group subtables). Do not edit.\n", nnames, ncodes, ngrp);
	fprintf(out, "\t.section .rodata\n\t.balign 64\n\t.globl x86_len_tab, x86_grp_tab, x86_idx, x86_ent, x86_nent\n");
	fprintf(out, "\t.globl x86_code_off, x86_code_str, x86_mnem_off, x86_mnem_str\n");
	fprintf(out, "x86_len_tab:\n");
	static const char *mapname[] = { "legacy one-byte", "legacy 0F", "legacy 0F38", "legacy 0F3A", "VEX/EVEX 0F", "VEX/EVEX 0F38", "VEX/EVEX 0F3A", "unused" };
	for (int m = 0; m < 8; m++) {
		fprintf(out, "# map %d: %s\n", m, mapname[m]);
		for (int o = 0; o < 256; o++) {
			struct lt *t = m < 7 ? &lt[m][o] : NULL;
			int b0 = t ? t->flags : LT_INVALID;
			int b1 = 0, b2 = 0, b3 = 0;
			if (t && (t->flags & LT_GROUP)) { b1 = t->sub; }
			else if (t) { b1 = (t->imm32 & 15) | ((t->imm16 & 15) << 4); b2 = (t->imm64 & 15) | (t->rel ? LI_REL : 0) | (t->moffs ? LI_MOFFS : 0); b3 = t->flow; }
			fprintf(out, "\t.byte 0x%02x, 0x%02x, 0x%02x, 0x%02x\t# %02x\n", b0, b1, b2, b3, o);
		}
	}
	fprintf(out, "\t.balign 64\nx86_grp_tab:\n");
	for (int g = 0; g < ngrp; g++) {
		fprintf(out, "# subtable %d\n", g);
		for (int r = 0; r < 8; r++) {
			struct lt *t = &grp[g][r];
			int b0 = t->flags | (t->seen ? 0 : LT_INVALID);
			int b1 = (t->imm32 & 15) | ((t->imm16 & 15) << 4);
			int b2 = (t->imm64 & 15) | (t->rel ? LI_REL : 0) | (t->moffs ? LI_MOFFS : 0);
			fprintf(out, "\t.byte 0x%02x, 0x%02x, 0x%02x, 0x%02x\n", b0, b1, b2, t->flow);
		}
	}
	fprintf(out, "\t.balign 64\nx86_idx:\n");
	for (int i = 0; i < 3 * 4 * 4 * 256; i += 8) {
		fprintf(out, "\t.short ");
		for (int j = 0; j < 8; j++) fprintf(out, "%s0x%04x", j ? ", " : "", idx[i + j] < 0 ? 0xffff : idx[i + j]);
		fprintf(out, "\n");
	}
	fprintf(out, "\t.balign 64\nx86_ent:\n");
	for (int i = 0; i < ncodes; i++) {
		const struct code *c = &codes[i];
		int last = i + 1 >= ncodes || key_of(&codes[i + 1]) != key_of(c);
		fprintf(out, "\t.byte %d, %d, %d, %d, %d, %d, %d, 0x%02x, %d, %d, %d, %d, %d, %d, %d, %d\n\t.short %d, %d, 0, 0\t# %s\n",
			c->w, c->l, c->grp < 0 ? 255 : c->grp, c->rmfix < 0 ? 255 : c->rmfix, c->modreq, c->n & 255, c->nb & 255,
			c->flags | (last ? EF_LAST : 0), c->opsize, c->nops, c->ops[0], c->ops[1], c->ops[2], c->ops[3], c->ops[4],
			c->asize | (c->d64 ? EX_D64 : 0) | (c->f64 ? EX_F64 : 0),
			c->code, c->mnem, names[c->code]);
	}
	fprintf(out, "x86_nent:\t.quad %d\n", ncodes);
	fprintf(out, "\t.balign 64\nx86_code_off:\n");
	int off = 0;
	for (int i = 0; i < nnames; i++) { fprintf(out, "\t.long %d\n", off); off += strlen(names[i]) + 1; }
	fprintf(out, "x86_code_str:\n");
	for (int i = 0; i < nnames; i++) fprintf(out, "\t.asciz \"%s\"\n", names[i]);
	fprintf(out, "\t.balign 64\nx86_mnem_off:\n");
	off = 0;
	for (int i = 0; i < nmnems; i++) { fprintf(out, "\t.long %d\n", off); off += strlen(mnems[i]) + 1; }
	fprintf(out, "x86_mnem_str:\n");
	for (int i = 0; i < nmnems; i++) fprintf(out, "\t.asciz \"%s\"\n", mnems[i]);
	fprintf(out, "\t.section .note.GNU-stack,\"\",@progbits\n");
	fclose(out);

	FILE *h = fopen(argv[3], "w");
	if (!h) { perror(argv[3]); return 1; }
	fprintf(h, "/* x86tab.h: the decoder's layouts for C tools, generated by tools/gen-x86-tables.c. Do not edit. */\n");
	fprintf(h, "#ifndef X86TAB_H\n#define X86TAB_H\n#include <stdint.h>\n");
	fprintf(h, "enum x86_opkind {\n");
	for (unsigned i = 0; i < NOPKINDS; i++) fprintf(h, "\tOK_%s = %u,\n", opkind_names[i], i);
	fprintf(h, "};\nstatic const char *const x86_opkind_names[%u] = {\n", (unsigned)NOPKINDS);
	for (unsigned i = 0; i < NOPKINDS; i++) fprintf(h, "\t\"%s\",\n", opkind_names[i]);
	fprintf(h, "};\n");
	fprintf(h, "#define LT_MODRM %d\n#define LT_GROUP %d\n#define LT_D64 %d\n#define LT_INVALID %d\n#define LT_PFX %d\n#define LT_ESC %d\n#define LT_F64 %d\n#define LT_X87 %d\n",
		LT_MODRM, LT_GROUP, LT_D64, LT_INVALID, LT_PFX, LT_ESC, LT_F64, LT_X87);
	fprintf(h, "enum x86_flow { FL_NEXT, FL_JCC, FL_JMP, FL_CALL, FL_RET, FL_JMPI, FL_CALLI, FL_TRAP, FL_LOOP, FL_FAR };\n");
	fprintf(h, "#define EF_B %d\n#define EF_Z %d\n#define EF_K %d\n#define EF_KREQ %d\n#define EF_RC %d\n#define EF_SAE %d\n#define EF_LOCK %d\n#define EF_LAST %d\n",
		EF_B, EF_Z, EF_K, EF_KREQ, EF_RC, EF_SAE, EF_LOCK, EF_LAST);
	fprintf(h, "struct x86_ent { uint8_t w, l, grp, rmfix, modreq, n, nb, flags, opsize, nops, ops[5], x; uint16_t code, mnem, pad2[2]; };\n#define EX_D64 %d\n#define EX_F64 %d\n", EX_D64, EX_F64);
	fprintf(h, "#define X86_NENT %d\n#define X86_NCODES %d\n#define X86_NMNEMS %d\n", ncodes, nnames, nmnems);
	fprintf(h, "extern const struct x86_ent x86_ent[];\nextern const uint32_t x86_code_off[], x86_mnem_off[];\nextern const char x86_code_str[], x86_mnem_str[];\n");
	fprintf(h, "extern const uint8_t x86_len_tab[], x86_grp_tab[];\nextern const uint16_t x86_idx[];\n");
	fprintf(h, "#endif\n");
	fclose(h);
	FILE *mn = fopen(argv[4], "w");
	if (!mn) { perror(argv[4]); return 1; }
	fprintf(mn, "# x86mnem.inc: the mnemonic ids of x86tab.inc (EN_MNEM), generated by tools/gen-x86-tables.c. Do not edit.\n");
	fprintf(mn, "\t.set MN_COUNT, %d\n", nmnems);
	for (int i = 0; i < nmnems; i++) fprintf(mn, "\t.set MN_%s, %d\n", mnems[i], i);
	fclose(mn);
	fprintf(stderr, "gen-x86-tables: %d codes, %d entries, %d names, %d mnemonics, %d group subtables\n", nnames, ncodes, nnames, nmnems, ngrp);
	return 0;
}

int main(int argc, char **argv) { return main_(argc, argv); }
