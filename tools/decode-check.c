/* decode-check.c: the assembly decoder (host/asm/phi512/decode.S) over an
 * ELF file's .text, one line per instruction in the format of
 * `avx512-xlate --dump` (iced-x86's decoding of the same bytes), so that
 * the two can be diffed:
 *
 *   as --64 -I host/asm/phi512 -o /tmp/decode.o host/asm/phi512/decode.S
 *   gcc -O2 -o /tmp/decode-check tools/decode-check.c /tmp/decode.o
 *   /tmp/decode-check libggml-cpu.so > asm.dump
 *   avx512-xlate --dump libggml-cpu.so > iced.dump
 *   diff iced.dump asm.dump
 *
 * Each line: address, length, flow control, encoding, the code's name,
 * the memory operand (base index scale displacement, or `-`), the last
 * immediate (or `-`; a branch's target), the mask register, zeroing,
 * broadcast. A decode failure prints `FAIL` and moves one byte on. See
 * decode-check.md. */
#include <elf.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "../host/asm/phi512/x86tab.h"

/* The decoded block (x86dec.inc). */
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

#define H_MODRM 1
#define H_SIB 2
#define H_DISP 4
#define H_IMM 8
#define H_RIPREL 16
#define H_MEM 32
#define H_ENTRY 64
#define H_VSIB 128

static const char *gpr[16] = { "RAX", "RCX", "RDX", "RBX", "RSP", "RBP", "RSI", "RDI", "R8", "R9", "R10", "R11", "R12", "R13", "R14", "R15" };
static const char *gpr32[16] = { "EAX", "ECX", "EDX", "EBX", "ESP", "EBP", "ESI", "EDI", "R8D", "R9D", "R10D", "R11D", "R12D", "R13D", "R14D", "R15D" };
static const char *flow_names[] = { "Next", "ConditionalBranch", "UnconditionalBranch", "Call", "Return", "IndirectBranch", "IndirectCall", "Interrupt", "ConditionalBranch", "Far" };
static const char *enc_names[] = { "Legacy", "VEX", "EVEX" };

