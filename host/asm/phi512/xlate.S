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
	FORM MN_Vpermd, xl_permd2, 0, 0
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
	FORM MN_Vpslld, xl_shift_d, 6, 0
	FORM MN_Vpsrld, xl_shift_d, 2, 0
	FORM MN_Vpsrad, xl_shift_d, 4, 0
	# compares into a mask
	FORM MN_Vpcmpeqd, xl_cmp_vec, (1 | (1 << 8) | (0 << 16) | (0x76 << 24)), 0
	FORM MN_Vpcmpgtd, xl_cmp_vec, (1 | (1 << 8) | (0 << 16) | (0x66 << 24)), 0
	FORM MN_Vpcmpd, xl_cmp_k2, (3 | (1 << 8) | (0 << 16) | (0x1f << 24)), XB_IMM
	FORM MN_Vpcmpud, xl_cmp_k2, (3 | (1 << 8) | (0 << 16) | (0x1e << 24)), XB_IMM
	FORM MN_Vcmpps, xl_cmp_vec, (1 | (0 << 8) | (0 << 16) | (0xc2 << 24)), XB_IMM | XB_FLOAT
	FORM MN_Vcmppd, xl_cmp_vec, (1 | (1 << 8) | (1 << 16) | (0xc2 << 24)), XB_IMM | XB_FLOAT | XB_QWORD
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
	FORM MN_Vpmaskmovd, xl_maskmov, 0, 0
	FORM MN_Vmovmskps, xl_movmsk, 0, 0
	FORM MN_Shlx, xl_shiftx, 4, 0
	FORM MN_Shrx, xl_shiftx, 5, 0
	FORM MN_Sarx, xl_shiftx, 7, 0
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
	FORM MN_Vpermilps, xl_permilps2, 0, 0
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
	FORM MN_Vfmadd132ss, xl_scalar, (2 | (1 << 8) | (0 << 16) | (0x98 << 24)), 0
	FORM MN_Vfmadd213ss, xl_scalar, (2 | (1 << 8) | (0 << 16) | (0xa8 << 24)), 0
	FORM MN_Vfmadd231ss, xl_scalar, (2 | (1 << 8) | (0 << 16) | (0xb8 << 24)), 0
	# interleaves: per block two vpshufd (the immediates) and the lanes taken from the second source
	FORM MN_Vunpcklps, xl_interleave, (0x50 | (0x50 << 8) | (0xaaaa << 16)), 0
	FORM MN_Vunpckhps, xl_interleave, (0xfa | (0xfa << 8) | (0xaaaa << 16)), 0
	FORM MN_Vpunpckldq, xl_interleave, (0x50 | (0x50 << 8) | (0xaaaa << 16)), 0
	FORM MN_Vpunpckhdq, xl_interleave, (0xfa | (0xfa << 8) | (0xaaaa << 16)), 0
	FORM MN_Vunpcklpd, xl_interleave, (0x44 | (0x44 << 8) | (0xcccc << 16)), 0
	FORM MN_Vunpckhpd, xl_interleave, (0xee | (0xee << 8) | (0xcccc << 16)), 0
	FORM MN_Vpunpcklqdq, xl_interleave, (0x44 | (0x44 << 8) | (0xcccc << 16)), 0
	FORM MN_Vpunpckhqdq, xl_interleave, (0xee | (0xee << 8) | (0xcccc << 16)), 0
	FORM MN_Vmovlhps, xl_interleave, (0x44 | (0x44 << 8) | (0xcccc << 16)), 0
	FORM MN_Vmovhlps, xl_interleave, (0xee | (0xee << 8) | (0x3333 << 16)), 0
	# the scalar compares into the flags
	FORM MN_Vcomiss, xl_comis, 0, 0
	FORM MN_Vucomiss, xl_comis, 0, 0
	FORM MN_Vcomisd, xl_comis, 0, XB_QWORD
	FORM MN_Vucomisd, xl_comis, 0, XB_QWORD
	# a lane to and from a general register or memory
	FORM MN_Vmovq, xl_movq, 1, 0
	FORM MN_Vmovd, xl_movq, 0, 0
	FORM MN_Vpinsrq, xl_pinsr, 1, 0
	FORM MN_Vpinsrd, xl_pinsr, 0, 0
	FORM MN_Vpextrq, xl_pextr, 1, 0
	FORM MN_Vpextrd, xl_pextr, 0, 0
	# a 16-byte block or a 32-byte half inserted
	FORM MN_Vinserti32x4, xl_insert, 0, 0
	FORM MN_Vinsertf32x4, xl_insert, 0, 0
	FORM MN_Vinserti128, xl_insert, 0, 0
	FORM MN_Vinsertf128, xl_insert, 0, 0
	FORM MN_Vinserti64x4, xl_insert, 1, 0
	FORM MN_Vinsertf64x4, xl_insert, 1, 0
	# the scalar conversions and the operations the card has no instruction for (x87)
	FORM MN_Vcvtsi2ss, xl_cvti2s, 0, 0
	FORM MN_Vcvtsi2sd, xl_cvti2s, 1, 0
	FORM MN_Vcvtss2sd, xl_cvtss2sd, 0, 0
	FORM MN_Vcvtsd2ss, xl_cvtss2sd, 1, 0
	FORM MN_Vdivss, xl_divs, 0, 0
	FORM MN_Vdivsd, xl_divs, 1, 0
	FORM MN_Vsqrtss, xl_sqrts, 0, 0
	FORM MN_Vsqrtsd, xl_sqrts, 1, 0
	# byte and word lanes the card has no mask for: synthesised in dword lanes
	FORM MN_Vpcmpeqb, xl_cmpeqb, 0, 0
	FORM MN_Vpcmpeqw, xl_cmpeqb, 1, 0
	FORM MN_Vptest, xl_ptest, 0, 0
	# the mask registers: the card has the two-operand forms
	FORM MN_Kmovw, xl_kmov, 0, 0
	FORM MN_Kortestw, xl_kcopy, 0x98, 0
	FORM MN_Knotw, xl_kcopy, 0x44, 0
	FORM MN_Kandw, xl_kbin, 0x41, 0
	FORM MN_Kandnw, xl_kbin, 0x42, 0
	FORM MN_Korw, xl_kbin, 0x45, 0
	FORM MN_Kxorw, xl_kbin, 0x47, 0
	FORM MN_Kxnorw, xl_kbin, 0x46, 0
	FORM MN_Kunpckbw, xl_kunpck, 0, 0
	# qword compares: dword compares packed two bits to one
	FORM MN_Vpcmpeqq, xl_cmp_q, 0, 0
	FORM MN_Vzeroupper, xl_nothing, 0, 0
	FORM MN_Vzeroall, xl_zeroall, 0, 0
	.include "xlate2.inc"
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
	.globl xl_tab
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
	testl $XB_IMM, %r14d
	jz 21f
	movzbl IN_IMM(%r12), %eax
	movw %ax, MV_IMM(%rsp)		# valignd: the immediate
21:	# the second source
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
	# an unmasked load straight into d, at whatever alignment
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movq %r12, %rdx
	movl 4(%rsp), %ecx
	movl %r15d, %r8d
	xorl %r9d, %r9d
	call em_unaligned_any
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
	movl %r15d, %r8d
	movl $1, %r9d
	call em_unaligned_any
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
.Ltern_reg:
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
	# the memory operand (or a broadcast) staged into a temporary, then the register path on it
	movq %rbx, %rdi
	movl %r14d, %esi
	xorl %edx, %edx
	call src2
	testl %eax, %eax
	js .Ltern_notemp
	movb %al, IN_RM(%r12)
	andb $~H_MEM, IN_HAS(%r12)
	movb $0, IN_B(%r12)
	jmp .Ltern_reg
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
3:	# (the rest of the low 128 bits come from s1 after the operation: lane 0 is its addend)
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
6:	# lanes 1 to 3 (lane 1 for sd) from s1 when d is another register
	movzbl IN_REG(%r12), %eax
	cmpb IN_VVVV(%r12), %al
	je 61f
	movl $0xe, %esi
	testl %r14d, %r14d
	jz 60f
	movl $0x2, %esi
60:	movq %rbx, %rdi
	call em_mask_imm
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_REG, %edx
	movzbl IN_VVVV(%r12), %ecx
	movl %eax, %r8d
	movl %r14d, %r9d
	call em_vmov
61:	movq %rbx, %rdi
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

# xl_interleave: vunpckl/hps, vpunpckl/hdq, vunpckl/hpd, vpunpckl/hqdq,
# vmovlhps, vmovhlps: per 128-bit block a vpshufd of s1 and one of s2
# (the form's two immediates) merged under the lanes the second gives
# (the form's mask), into a temporary, then commit (rewrite.rs
# interleave).
	.text
xl_interleave:
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
	js .Lil_notemp
	movl %eax, %r14d
	jmp 2f
