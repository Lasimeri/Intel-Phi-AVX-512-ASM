# seeds.S: the functions the preload library has blobs for today: the
# three kernels of tools/avx512-seamless-test.c, translated by hand from
# gcc's output (`-O2 -mavx512f -mno-avx512vl -mno-avx512bw -mno-avx512dq
# -mno-avx512cd`, 2026-10-13) into the card's MVEX, instruction for
# instruction, entered where the host program faults (the function's
# first AVX-512 instruction, after whatever gcc put before it), with the
# loop's counter and bound registers the stripes set. The scaffold of
# stage 2 of the restart: stage 3's translator produces these from the
# binary itself. See seeds.md.

	.include "common.inc"
	.include "proto.inc"
	.include "mvex.inc"
	.include "defs.inc"

	.section .rodata
	.balign 64

# poly_avx512(out rdi, x rsi, coef rdx, n rcx). gcc moved the arguments
# before the loop: r10 = out, r9 = x, r8 = n, rsi = coef, rdi = coef +
# 0x74 (coef[29]), rdx = coef - 4, rcx = 0 (the counter); the first
# AVX-512 instruction is the loop head at +0x20. Per 16 lanes: v = x[i],
# acc = coef[30] broadcast, acc = acc * v + coef[k] for k = 29 .. 0, out[i]
# = acc. r11 holds the addresses the SIB forms computed (MVEX here takes
# base + disp32 only).
	.globl blob_poly, blob_poly_end
blob_poly:
1:	leaq (%r9,%rcx,4), %r11
	VMOVAPS zmm1, r11, 0
	MVEX_M MAP_0F38, PP_66, 0, 0x18, zmm0, 0, rsi, 0x78		# vbroadcastss zmm0, [rsi + 0x78]
	movq %rdi, %rax
2:	VFMADD213PS zmm0, zmm1, rax, 0, CV_1TO16			# zmm0 = zmm1 * zmm0 + [rax]{1to16}
	subq $4, %rax
	cmpq %rax, %rdx
	jne 2b
	leaq (%r10,%rcx,4), %r11
	VMOVAPS_ST r11, 0, zmm0
	addq $16, %rcx
	cmpq %rcx, %r8
	jg 1b
	ret
blob_poly_end:

# dot_avx512(a rdi, b rsi, n rdx): rax = 0 (the counter), zmm0 = 0 at the
# first AVX-512 instruction (+0x10, the loop head). Per 16 lanes: zmm0 =
# a[i] * b[i] + zmm0. Then the reduce gcc emitted with VL forms (an extract
# of the high 256 bits added to the low, the high 128 to the low, the
# pairs, the neighbours), here as a 128-bit-group permute and the
# card's swizzles, the same additions in the same order; lane 0 is the
# result, the function's xmm0. Not split: the lane sums are a chain.
	.globl blob_dot, blob_dot_end
	.balign 64
blob_dot:
1:	leaq (%rdi,%rax,4), %r11
	VMOVAPS zmm2, r11, 0
	leaq (%rsi,%rax,4), %r11
	VFMADD231PS zmm0, zmm2, r11, 0				# zmm0 = zmm2 * [r11] + zmm0
	addq $16, %rax
	cmpq %rax, %rdx
	jg 1b
	MVEX_RMI MAP_0F3A, PP_66, 0, 0x07, zmm1, zmm0, 0x4e		# vpermf32x4 zmm1, zmm0, groups 2 3 0 1
	VADDPS zmm0, zmm1, zmm0
	MVEX_RMI MAP_0F3A, PP_66, 0, 0x07, zmm1, zmm0, 0xb1		# groups 1 0 3 2
	VADDPS zmm0, zmm1, zmm0
	VADDPS zmm0, zmm0, zmm0, , SW_BADC				# lane l + lane l^2 (badc: pairs swapped)
	VADDPS zmm0, zmm0, zmm0, , SW_CDAB				# lane l + lane l^1 (cdab: neighbours swapped)
	ret
blob_dot_end:

# ints_avx512(out rdi, in rsi, n rdx): rax = 0, zmm3 = 0 at the first
# AVX-512 instruction (+0x06, gcc's vpternlogd that makes all ones for the
# constants). The constants 1, 7 and 3 come from the blob's own bytes
# (vbroadcastss from r11). Per 16 lanes: v = in[i], odd = (v & 1) == 1,
# r = v + 7, r{odd} = v * 3, out[i] = r.
	.globl blob_ints, blob_ints_end
	.balign 64				# the card copies a blob to a 64-aligned address: in-blob
blob_ints:					# offsets (the constants below, 4-byte loads) keep their alignment
	leaq 3f(%rip), %r11
	MVEX_M MAP_0F38, PP_66, 0, 0x18, zmm2, 0, r11, 0		# one
	MVEX_M MAP_0F38, PP_66, 0, 0x18, zmm4, 0, r11, 4		# seven
	MVEX_M MAP_0F38, PP_66, 0, 0x18, zmm3, 0, r11, 8		# three
1:	leaq (%rsi,%rax,4), %r11
	VMOVDQA32 zmm1, r11, 0
	VPANDD zmm0, zmm2, zmm1
	MVEX_R MAP_0F, PP_66, 0, 0x76, k1, zmm0, zmm2			# vpcmpeqd k1, zmm0, zmm2
	VPADDD zmm0, zmm4, zmm1
	MVEX_R MAP_0F38, PP_66, 0, 0x40, zmm0, zmm1, zmm3, 0, k1	# vpmulld zmm0{k1}, zmm1, zmm3
	leaq (%rdi,%rax,4), %r11
	VMOVDQA32_ST r11, 0, zmm0
	addq $16, %rax
	cmpq %rax, %rdx
	jg 1b
	ret
	.balign 16
3:	.long 1, 7, 3, 0
blob_ints_end:

# The seed table: SD_BYTES per seed (defs.inc), the names NUL-terminated;
# in .data, since the handler writes the resolved addresses into it.
	.globl seeds, nseeds
s_poly:	.asciz "poly_avx512"
s_dot:	.asciz "dot_avx512"
s_ints:	.asciz "ints_avx512"
	.data
	.balign 64
seeds:
	.quad s_poly, blob_poly, blob_poly_end - blob_poly, 0x20
	.long R_RCX, R_R8, 16, 0
	.long R_R9, 4, OPK_READ, 0
	.long R_R10, 4, OPK_WRITE, 0
	.long R_RSI, 0, OPK_FIXED, 124
	.long 0, 0, OPK_NONE, 0
	.quad 0, 0
	.quad 0, 0, 0, 0, 0, 0, 0, 0
	.quad s_dot, blob_dot, blob_dot_end - blob_dot, 0x10
	.long R_RAX, R_RDX, 0, 1
	.long R_RDI, 4, OPK_READ, 0
	.long R_RSI, 4, OPK_READ, 0
	.long 0, 0, OPK_NONE, 0
	.long 0, 0, OPK_NONE, 0
	.quad 0, 0
	.quad 0, 0, 0, 0, 0, 0, 0, 0
	.quad s_ints, blob_ints, blob_ints_end - blob_ints, 0x06
	.long R_RAX, R_RDX, 16, 0
	.long R_RSI, 4, OPK_READ, 0
	.long R_RDI, 4, OPK_WRITE, 0
	.long 0, 0, OPK_NONE, 0
	.long 0, 0, OPK_NONE, 0
	.quad 0, 0
	.quad 0, 0, 0, 0, 0, 0, 0, 0
nseeds:	.quad 3
