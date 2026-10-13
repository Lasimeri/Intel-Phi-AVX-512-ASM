# xlate.S: one vector instruction of the program (EVEX, VEX or SSE, as
# decode.S decoded it) written as the card's MVEX through mvex.S: the
# recipes. A recipe is chosen by mnemonic (x86mnem.inc's ids, the table
# filled at xl_init from the xl_forms list) and sees the instruction's
# operands through the decoded block: reg, rm or the memory operand,
# vvvv, the mask, zeroing, broadcast, the vector length, W. What the
# card does one to one (a 512-bit operation on the lanes the mask
# selects) is one MVEX instruction; a 128- or 256-bit form is the same
# operation under a lane mask with the lanes above the length zeroed
# (what EVEX and VEX require); zeroing masking zeroes the unselected
# lanes after; a memory operand that is not an aligned move is staged
# through the unaligned pair into a temporary (the card needs every
# memory operand aligned to its size, ISA reference 327364-001 2.1.1).
# The sequences are those of host/crates/avx512-xlate/src/rewrite.rs,
# checked on the card by tools/avx512-narrow-test.c. See xlate.md.
#
#   xl_insn(rdi = the blob (BL_*), rsi = the decoded instruction (IN_*,
#   its memory operand already re-based if it was rip-relative)) ->
#   rax = 0, or a refusal (a string).

	.include "x86dec.inc"
	.include "xlate.inc"
	.include "x86mnem.inc"

# A form record: the handler, two arguments, the mnemonic.
	.set XF_HANDLER, 0
	.set XF_A, 8				# map | pp << 8 | w << 16 | op << 24 (the MVEX encoding of a one-to-one form)
	.set XF_B, 12				# handler-specific
	.set XF_MNEM, 16
	.set XF_BYTES, 24
	.macro FORM mnem, handler, a=0, b=0
	.quad \handler
	.long \a, \b
	.short \mnem, 0, 0, 0			# 24 bytes with the quad and the two longs
	.endm
	.macro ENC map, pp, w, op
	.long (\map) | ((\pp) << 8) | ((\w) << 16) | ((\op) << 24)
	.endm
# XF_B bits the generic recipes read.
	.set XB_QWORD, 1			# qword lanes (the lane masks by 8)
	.set XB_FLOAT, 2			# the unaligned pair's float form
	.set XB_NDD, 4				# the destination in vvvv, the source in r/m (the shifts by immediate)
	.set XB_TOK, 8				# the result is a mask register (compares)
	.set XB_IMM, 16				# an immediate follows

	.data					# absolute addresses: not for a read-only section of a shared object
	.balign 8
xl_forms:
	# one to one: three operands, dst, src1 (vvvv), src2 (r/m, a memory operand, a broadcast)
	FORM MN_Vaddps, xl_nds, (1 | (0 << 8) | (0 << 16) | (0x58 << 24)), XB_FLOAT
	FORM MN_Vsubps, xl_nds, (1 | (0 << 8) | (0 << 16) | (0x5c << 24)), XB_FLOAT
	FORM MN_Vmulps, xl_nds, (1 | (0 << 8) | (0 << 16) | (0x59 << 24)), XB_FLOAT
	FORM MN_Vaddpd, xl_nds, (1 | (1 << 8) | (1 << 16) | (0x58 << 24)), XB_FLOAT | XB_QWORD
	FORM MN_Vsubpd, xl_nds, (1 | (1 << 8) | (1 << 16) | (0x5c << 24)), XB_FLOAT | XB_QWORD
	FORM MN_Vmulpd, xl_nds, (1 | (1 << 8) | (1 << 16) | (0x59 << 24)), XB_FLOAT | XB_QWORD
	FORM MN_Vfmadd132ps, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x98 << 24)), XB_FLOAT
	FORM MN_Vfmadd213ps, xl_nds, (2 | (1 << 8) | (0 << 16) | (0xa8 << 24)), XB_FLOAT
	FORM MN_Vfmadd231ps, xl_nds, (2 | (1 << 8) | (0 << 16) | (0xb8 << 24)), XB_FLOAT
	FORM MN_Vfmsub132ps, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x9a << 24)), XB_FLOAT
	FORM MN_Vfmsub213ps, xl_nds, (2 | (1 << 8) | (0 << 16) | (0xaa << 24)), XB_FLOAT
	FORM MN_Vfmsub231ps, xl_nds, (2 | (1 << 8) | (0 << 16) | (0xba << 24)), XB_FLOAT
	FORM MN_Vfnmadd132ps, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x9c << 24)), XB_FLOAT
	FORM MN_Vfnmadd213ps, xl_nds, (2 | (1 << 8) | (0 << 16) | (0xac << 24)), XB_FLOAT
	FORM MN_Vfnmadd231ps, xl_nds, (2 | (1 << 8) | (0 << 16) | (0xbc << 24)), XB_FLOAT
	FORM MN_Vfnmsub132ps, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x9e << 24)), XB_FLOAT
	FORM MN_Vfnmsub213ps, xl_nds, (2 | (1 << 8) | (0 << 16) | (0xae << 24)), XB_FLOAT
	FORM MN_Vfnmsub231ps, xl_nds, (2 | (1 << 8) | (0 << 16) | (0xbe << 24)), XB_FLOAT
	FORM MN_Vfmadd132pd, xl_nds, (2 | (1 << 8) | (1 << 16) | (0x98 << 24)), XB_FLOAT | XB_QWORD
	FORM MN_Vfmadd213pd, xl_nds, (2 | (1 << 8) | (1 << 16) | (0xa8 << 24)), XB_FLOAT | XB_QWORD
	FORM MN_Vfmadd231pd, xl_nds, (2 | (1 << 8) | (1 << 16) | (0xb8 << 24)), XB_FLOAT | XB_QWORD
	FORM MN_Vpaddd, xl_nds, (1 | (1 << 8) | (0 << 16) | (0xfe << 24)), 0
	FORM MN_Vpsubd, xl_nds, (1 | (1 << 8) | (0 << 16) | (0xfa << 24)), 0
	FORM MN_Vpandd, xl_nds, (1 | (1 << 8) | (0 << 16) | (0xdb << 24)), 0
	FORM MN_Vpandnd, xl_nds, (1 | (1 << 8) | (0 << 16) | (0xdf << 24)), 0
	FORM MN_Vpord, xl_nds, (1 | (1 << 8) | (0 << 16) | (0xeb << 24)), 0
	FORM MN_Vpxord, xl_nds, (1 | (1 << 8) | (0 << 16) | (0xef << 24)), 0
	FORM MN_Vpandq, xl_nds, (1 | (1 << 8) | (1 << 16) | (0xdb << 24)), XB_QWORD
	FORM MN_Vpandnq, xl_nds, (1 | (1 << 8) | (1 << 16) | (0xdf << 24)), XB_QWORD
	FORM MN_Vporq, xl_nds, (1 | (1 << 8) | (1 << 16) | (0xeb << 24)), XB_QWORD
	FORM MN_Vpxorq, xl_nds, (1 | (1 << 8) | (1 << 16) | (0xef << 24)), XB_QWORD
	FORM MN_Vpmulld, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x40 << 24)), 0
	FORM MN_Vpminsd, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x39 << 24)), 0
	FORM MN_Vpminud, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x3b << 24)), 0
	FORM MN_Vpmaxsd, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x3d << 24)), 0
	FORM MN_Vpmaxud, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x3f << 24)), 0
	FORM MN_Vpsllvd, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x47 << 24)), 0
	FORM MN_Vpsrlvd, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x45 << 24)), 0
	FORM MN_Vpsravd, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x46 << 24)), 0
	FORM MN_Vpermd, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x36 << 24)), 0
	# the VEX names of the same operations (vpand, vpor, vpxor, vpadd): 128- and 256-bit forms
	FORM MN_Vpand, xl_nds, (1 | (1 << 8) | (0 << 16) | (0xdb << 24)), 0
	FORM MN_Vpandn, xl_nds, (1 | (1 << 8) | (0 << 16) | (0xdf << 24)), 0
	FORM MN_Vpor, xl_nds, (1 | (1 << 8) | (0 << 16) | (0xeb << 24)), 0
	FORM MN_Vpxor, xl_nds, (1 | (1 << 8) | (0 << 16) | (0xef << 24)), 0
	FORM MN_Vxorps, xl_nds, (1 | (1 << 8) | (0 << 16) | (0xef << 24)), 0
	FORM MN_Vandps, xl_nds, (1 | (1 << 8) | (0 << 16) | (0xdb << 24)), 0
	FORM MN_Vorps, xl_nds, (1 | (1 << 8) | (0 << 16) | (0xeb << 24)), 0
	FORM MN_Vandnps, xl_nds, (1 | (1 << 8) | (0 << 16) | (0xdf << 24)), 0
	FORM MN_Vxorpd, xl_nds, (1 | (1 << 8) | (1 << 16) | (0xef << 24)), XB_QWORD
	FORM MN_Vandpd, xl_nds, (1 | (1 << 8) | (1 << 16) | (0xdb << 24)), XB_QWORD
	# the shifts by immediate: NDD, the opcode's /n in the reg field
	FORM MN_Vpslld, xl_shift_imm, 6, 0
	FORM MN_Vpsrld, xl_shift_imm, 2, 0
	FORM MN_Vpsrad, xl_shift_imm, 4, 0
	# compares into a mask
	FORM MN_Vpcmpeqd, xl_cmp_k, (1 | (1 << 8) | (0 << 16) | (0x76 << 24)), 0
	FORM MN_Vpcmpgtd, xl_cmp_k, (1 | (1 << 8) | (0 << 16) | (0x66 << 24)), 0
	FORM MN_Vpcmpd, xl_cmp_k, (3 | (1 << 8) | (0 << 16) | (0x1f << 24)), XB_IMM
	FORM MN_Vpcmpud, xl_cmp_k, (3 | (1 << 8) | (0 << 16) | (0x1e << 24)), XB_IMM
	FORM MN_Vcmpps, xl_cmp_k, (1 | (0 << 8) | (0 << 16) | (0xc2 << 24)), XB_IMM | XB_FLOAT
	FORM MN_Vcmppd, xl_cmp_k, (1 | (1 << 8) | (1 << 16) | (0xc2 << 24)), XB_IMM | XB_FLOAT | XB_QWORD
	# moves
	FORM MN_Vmovaps, xl_mov_aligned, 0, 0
	FORM MN_Vmovapd, xl_mov_aligned, 0, XB_QWORD
	FORM MN_Vmovdqa32, xl_mov_aligned, 0, 0
	FORM MN_Vmovdqa64, xl_mov_aligned, 0, XB_QWORD
	FORM MN_Vmovdqa, xl_mov_aligned, 0, 0
	FORM MN_Vmovups, xl_mov_unaligned, 0, 0
	FORM MN_Vmovupd, xl_mov_unaligned, 0, XB_QWORD
	FORM MN_Vmovdqu32, xl_mov_unaligned, 0, 0
	FORM MN_Vmovdqu64, xl_mov_unaligned, 0, XB_QWORD
	FORM MN_Vmovdqu, xl_mov_unaligned, 0, 0
	FORM MN_Vbroadcastss, xl_broadcast, 0, 0
	FORM MN_Vbroadcastsd, xl_broadcast, 0, XB_QWORD
	FORM MN_Vpbroadcastd, xl_broadcast, 0, 0
	FORM MN_Vpbroadcastq, xl_broadcast, 0, XB_QWORD
	# lanes and blocks
	FORM MN_Vpternlogd, xl_ternlog, 0, 0
	FORM MN_Vpternlogq, xl_ternlog, 0, XB_QWORD
	FORM MN_Vextractf64x4, xl_extract, 1, 0
	FORM MN_Vextracti64x4, xl_extract, 1, 0
	FORM MN_Vextractf32x8, xl_extract, 1, 0
	FORM MN_Vextracti32x8, xl_extract, 1, 0
	FORM MN_Vextractf32x4, xl_extract, 0, 0
	FORM MN_Vextracti32x4, xl_extract, 0, 0
	FORM MN_Vextractf64x2, xl_extract, 0, 0
	FORM MN_Vextracti64x2, xl_extract, 0, 0
	FORM MN_Vextractf128, xl_extract, 0, 0
	FORM MN_Vextracti128, xl_extract, 0, 0
	FORM MN_Vpermilps, xl_permilps, 0, 0
	FORM MN_Vpshufd, xl_permilps, 0, 0
	FORM MN_Vshufps, xl_shufps, 0, 0
	FORM MN_Vmovss, xl_movss, 0, 0
	FORM MN_Vmovsd, xl_movss, 0, XB_QWORD
	FORM MN_Vaddss, xl_scalar, (1 | (0 << 8) | (0 << 16) | (0x58 << 24)), 0
	FORM MN_Vsubss, xl_scalar, (1 | (0 << 8) | (0 << 16) | (0x5c << 24)), 0
	FORM MN_Vmulss, xl_scalar, (1 | (0 << 8) | (0 << 16) | (0x59 << 24)), 0
	FORM MN_Vaddsd, xl_scalar, (1 | (1 << 8) | (1 << 16) | (0x58 << 24)), XB_QWORD
	FORM MN_Vsubsd, xl_scalar, (1 | (1 << 8) | (1 << 16) | (0x5c << 24)), XB_QWORD
	FORM MN_Vmulsd, xl_scalar, (1 | (1 << 8) | (1 << 16) | (0x59 << 24)), XB_QWORD
	FORM MN_Vfmadd132ss, xl_scalar, (2 | (1 << 8) | (0 << 16) | (0x99 << 24)), 0
	FORM MN_Vfmadd213ss, xl_scalar, (2 | (1 << 8) | (0 << 16) | (0xa9 << 24)), 0
	FORM MN_Vfmadd231ss, xl_scalar, (2 | (1 << 8) | (0 << 16) | (0xb9 << 24)), 0
	FORM MN_Vzeroupper, xl_nothing, 0, 0
	FORM MN_Vzeroall, xl_zeroall, 0, 0