1:	movzbl IN_RM(%r12), %r14d		# s2
2:	movq %rbx, %rdi
	call em_temp
	testl %eax, %eax
	js .Lil_notemp
	movl %eax, %r15d			# r
	movq %rbx, %rdi
	call em_temp
	testl %eax, %eax
	js .Lil_notemp
	movl %eax, (%rsp)			# t
	movq %rbx, %rdi
	movl %r15d, %esi
	movl $RM_REG, %edx
	movzbl IN_VVVV(%r12), %ecx
	movl XF_A(%r13), %r8d
	andl $0xff, %r8d
	xorl %r9d, %r9d
	call xl_vpshufd
	movq %rbx, %rdi
	movl (%rsp), %esi
	movl $RM_REG, %edx
	movl %r14d, %ecx
	movl XF_A(%r13), %r8d
	shrl $8, %r8d
	andl $0xff, %r8d
	xorl %r9d, %r9d
	call xl_vpshufd
	movq %rbx, %rdi
	movl XF_A(%r13), %esi
	shrl $16, %esi
	call em_mask_imm
	movq %rbx, %rdi
	movl %r15d, %esi
	movl $RM_REG, %edx
	movl (%rsp), %ecx
	movl %eax, %r8d
	xorl %r9d, %r9d
	call em_vmov
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl %r15d, %edx
	xorl %ecx, %ecx
	call commit
	xorl %eax, %eax
	jmp 9f
.Lil_notemp:
	leaq s_no_temp(%rip), %rax
9:	addq $16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_comis: vcomiss/vucomiss/vcomisd/vucomisd: the flags from three
# compares of lane 0 into the scratch mask (less: CF; equal: ZF;
# unordered: ZF, PF and CF), composed in ecx, written to [fs:S_XFER],
# which em_finish puts into the flags last of all (rewrite.rs comis). A
# memory operand is the broadcast source (SSS 001).
xl_comis:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES + 16, %rsp
	LOADCTX
	movl XF_B(%r13), %r14d
	andl $XB_QWORD, %r14d
	movq %rbx, %rdi
	call em_rax
	movq %rbx, %rdi
	call em_rcx
	movq %rbx, %rdi
	call em_k
	movl %eax, %r15d			# ks
	# the block: vcmpps (0F C2, pp 0 W0) or vcmppd (66 0F W1 C2); reg = ks, vvvv = s1 (IN_REG), rm = the second operand
	movq %rsp, %rdi
	movl $1, %esi
	movl %r14d, %edx
	movl %r14d, %ecx
	movl $0xc2, %r8d
	movl %r15d, %r9d
	call mv_set
	movzbl IN_REG(%r12), %eax
	movb %al, MV_VVVV(%rsp)
	testb $H_MEM, IN_HAS(%r12)
	jz 1f
	movq %rsp, %rdi
	movl $RM_MEM, %esi
	movq %r12, %rdx
	call mv_rm
	movb $1, MV_SSS(%rsp)
	jmp 2f
1:	movq %rsp, %rdi
	movl $RM_REG, %esi
	movzbl IN_RM(%r12), %edx
	call mv_rm
2:	# CF: less than (predicate 1)
	movw $1, MV_IMM(%rsp)
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	movq %rbx, %rdi
	xorl %esi, %esi
	movl %r15d, %edx
	call em_kmov_r_k
	movq %rbx, %rdi
	leaq .Lb_comis1(%rip), %rsi
	movl $5, %edx
	call em_bytes				# and eax, 1; mov ecx, eax
	# ZF: equal (0)
	movw $0, MV_IMM(%rsp)
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	movq %rbx, %rdi
	xorl %esi, %esi
	movl %r15d, %edx
	call em_kmov_r_k
	movq %rbx, %rdi
	leaq .Lb_comis2(%rip), %rsi
	movl $8, %edx
	call em_bytes				# and eax, 1; shl eax, 6; or ecx, eax
	# ZF, PF, CF: unordered (3)
	movw $3, MV_IMM(%rsp)
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	movq %rbx, %rdi
	xorl %esi, %esi
	movl %r15d, %edx
	call em_kmov_r_k
	movq %rbx, %rdi
	leaq .Lb_comis3(%rip), %rsi
	movl $10, %edx
	call em_bytes				# and eax, 1; neg eax; and eax, 0x45; or ecx, eax
	movq %rbx, %rdi
	movl $1, %esi
	xorl %edx, %edx
	movl $S_XFER, %ecx
	movl $1, %r8d
	call em_gpr_scratch			# mov [fs:S_XFER], ecx
	movl $S_XFER, EM_FLAGS_OUT(%rbx)
	xorl %eax, %eax
	addq $MV_BYTES + 16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
	.section .rodata
.Lb_comis1: .byte 0x83, 0xe0, 0x01, 0x89, 0xc1
.Lb_comis2: .byte 0x83, 0xe0, 0x01, 0xc1, 0xe0, 0x06, 0x09, 0xc1
.Lb_comis3: .byte 0x83, 0xe0, 0x01, 0xf7, 0xd8, 0x83, 0xe0, 0x45, 0x09, 0xc1
	.text
	.section .note.GNU-stack,"",@progbits

	.text
# xl_movq: vmovq and vmovd (XF_A 1 qword, 0 dword) between the low lane
# of a vector register and a general register or memory: the card
# moves nothing between the two files, so a general register goes
# through the scratch (S_GPR). A load zeroes the destination and
# broadcasts the element under a one-lane mask (vbroadcastsd/ss from
# the scratch or the memory operand); a store packs the lane out
# (vpackstoreld under the dword lanes of the element) to memory or to
# the scratch, from where the general register is loaded last.
# Forms: 6E (xmm from r/m), 66 7E (r/m from xmm), F3 7E (xmm from
# xmm/m64), D6 (m64 from xmm).
xl_movq:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES + 16, %rsp
	LOADCTX
	movl XF_A(%r13), %r14d			# wide
	movzbl IN_OP(%r12), %eax
	cmpl $0x6e, %eax
	je .Lmq_load
	cmpl $0xd6, %eax
	je .Lmq_store
	cmpl $0x7e, %eax
	jne .Lmq_shape
	cmpb $2, IN_PP(%r12)
	je .Lmq_load
.Lmq_store:
	movl $1, %esi
	testl %r14d, %r14d
	jz 1f
	movl $3, %esi
1:	movq %rbx, %rdi
	call em_mask_imm
	movl %eax, %r15d			# the lanes' mask register
	testb $H_MEM, IN_HAS(%r12)
	jz 2f
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movq %r12, %rdx
	movl %r15d, %ecx
	xorl %r8d, %r8d
	movl $1, %r9d
	pushq $0
	pushq $0
	call em_unaligned
	addq $16, %rsp
	jmp .Lmq_ok
2:	# vpackstoreld [fs:S_GPR]{k}, s; the general register from there, last
	movq %rsp, %rdi
	movl $2, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0xd0, %r8d
	movzbl IN_REG(%r12), %r9d
	call mv_set
	movq %rsp, %rdi
	movl $RM_FS, %esi
	movl $S_GPR, %edx
	call mv_rm
	movb %r15b, MV_K(%rsp)
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	movq %rbx, %rdi
	movzbl IN_RM(%r12), %esi
	movl %r14d, %edx
	movl $S_GPR, %ecx
	call em_gpr_result
	jmp .Lmq_ok
.Lmq_load:
	testb $H_MEM, IN_HAS(%r12)
	jnz 3f
	cmpb $0x7e, IN_OP(%r12)
	jne 4f
	# xmm from xmm: the low qword kept or moved, the rest zeroed
	movzbl IN_REG(%r12), %esi
	cmpb IN_RM(%r12), %sil
	jne 31f
	movq %rbx, %rdi
	movl $0xfffc, %edx
	call em_zero_lanes
	jmp .Lmq_ok
31:	movq %rbx, %rdi
	xorl %edx, %edx
	xorl %ecx, %ecx
	call em_zero
	movq %rbx, %rdi
	movl $3, %esi
	call em_mask_imm
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_REG, %edx
	movzbl IN_RM(%r12), %ecx
	movl %eax, %r8d
	xorl %r9d, %r9d
	call em_vmov
	jmp .Lmq_ok
3:	# from memory: zero, then the element broadcast under lane 0
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	xorl %edx, %edx
	xorl %ecx, %ecx
	call em_zero
	movq %rbx, %rdi
	movl $1, %esi
	call em_mask_imm
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_MEM, %edx
	movq %r12, %rcx
	movl %eax, %r8d
	movl %r14d, %r9d
	call em_broadcast
	jmp .Lmq_ok