static void shex(char *out, int64_t v)
{
	if (v < 0) sprintf(out, "-%llx", (unsigned long long)(-v));
	else sprintf(out, "%llx", (unsigned long long)v);
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: decode-check ELF [SECTION]\n");
		return 2;
	}
	const char *secname = argc > 2 ? argv[2] : ".text";
	int fd = open(argv[1], O_RDONLY);
	if (fd < 0) { perror(argv[1]); return 1; }
	struct stat st;
	fstat(fd, &st);
	const uint8_t *f = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (f == MAP_FAILED) { perror("mmap"); return 1; }
	const Elf64_Ehdr *eh = (const Elf64_Ehdr *)f;
	const Elf64_Shdr *sh = (const Elf64_Shdr *)(f + eh->e_shoff);
	const char *shstr = (const char *)(f + sh[eh->e_shstrndx].sh_offset);
	const Elf64_Shdr *text = NULL;
	for (int i = 0; i < eh->e_shnum; i++)
		if (!strcmp(shstr + sh[i].sh_name, secname)) text = &sh[i];
	if (!text) { fprintf(stderr, "no %s\n", secname); return 1; }
	const uint8_t *p = f + text->sh_offset, *end = p + text->sh_size;
	uint64_t addr = text->sh_addr;
	static char out[1 << 16];
	setvbuf(stdout, out, _IOFBF, sizeof out);
	struct insn in;
	while (p < end) {
		uint64_t len = x86_decode(p, end - p, &in, addr);
		if (!len) {
			printf("%llx 0 FAIL\n", (unsigned long long)addr);
			p++;
			addr++;
			continue;
		}
		char mem[128] = "-", imm[64] = "-";
		const struct x86_ent *e = (in.has & H_ENTRY) ? in.ent : NULL;
		const char *code = e ? x86_code_str + x86_code_off[e->code] : "?";
		int moffs = 0, nimm8 = 0;
		if (e) {
			int64_t v = 0;
			int have = 0;
			for (int i = 0; i < e->nops; i++) {
				int k = e->ops[i];
				switch (k) {
				case OK_mem_offs: moffs = 1; break;
				case OK_imm8: v = nimm8++ ? (in.imm >> 8) & 0xff : in.imm & 0xff; have = 1; break;
				case OK_imm8sex16: v = (int16_t)(int8_t)in.imm; have = 1; break;
				case OK_imm8sex32: v = (int32_t)(int8_t)in.imm; have = 1; break;
				case OK_imm8sex64: v = (int64_t)(int8_t)in.imm; have = 1; break;
				case OK_imm16: v = in.imm & 0xffff; have = 1; break;
				case OK_imm32: v = in.imm & 0xffffffffu; have = 1; break;
				case OK_imm32sex64: v = (int64_t)(int32_t)in.imm; have = 1; break;
				case OK_imm64: v = (int64_t)in.imm; have = 1; break;
				case OK_imm8_const_1: v = 1; have = 1; break;
				case OK_br16_1: case OK_br32_1: case OK_br64_1: case OK_br16_2: case OK_br32_4: case OK_br64_4:
				case OK_xbegin_2: case OK_xbegin_4:
					v = (int64_t)in.target; have = 1; break;
				default: break;
				}
				if (k == OK_imm8 && in.imm_sz == 3) v = in.imm2;	/* ENTER's second immediate */
			}
			if (have) {
				if (v < 0 && !(e->nops && e->ops[0] == OK_imm64)) shex(imm, v);
				else sprintf(imm, "%llx", (unsigned long long)v);
			}
		}
		if (in.has & H_MEM) {
			const char *const *names = (in.pfx & 16) ? gpr32 : gpr;	/* a 67 prefix: 32-bit addressing */
			const char *base = in.base == 0xff ? ((in.has & H_RIPREL) ? ((in.pfx & 16) ? "EIP" : "RIP") : "None") : names[in.base];
			char index[16] = "None";
			if (in.index != 0xff) {
				if (in.has & H_VSIB) {
					int kind = 0;
					for (int i = 0; e && i < e->nops; i++)
						if (e->ops[i] >= OK_mem_vsib32x && e->ops[i] <= OK_mem_vsib64z) kind = e->ops[i];
					const char *w = (kind == OK_mem_vsib32z || kind == OK_mem_vsib64z) ? "ZMM" : (kind == OK_mem_vsib32y || kind == OK_mem_vsib64y) ? "YMM" : "XMM";
					sprintf(index, "%s%d", w, in.index);
				} else {
					strcpy(index, names[in.index & 15]);
				}
			}
			char d[32];
			shex(d, in.disp);
			sprintf(mem, "%s %s %d %s", base, index, 1 << in.scale, d);
		} else if (moffs) {
			sprintf(mem, "None None 1 %llx", (unsigned long long)in.imm);
			strcpy(imm, "-");
		}
		/* iced's flow names for the traps */
		const char *flow = flow_names[in.flow];
		if (e) {
			const char *m = x86_mnem_str + x86_mnem_off[e->mnem];
			if (!strcmp(m, "Syscall")) flow = "Call";
			else if (!strcmp(m, "Hlt")) flow = "Next";
			else if (!strncmp(m, "Ud", 2)) flow = "Exception";
		}
		char mask[8] = "None";
		if (in.aaa) sprintf(mask, "K%d", in.aaa);
		printf("%llx %u %s %s %s %s %s %s %u %u\n", (unsigned long long)addr, (unsigned)len, flow, enc_names[in.enc],
			code, mem, imm, mask, in.z, (in.b && (in.has & H_MEM)) ? 1 : 0);
		p += len;
		addr += len;
	}
	fflush(stdout);
	return 0;
}