xl_forms_end:
s_no_recipe:	.asciz "no recipe for this instruction"
s_no_temp:	.asciz "no free vector register or scratch slot for a temporary"
s_full:		.asciz "the blob's room ran out"
s_qmask:	.asciz "a byte or word mask: the card masks 32-bit lanes only"
s_ternlog:	.asciz "vpternlog with memory or broadcast is not translated yet"
s_shape:	.asciz "an operand shape the recipe does not take"
s_scalar_mem:	.asciz "a scalar operation with a memory operand is not translated yet"

	.data
	.balign 8
xl_tab:	.skip MN_COUNT * 8
xl_inited: .quad 0

	.text
# xl_init: the dispatch table from the forms list (once).
	.globl xl_init
xl_init:
	cmpq $0, xl_inited(%rip)
	jne 9f
	movq $1, xl_inited(%rip)
	leaq xl_forms(%rip), %rax
	leaq xl_forms_end(%rip), %rcx
	leaq xl_tab(%rip), %rdx
1:	cmpq %rcx, %rax
	jae 9f
	movzwl XF_MNEM(%rax), %esi
	movq %rax, (%rdx,%rsi,8)
	addq $XF_BYTES, %rax
	jmp 1b
9:	ret

# Lane masks: vl_lanes(ll, qword) = the lanes of the vector length in
# elements (0x000f/0x00ff/0xffff dwords, 0x0003/0x000f/0x00ff qwords);
# upper(ll) = the dword lanes above the length (0xfff0, 0xff00, 0).
vl_lanes:
	# edi = ll, esi = qword -> eax
	andl $3, %edi
	testl %esi, %esi
	jz 1f
	addl $4, %edi
1:	leaq .Lvl_tab(%rip), %rax
	movzwl (%rax,%rdi,2), %eax
	ret
	.section .rodata
.Lvl_tab: .short 0x000f, 0x00ff, 0xffff, 0xffff, 0x0003, 0x000f, 0x00ff, 0x00ff
	.text
upper_lanes:
	# edi = ll -> eax
	xorl %eax, %eax
	cmpl $2, %edi
	je 1f
	movl $0xff00, %eax
	cmpl $1, %edi
	je 1f
	movl $0xfff0, %eax
1:	ret

# The instruction's view: the fields the recipes read, from the block
# the emitter remembers (EM_IN). Register use inside a recipe: rbx = em,
# r12 = in, r13 = the form; the rest as each recipe says.
	.macro LOADCTX
	movq %rdi, %rbx
	movq EM_IN(%rbx), %r12
	movq %rsi, %r13
	.endm
# EV_LL r, in: the vector length of the instruction at in (VEX: L;
# EVEX: L'L; a rounding form, EVEX.b on a register form, has 512).
	.macro EV_LL r, in=%r12
	movzbl IN_L(\in), \r
	cmpb $2, IN_ENC(\in)
	jne 1f
	cmpb $0, IN_B(\in)
	je 1f
	cmpb $3, IN_MOD(\in)
	jne 1f
	movl $2, \r
1:
	.endm

# xl_insn(blob rdi, in rsi): the recipe for the instruction's mnemonic
# run with an emitter on this stack; rax 0 or the refusal.
	.globl xl_insn
xl_insn:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $EM_BYTES + 16, %rsp
	movq %rdi, %r14				# the blob
	movq %rsi, %r12				# the instruction
	call xl_init
	movq IN_ENTRYP(%r12), %r13
	testq %r13, %r13
	jz .Lxl_none
	movzwl EN_MNEM(%r13), %eax
	leaq xl_tab(%rip), %rcx
	movq (%rcx,%rax,8), %r13		# the form
	testq %r13, %r13
	jz .Lxl_none
	# the reserved registers: the vector and mask registers the operands name
	xorl %r15d, %r15d
	movq IN_ENTRYP(%r12), %rcx
	movzbl EN_NOPS(%rcx), %edx
	xorl %esi, %esi