4:	# from a general register: to the scratch, zero, the broadcast under lane 0
	movq %rbx, %rdi
	movzbl IN_RM(%r12), %esi
	movl %r14d, %edx
	movl $S_GPR, %ecx
	movl $1, %r8d
	call em_gpr_scratch
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	xorl %edx, %edx
	xorl %ecx, %ecx
	call em_zero
	movq %rbx, %rdi
	movl $1, %esi
	call em_mask_imm
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_FS, %edx
	movl $S_GPR, %ecx
	movl %eax, %r8d
	movl %r14d, %r9d
	call em_broadcast
.Lmq_ok:
	xorl %eax, %eax
	jmp .Lmq_out
.Lmq_shape:
	leaq s_shape(%rip), %rax
.Lmq_out:
	addq $MV_BYTES + 16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_pinsr: vpinsrq (XF_A 1) and vpinsrd (0): d = s1 with element imm
# replaced by the general register or memory operand, the lanes above
# the 128 bits zeroed. The element arrives by a broadcast under the
# element's lane (qword or dword), from the scratch for a register.
xl_pinsr:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	LOADCTX
	movl XF_A(%r13), %r14d			# wide
	movq IN_IMM(%r12), %r15
	andl $3, %r15d
	testl %r14d, %r14d
	jz 1f
	andl $1, %r15d
1:	testb $H_MEM, IN_HAS(%r12)
	jnz 11f
	# a register source to the scratch first: the mask below goes through
	# eax, and a source in rax read after it was the mask (2026-10-14: the
	# CPU backend's device table, built with vpinsrq from rax, came out
	# with 2 in it and llama-server jumped to address 2)
	movq %rbx, %rdi
	movzbl IN_RM(%r12), %esi
	movl %r14d, %edx
	movl $S_GPR, %ecx
	movl $1, %r8d
	call em_gpr_scratch
11:	movzbl IN_REG(%r12), %esi
	cmpb IN_VVVV(%r12), %sil
	je 2f
	movq %rbx, %rdi
	movl $RM_REG, %edx
	movzbl IN_VVVV(%r12), %ecx
	xorl %r8d, %r8d
	xorl %r9d, %r9d
	call em_vmov
2:	movl $1, %esi
	movl %r15d, %ecx
	shll %cl, %esi
	movq %rbx, %rdi
	call em_mask_imm
	movl %eax, %r15d			# the element's mask register
	testb $H_MEM, IN_HAS(%r12)
	jz 3f
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_MEM, %edx
	movq %r12, %rcx
	movl %r15d, %r8d
	movl %r14d, %r9d
	call em_broadcast
	jmp 4f
3:	movq %rbx, %rdi				# (the register went to the scratch above)
	movzbl IN_REG(%r12), %esi
	movl $RM_FS, %edx
	movl $S_GPR, %ecx
	movl %r15d, %r8d
	movl %r14d, %r9d
	call em_broadcast
4:	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $0xfff0, %edx
	call em_zero_lanes
	xorl %eax, %eax
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_pextr: vpextrq (XF_A 1) and vpextrd (0): element imm of the vector
# register to a general register or memory: a pack-store of the
# element's dword lanes (packed: it lands at the address whatever its
# lane), to memory by the unaligned pair, or to the scratch from where
# the general register is loaded last.
xl_pextr:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES, %rsp
	LOADCTX
	movl XF_A(%r13), %r14d			# wide
	movq IN_IMM(%r12), %rcx
	andl $3, %ecx
	movl $1, %esi
	testl %r14d, %r14d
	jz 1f
	andl $1, %ecx
	addl %ecx, %ecx
	movl $3, %esi
1:	shll %cl, %esi
	movq %rbx, %rdi
	call em_mask_imm
	movl %eax, %r15d
	testb $H_MEM, IN_HAS(%r12)
	jz 2f
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movq %r12, %rdx
	movl %r15d, %ecx
	xorl %r8d, %r8d
	movl $1, %r9d
	pushq $0
	pushq $0
	call em_unaligned
	addq $16, %rsp
	jmp 3f
2:	movq %rsp, %rdi
	movl $2, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0xd0, %r8d
	movzbl IN_REG(%r12), %r9d
	call mv_set
	movq %rsp, %rdi
	movl $RM_FS, %esi
	movl $S_GPR, %edx
	call mv_rm
	movb %r15b, MV_K(%rsp)
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	movq %rbx, %rdi
	movzbl IN_RM(%r12), %esi
	movl %r14d, %edx
	movl $S_GPR, %ecx
	call em_gpr_result