1:	cmpl %edx, %esi
	jae 5f
	movzbl EN_OPS(%rcx,%rsi), %eax
	incl %esi
	# xmm/ymm/zmm _reg (48, 54, 59), _rm (49, 55, 60), _vvvv (50, 56, 61), _or_mem (20, 21, 22)
	cmpl $48, %eax
	je 11f
	cmpl $54, %eax
	je 11f
	cmpl $59, %eax
	je 11f
	cmpl $49, %eax
	je 12f
	cmpl $55, %eax
	je 12f
	cmpl $60, %eax
	je 12f
	cmpl $20, %eax
	je 12f
	cmpl $21, %eax
	je 12f
	cmpl $22, %eax
	je 12f
	cmpl $50, %eax
	je 13f
	cmpl $56, %eax
	je 13f
	cmpl $61, %eax
	je 13f
	cmpl $42, %eax				# k_reg
	je 14f
	cmpl $44, %eax				# k_rm
	je 15f
	cmpl $45, %eax				# k_vvvv
	je 16f
	jmp 1b
11:	movzbl IN_REG(%r12), %eax
	btsq %rax, %r15
	jmp 1b
12:	cmpb $3, IN_MOD(%r12)
	jne 1b
	movzbl IN_RM(%r12), %eax
	btsq %rax, %r15
	jmp 1b
13:	movzbl IN_VVVV(%r12), %eax
	btsq %rax, %r15
	jmp 1b
14:	movzbl IN_REG(%r12), %eax
	addl $32, %eax
	btsq %rax, %r15
	jmp 1b
15:	movzbl IN_RM(%r12), %eax
	addl $32, %eax
	btsq %rax, %r15
	jmp 1b
16:	movzbl IN_VVVV(%r12), %eax
	addl $32, %eax
	btsq %rax, %r15
	jmp 1b
5:	movzbl IN_AAA(%r12), %eax
	addl $32, %eax
	btsq %rax, %r15
	# the emitter
	movq %r15, (%rsp)
	leaq 16(%rsp), %rdi
	movq BL_OUT(%r14), %rsi
	movq BL_CODE_LIM(%r14), %rdx
	movq %r14, %rcx
	movl BL_SCRATCH(%r14), %r8d
	movq %r12, %r9
	call em_init
	leaq 16(%rsp), %rdi
	movq %r13, %rsi
	call *XF_HANDLER(%r13)
	testq %rax, %rax
	jnz .Lxl_out
	leaq 16(%rsp), %rdi
	call em_finish
	testl %eax, %eax
	jz 6f
	leaq s_full(%rip), %rax
	jmp .Lxl_out
6:	movq 16 + EM_OUT(%rsp), %rax
	movq %rax, BL_OUT(%r14)
	xorl %eax, %eax
.Lxl_out:
	addq $EM_BYTES + 16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
.Lxl_none:
	leaq s_no_recipe(%rip), %rax
	jmp .Lxl_out

# commit(em rdi, d esi, r edx): the result held in r written into d
# under the instruction's mask and vector length: merge under the mask,
# zero under {z}, zero above the length. (rewrite.rs commit.) qword
# lanes when ecx is 1.
commit:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $16, %rsp
	movq %rdi, %rbx
	movl %esi, %r12d			# d
	movl %edx, %r13d			# r
	movl %ecx, %r14d			# qword
	movq EM_IN(%rbx), %r15			# in
	EV_LL %eax, %r15
	movl %eax, (%rsp)			# ll
	movl $0, 4(%rsp)			# the mask register holding lanes & {k}, 0 none yet
	cmpl %r12d, %r13d
	je 2f
	# r != d: d{k} = r, k = 0 when full and unmasked, else lanes & {k}
	xorl %ecx, %ecx
	cmpl $2, (%rsp)
	jne 1f
	cmpb $0, IN_AAA(%r15)
	je 11f
1:	call .Lcommit_k
	movl %eax, %ecx
11:	movq %rbx, %rdi
	movl %r12d, %esi
	movl $RM_REG, %edx
	movl %r13d, %ecx
	movl 4(%rsp), %r8d
	movl %r14d, %r9d
	call em_vmov
2:	cmpb $0, IN_Z(%r15)
	je 3f
	cmpb $0, IN_AAA(%r15)
	je 3f
	cmpl $0, 4(%rsp)
	jne 21f
	call .Lcommit_k
21:	movq %rbx, %rdi
	movzbl EM_KSCR(%rbx), %esi
	movl %esi, %edx
	call em_knot
	movq %rbx, %rdi
	movl %r12d, %esi
	movzbl EM_KSCR(%rbx), %edx
	movl %r14d, %ecx
	call em_zero
3:	movl (%rsp), %edi
	call upper_lanes
	movq %rbx, %rdi
	movl %r12d, %esi
	movl %eax, %edx
	call em_zero_lanes
	addq $16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
# .Lcommit_k: the scratch mask set to the length's lanes and {k}; its
# number in eax and in 4(%rsp) of commit's frame (8(%rsp) here).
.Lcommit_k:
	movl 8(%rsp), %edi
	movl %r14d, %esi
	call vl_lanes
	movq %rbx, %rdi
	movl %eax, %esi
	call em_mask_imm
	cmpb $0, IN_AAA(%r15)
	je 1f
	movq %rbx, %rdi
	movzbl EM_KSCR(%rbx), %esi
	movzbl IN_AAA(%r15), %edx
	call em_kand
1:	movzbl EM_KSCR(%rbx), %eax
	movl %eax, 12(%rsp)
	ret

# src2(em rdi, qword esi, float edx): the second source as a register:
# the register itself, or the memory operand staged into a temporary
# (an embedded broadcast: vbroadcastss/sd; else the unaligned pair under
# the length's lane mask). eax the register, -1 none free.
src2:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	movq %rdi, %rbx
	movl %esi, %r13d
	movl %edx, %r14d
	movq EM_IN(%rbx), %r12
	testb $H_MEM, IN_HAS(%r12)
	jnz 1f
	movzbl IN_RM(%r12), %eax
	jmp 9f
1:	call em_temp
	testl %eax, %eax
	js 9f
	movl %eax, %esi
	pushq %rsi
	cmpb $0, IN_B(%r12)
	je 2f
	movq %rbx, %rdi
	movl $RM_MEM, %edx
	movq %r12, %rcx
	xorl %r8d, %r8d
	movl %r13d, %r9d
	call em_broadcast
	jmp 3f
2:	# the lane mask of the length (dword lanes: the pair moves dwords)
	EV_LL %edi
	xorl %esi, %esi
	call vl_lanes
	xorl %ecx, %ecx
	cmpl $0xffff, %eax
	je 21f
	movq %rbx, %rdi
	movl %eax, %esi
	call em_mask_imm
	movl %eax, %ecx
21:	movq %rbx, %rdi
	movl (%rsp), %esi
	movq %r12, %rdx
	xorl %r8d, %r8d
	xorl %r9d, %r9d
	pushq $0				# sss
	pushq $0				# float: the dword pair for every type
	call em_unaligned
	addq $16, %rsp
3:	popq %rax
9:	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# ---- the recipes ----
# Each: rdi = em, rsi = the form; rax 0 or a refusal.

# xl_nds: d = op(s1, s2) with s1 = vvvv, s2 = r/m or memory or a
# broadcast; one MVEX under the mask the length and {k} make; {z} and
# the upper lanes by commit.
xl_nds:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES + 16, %rsp
	LOADCTX
	movl XF_B(%r13), %r14d
	# the block: map, pp, w, op
	movq %rsp, %rdi
	movl XF_A(%r13), %eax
	movzbl %al, %esi
	movl %eax, %edx
	shrl $8, %edx
	movzbl %dl, %edx
	movl %eax, %ecx
	shrl $16, %ecx
	movzbl %cl, %ecx
	movl %eax, %r8d
	shrl $24, %r8d
	movzbl IN_REG(%r12), %r9d
	call mv_set
	# the mask: the length's lanes and {k}
	xorl %r15d, %r15d			# k
	EV_LL %edi
	movl %edi, MV_BYTES(%rsp)
	cmpl $2, %edi
	jne 1f
	movzbl IN_AAA(%r12), %r15d
	jmp 2f
1:	movl %r14d, %esi
	andl $XB_QWORD, %esi
	call vl_lanes
	movq %rbx, %rdi
	movl %eax, %esi
	call em_mask_imm
	movl %eax, %r15d
	cmpb $0, IN_AAA(%r12)
	je 2f
	movq %rbx, %rdi
	movl %r15d, %esi
	movzbl IN_AAA(%r12), %edx
	call em_kand
2:	movb %r15b, MV_K(%rsp)
	movzbl IN_VVVV(%r12), %eax
	movb %al, MV_VVVV(%rsp)
	# the second source
	testb $H_MEM, IN_HAS(%r12)
	jz 3f
	cmpb $0, IN_B(%r12)
	je 4f
	# an embedded broadcast: the memory operand with SSS 001
	movq %rsp, %rdi
	movl $RM_MEM, %esi
	movq %r12, %rdx
	call mv_rm
	movb $1, MV_SSS(%rsp)
	jmp 5f