3:	xorl %eax, %eax
	addq $MV_BYTES, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_insert: vinserti32x4/vinsertf32x4/vinserti128/vinsertf128 (XF_A 0:
# a 16-byte block) and vinserti64x4/vinsertf64x4 (1: a 32-byte half):
# d = s1 with block imm replaced by the source's low block. The source
# block goes into a temporary at every block position (vpermf32x4 of a
# register, or the block broadcast of a memory operand), then a move
# under the block's lanes; the lanes above the destination's length
# are zeroed (commit). A masked form is not taken.
xl_insert:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $16, %rsp
	LOADCTX
	cmpb $0, IN_AAA(%r12)
	jne .Lins_shape
	movl XF_A(%r13), %r14d			# half
	movq IN_IMM(%r12), %rax
	andl $3, %eax
	testl %r14d, %r14d
	jz 1f
	andl $1, %eax
1:	movl %eax, (%rsp)			# the block
	movq %rbx, %rdi
	call em_temp
	cmpl $-1, %eax
	je .Lins_notemp
	movl %eax, %r15d			# the temporary
	testb $H_MEM, IN_HAS(%r12)
	jz 2f
	movq %rbx, %rdi
	movl %r15d, %esi
	movl $RM_MEM, %edx
	movq %r12, %rcx
	xorl %r8d, %r8d
	movl %r14d, %r9d
	call em_load_block
	jmp 3f
2:	movl $0x44, %eax			# both halves from blocks 0 and 1
	testl %r14d, %r14d
	jnz 21f
	xorl %eax, %eax				# every block from block 0
21:	pushq $0				# k
	pushq %rax				# imm
	movzbl IN_RM(%r12), %eax
	pushq %rax				# rm
	pushq $RM_REG
	movq %rbx, %rdi
	movl $3, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0x07, %r8d
	movl %r15d, %r9d
	call em_op2i
	addq $32, %rsp
3:	movzbl IN_REG(%r12), %esi
	cmpb IN_VVVV(%r12), %sil
	je 4f
	movq %rbx, %rdi
	movl $RM_REG, %edx
	movzbl IN_VVVV(%r12), %ecx
	xorl %r8d, %r8d
	xorl %r9d, %r9d
	call em_vmov
4:	movl (%rsp), %ecx
	movl $0xf, %esi
	shll $2, %ecx
	testl %r14d, %r14d
	jz 41f
	movl $0xff, %esi
	addl %ecx, %ecx
41:	shll %cl, %esi
	movq %rbx, %rdi
	call em_mask_imm
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_REG, %edx
	movl %r15d, %ecx
	movl %eax, %r8d
	xorl %r9d, %r9d
	call em_vmov
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl %esi, %edx
	xorl %ecx, %ecx
	call commit
	xorl %eax, %eax
	jmp .Lins_out
.Lins_shape:
	leaq s_shape(%rip), %rax
	jmp .Lins_out
.Lins_notemp:
	leaq s_no_temp(%rip), %rax
.Lins_out:
	addq $16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

	.text
# ---- the x87 path: what the card's vector unit cannot do exactly, its
# core's x87 unit does on one lane staged through the scratch ----

# fs_op(em rdi, bytes rsi, n edx, reg ecx, off r8d): a legacy
# instruction (its opcode bytes) with one [fs:scratch + off] memory
# operand, reg the ModRM extension: 64, the bytes, ModRM 04 | reg << 3,
# SIB 25, the absolute disp32.
fs_op:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %rbx
	movq %rsi, %r12
	movl %edx, %r13d
	movl %ecx, %r14d
	movl %r8d, %r15d
	movl $0x64, %eax
	call em_byte
	movq %rbx, %rdi
	movq %r12, %rsi
	movl %r13d, %edx
	call em_bytes
	movl %r14d, %eax
	shll $3, %eax
	orl $4, %eax
	movq %rbx, %rdi
	call em_byte
	movl $0x25, %eax
	movq %rbx, %rdi
	call em_byte
	movl EM_SCRATCH(%rbx), %eax
	addl %r15d, %eax
	movq %rbx, %rdi
	call em_dword
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# lane_out(em rdi, s esi, w edx, off ecx): lane 0 of s (a dword, or a
# qword for w) packed to [fs:scratch + off]: vpackstoreld/q under the
# mask 1.
lane_out:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	subq $MV_BYTES, %rsp
	movq %rdi, %rbx
	movl %esi, %r12d
	movl %edx, %r13d
	movl %ecx, %r14d
	movl $1, %esi
	call em_mask_imm
	movl %eax, %r8d
	pushq %r8
	movq %rsp, %rdi
	addq $8, %rdi
	movl $2, %esi
	movl $1, %edx
	movl %r13d, %ecx
	movl $0xd0, %r8d
	movl %r12d, %r9d
	call mv_set
	popq %r8
	movq %rsp, %rdi
	movl $RM_FS, %esi
	movl %r14d, %edx
	call mv_rm
	movb %r8b, MV_K(%rsp)
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	addq $MV_BYTES, %rsp
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# x87_pc(em rdi, double esi): the control word saved to S_CW and loaded
# with the precision of the operand (24 bits, or 53 for double) from
# S_CW2; rax and the flags are saved first (restored at the finish).
x87_pc:
	pushq %rbx
	pushq %r12
	movq %rdi, %rbx
	movl %esi, %r12d
	call em_rax
	movq %rbx, %rdi
	call em_flags
	movq %rbx, %rdi
	leaq .Lx87_d9(%rip), %rsi
	movl $1, %edx
	movl $7, %ecx
	movl $S_CW, %r8d
	call fs_op				# fnstcw [cw]
	movq %rbx, %rdi
	leaq .Lx87_movzx(%rip), %rsi
	movl $2, %edx
	xorl %ecx, %ecx
	movl $S_CW, %r8d
	call fs_op				# movzx eax, word [cw]
	movq %rbx, %rdi
	leaq .Lx87_and_ah(%rip), %rsi
	movl $3, %edx
	call em_bytes				# and ah, 0xfc: 24 bits
	testl %r12d, %r12d
	jz 1f
	movq %rbx, %rdi
	leaq .Lx87_or_ah(%rip), %rsi
	movl $3, %edx
	call em_bytes				# or ah, 2: 53 bits
1:	movq %rbx, %rdi
	leaq .Lx87_mov_ax(%rip), %rsi
	movl $2, %edx
	xorl %ecx, %ecx
	movl $S_CW2, %r8d
	call fs_op				# mov [cw2], ax
	movq %rbx, %rdi
	leaq .Lx87_d9(%rip), %rsi
	movl $1, %edx
	movl $5, %ecx
	movl $S_CW2, %r8d
	call fs_op				# fldcw [cw2]
	popq %r12
	popq %rbx
	ret
# x87_pc_back(em rdi): fldcw [cw].
x87_pc_back:
	leaq .Lx87_d9(%rip), %rsi
	movl $1, %edx
	movl $5, %ecx
	movl $S_CW, %r8d
	jmp fs_op
# x87_fs(em rdi, op esi, reg edx, off ecx): one x87 instruction with an
# fs memory operand (the opcode byte in esi).
x87_fs:
	subq $8, %rsp
	movb %sil, (%rsp)
	movq %rsp, %rsi
	movl %ecx, %r8d
	movl %edx, %ecx
	movl $1, %edx
	call fs_op
	addq $8, %rsp
	ret
# scalar_in(em rdi, d esi, s1 edx, w ecx): d = [fs:S_XFER] in lane 0
# (a broadcast under the mask 1), the rest of the 128 bits from s1, the
# lanes above zeroed: the common ending of the x87 recipes.
scalar_in:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	movq %rdi, %rbx
	movl %esi, %r12d
	movl %edx, %r13d
	movl %ecx, %r14d
	movl $1, %esi
	call em_mask_imm
	movq %rbx, %rdi
	movl %r12d, %esi
	movl $RM_FS, %edx
	movl $S_XFER, %ecx
	movl %eax, %r8d
	movl %r14d, %r9d
	call em_broadcast
	cmpl %r12d, %r13d
	je 1f
	movl $0xe, %esi
	testl %r14d, %r14d
	jz 2f
	movl $2, %esi
2:	movq %rbx, %rdi
	call em_mask_imm
	movq %rbx, %rdi
	movl %r12d, %esi
	movl $RM_REG, %edx
	movl %r13d, %ecx
	movl %eax, %r8d
	movl %r14d, %r9d
	call em_vmov
1:	movq %rbx, %rdi
	movl %r12d, %esi
	movl $0xfff0, %edx
	call em_zero_lanes
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
	.section .rodata
.Lx87_d9:	.byte 0xd9
.Lx87_movzx:	.byte 0x0f, 0xb7
.Lx87_and_ah:	.byte 0x80, 0xe4, 0xfc
.Lx87_or_ah:	.byte 0x80, 0xcc, 0x02
.Lx87_mov_ax:	.byte 0x66, 0x89
.Lx87_fsqrt:	.byte 0xd9, 0xfa
	.text

# xl_cvtsi2s: vcvtsi2ss (XF_A 0) and vcvtsi2sd (1) from a general
# register: the integer to S_XFER as a qword (sign-extended when 32
# bits), fild, fstp at the width (the one rounding), then the lane
# in. A memory source is not taken yet.
xl_cvtsi2s:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $16, %rsp
	LOADCTX
	movl XF_A(%r13), %r14d			# double
	testb $H_MEM, IN_HAS(%r12)
	jnz .Lcvtsi_mem
	cmpb $0, IN_W(%r12)
	je 1f
	movq %rbx, %rdi
	movzbl IN_RM(%r12), %esi
	movl $1, %edx
	movl $S_XFER, %ecx
	movl $1, %r8d
	call em_gpr_scratch
	jmp 2f
1:	# movsxd rax, r32; the qword to the slot
	movq %rbx, %rdi
	call em_rax
	movzbl IN_RM(%r12), %eax
	movl %eax, %ecx
	shrl $3, %ecx
	andl $1, %ecx
	orl $0x48, %ecx
	movb %cl, (%rsp)
	movb $0x63, 1(%rsp)
	andl $7, %eax
	orl $0xc0, %eax
	movb %al, 2(%rsp)
	movq %rbx, %rdi
	movq %rsp, %rsi
	movl $3, %edx
	call em_bytes
	movq %rbx, %rdi
	xorl %esi, %esi
	movl $1, %edx
	movl $S_XFER, %ecx
	movl $1, %r8d
	call em_gpr_scratch
2:	movq %rbx, %rdi
	movl $0xdf, %esi
	movl $5, %edx
	movl $S_XFER, %ecx
	call x87_fs				# fild qword [xfer]
	movl $0xd9, %esi			# fstp dword
	testl %r14d, %r14d
	jz 3f
	movl $0xdd, %esi			# fstp qword
3:	movq %rbx, %rdi
	movl $3, %edx
	movl $S_XFER, %ecx
	call x87_fs
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movzbl IN_VVVV(%r12), %edx
	movl %r14d, %ecx
	call scalar_in
	xorl %eax, %eax
	jmp .Lcvtsi_out
.Lcvtsi_mem:
	leaq s_scalar_mem(%rip), %rax
.Lcvtsi_out:
	addq $16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_cvtss2sd: vcvtss2sd (XF_A 0: the card's vcvtps2pd, MVEX.512.0F.W0
# 5A) and vcvtsd2ss (1: vcvtpd2ps, MVEX.512.66.0F.W1 5A) through a
# temporary, lane 0 into d, the rest of the 128 bits from s1, the lanes
# above zeroed. A memory source is broadcast into a temporary first.
xl_cvtss2sd:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES, %rsp
	LOADCTX
	movl XF_A(%r13), %r14d			# from double
	movzbl IN_RM(%r12), %r15d		# the source
	testb $H_MEM, IN_HAS(%r12)
	jz 1f
	movq %rbx, %rdi
	call em_temp
	cmpl $-1, %eax
	je .Lcvtss_notemp
	movl %eax, %r15d
	movq %rbx, %rdi
	movl %r15d, %esi
	movl $RM_MEM, %edx
	movq %r12, %rcx
	xorl %r8d, %r8d
	movl %r14d, %r9d
	call em_broadcast
1:	movq %rbx, %rdi
	call em_temp
	cmpl $-1, %eax
	je .Lcvtss_notemp
	movl %eax, %r13d			# the converted vector (the form is no longer needed)
	movq %rsp, %rdi
	movl $1, %esi
	movl %r14d, %edx
	movl %r14d, %ecx
	movl $0x5a, %r8d
	movl %r13d, %r9d
	call mv_set
	movq %rsp, %rdi
	movl $RM_REG, %esi
	movl %r15d, %edx
	call mv_rm
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	# d = lane 0 of the temporary at the result width, s1 beside it
	movl $1, %ecx
	subl %r14d, %ecx			# the result's width: 1 (double) from single, 0 from double
	movl %ecx, 8(%rsp)
	movq %rbx, %rdi
	movl $1, %esi
	call em_mask_imm
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_REG, %edx
	movl %r13d, %ecx
	movl %eax, %r8d
	movl 8(%rsp), %r9d
	call em_vmov
	movzbl IN_REG(%r12), %esi
	cmpb IN_VVVV(%r12), %sil
	je 2f
	movl $0xe, %esi
	cmpl $0, 8(%rsp)
	je 21f
	movl $2, %esi
21:	movq %rbx, %rdi
	call em_mask_imm
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_REG, %edx
	movzbl IN_VVVV(%r12), %ecx
	movl %eax, %r8d
	movl 8(%rsp), %r9d
	call em_vmov
2:	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $0xfff0, %edx
	call em_zero_lanes
	xorl %eax, %eax
	jmp .Lcvtss_out
.Lcvtss_notemp:
	leaq s_no_temp(%rip), %rax
.Lcvtss_out:
	addq $MV_BYTES, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_divs: vdivss (XF_A 0) and vdivsd (1): the two lanes to the scratch,
# x87 fdiv under the operand's precision (one rounding), the quotient
# back into lane 0 of d. The card has no division; the x87 quotient is
# the correctly rounded one (a denormal result may round twice).
xl_divs:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	LOADCTX
	movl XF_A(%r13), %r14d			# double
	movq %rbx, %rdi
	movzbl IN_VVVV(%r12), %esi
	movl %r14d, %edx
	movl $S_XFER, %ecx
	call lane_out				# the dividend
	movzbl IN_RM(%r12), %r15d
	testb $H_MEM, IN_HAS(%r12)
	jz 1f
	movq %rbx, %rdi
	call em_temp
	cmpl $-1, %eax
	je .Ldivs_notemp
	movl %eax, %r15d
	movq %rbx, %rdi
	movl %r15d, %esi
	movl $RM_MEM, %edx
	movq %r12, %rcx
	xorl %r8d, %r8d
	movl %r14d, %r9d
	call em_broadcast
1:	movq %rbx, %rdi
	movl %r15d, %esi
	movl %r14d, %edx
	movl $S_XFER + 8, %ecx
	call lane_out				# the divisor
	movq %rbx, %rdi
	movl %r14d, %esi
	call x87_pc
	movl $0xd9, %r13d			# fld dword, fdiv dword, fstp dword
	movl $0xd8, %r15d
	testl %r14d, %r14d
	jz 2f
	movl $0xdd, %r13d			# fld qword, fdiv qword, fstp qword
	movl $0xdc, %r15d
2:	movq %rbx, %rdi
	movl %r13d, %esi
	xorl %edx, %edx
	movl $S_XFER, %ecx
	call x87_fs
	movq %rbx, %rdi
	movl %r15d, %esi
	movl $6, %edx
	movl $S_XFER + 8, %ecx
	call x87_fs
	movq %rbx, %rdi
	movl %r13d, %esi
	movl $3, %edx
	movl $S_XFER, %ecx
	call x87_fs
	movq %rbx, %rdi
	call x87_pc_back
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movzbl IN_VVVV(%r12), %edx
	movl %r14d, %ecx
	call scalar_in
	xorl %eax, %eax
	jmp .Ldivs_out
.Ldivs_notemp:
	leaq s_no_temp(%rip), %rax
.Ldivs_out:
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_sqrts: vsqrtss (XF_A 0) and vsqrtsd (1): the source lane to the
# scratch, x87 fsqrt under the operand's precision, back into lane 0
# of d, the rest from s1.
xl_sqrts:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	LOADCTX
	movl XF_A(%r13), %r14d
	movzbl IN_RM(%r12), %r15d
	testb $H_MEM, IN_HAS(%r12)
	jz 1f
	movq %rbx, %rdi
	call em_temp
	cmpl $-1, %eax
	je .Lsqrts_notemp
	movl %eax, %r15d
	movq %rbx, %rdi
	movl %r15d, %esi
	movl $RM_MEM, %edx
	movq %r12, %rcx
	xorl %r8d, %r8d
	movl %r14d, %r9d
	call em_broadcast
1:	movq %rbx, %rdi
	movl %r15d, %esi
	movl %r14d, %edx
	movl $S_XFER, %ecx
	call lane_out
	movq %rbx, %rdi
	movl %r14d, %esi
	call x87_pc
	movl $0xd9, %r13d
	testl %r14d, %r14d
	jz 2f
	movl $0xdd, %r13d
2:	movq %rbx, %rdi
	movl %r13d, %esi
	xorl %edx, %edx
	movl $S_XFER, %ecx
	call x87_fs				# fld
	movq %rbx, %rdi
	leaq .Lx87_fsqrt(%rip), %rsi
	movl $2, %edx
	call em_bytes				# fsqrt
	movq %rbx, %rdi
	movl %r13d, %esi
	movl $3, %edx
	movl $S_XFER, %ecx
	call x87_fs				# fstp
	movq %rbx, %rdi
	call x87_pc_back
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movzbl IN_VVVV(%r12), %edx
	movl %r14d, %ecx
	call scalar_in
	xorl %eax, %eax
	jmp .Lsqrts_out
.Lsqrts_notemp:
	leaq s_no_temp(%rip), %rax
.Lsqrts_out:
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

	.text
# xl_cmpeqb: vpcmpeqb (XF_A 0) and vpcmpeqw (1), VEX forms: the card
# masks dword lanes only, so the per-byte (per-word) equality is made
# in dword arithmetic: t = s1 ^ s2; u = ((t & 0x7f..) + 0x7f..) | t has
# the top bit of every element set when the element is not zero; d =
# ((~u & 0x80..) >> 7) * 0xff is 0xff in every equal element (0xffff for
# words: 0x7fff, 0x8000, 15, 0xffff). The lanes above the length zeroed.
xl_cmpeqb:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES + 32, %rsp
	LOADCTX
	movl XF_A(%r13), %r14d			# words
	# the second source as a register
	movzbl IN_RM(%r12), %r15d
	testb $H_MEM, IN_HAS(%r12)
	jz 1f
	movq %rbx, %rdi
	xorl %esi, %esi
	xorl %edx, %edx
	call src2
	testl %eax, %eax
	js .Lceq_notemp
	movl %eax, %r15d
1:	movq %rbx, %rdi
	call em_temp
	cmpl $-1, %eax
	je .Lceq_notemp
	movl %eax, MV_BYTES(%rsp)		# t
	# the constants
	movl $0x7f7f7f7f, %esi
	movl $0x80808080, %r8d
	movl $0xff, %r9d
	movl $7, %r10d
	testl %r14d, %r14d
	jz 2f
	movl $0x7fff7fff, %esi
	movl $0x80008000, %r8d
	movl $0xffff, %r9d
	movl $15, %r10d
2:	movl %r10d, MV_BYTES + 28(%rsp)	# the shift
	pushq %r8
	pushq %r9
	movq %rbx, %rdi
	call em_const_dw
	movl %eax, MV_BYTES + 8 + 16(%rsp)	# c7f (the frame moved by 16)
	popq %r9
	popq %r8
	pushq %r9
	movq %rbx, %rdi
	movl %r8d, %esi
	call em_const_dw
	movl %eax, MV_BYTES + 12 + 8(%rsp)	# c80
	popq %r9
	movq %rbx, %rdi
	movl %r9d, %esi
	call em_const_dw
	movl %eax, MV_BYTES + 16(%rsp)		# cff
	cmpl $-1, MV_BYTES + 8(%rsp)
	je .Lceq_notemp
	cmpl $-1, MV_BYTES + 12(%rsp)
	je .Lceq_notemp
	cmpl $-1, MV_BYTES + 16(%rsp)
	je .Lceq_notemp
	# t = s1 ^ s2
	movq %rsp, %rdi
	movl $1, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0xef, %r8d
	xorl %r9d, %r9d
	call mv_set
	pushq $-1
	pushq $0
	movq %rbx, %rdi
	leaq 16(%rsp), %rsi
	movl MV_BYTES + 16(%rsp), %edx		# t
	movzbl IN_VVVV(%r12), %ecx
	movl $RM_REG, %r8d
	movl %r15d, %r9d
	call em_op3
	addq $16, %rsp
	# d = t & c7f
	movb $0xdb, MV_OP(%rsp)
	pushq $-1
	pushq $0
	movq %rbx, %rdi
	leaq 16(%rsp), %rsi
	movzbl IN_REG(%r12), %edx
	movl MV_BYTES + 16(%rsp), %ecx		# t
	movl $RM_CONST, %r8d
	movl MV_BYTES + 8 + 16(%rsp), %r9d	# c7f
	call em_op3
	addq $16, %rsp
	# d = d + c7f
	movb $0xfe, MV_OP(%rsp)
	pushq $-1
	pushq $0
	movq %rbx, %rdi
	leaq 16(%rsp), %rsi
	movzbl IN_REG(%r12), %edx
	movl %edx, %ecx
	movl $RM_CONST, %r8d
	movl MV_BYTES + 8 + 16(%rsp), %r9d
	call em_op3
	addq $16, %rsp
	# d = d | t
	movb $0xeb, MV_OP(%rsp)
	pushq $-1
	pushq $0
	movq %rbx, %rdi
	leaq 16(%rsp), %rsi
	movzbl IN_REG(%r12), %edx
	movl %edx, %ecx
	movl $RM_REG, %r8d
	movl MV_BYTES + 16(%rsp), %r9d		# t
	call em_op3
	addq $16, %rsp
	# d = ~d & c80
	movb $0xdf, MV_OP(%rsp)
	pushq $-1
	pushq $0
	movq %rbx, %rdi
	leaq 16(%rsp), %rsi
	movzbl IN_REG(%r12), %edx
	movl %edx, %ecx
	movl $RM_CONST, %r8d
	movl MV_BYTES + 12 + 16(%rsp), %r9d	# c80
	call em_op3
	addq $16, %rsp
	# d = d >> shift (vpsrld: 66.0F 72 /2 ib, the destination in vvvv)
	movq %rsp, %rdi
	movl $1, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0x72, %r8d
	movl $2, %r9d
	call mv_set
	movzbl IN_REG(%r12), %eax
	movb %al, MV_VVVV(%rsp)
	movq %rsp, %rdi
	movl $RM_REG, %esi
	movzbl IN_REG(%r12), %edx
	call mv_rm
	movl MV_BYTES + 28(%rsp), %eax
	movw %ax, MV_IMM(%rsp)
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	# d = d * cff (vpmulld 66.0F38 40)
	movq %rsp, %rdi
	movl $2, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0x40, %r8d
	xorl %r9d, %r9d
	call mv_set
	pushq $-1
	pushq $0
	movq %rbx, %rdi
	leaq 16(%rsp), %rsi
	movzbl IN_REG(%r12), %edx
	movl %edx, %ecx
	movl $RM_CONST, %r8d
	movl MV_BYTES + 16 + 16(%rsp), %r9d	# cff
	call em_op3
	addq $16, %rsp
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl %esi, %edx
	xorl %ecx, %ecx
	call commit
	xorl %eax, %eax
	jmp .Lceq_out
.Lceq_notemp:
	leaq s_no_temp(%rip), %rax
.Lceq_out:
	addq $MV_BYTES + 32, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_ptest: vptest a, b/m (VEX): ZF = (a & b) == 0, CF = (~a & b) == 0,
# the other flags cleared, over the length's lanes (the lanes above a
# narrow register are zero already). vptestmd (MVEX.NDS.512.66.0F38.W0
# 27) into the scratch mask, kmov, test; the flags byte to S_XFER as
# the scalar compares do (EM_FLAGS_OUT).
xl_ptest:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES + 16, %rsp
	LOADCTX
	movzbl IN_RM(%r12), %r15d
	testb $H_MEM, IN_HAS(%r12)
	jz 1f
	movq %rbx, %rdi
	xorl %esi, %esi
	xorl %edx, %edx
	call src2
	testl %eax, %eax
	js .Lptest_notemp
	movl %eax, %r15d
1:	movq %rbx, %rdi
	call em_rax
	movq %rbx, %rdi
	call em_rcx
	movq %rbx, %rdi
	call em_k
	movl %eax, %r14d			# the scratch mask
	# k = (a & b) != 0 per lane
	movq %rsp, %rdi
	movl $2, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0x27, %r8d
	movl %r14d, %r9d
	call mv_set
	movzbl IN_REG(%r12), %eax
	movb %al, MV_VVVV(%rsp)
	movq %rsp, %rdi
	movl $RM_REG, %esi
	movl %r15d, %edx
	call mv_rm
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	movq %rbx, %rdi
	xorl %esi, %esi
	movl %r14d, %edx
	call em_kmov_r_k			# eax = k
	movq %rbx, %rdi
	leaq .Lb_ptest1(%rip), %rsi
	movl $11, %edx
	call em_bytes				# test eax, eax; sete cl; movzx ecx, cl; shl ecx, 6
	# the temporary t = ~a & b; k = t != 0
	movq %rbx, %rdi
	call em_temp
	cmpl $-1, %eax
	je .Lptest_notemp
	movl %eax, MV_BYTES(%rsp)
	movq %rsp, %rdi
	movl $1, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0xdf, %r8d
	xorl %r9d, %r9d
	call mv_set
	pushq $-1
	pushq $0
	movq %rbx, %rdi
	leaq 16(%rsp), %rsi
	movl MV_BYTES + 16(%rsp), %edx
	movzbl IN_REG(%r12), %ecx
	movl $RM_REG, %r8d
	movl %r15d, %r9d
	call em_op3
	addq $16, %rsp
	movq %rsp, %rdi
	movl $2, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0x27, %r8d
	movl %r14d, %r9d
	call mv_set
	movl MV_BYTES(%rsp), %eax
	movb %al, MV_VVVV(%rsp)
	movq %rsp, %rdi
	movl $RM_REG, %esi
	movl MV_BYTES(%rsp), %edx
	call mv_rm
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	movq %rbx, %rdi
	xorl %esi, %esi
	movl %r14d, %edx
	call em_kmov_r_k
	movq %rbx, %rdi
	leaq .Lb_ptest2(%rip), %rsi
	movl $10, %edx
	call em_bytes				# test eax, eax; sete al; movzx eax, al; or ecx, eax
	movq %rbx, %rdi
	movl $1, %esi
	xorl %edx, %edx
	movl $S_XFER, %ecx
	movl $1, %r8d
	call em_gpr_scratch			# mov [fs:S_XFER], ecx
	movl $S_XFER, EM_FLAGS_OUT(%rbx)
	xorl %eax, %eax
	jmp .Lptest_out
.Lptest_notemp:
	leaq s_no_temp(%rip), %rax
.Lptest_out:
	addq $MV_BYTES + 16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
	.section .rodata
.Lb_ptest1: .byte 0x85, 0xc0, 0x0f, 0x94, 0xc1, 0x0f, 0xb6, 0xc9, 0xc1, 0xe1, 0x06
.Lb_ptest2: .byte 0x85, 0xc0, 0x0f, 0x94, 0xc0, 0x0f, 0xb6, 0xc0, 0x09, 0xc1
	.text

	.text
# xl_kcopy: kortestw (XF_A 0x98) and knotw (0x44): the card's form is the
# same two-register VEX instruction (kortest sets ZF and CF as the
# program expects; nothing after it in the sequence touches the flags).
xl_kcopy:
	pushq %rbx
	pushq %r12
	pushq %r13
	LOADCTX
	movq %rbx, %rdi
	movl XF_A(%r13), %esi
	movzbl IN_REG(%r12), %edx
	movzbl IN_RM(%r12), %ecx
	call em_vexk
	xorl %eax, %eax
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_kbin: kandw/kandnw/korw/kxorw/kxnorw k1, k2, k3 (XF_A the card's
# two-operand opcode): k1 = k2 op k3 as a move and the two-operand form
# (k1 = k1 op k3); when k1 is k3 and the operation is symmetric the
# operands swap; kandn with k1 = k3 goes through the scratch mask.
xl_kbin:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	LOADCTX
	movzbl IN_REG(%r12), %r14d		# k1
	movzbl IN_VVVV(%r12), %r15d		# k2
	movzbl IN_RM(%r12), %ecx		# k3
	cmpl %r14d, %r15d
	je 2f
	cmpl %r14d, %ecx
	jne 1f
	# k1 == k3
	cmpl $0x42, XF_A(%r13)
	je 3f
	movl %r15d, %ecx			# symmetric: k1 = k1 op k2
	jmp 2f
1:	pushq %rcx
	movq %rbx, %rdi
	movl $0x90, %esi
	movl %r14d, %edx
	movl %r15d, %ecx
	call em_vexk				# kmov k1, k2
	popq %rcx
2:	movq %rbx, %rdi
	movl XF_A(%r13), %esi
	movl %r14d, %edx
	call em_vexk				# k1 = k1 op k3
	jmp 9f
3:	# kandn k1, k2, k1: t = k2; t = ~t & k1 (kandn t, k1); k1 = t
	movq %rbx, %rdi
	call em_k
	movl %eax, %r13d
	movq %rbx, %rdi
	movl $0x90, %esi
	movl %r13d, %edx
	movl %r15d, %ecx
	call em_vexk
	movq %rbx, %rdi
	movl $0x42, %esi
	movl %r13d, %edx
	movl %r14d, %ecx
	call em_vexk
	movq %rbx, %rdi
	movl $0x90, %esi
	movl %r14d, %edx
	movl %r13d, %ecx
	call em_vexk
9:	xorl %eax, %eax
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_kunpck: kunpckbw k1, k2, k3: k1 = k2[7:0] << 8 | k3[7:0], through
# eax and ecx.
xl_kunpck:
	pushq %rbx
	pushq %r12
	pushq %r13
	LOADCTX
	movq %rbx, %rdi
	call em_rax
	movq %rbx, %rdi
	call em_rcx
	movq %rbx, %rdi
	call em_flags
	movq %rbx, %rdi
	xorl %esi, %esi
	movzbl IN_VVVV(%r12), %edx
	call em_kmov_r_k			# eax = k2
	movq %rbx, %rdi
	movl $1, %esi
	movzbl IN_RM(%r12), %edx
	call em_kmov_r_k			# ecx = k3
	movq %rbx, %rdi
	leaq .Lb_kunpck(%rip), %rsi
	movl $11, %edx
	call em_bytes				# shl eax, 8; movzx ecx, cl; or eax, ecx; movzx eax, ax
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	xorl %edx, %edx
	call em_kmov_k_r
	xorl %eax, %eax
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_kmov: kmovw: 90 k, k/m16; 91 m16, k; 92 k, r32; 93 r32, k. The
# register forms are the card's own; the memory forms go through eax
# with the address in rcx (em_lea).
xl_kmov:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	LOADCTX
	movzbl IN_OP(%r12), %r14d
	testb $H_MEM, IN_HAS(%r12)
	jnz 1f
	movq %rbx, %rdi
	movl %r14d, %esi
	movzbl IN_REG(%r12), %edx
	movzbl IN_RM(%r12), %ecx
	call em_vexk
	jmp 9f
1:	movq %rbx, %rdi
	call em_rax
	movq %rbx, %rdi
	call em_rcx
	movq %rbx, %rdi
	movq %r12, %rsi
	call em_addr_regs
	movq %rbx, %rdi
	movl $1, %esi
	movq %r12, %rdx
	call em_lea				# lea rcx, [m]
	cmpl $0x91, %r14d
	je 2f
	# k = [m]: movzx eax, word [rcx]; kmov k, eax
	movq %rbx, %rdi
	leaq .Lb_movzx_w_rcx(%rip), %rsi
	movl $3, %edx
	call em_bytes
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	xorl %edx, %edx
	call em_kmov_k_r
	jmp 9f
2:	# [m] = k: kmov eax, k; mov [rcx], ax
	movq %rbx, %rdi
	xorl %esi, %esi
	movzbl IN_REG(%r12), %edx
	call em_kmov_r_k
	movq %rbx, %rdi
	leaq .Lb_mov_rcx_ax(%rip), %rsi
	movl $3, %edx
	call em_bytes
9:	xorl %eax, %eax
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_cmp_q: vpcmpeqq: the qword equality from the dword compare under
# the length's lanes, the mask's bit pairs packed to one bit a qword in
# eax, the program's mask applied; into the mask register (EVEX) or,
# for the VEX form, spread back to dword lanes and the register set
# to all ones there, zero elsewhere.
xl_cmp_q:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES + 16, %rsp
	LOADCTX
	movzbl IN_RM(%r12), %r15d
	testb $H_MEM, IN_HAS(%r12)
	jz 1f
	movq %rbx, %rdi
	movl $1, %esi
	xorl %edx, %edx
	call src2
	testl %eax, %eax
	js .Lcq_notemp
	movl %eax, %r15d
1:	movq %rbx, %rdi
	call em_rax
	movq %rbx, %rdi
	call em_rcx
	movq %rbx, %rdi
	call em_flags				# the packing arithmetic below sets flags the program keeps
	EV_LL %edi
	movl $1, %esi
	call vl_lanes				# the qword lanes of the length
	movl %eax, MV_BYTES(%rsp)		# the qword lane mask
	movl %eax, %edi
	# the dword lanes: every qword lane twice
	movl %eax, %edx
	andl $0x5555, %eax
	movl %edx, %ecx
	shll $1, %ecx
	andl $0xaaaa, %ecx
	# (a qword mask bit i to dword bits 2i, 2i+1: spread)
	movl %edi, %eax
	xorl %ecx, %ecx
	xorl %edx, %edx
11:	cmpl $8, %ecx
	jae 12f
	btl %ecx, %eax
	jnc 13f
	movl %ecx, %esi
	addl %esi, %esi
	btsl %esi, %edx
	incl %esi
	btsl %esi, %edx
13:	incl %ecx
	jmp 11b
12:	movq %rbx, %rdi
	movl %edx, %esi
	call em_mask_imm			# the scratch mask = the dword lanes
	movl %eax, %r14d
	# vpcmpeqd ks{ks}, s1, s2
	movq %rsp, %rdi
	movl $1, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0x76, %r8d
	movl %r14d, %r9d
	call mv_set
	movzbl IN_VVVV(%r12), %eax
	movb %al, MV_VVVV(%rsp)
	movb %r14b, MV_K(%rsp)
	movq %rsp, %rdi
	movl $RM_REG, %esi
	movl %r15d, %edx
	call mv_rm
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	movq %rbx, %rdi
	xorl %esi, %esi
	movl %r14d, %edx
	call em_kmov_r_k			# eax = the dword mask
	movq %rbx, %rdi
	leaq .Lb_pack2(%rip), %rsi
	movl $46, %edx
	call em_bytes				# eax = one bit a qword
	cmpb $0, IN_AAA(%r12)
	je 2f
	movq %rbx, %rdi
	movl $1, %esi
	movzbl IN_AAA(%r12), %edx
	call em_kmov_r_k
	movq %rbx, %rdi
	leaq .Lb_and_eax_ecx(%rip), %rsi
	movl $2, %edx
	call em_bytes
2:	cmpb $2, IN_ENC(%r12)
	jne 3f
	# EVEX: into the mask register
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	xorl %edx, %edx
	call em_kmov_k_r
	jmp .Lcq_ok
3:	# VEX: the register: the qword bits spread to dword lanes, all ones there
	movq %rbx, %rdi
	movl %r14d, %esi
	xorl %edx, %edx
	call em_kmov_k_r			# ks = the qword mask
	movq %rbx, %rdi
	movl %r14d, %esi
	movl $0xffff, %edx
	call em_qmask_to_dmask
	movl %eax, %r14d
	movq %rbx, %rdi
	movl $-1, %esi
	call em_const_dw
	cmpl $-1, %eax
	je .Lcq_notemp
	movl %eax, MV_BYTES + 8(%rsp)
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	xorl %edx, %edx
	xorl %ecx, %ecx
	call em_zero
	movq %rbx, %rdi
	movzbl IN_REG(%r12), %esi
	movl $RM_CONST, %edx
	movl MV_BYTES + 8(%rsp), %ecx
	movl %r14d, %r8d
	xorl %r9d, %r9d
	call em_vmov
.Lcq_ok:
	xorl %eax, %eax
	jmp .Lcq_out
.Lcq_notemp:
	leaq s_no_temp(%rip), %rax
.Lcq_out:
	addq $MV_BYTES + 16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
	.section .rodata
.Lb_kunpck: .byte 0xc1, 0xe0, 0x08, 0x0f, 0xb6, 0xc9, 0x09, 0xc8, 0x0f, 0xb7, 0xc0
.Lb_movzx_w_rcx: .byte 0x0f, 0xb7, 0x01
.Lb_mov_rcx_ax: .byte 0x66, 0x89, 0x01
	# mov ecx,eax; shr ecx,1; and eax,ecx; and eax,0x5555; mov ecx,eax; shr ecx,1; or eax,ecx; and eax,0x3333;
	# mov ecx,eax; shr ecx,2; or eax,ecx; and eax,0x0f0f; mov ecx,eax; shr ecx,4; or eax,ecx; and eax,0x00ff
.Lb_pack2: .byte 0x89, 0xc1, 0xd1, 0xe9, 0x21, 0xc8, 0x25, 0x55, 0x55, 0x00, 0x00
	.byte 0x89, 0xc1, 0xd1, 0xe9, 0x09, 0xc8, 0x25, 0x33, 0x33, 0x00, 0x00
	.byte 0x89, 0xc1, 0xc1, 0xe9, 0x02, 0x09, 0xc8, 0x25, 0x0f, 0x0f, 0x00, 0x00
	.byte 0x89, 0xc1, 0xc1, 0xe9, 0x04, 0x09, 0xc8, 0x25, 0xff, 0x00, 0x00, 0x00
.Lb_and_eax_ecx: .byte 0x21, 0xc8
	.text
	.include "xlate2.S"

# xl_maskmov: vpmaskmovd (AVX2: VEX.128/256.66.0F38.W0 8C load, 8E
# store): the dword lanes whose mask (vvvv) has its sign set are moved,
# a load zeroes the others. The card has no such move: the scratch mask
# is set to the length's lanes, then vpcmpd k{k}, vvvv, zero, 1 (lt)
# keeps those whose mask dword is negative; a load zeroes d first (after
# the compare: d may be the mask register, as in tinyBLAS's gemm_bloc);
# then the decoded instruction becomes a vmovdqu (6F load, 7F store)
# under that mask, merging, and xl_mov_unaligned does the move (the
# unaligned pair: the card needs aligned operands; masked-off lanes are
# never written, and a read past the program's mapping reads the card's
# zero pages). 2026-10-14: gemm_bloc left the card at each of its six
# vpmaskmovd (an X_HOST exit, then native).
xl_maskmov:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES + 16, %rsp
	LOADCTX
	testb $H_MEM, IN_HAS(%r12)
	jz .Lmk_shape
	# the scratch mask: the length's lanes
	EV_LL %edi
	movl $16, %eax
	cmpl $2, %edi
	je 1f
	xorl %esi, %esi
	call vl_lanes
1:	movq %rbx, %rdi
	movl %eax, %esi
	call em_mask_imm
	movl %eax, %r14d			# the scratch k
	movq %rbx, %rdi
	call em_temp
	testl %eax, %eax
	js .Lmk_notemp
	movl %eax, %r15d
	movq %rbx, %rdi
	movl %r15d, %esi
	xorl %edx, %edx
	xorl %ecx, %ecx
	call em_zero				# a zero vector
	movq %rsp, %rdi				# vpcmpd k{k}, vvvv, zero, 1: MVEX.66.0F3A.W0 1F
	movl $3, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0x1f, %r8d
	movl %r14d, %r9d
	call mv_set
	movzbl IN_VVVV(%r12), %eax
	movb %al, MV_VVVV(%rsp)
	movw $1, MV_IMM(%rsp)
	movb %r14b, MV_K(%rsp)
	movq %rsp, %rdi
	movl $RM_REG, %esi
	movl %r15d, %edx
	call mv_rm
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	cmpb $0x8c, IN_OP(%r12)
	jne 2f
	movq %rbx, %rdi				# a load: d zeroed, then merged into
	movzbl IN_REG(%r12), %esi
	xorl %edx, %edx
	xorl %ecx, %ecx
	call em_zero
	movb $0x6f, IN_OP(%r12)
	jmp 3f
2:	movb $0x7f, IN_OP(%r12)
3:	movb %r14b, IN_AAA(%r12)
	movb $0, IN_Z(%r12)
	movb $0, IN_VVVV(%r12)
	movb $2, IN_L(%r12)			# as a 512-bit move: the mask holds the length already, and
						# xl_mov_unaligned would set its length lanes in the same scratch mask (all lanes moved: the first try)
	movq %rbx, %rdi
	movq %r13, %rsi
	addq $MV_BYTES + 16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	jmp xl_mov_unaligned
.Lmk_notemp:
	leaq s_no_temp(%rip), %rax
	jmp 9f
.Lmk_shape:
	leaq s_shape(%rip), %rax
9:	addq $MV_BYTES + 16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_shiftx: shlx, shrx, sarx (BMI2: VEX.LZ.{66,F2,F3}.0F38.W0/W1 F7 /r):
# d = s shifted by vvvv (masked to 31 or 63), the flags untouched. The
# card has no BMI2: the flags, rax and rcx saved (em_flags, em_rcx), s
# into rax and the count into rcx (from their saved values when they are
# rax or rcx), shl/shr/sar rax, cl (D3 /4, /5, /7; REX.W for W1; the
# 32-bit form zero-extends as the original does), rax into [fs:S_GPR],
# and d from there once everything is restored (em_gpr_result). A memory
# s is refused (it stays a lazy site). 2026-10-14: two in
# ggml_graph_compute_thread made the graph thread leave the card.
xl_shiftx:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	LOADCTX
	testb $H_MEM, IN_HAS(%r12)
	jnz .Lsx_shape
	movzbl IN_W(%r12), %r14d
	movl XF_A(%r13), %r15d			# the shift's /reg
	movq %rbx, %rdi
	call em_flags
	movq %rbx, %rdi
	call em_rcx
	# s into rax
	movzbl IN_RM(%r12), %eax
	cmpl $1, %eax
	ja 2f
	movl $S_RAX, %ecx			# rax or rcx: their saved values
	testl %eax, %eax
	jz 11f
	movl $S_RCX, %ecx
11:	movq %rbx, %rdi
	xorl %esi, %esi
	movl $1, %edx
	xorl %r8d, %r8d
	call em_gpr_scratch
	jmp 3f
2:	movq %rbx, %rdi				# mov rax, rN: REX.W (+B) 8B C0+n
	movl %eax, %r8d
	movl $0x48, %eax
	cmpl $8, %r8d
	jb 21f
	orl $1, %eax
21:	pushq %r8
	pushq %r8
	call em_byte
	movl $0x8b, %eax
	call em_byte
	popq %r8
	popq %r8
	movl %r8d, %eax
	andl $7, %eax
	orl $0xc0, %eax
	call em_byte
3:	# the count into rcx
	movzbl IN_VVVV(%r12), %eax
	cmpl $1, %eax
	je 5f					# rcx itself: still the program's
	testl %eax, %eax
	jnz 4f
	movq %rbx, %rdi				# rax: its saved value
	movl $1, %esi
	movl $1, %edx
	movl $S_RAX, %ecx
	xorl %r8d, %r8d
	call em_gpr_scratch
	jmp 5f
4:	movq %rbx, %rdi				# mov rcx, rN: REX.W (+B) 8B C8+n
	movl %eax, %r8d
	movl $0x48, %eax
	cmpl $8, %r8d
	jb 41f
	orl $1, %eax
41:	pushq %r8
	pushq %r8
	call em_byte
	movl $0x8b, %eax
	call em_byte
	popq %r8
	popq %r8
	movl %r8d, %eax
	andl $7, %eax
	orl $0xc8, %eax
	call em_byte
5:	# the shift: [REX.W] D3 /k with rax
	movq %rbx, %rdi
	testl %r14d, %r14d
	jz 6f
	movl $0x48, %eax
	call em_byte
6:	movl $0xd3, %eax
	call em_byte
	movl %r15d, %eax
	shll $3, %eax
	orl $0xc0, %eax
	call em_byte
	movq %rbx, %rdi				# rax into [fs:S_GPR]
	xorl %esi, %esi
	movl $1, %edx
	movl $S_GPR, %ecx
	movl $1, %r8d
	call em_gpr_scratch
	movq %rbx, %rdi				# d from there, last
	movzbl IN_REG(%r12), %esi
	movl %r14d, %edx
	movl $S_GPR, %ecx
	call em_gpr_result
	xorl %eax, %eax
	jmp 9f
.Lsx_shape:
	leaq s_shape(%rip), %rax
9:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# xl_movmsk: vmovmskps r32, xmm/ymm (VEX 0F 50 /r, register form): the
# sign bits of the dword lanes into the low bits of r, the rest zero. The
# card has no such move: the scratch mask set to the length's lanes,
# vpcmpd k{k}, s, zero, 1 (lt: a negative int32 is a set sign bit), then
# kmov eax, k into [fs:S_GPR] and r from there once all is restored
# (em_gpr_result: rax was the transient). 2026-10-14: in
# ggml_vec_soft_max_f32's loop, a host exit each (128 every 5 s).
xl_movmsk:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES + 16, %rsp
	LOADCTX
	testb $H_MEM, IN_HAS(%r12)
	jnz .Lmk2_shape
	EV_LL %edi
	movl $16, %eax
	cmpl $2, %edi
	je 1f
	xorl %esi, %esi
	call vl_lanes
1:	movq %rbx, %rdi
	movl %eax, %esi
	call em_mask_imm
	movl %eax, %r14d			# the scratch k: the length's lanes
	movq %rbx, %rdi
	call em_temp
	testl %eax, %eax
	js .Lmk2_notemp
	movl %eax, %r15d
	movq %rbx, %rdi
	movl %r15d, %esi
	xorl %edx, %edx
	xorl %ecx, %ecx
	call em_zero
	movq %rsp, %rdi				# vpcmpd k{k}, s, zero, 1
	movl $3, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0x1f, %r8d
	movl %r14d, %r9d
	call mv_set
	movzbl IN_RM(%r12), %eax
	movb %al, MV_VVVV(%rsp)
	movw $1, MV_IMM(%rsp)
	movb %r14b, MV_K(%rsp)
	movq %rsp, %rdi
	movl $RM_REG, %esi
	movl %r15d, %edx
	call mv_rm
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	movq %rbx, %rdi				# kmov eax, k (rax saved: em_mask_imm took it)
	call em_rax
	movq %rbx, %rdi
	xorl %esi, %esi
	movl %r14d, %edx
	call em_kmov_r_k
	movq %rbx, %rdi				# into [fs:S_GPR]
	xorl %esi, %esi
	movl $1, %edx
	movl $S_GPR, %ecx
	movl $1, %r8d
	call em_gpr_scratch
	movq %rbx, %rdi				# r from there, last (32 bits: zero-extended)
	movzbl IN_REG(%r12), %esi
	xorl %edx, %edx
	movl $S_GPR, %ecx
	call em_gpr_result
	xorl %eax, %eax
	jmp 9f
.Lmk2_notemp:
	leaq s_no_temp(%rip), %rax
	jmp 9f
.Lmk2_shape:
	leaq s_shape(%rip), %rax
9:	addq $MV_BYTES + 16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