4:	movq %rbx, %rdi
	movl %r14d, %esi
	andl $XB_QWORD, %esi
	movl %r14d, %edx
	andl $XB_FLOAT, %edx
	call src2
	testl %eax, %eax
	js .Lnds_notemp
	movq %rsp, %rdi
	movl $RM_REG, %esi
	movl %eax, %edx
	call mv_rm
	jmp 5f
3:	movq %rsp, %rdi
	movl $RM_REG, %esi
	movzbl IN_RM(%r12), %edx
	call mv_rm
5:	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	# {z} and the upper lanes
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl %esi, %edx
	movl %r14d, %ecx
	andl $XB_QWORD, %ecx
	call commit
	xorl %eax, %eax
	jmp 9f
.Lnds_notemp:
	leaq s_no_temp(%rip), %rax
9:	addq $MV_BYTES + 16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_shift_imm: vpslld /6, vpsrld /2, vpsrad /4 by immediate
# (MVEX.NDD.512.66.0F.W0 72 /n ib): the destination in vvvv, the source
# in r/m, as EVEX has it; under the mask the length and {k} make.
xl_shift_imm:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES + 16, %rsp
	LOADCTX
	movq %rsp, %rdi
	movl $1, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0x72, %r8d
	movl XF_A(%r13), %r9d			# /n
	call mv_set
	movzbl IN_VVVV(%r12), %eax
	movb %al, MV_VVVV(%rsp)			# the destination
	movzbl IN_IMM(%r12), %eax
	movw %ax, MV_IMM(%rsp)
	xorl %r15d, %r15d
	EV_LL %edi
	cmpl $2, %edi
	jne 1f
	movzbl IN_AAA(%r12), %r15d
	jmp 2f
1:	xorl %esi, %esi
	call vl_lanes
	movq %rbx, %rdi
	movl %eax, %esi
	call em_mask_imm
	movl %eax, %r15d
	cmpb $0, IN_AAA(%r12)
	je 2f
	movq %rbx, %rdi
	movl %r15d, %esi
	movzbl IN_AAA(%r12), %edx
	call em_kand
2:	movb %r15b, MV_K(%rsp)
	testb $H_MEM, IN_HAS(%r12)
	jz 3f
	movq %rbx, %rdi
	xorl %esi, %esi
	xorl %edx, %edx
	call src2
	testl %eax, %eax
	js 8f
	movq %rsp, %rdi
	movl $RM_REG, %esi
	movl %eax, %edx
	call mv_rm
	jmp 4f
3:	movq %rsp, %rdi
	movl $RM_REG, %esi
	movzbl IN_RM(%r12), %edx
	call mv_rm
4:	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	movq %rbx, %rdi
	movzbl IN_VVVV(%r12), %esi
	movl %esi, %edx
	xorl %ecx, %ecx
	call commit
	xorl %eax, %eax
	jmp 9f
8:	leaq s_no_temp(%rip), %rax
9:	addq $MV_BYTES + 16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_cmp_k: a compare into a mask register (vpcmpeqd 66.0F 76, vpcmpgtd
# 66.0F 66, vcmpps 0F C2 ib, vcmppd 66.0F.W1 C2 ib): k{k2} = s1 cmp s2;
# the card writes 0 to the unselected bits as AVX-512 does; a form
# shorter than 512 is the same compare under the length's lanes. A
# predicate above 7 is refused here (the card has the eight of AVX).
xl_cmp_k:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES + 16, %rsp
	LOADCTX
	movl XF_B(%r13), %r14d
	movq %rsp, %rdi
	movl XF_A(%r13), %eax
	movzbl %al, %esi
	movl %eax, %edx
	shrl $8, %edx
	movzbl %dl, %edx
	movl %eax, %ecx
	shrl $16, %ecx
	movzbl %cl, %ecx
	movl %eax, %r8d
	shrl $24, %r8d
	movzbl IN_REG(%r12), %r9d
	call mv_set
	testl $XB_IMM, %r14d
	jz 1f
	movzbl IN_IMM(%r12), %eax
	cmpl $8, %eax
	jae .Lcmp_shape
	cmpb $3, MV_MAP(%rsp)			# the integer compares: predicates 3 (false) and 7 (true) are not the card's
	jne 12f
	cmpl $3, %eax
	je .Lcmp_shape
	cmpl $7, %eax
	je .Lcmp_shape
12:	movw %ax, MV_IMM(%rsp)
1:	movzbl IN_VVVV(%r12), %eax
	movb %al, MV_VVVV(%rsp)
	xorl %r15d, %r15d
	EV_LL %edi
	cmpl $2, %edi
	jne 2f
	movzbl IN_AAA(%r12), %r15d
	jmp 3f
2:	movl %r14d, %esi
	andl $XB_QWORD, %esi
	call vl_lanes
	movq %rbx, %rdi
	movl %eax, %esi
	call em_mask_imm
	movl %eax, %r15d
	cmpb $0, IN_AAA(%r12)
	je 3f
	movq %rbx, %rdi
	movl %r15d, %esi
	movzbl IN_AAA(%r12), %edx
	call em_kand
3:	movb %r15b, MV_K(%rsp)
	testb $H_MEM, IN_HAS(%r12)
	jz 4f
	cmpb $0, IN_B(%r12)
	je 5f
	movq %rsp, %rdi
	movl $RM_MEM, %esi
	movq %r12, %rdx
	call mv_rm
	movb $1, MV_SSS(%rsp)
	jmp 6f
5:	movq %rbx, %rdi
	movl %r14d, %esi
	andl $XB_QWORD, %esi
	xorl %edx, %edx
	call src2
	testl %eax, %eax
	js 8f
	movq %rsp, %rdi
	movl $RM_REG, %esi
	movl %eax, %edx
	call mv_rm
	jmp 6f
4:	movq %rsp, %rdi
	movl $RM_REG, %esi
	movzbl IN_RM(%r12), %edx
	call mv_rm
6:	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	xorl %eax, %eax
	jmp 9f
8:	leaq s_no_temp(%rip), %rax
	jmp 9f
.Lcmp_shape:
	leaq s_shape(%rip), %rax
9:	addq $MV_BYTES + 16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_mov_aligned: vmovaps/vmovapd/vmovdqa32/64 (and VEX vmovdqa). A
# 512-bit load or store is the card's own aligned move under the mask
# (AVX-512 requires the 64-byte alignment too); register to register
# the same; {z} on a load zeroes the unselected lanes after. A 128- or
# 256-bit load reads its block with a block broadcast (the card's
# vbroadcasti32x4/64x4 need only the block's alignment, which AVX
# requires) and zeroes above; a 128- or 256-bit store is the pack pair
# under the length's lanes.
xl_mov_aligned:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $16, %rsp
	LOADCTX
	movl XF_B(%r13), %r14d
	andl $XB_QWORD, %r14d
	EV_LL %r15d
	# the direction: a store when the memory operand is the destination (opcode 29/7F)
	movzbl IN_OP(%r12), %eax
	andl $1, %eax				# 28 -> 0 load, 29 -> 1 store; 6F -> 1?, 7F -> 1: handled below
	movzbl IN_OP(%r12), %ecx
	cmpl $0x7f, %ecx
	jne 1f
	movl $1, %eax
	jmp 2f
1:	cmpl $0x6f, %ecx
	jne 2f
	xorl %eax, %eax
2:	movl %eax, (%rsp)			# store?
	testb $H_MEM, IN_HAS(%r12)
	jz .Lmova_reg
	cmpl $2, %r15d
	jne .Lmova_narrow
	cmpl $0, (%rsp)
	jne .Lmova_store
	# a 512-bit load: vmovaps d{k}, [m]
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_MEM, %edx
	movq %r12, %rcx
	movzbl IN_AAA(%r12), %r8d
	movl %r14d, %r9d
	call em_vmov
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl %esi, %edx
	movl %r14d, %ecx
	call commit
	jmp .Lmova_ok
.Lmova_store:
	# a 512-bit store: vmovaps [m]{k}, s (MVEX.512.0F.W0 29 /r)
	subq $MV_BYTES, %rsp
	movq %rsp, %rdi
	movl $1, %esi
	movl %r14d, %edx
	movl %r14d, %ecx
	movl $0x29, %r8d
	movzbl IN_REG(%r12), %r9d
	call mv_set
	movq %rsp, %rdi
	movl $RM_MEM, %esi
	movq %r12, %rdx
	call mv_rm
	movzbl IN_AAA(%r12), %eax
	movb %al, MV_K(%rsp)
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	addq $MV_BYTES, %rsp
	jmp .Lmova_ok
.Lmova_narrow:
	cmpl $0, (%rsp)
	jne .Lmova_narrow_store
	# the block broadcast into d (every block gets the data; the upper lanes go)
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_MEM, %edx
	movq %r12, %rcx
	xorl %r8d, %r8d
	movl %r15d, %r9d			# 0 -> 16-byte block (5A), 1 -> 32-byte half (5B)
	call em_load_block
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl %esi, %edx
	movl %r14d, %ecx
	call commit
	jmp .Lmova_ok
.Lmova_narrow_store:
	movl %r15d, %edi
	xorl %esi, %esi
	call vl_lanes
	movq %rbx, %rdi
	movl %eax, %esi
	call em_mask_imm
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movq %r12, %rdx
	movl %eax, %ecx
	xorl %r8d, %r8d
	movl $1, %r9d
	pushq $0
	pushq $0
	call em_unaligned
	addq $16, %rsp
	jmp .Lmova_ok
.Lmova_reg:
	# register to register: the load direction has d = reg, s = rm; the store direction d = rm, s = reg
	movzbl IN_REG(%r12), %esi
	movzbl IN_RM(%r12), %ecx
	cmpl $0, (%rsp)
	je 3f
	xchgl %esi, %ecx
3:	movl %esi, 8(%rsp)
	movq %rbx, %rdi
	movl $RM_REG, %edx
	movzbl IN_AAA(%r12), %r8d
	movl %r14d, %r9d
	call em_vmov
	movq %rbx, %rdi
	movl 8(%rsp), %esi
	movl %esi, %edx
	movl %r14d, %ecx
	call commit
.Lmova_ok:
	xorl %eax, %eax
	addq $16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_mov_unaligned: vmovups/vmovupd/vmovdqu32/64 (and VEX vmovdqu,
# vmovups): the unaligned pair over the memory operand (dwords whatever
# the element size; a qword mask is spread), a program mask applied by
# lane through a temporary (rewrite.rs unaligned_move); register to
# register as the aligned move.
xl_mov_unaligned:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $32, %rsp
	LOADCTX
	movl XF_B(%r13), %r14d
	andl $XB_QWORD, %r14d
	EV_LL %r15d
	movzbl IN_OP(%r12), %eax
	andl $1, %eax
	movzbl IN_OP(%r12), %ecx
	cmpl $0x7f, %ecx
	jne 1f
	movl $1, %eax
	jmp 2f
1:	cmpl $0x6f, %ecx
	jne 2f
	xorl %eax, %eax
2:	movl %eax, (%rsp)			# store?
	testb $H_MEM, IN_HAS(%r12)
	jnz 3f
	# register to register: the aligned move does the same
	movzbl IN_REG(%r12), %esi
	movzbl IN_RM(%r12), %ecx
	cmpl $0, (%rsp)
	je 21f
	xchgl %esi, %ecx
21:	movl %esi, 8(%rsp)
	movq %rbx, %rdi
	movl $RM_REG, %edx
	movzbl IN_AAA(%r12), %r8d
	movl %r14d, %r9d
	call em_vmov
	movq %rbx, %rdi
	movl 8(%rsp), %esi
	movl %esi, %edx
	movl %r14d, %ecx
	call commit
	jmp .Lmovu_ok
3:	# the span: the length's dword lanes (0 = all)
	xorl %eax, %eax
	movl %eax, 4(%rsp)			# span mask register
	cmpl $2, %r15d
	je 4f
	movl %r15d, %edi
	xorl %esi, %esi
	call vl_lanes
	movq %rbx, %rdi
	movl %eax, %esi
	call em_mask_imm
	movl %eax, 4(%rsp)
4:	# the program mask as dword lanes (a qword mask spread)
	movl $0, 8(%rsp)			# prog mask register (0 none)
	cmpb $0, IN_AAA(%r12)
	je 5f
	testl %r14d, %r14d
	jz 41f
	movl %r15d, %edi
	xorl %esi, %esi
	call vl_lanes
	movq %rbx, %rdi
	movzbl IN_AAA(%r12), %esi
	movl %eax, %edx
	call em_qmask_to_dmask
	movl %eax, 8(%rsp)
	jmp 5f
41:	movzbl IN_AAA(%r12), %eax
	movl %eax, 8(%rsp)
5:	cmpl $0, (%rsp)
	jne .Lmovu_store
	cmpl $0, 8(%rsp)
	jne 6f
	# an unmasked load straight into d
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movq %r12, %rdx
	movl 4(%rsp), %ecx
	xorl %r8d, %r8d
	xorl %r9d, %r9d
	pushq $0
	pushq $0
	call em_unaligned
	addq $16, %rsp
	jmp 7f
6:	# through a temporary, merged under the program mask, {z} zeroes the rest
	movq %rbx, %rdi
	call em_temp
	testl %eax, %eax
	js .Lmovu_notemp
	movl %eax, 12(%rsp)
	movq %rbx, %rdi
	movl %eax, %esi
	movq %r12, %rdx
	movl 4(%rsp), %ecx
	xorl %r8d, %r8d
	xorl %r9d, %r9d
	pushq $0
	pushq $0
	call em_unaligned
	addq $16, %rsp
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_REG, %edx
	movl 12(%rsp), %ecx
	movl 8(%rsp), %r8d
	xorl %r9d, %r9d
	call em_vmov
	cmpb $0, IN_Z(%r12)
	je 7f
	movq %rbx, %rdi
	call em_k
	movq %rbx, %rdi
	movl %eax, %esi
	movl 8(%rsp), %edx
	call em_knot
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movzbl EM_KSCR(%rbx), %edx
	xorl %ecx, %ecx
	call em_zero
7:	cmpl $2, %r15d
	je .Lmovu_ok
	movl %r15d, %edi
	call upper_lanes
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl %eax, %edx
	call em_zero_lanes
	jmp .Lmovu_ok
.Lmovu_store:
	cmpl $0, 8(%rsp)
	jne 8f
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movq %r12, %rdx
	movl 4(%rsp), %ecx
	xorl %r8d, %r8d
	movl $1, %r9d
	pushq $0
	pushq $0
	call em_unaligned
	addq $16, %rsp
	jmp .Lmovu_ok
8:	# read, merge under the program mask, write the span back
	movq %rbx, %rdi
	call em_temp
	testl %eax, %eax
	js .Lmovu_notemp
	movl %eax, 12(%rsp)
	movq %rbx, %rdi
	movl %eax, %esi
	movq %r12, %rdx
	movl 4(%rsp), %ecx
	xorl %r8d, %r8d
	xorl %r9d, %r9d
	pushq $0
	pushq $0
	call em_unaligned
	addq $16, %rsp
	movq %rbx, %rdi
	movl 12(%rsp), %esi
	movl $RM_REG, %edx
	movzbl IN_REG(%r12), %ecx
	movl 8(%rsp), %r8d
	xorl %r9d, %r9d
	call em_vmov
	movq %rbx, %rdi
	movl 12(%rsp), %esi
	movq %r12, %rdx
	movl 4(%rsp), %ecx
	xorl %r8d, %r8d
	movl $1, %r9d
	pushq $0
	pushq $0
	call em_unaligned
	addq $16, %rsp
.Lmovu_ok:
	xorl %eax, %eax
	jmp 9f
.Lmovu_notemp:
	leaq s_no_temp(%rip), %rax
9:	addq $32, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_broadcast: vbroadcastss/sd and vpbroadcastd/q from memory (the
# card's own, MVEX.512.66.0F38 18/19, under the mask), from a vector
# register (lane 0 to every lane: vpshufd 0 within the block, then
# vpermf32x4 0 across the blocks; a qword: vpshufd 0x44), from a
# general register (through the scratch's transfer slot). {z} and the
# length by commit.
xl_broadcast:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $16, %rsp
	LOADCTX
	movl XF_B(%r13), %r14d
	andl $XB_QWORD, %r14d
	testb $H_MEM, IN_HAS(%r12)
	jz 1f
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_MEM, %edx
	movq %r12, %rcx
	movzbl IN_AAA(%r12), %r8d
	movl %r14d, %r9d
	call em_broadcast
	jmp 8f
1:	# the source register: a vector register (xmm_rm) or a general one (r32_rm, r64_rm)
	movq IN_ENTRYP(%r12), %rax
	movzbl EN_OPS + 1(%rax), %eax
	cmpl $33, %eax				# r32_rm
	je 2f
	cmpl $38, %eax				# r64_rm
	je 2f
	# a vector register
	movl $0x00, %r15d			# vpshufd imm: lane 0 to the four
	testl %r14d, %r14d
	jz 11f
	movl $0x44, %r15d			# lanes 0 1 0 1: qword 0 to both
11:	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_REG, %edx
	movzbl IN_RM(%r12), %ecx
	movl %r15d, %r8d
	xorl %r9d, %r9d
	call xl_vpshufd
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_REG, %edx
	movzbl IN_REG(%r12), %ecx
	xorl %r8d, %r8d				# block 0 to the four
	xorl %r9d, %r9d
	call xl_vpermf32x4
	jmp 7f
2:	# a general register: through the transfer slot (mov [fs:S_XFER], r), then the broadcast from it
	movq %rbx, %rdi
	movzbl IN_RM(%r12), %esi
	movl %r14d, %edx
	movl $S_XFER, %ecx
	movl $1, %r8d
	call em_gpr_scratch
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_FS, %edx
	movl $S_XFER, %ecx
	xorl %r8d, %r8d
	movl %r14d, %r9d
	call em_broadcast
7:	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl %esi, %edx
	movl %r14d, %ecx
	call commit
	jmp 9f
8:	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl %esi, %edx
	movl %r14d, %ecx
	call commit
9:	xorl %eax, %eax
	addq $16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
# xl_vpshufd(em, d, rmkind, rm, imm, k) and xl_vpermf32x4: the two-operand
# forms with an immediate through em_op2i.
xl_vpshufd:
	pushq %r9
	pushq %r8
	pushq %rcx
	pushq %rdx
	pushq %rsi
	movl $1, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0x70, %r8d
	movl (%rsp), %r9d
	addq $8, %rsp
	call em_op2i
	addq $32, %rsp
	ret
xl_vpermf32x4:
	pushq %r9
	pushq %r8
	pushq %rcx
	pushq %rdx
	pushq %rsi
	movl $3, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0x07, %r8d
	movl (%rsp), %r9d
	addq $8, %rsp
	call em_op2i
	addq $32, %rsp
	ret

# xl_ternlog: vpternlogd/q d{k}, s1, s2, table. The table of three
# inputs d, s1, s2 split on d: d = d ? f1(s1, s2) : f0(s1, s2), each a
# two-input function of the card's bitwise instructions (and, andn, or,
# xor, a copy, a complement, all ones, all zeros) (rewrite.rs ternlog,
# bool2). Here the register forms; a memory operand is refused for now.
xl_ternlog:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $32, %rsp
	LOADCTX
	movl XF_B(%r13), %r14d
	andl $XB_QWORD, %r14d
	testb $H_MEM, IN_HAS(%r12)
	jnz .Ltern_mem
	movzbl IN_IMM(%r12), %r15d		# the table: bit (d << 2 | s1 << 1 | s2)
	# f0 = bits 0..3 (d = 0), f1 = bits 4..7 (d = 1), each a function of (s1, s2) with bit (s1 << 1 | s2)
	movl %r15d, %eax
	andl $0xf, %eax
	movl %eax, (%rsp)			# f0
	movl %r15d, %eax
	shrl $4, %eax
	movl %eax, 4(%rsp)			# f1
	# the easy tables: all ones (0xff) and all zeros (0x00)
	cmpl $0xff, %r15d
	jne 1f
	movq %rbx, %rdi
	movl $0xffffffff, %esi
	call em_const_dw
	testl %eax, %eax
	js .Ltern_notemp
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_CONST, %edx
	movl %eax, %ecx
	xorl %r8d, %r8d
	xorl %r9d, %r9d
	call em_vmov
	jmp .Ltern_commit
1:	cmpl $0, %r15d
	jne 2f
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	xorl %edx, %edx
	xorl %ecx, %ecx
	call em_zero
	jmp .Ltern_commit
2:	# f0 == f1: the result does not depend on d: d = f(s1, s2)
	movl (%rsp), %eax
	cmpl 4(%rsp), %eax
	jne 3f
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movzbl IN_VVVV(%r12), %edx
	movzbl IN_RM(%r12), %ecx
	movl (%rsp), %r8d
	call bool2
	testq %rax, %rax
	jnz .Ltern_out
	jmp .Ltern_commit
3:	# the general split: t = f1(s1, s2) and u = f0(s1, s2); d = (d and t) or (not d and u)
	movq %rbx, %rdi
	call em_temp
	testl %eax, %eax
	js .Ltern_notemp
	movl %eax, 8(%rsp)			# t
	movq %rbx, %rdi
	call em_temp
	testl %eax, %eax
	js .Ltern_notemp
	movl %eax, 12(%rsp)			# u
	movq %rbx, %rdi
	movl 8(%rsp), %esi
	movzbl IN_VVVV(%r12), %edx
	movzbl IN_RM(%r12), %ecx
	movl 4(%rsp), %r8d
	call bool2
	testq %rax, %rax
	jnz .Ltern_out
	movq %rbx, %rdi
	movl 12(%rsp), %esi
	movzbl IN_VVVV(%r12), %edx
	movzbl IN_RM(%r12), %ecx
	movl (%rsp), %r8d
	call bool2
	testq %rax, %rax
	jnz .Ltern_out
	# t = d and t; u = (not d) and u (vpandnd u, d, u: (not d) and u); d = t or u
	movq %rbx, %rdi
	movl $0xdb, %esi
	movl 8(%rsp), %edx
	movzbl IN_REG(%r12), %ecx
	movl 8(%rsp), %r8d
	call bitop
	movq %rbx, %rdi
	movl $0xdf, %esi
	movl 12(%rsp), %edx
	movzbl IN_REG(%r12), %ecx
	movl 12(%rsp), %r8d
	call bitop
	movq %rbx, %rdi
	movl $0xeb, %esi
	movzbl IN_REG(%r12), %edx
	movl 8(%rsp), %ecx
	movl 12(%rsp), %r8d
	call bitop
.Ltern_commit:
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl %esi, %edx
	movl %r14d, %ecx
	call commit
	xorl %eax, %eax
	jmp .Ltern_out
.Ltern_mem:
	leaq s_ternlog(%rip), %rax
	jmp .Ltern_out
.Ltern_notemp:
	leaq s_no_temp(%rip), %rax
.Ltern_out:
	addq $32, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
# bitop(em rdi, op esi, d edx, s1 ecx, s2 r8d): a 66.0F.W0 bitwise op
# (and DB, andn DF, or EB, xor EF) on dword lanes, no mask.
bitop:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES, %rsp
	movq %rdi, %r15
	movl %edx, %r12d
	movl %ecx, %r13d
	movl %r8d, %r14d
	movq %rsp, %rdi
	movl %esi, %r8d
	movl $1, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl %r12d, %r9d
	call mv_set
	movb %r13b, MV_VVVV(%rsp)
	movb %r14b, MV_RM(%rsp)
	movq %r15, %rdi
	movq %rsp, %rsi
	call em_mvex
	addq $MV_BYTES, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
# bool2(em rdi, t esi, b edx, c ecx, table r8d): t = f(b, c) for the
# two-input table (bit (b << 1 | c)): 0 zero, 1 nor, 2 c and not b, 3
# not b, 4 b and not c, 5 not c, 6 xor, 7 nand, 8 and, 9 xnor, 10 c, 11
# not b or c, 12 b, 13 b or not c, 14 or, 15 ones. The complements go
# through all ones (a constant). rax 0 or a refusal.
bool2:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %rbx
	movl %esi, %r12d
	movl %edx, %r13d
	movl %ecx, %r14d
	movl %r8d, %r15d
	leaq .Lbool2_tab(%rip), %rax
	movzbl (%rax,%r15), %eax
	movl %eax, %r8d				# the opcode, or a code: 0xf0 zero, 0xf1 ones, 0xf2 copy b, 0xf3 copy c, 0xf4 not b, 0xf5 not c, 0xf6 nor, 0xf7 nand, 0xf8 xnor, 0xf9 not b or c, 0xfa b or not c
	cmpl $0xf0, %r8d
	jb 1f
	je 2f
	cmpl $0xf1, %r8d
	je 3f
	cmpl $0xf2, %r8d
	je 4f
	cmpl $0xf3, %r8d
	je 5f
	# the complements: t = f'(b, c) then t = t xor ones; nor = not or, nand = not and, xnor = not xor, not b = b xor ones, not c = c xor ones, not b or c = (b andn c)' ... computed as not (b and not c), b or not c = not (not b and c)
	cmpl $0xf4, %r8d
	jne 41f
	movl $0xf2, %esi
	jmp 6f
41:	cmpl $0xf5, %r8d
	jne 42f
	movl $0xf3, %esi
	jmp 6f
42:	cmpl $0xf6, %r8d
	jne 43f
	movl $0xeb, %esi
	jmp 6f
43:	cmpl $0xf7, %r8d
	jne 44f
	movl $0xdb, %esi
	jmp 6f
44:	cmpl $0xf8, %r8d
	jne 45f
	movl $0xef, %esi
	jmp 6f
45:	cmpl $0xf9, %r8d
	jne 46f
	# not b or c = not (b and not c): b andn c is (not b) and c; we need b and (not c) = c andn b: vpandnd t, c, b
	movq %rbx, %rdi
	movl $0xdf, %esi
	movl %r12d, %edx
	movl %r14d, %ecx
	movl %r13d, %r8d
	call bitop
	jmp 7f
46:	# 0xfa: b or not c = not ((not b) and c) = not (vpandnd b, c)
	movq %rbx, %rdi
	movl $0xdf, %esi
	movl %r12d, %edx
	movl %r13d, %ecx
	movl %r14d, %r8d
	call bitop
	jmp 7f
6:	# the first step of a complemented function
	cmpl $0xf2, %esi
	je 61f
	cmpl $0xf3, %esi
	je 62f
	movq %rbx, %rdi
	movl %r12d, %edx
	movl %r13d, %ecx
	movl %r14d, %r8d
	call bitop
	jmp 7f
61:	movq %rbx, %rdi
	movl %r12d, %esi
	movl $RM_REG, %edx
	movl %r13d, %ecx
	xorl %r8d, %r8d
	xorl %r9d, %r9d
	call em_vmov
	jmp 7f
62:	movq %rbx, %rdi
	movl %r12d, %esi
	movl $RM_REG, %edx
	movl %r14d, %ecx
	xorl %r8d, %r8d
	xorl %r9d, %r9d
	call em_vmov
7:	# t = t xor ones
	movq %rbx, %rdi
	movl $0xffffffff, %esi
	call em_const_dw
	testl %eax, %eax
	js 8f
	pushq %rax
	pushq %rax
	movq %rsp, %rdi
	subq $MV_BYTES, %rsp
	movq %rsp, %rdi
	movl $1, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0xef, %r8d
	movl %r12d, %r9d
	call mv_set
	movb %r12b, MV_VVVV(%rsp)
	movq %rsp, %rdi
	movl $RM_CONST, %esi
	movl MV_BYTES(%rsp), %edx
	call mv_rm
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	addq $MV_BYTES + 16, %rsp
	jmp 9f
1:	# a plain bitwise op
	movq %rbx, %rdi
	movl %r8d, %esi
	movl %r12d, %edx
	movl %r13d, %ecx
	movl %r14d, %r8d
	# andn's operand order: vpandnd t, b, c = (not b) and c = table 2; table 4 (b and not c) swaps them
	cmpl $4, %r15d
	jne 11f
	movl %r14d, %ecx
	movl %r13d, %r8d
11:	call bitop
	jmp 9f
2:	movq %rbx, %rdi
	movl %r12d, %esi
	xorl %edx, %edx
	xorl %ecx, %ecx
	call em_zero
	jmp 9f
3:	movq %rbx, %rdi
	movl $0xffffffff, %esi
	call em_const_dw
	testl %eax, %eax
	js 8f
	movq %rbx, %rdi
	movl %r12d, %esi
	movl $RM_CONST, %edx
	movl %eax, %ecx
	xorl %r8d, %r8d
	xorl %r9d, %r9d
	call em_vmov
	jmp 9f
4:	movq %rbx, %rdi
	movl %r12d, %esi
	movl $RM_REG, %edx
	movl %r13d, %ecx
	xorl %r8d, %r8d
	xorl %r9d, %r9d
	call em_vmov
	jmp 9f
5:	movq %rbx, %rdi
	movl %r12d, %esi
	movl $RM_REG, %edx
	movl %r14d, %ecx
	xorl %r8d, %r8d
	xorl %r9d, %r9d
	call em_vmov
	jmp 9f
8:	leaq s_no_temp(%rip), %rax
	jmp 10f
9:	xorl %eax, %eax
10:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
	.section .rodata
.Lbool2_tab:
	# table index 0..15 -> opcode or code
	.byte 0xf0, 0xf6, 0xdf, 0xf4, 0xdf, 0xf5, 0xef, 0xf7, 0xdb, 0xf8, 0xf3, 0xf9, 0xf2, 0xfa, 0xeb, 0xf1
	.text

# xl_extract: vextract{f,i}{32x4,64x2,128} (a 128-bit block: XF_A 0)
# and vextract{f,i}{64x4,32x8} (a 256-bit half: XF_A 1) of a zmm or ymm
# into a register or memory: the block or half moved to the bottom by
# vpermf32x4 (the immediate selecting the blocks), the lanes above
# zeroed; to memory, the pack pair under the lanes. {k} and {z} by
# commit for the register form; a masked store under the mask.
xl_extract:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $16, %rsp
	LOADCTX
	movl XF_A(%r13), %r14d			# 1 = a 256-bit half
	movzbl IN_IMM(%r12), %r15d
	# the vpermf32x4 immediate: a block i -> field 0 = i; a half h -> fields 0 1 = 2h 2h+1
	testl %r14d, %r14d
	jnz 1f
	andl $3, %r15d
	movl %r15d, %eax
	jmp 2f
1:	andl $1, %r15d
	leal (%r15,%r15), %eax			# 2h
	leal 1(%rax), %ecx			# 2h + 1
	shll $2, %ecx
	orl %ecx, %eax
2:	movl %eax, (%rsp)			# the immediate
	# the lanes of the result: 4 or 8 dwords
	movl $0x000f, %eax
	testl %r14d, %r14d
	jz 3f
	movl $0x00ff, %eax
3:	movl %eax, 4(%rsp)
	testb $H_MEM, IN_HAS(%r12)
	jnz .Lext_mem
	# into a register: the destination is the r/m operand, the source the reg field
	movq %rbx, %rdi
	movzbl IN_RM(%r12), %esi
	movl $RM_REG, %edx
	movzbl IN_REG(%r12), %ecx
	movl (%rsp), %r8d
	xorl %r9d, %r9d
	call xl_vpermf32x4
	# the length of the destination is the result's: the upper lanes go; {k}{z} apply
	movq %rbx, %rdi
	movzbl IN_RM(%r12), %esi
	movl %esi, %edx
	xorl %ecx, %ecx
	call commit_lanes
	jmp .Lext_ok
.Lext_mem:
	movq %rbx, %rdi
	call em_temp
	testl %eax, %eax
	js .Lext_notemp
	movl %eax, 8(%rsp)
	movq %rbx, %rdi
	movl %eax, %esi
	movl $RM_REG, %edx
	movzbl IN_REG(%r12), %ecx
	movl (%rsp), %r8d
	xorl %r9d, %r9d
	call xl_vpermf32x4
	movl 4(%rsp), %esi
	cmpb $0, IN_AAA(%r12)
	je 4f
	# a masked store: the lanes and the mask
	movq %rbx, %rdi
	call em_mask_imm
	movq %rbx, %rdi
	movl %eax, %esi
	movzbl IN_AAA(%r12), %edx
	call em_kand
	movzbl EM_KSCR(%rbx), %eax
	jmp 5f
4:	movq %rbx, %rdi
	call em_mask_imm
5:	movq %rbx, %rdi
	movl 8(%rsp), %esi
	movq %r12, %rdx
	movl %eax, %ecx
	xorl %r8d, %r8d
	movl $1, %r9d
	pushq $0
	pushq $0
	call em_unaligned
	addq $16, %rsp
.Lext_ok:
	xorl %eax, %eax
	jmp 9f
.Lext_notemp:
	leaq s_no_temp(%rip), %rax
9:	addq $16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
# commit_lanes(em rdi, d esi, r edx): as commit, but the length is the
# destination register's (an extract's result is narrower than its
# source): the destination's length from its operand kind.
commit_lanes:
	pushq %rbx
	pushq %r12
	pushq %r13
	movq %rdi, %rbx
	movl %esi, %r12d
	movl %edx, %r13d
	movq EM_IN(%rbx), %rax
	movq IN_ENTRYP(%rax), %rcx
	movzbl EN_OPS(%rcx), %ecx		# the destination's kind: xmm (48) ymm (54) zmm (59) or _or_mem
	movl $0, %edx
	cmpl $54, %ecx
	je 1f
	cmpl $21, %ecx
	je 1f
	cmpl $59, %ecx
	je 2f
	cmpl $22, %ecx
	je 2f
	jmp 3f
1:	movl $1, %edx
	jmp 3f
2:	movl $2, %edx
3:	# commit reads the length from the instruction: set it for the call, then put it back
	movzbl IN_L(%rax), %ecx
	pushq %rcx
	pushq %rax
	movb %dl, IN_L(%rax)
	movq %rbx, %rdi
	movl %r12d, %esi
	movl %r13d, %edx
	xorl %ecx, %ecx
	call commit
	popq %rax
	popq %rcx
	movb %cl, IN_L(%rax)
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_permilps: vpermilps d, s, imm (a dword permute within each 128-bit
# block) and vpshufd: the card's vpshufd with the same immediate, under
# the length's lanes.
xl_permilps:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	LOADCTX
	movq IN_ENTRYP(%r12), %rax
	movzbl EN_OPS + 2(%rax), %eax
	cmpl $82, %eax				# imm8: the immediate form
	jne .Lperm_shape
	testb $H_MEM, IN_HAS(%r12)
	jz 1f
	movq %rbx, %rdi
	xorl %esi, %esi
	xorl %edx, %edx
	call src2
	testl %eax, %eax
	js .Lperm_notemp
	movl %eax, %ecx
	jmp 2f
1:	movzbl IN_RM(%r12), %ecx
2:	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_REG, %edx
	movzbl IN_IMM(%r12), %r8d
	xorl %r9d, %r9d
	call xl_vpshufd
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl %esi, %edx
	xorl %ecx, %ecx
	call commit
	xorl %eax, %eax
	jmp 9f
.Lperm_shape:
	leaq s_shape(%rip), %rax
	jmp 9f
.Lperm_notemp:
	leaq s_no_temp(%rip), %rax
9:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_shufps: vshufps d, s1, s2, imm: per block, lanes 0 and 1 from s1
# (selected by the immediate's low fields), lanes 2 and 3 from s2 (the
# high fields): two vpshufd under the lane masks 0x3333 and 0xcccc into
# a temporary (s2 may be d), then the result moved under the length.
xl_shufps:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $16, %rsp
	LOADCTX
	testb $H_MEM, IN_HAS(%r12)
	jz 1f
	movq %rbx, %rdi
	xorl %esi, %esi
	xorl %edx, %edx
	call src2
	testl %eax, %eax
	js .Lshuf_notemp
	movl %eax, %r14d
	jmp 2f
1:	movzbl IN_RM(%r12), %r14d		# s2
2:	movq %rbx, %rdi
	call em_temp
	testl %eax, %eax
	js .Lshuf_notemp
	movl %eax, %r15d			# t
	movq %rbx, %rdi
	movl $0x3333, %esi
	call em_mask_imm
	movq %rbx, %rdi
	movl %r15d, %esi
	movl $RM_REG, %edx
	movzbl IN_VVVV(%r12), %ecx
	movzbl IN_IMM(%r12), %r8d
	movl %eax, %r9d
	call xl_vpshufd
	movq %rbx, %rdi
	movl $0xcccc, %esi
	call em_mask_imm
	movq %rbx, %rdi
	movl %r15d, %esi
	movl $RM_REG, %edx
	movl %r14d, %ecx
	movzbl IN_IMM(%r12), %r8d
	movl %eax, %r9d
	call xl_vpshufd
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl %r15d, %edx
	xorl %ecx, %ecx
	call commit
	xorl %eax, %eax
	jmp 9f
.Lshuf_notemp:
	leaq s_no_temp(%rip), %rax
9:	addq $16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_movss: vmovss/vmovsd. Register form d, s1, s2: lane 0 (lanes 0 1
# for sd) from s2, the rest of the low 128 bits from s1, the upper
# lanes zero. Load d{k}, m32: the element into lane 0 under the mask
# (a broadcast then the lanes above 0 zeroed), {z} zeroes lane 0 when
# the mask bit is clear, else it keeps d's lane 0 ... (AVX-512: merging
# keeps d's lane; the rest of the vector is zeroed). Store m32{k}, s:
# the pack pair under lane 0.
xl_movss:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $16, %rsp
	LOADCTX
	movl XF_B(%r13), %r14d
	andl $XB_QWORD, %r14d
	movl $0x0001, %r15d			# lane 0 as dwords
	testl %r14d, %r14d
	jz 1f
	movl $0x0003, %r15d
1:	testb $H_MEM, IN_HAS(%r12)
	jnz .Lmovss_mem
	# register form: d = {s2 lane 0, s1 lanes 1..3} (lanes 2 3 for sd come from s1 too)
	movzbl IN_REG(%r12), %eax
	cmpb IN_VVVV(%r12), %al
	je 2f
	# d != s1: d{low 4 lanes} = s1 first
	movq %rbx, %rdi
	movl $0x000f, %esi
	call em_mask_imm
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_REG, %edx
	movzbl IN_VVVV(%r12), %ecx
	movl %eax, %r8d
	xorl %r9d, %r9d
	call em_vmov
2:	movq %rbx, %rdi
	movl %r15d, %esi
	call em_mask_imm
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_REG, %edx
	movzbl IN_RM(%r12), %ecx
	movl %eax, %r8d
	xorl %r9d, %r9d
	call em_vmov
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $0xfff0, %edx
	call em_zero_lanes
	jmp .Lmovss_ok
.Lmovss_mem:
	movzbl IN_OP(%r12), %eax
	cmpl $0x11, %eax
	je .Lmovss_store
	# a load: the element broadcast (4- or 8-byte alignment is all the card needs), lanes above 0 zeroed; {k}: lane 0 under the mask, {z} zeroes it when clear
	movq %rbx, %rdi
	movl %r15d, %esi
	call em_mask_imm
	movl %eax, (%rsp)
	cmpb $0, IN_AAA(%r12)
	je 3f
	movq %rbx, %rdi
	movl %eax, %esi
	movzbl IN_AAA(%r12), %edx
	call em_kand
3:	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_MEM, %edx
	movq %r12, %rcx
	movl (%rsp), %r8d
	movl %r14d, %r9d
	call em_broadcast
	cmpb $0, IN_Z(%r12)
	je 4f
	cmpb $0, IN_AAA(%r12)
	je 4f
	movq %rbx, %rdi
	call em_k
	movq %rbx, %rdi
	movl %eax, %esi
	movl (%rsp), %edx
	call em_knot
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movzbl EM_KSCR(%rbx), %edx
	xorl %ecx, %ecx
	call em_zero
4:	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $0xffff, %edx
	xorl %r15d, %edx			# every lane but the element's
	call em_zero_lanes
	jmp .Lmovss_ok
.Lmovss_store:
	movq %rbx, %rdi
	movl %r15d, %esi
	call em_mask_imm
	cmpb $0, IN_AAA(%r12)
	je 5f
	movq %rbx, %rdi
	movl %eax, %esi
	movzbl IN_AAA(%r12), %edx
	call em_kand
	movzbl EM_KSCR(%rbx), %eax
5:	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movq %r12, %rdx
	movl %eax, %ecx
	xorl %r8d, %r8d
	movl $1, %r9d
	pushq $0
	pushq $0
	call em_unaligned
	addq $16, %rsp
.Lmovss_ok:
	xorl %eax, %eax
	addq $16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_scalar: vaddss/vsubss/vmulss (and sd, and the fma ss forms): lane 0
# (lanes 0 1 for sd) of d = op(s1, s2) under the lane mask (and {k}),
# lanes 1..3 of the low 128 bits from s1, the upper lanes zero. The
# card's packed instruction on lane 0 is the same IEEE operation. A
# memory second operand is refused for now (its broadcast form would
# serve: a 4-byte alignment).
xl_scalar:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES + 16, %rsp
	LOADCTX
	movl XF_B(%r13), %r14d
	andl $XB_QWORD, %r14d
	movl $0x0001, %r15d
	testl %r14d, %r14d
	jz 1f
	movl $0x0003, %r15d
1:	cmpb $0, IN_Z(%r12)
	je 11f
	cmpb $0, IN_AAA(%r12)
	jne .Lscalar_shape			# {z} under a mask on a scalar: not translated yet
11:	movq %rsp, %rdi
	movl XF_A(%r13), %eax
	movzbl %al, %esi
	movl %eax, %edx
	shrl $8, %edx
	movzbl %dl, %edx
	movl %eax, %ecx
	shrl $16, %ecx
	movzbl %cl, %ecx
	movl %eax, %r8d
	shrl $24, %r8d
	movzbl IN_REG(%r12), %r9d
	call mv_set
	movzbl IN_VVVV(%r12), %eax
	movb %al, MV_VVVV(%rsp)
	testb $H_MEM, IN_HAS(%r12)
	jz 2f
	# the memory element as a broadcast source (SSS 001): every lane sees it, lane 0 is kept
	movq %rsp, %rdi
	movl $RM_MEM, %esi
	movq %r12, %rdx
	call mv_rm
	movb $1, MV_SSS(%rsp)
	jmp 3f
2:	movq %rsp, %rdi
	movl $RM_REG, %esi
	movzbl IN_RM(%r12), %edx
	call mv_rm
3:	# d's lanes 1..3 from s1 first when d != s1 (the op does not touch them)
	movzbl IN_REG(%r12), %eax
	cmpb IN_VVVV(%r12), %al
	je 4f
	movq %rbx, %rdi
	movl $0x000f, %esi
	call em_mask_imm
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_REG, %edx
	movzbl IN_VVVV(%r12), %ecx
	movl %eax, %r8d
	xorl %r9d, %r9d
	call em_vmov
4:	# the lane mask (and {k})
	movq %rbx, %rdi
	movl %r15d, %esi
	call em_mask_imm
	movl %eax, MV_BYTES(%rsp)
	cmpb $0, IN_AAA(%r12)
	je 5f
	movq %rbx, %rdi
	movl %eax, %esi
	movzbl IN_AAA(%r12), %edx
	call em_kand
5:	movl MV_BYTES(%rsp), %eax
	movb %al, MV_K(%rsp)
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
6:	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $0xfff0, %edx
	call em_zero_lanes
	xorl %eax, %eax
	jmp 9f
.Lscalar_shape:
	leaq s_shape(%rip), %rax
9:	addq $MV_BYTES + 16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_nothing: vzeroupper: the upper halves of ymm0..15 are zeroed by the
# handler when the function returns; inside a function nothing reads
# them in the program's own terms (the VEX forms zero them anyway).
xl_nothing:
	xorl %eax, %eax
	ret
# xl_zeroall: vzeroall: zmm0..15 zeroed.
xl_zeroall:
	pushq %rbx
	pushq %r12
	movq %rdi, %rbx
	xorl %r12d, %r12d
1:	movq %rbx, %rdi
	movl %r12d, %esi
	xorl %edx, %edx
	xorl %ecx, %ecx
	call em_zero
	incl %r12d
	cmpl $16, %r12d
	jb 1b
	xorl %eax, %eax
	popq %r12
	popq %rbx
	ret
	.section .note.GNU-stack,"",@progbits
