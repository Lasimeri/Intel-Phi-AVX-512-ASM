# xlate2.S: the second file of recipes, included by xlate.S at its end
# (one assembly unit: the helpers commit, src2, vl_lanes, the macros
# LOADCTX and EV_LL, the refusal strings and the byte strings of xlate.S
# are in reach; the forms are listed in xlate2.inc, included in xlate.S's
# table). The recipes are ports of host/crates/avx512-xlate/src/rewrite.rs,
# sequence for sequence. Each: rdi = em, rsi = the form; rax 0 or a
# refusal. Register use: rbx = em, r12 = in, r13 = the form (LOADCTX),
# r14 and r15 and the frame's slots as each recipe says. See xlate2.md.

	.text

# The frame of a recipe: the MVEX argument block at 0, the instruction's
# fields as dwords, six 8-byte slots. R_FRAME keeps the stack 16-aligned
# at the calls (five pushes before it).
	.set R_FRAME, 112
	.set FD, MV_BYTES			# IN_REG
	.set FS1, MV_BYTES + 4			# IN_VVVV
	.set FRM, MV_BYTES + 8			# IN_RM
	.set FAAA, MV_BYTES + 12		# IN_AAA
	.set FLL, MV_BYTES + 16			# the vector length (0 128, 1 256, 2 512)
	.set FR0, MV_BYTES + 24
	.set FR1, MV_BYTES + 32
	.set FR2, MV_BYTES + 40
	.set FR3, MV_BYTES + 48
	.set FR4, MV_BYTES + 56
	.set FR5, MV_BYTES + 64

	.macro R_ENTER
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $R_FRAME, %rsp
	LOADCTX
	movzbl IN_REG(%r12), %eax
	movl %eax, FD(%rsp)
	movzbl IN_VVVV(%r12), %eax
	movl %eax, FS1(%rsp)
	movzbl IN_RM(%r12), %eax
	movl %eax, FRM(%rsp)
	movzbl IN_AAA(%r12), %eax
	movl %eax, FAAA(%rsp)
	EV_LL %eax
	movl %eax, FLL(%rsp)
	.endm
	.macro R_LEAVE
	addq $R_FRAME, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
	.endm
	.macro R_OK
	xorl %eax, %eax
	R_LEAVE
	.endm
	.macro R_EM fn
	movq %rbx, %rdi
	call \fn
	.endm
# R_MVEX map, pp, w, op, reg, vvvv, kind, rm, k, sss, imm: one MVEX
# instruction through the frame's block; rm a register number, a scratch
# offset or a constant's index. R_MVEXM: the instruction's memory
# operand as the r/m. The arguments are immediates, frame slots or
# callee-saved registers (never eax, ecx, edx, esi, edi, r8, r9).
	.macro R_MVEX map, pp, w, op, reg, vvvv, kind, rm, k=$0, sss=$0, imm=$-1
	movq %rsp, %rdi
	movl \map, %esi
	movl \pp, %edx
	movl \w, %ecx
	movl \op, %r8d
	movl \reg, %r9d
	call mv_set
	movq %rsp, %rdi
	movl \kind, %esi
	movl \rm, %edx
	call mv_rm
	movl \vvvv, %eax
	movb %al, MV_VVVV(%rsp)
	movl \k, %eax
	movb %al, MV_K(%rsp)
	movl \sss, %eax
	movb %al, MV_SSS(%rsp)
	movl \imm, %eax
	movw %ax, MV_IMM(%rsp)
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	.endm
	.macro R_MVEXM map, pp, w, op, reg, vvvv, k=$0, sss=$0, imm=$-1
	movq %rsp, %rdi
	movl \map, %esi
	movl \pp, %edx
	movl \w, %ecx
	movl \op, %r8d
	movl \reg, %r9d
	call mv_set
	movq %rsp, %rdi
	movl $RM_MEM, %esi
	movq %r12, %rdx
	call mv_rm
	movl \vvvv, %eax
	movb %al, MV_VVVV(%rsp)
	movl \k, %eax
	movb %al, MV_K(%rsp)
	movl \sss, %eax
	movb %al, MV_SSS(%rsp)
	movl \imm, %eax
	movw %ax, MV_IMM(%rsp)
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	.endm
	.macro R_I0F op, d, s1, kind, rm, k=$0, w=$0
	R_MVEX $1, $1, \w, \op, \d, \s1, \kind, \rm, \k
	.endm
	.macro R_I38 op, d, s1, kind, rm, k=$0
	R_MVEX $2, $1, $0, \op, \d, \s1, \kind, \rm, \k
	.endm
# R_SHIFT which, d, kind, rm, n, k: vpsrld /2, vpsrad /4, vpslld /6 by n.
	.macro R_SHIFT which, d, kind, rm, n, k=$0
	R_MVEX $1, $1, $0, $0x72, \which, \d, \kind, \rm, \k, $0, \n
	.endm
	.macro R_VPSHUFD d, kind, rm, imm, k=$0
	R_MVEX $1, $1, $0, $0x70, \d, $0, \kind, \rm, \k, $0, \imm
	.endm
	.macro R_VPERMF d, kind, rm, imm, k=$0
	R_MVEX $3, $1, $0, $0x07, \d, $0, \kind, \rm, \k, $0, \imm
	.endm
	.macro R_VPERMD d, idx, kind, rm, k=$0
	R_MVEX $2, $1, $0, $0x36, \d, \idx, \kind, \rm, \k
	.endm
	.macro R_VALIGND d, s1, kind, rm, imm, k=$0
	R_MVEX $3, $1, $0, $0x03, \d, \s1, \kind, \rm, \k, $0, \imm
	.endm
# R_VCMP kd, s1, kind, rm, pred, k, w: vcmpps (0F C2 ib), vcmppd (66.0F.W1 C2 ib).
	.macro R_VCMP kd, s1, kind, rm, pred, k=$0, w=$0
	R_MVEX $1, \w, \w, $0xc2, \kd, \s1, \kind, \rm, \k, $0, \pred
	.endm
	.macro R_VPCMPD kd, s1, kind, rm, pred, k=$0
	R_MVEX $3, $1, $0, $0x1f, \kd, \s1, \kind, \rm, \k, $0, \pred
	.endm
	.macro R_VPCMPUD kd, s1, kind, rm, pred, k=$0
	R_MVEX $3, $1, $0, $0x1e, \kd, \s1, \kind, \rm, \k, $0, \pred
	.endm
	.macro R_VPCMPEQD kd, s1, kind, rm, k=$0
	R_MVEX $1, $1, $0, $0x76, \kd, \s1, \kind, \rm, \k
	.endm
	.macro R_VPTESTMD kd, s1, kind, rm, k=$0
	R_MVEX $2, $1, $0, $0x27, \kd, \s1, \kind, \rm, \k
	.endm
	.macro R_FMA op, d, s1, kind, rm, w=$0
	R_MVEX $2, $1, \w, \op, \d, \s1, \kind, \rm
	.endm
	.macro R_VMULP d, s1, kind, rm, w=$0
	R_MVEX $1, \w, \w, $0x59, \d, \s1, \kind, \rm
	.endm
	.macro R_VMOV d, kind, rm, k=$0, w=$0
	movq %rbx, %rdi
	movl \d, %esi
	movl \kind, %edx
	movl \rm, %ecx
	movl \k, %r8d
	movl \w, %r9d
	call em_vmov
	.endm
	.macro R_ZERO d, k=$0, w=$0
	movq %rbx, %rdi
	movl \d, %esi
	movl \k, %edx
	movl \w, %ecx
	call em_zero
	.endm
	.macro R_ZERO_LANES d, mask
	movq %rbx, %rdi
	movl \d, %esi
	movl \mask, %edx
	call em_zero_lanes
	.endm
# R_MASK mask: the scratch mask set to mask; its number in eax.
	.macro R_MASK mask
	movq %rbx, %rdi
	movl \mask, %esi
	call em_mask_imm
	.endm
	.macro R_CONST_DW v, fail
	movq %rbx, %rdi
	movl \v, %esi
	call em_const_dw
	cmpl $-1, %eax
	je \fail
	.endm
	.macro R_CONST bytes, fail
	movq %rbx, %rdi
	leaq \bytes(%rip), %rsi
	call em_const
	cmpl $-1, %eax
	je \fail
	.endm
	.macro R_TEMP fail
	movq %rbx, %rdi
	call em_temp
	cmpl $-1, %eax
	je \fail
	.endm
# R_K2 fn, a, b: a two-operand mask helper (em_kand, em_knot, em_kor,
# em_kmov_kk, em_kmov_k_r k r, em_kmov_r_k r k).
	.macro R_K2 fn, a, b
	movq %rbx, %rdi
	movl \a, %esi
	movl \b, %edx
	call \fn
	.endm
	.macro R_BYTES lbl, n
	movq %rbx, %rdi
	leaq \lbl(%rip), %rsi
	movl \n, %edx
	call em_bytes
	.endm
	.macro R_BYTE v
	movq %rbx, %rdi
	movl \v, %eax
	call em_byte
	.endm
# R_AND_EAX v: and eax, imm32.
	.macro R_AND_EAX v
	movq %rbx, %rdi
	movl $0x25, %eax
	call em_byte
	movq %rbx, %rdi
	movl \v, %eax
	call em_dword
	.endm
# R_SRC2 qword, float, fail: the second source as a register in eax.
	.macro R_SRC2 qword, float, fail
	movq %rbx, %rdi
	movl \qword, %esi
	movl \float, %edx
	call src2
	cmpl $-1, %eax
	je \fail
	.endm
	.macro R_COMMIT d, r, qword=$0
	movq %rbx, %rdi
	movl \d, %esi
	movl \r, %edx
	movl \qword, %ecx
	call commit
	.endm
# R_LANES qword: the lanes of the instruction's vector length in eax.
	.macro R_LANES qword
	EV_LL %edi
	movl \qword, %esi
	call vl_lanes
	.endm
	.macro R_BCASTM d, k=$0, w=$0
	movq %rbx, %rdi
	movl \d, %esi
	movl $RM_MEM, %edx
	movq %r12, %rcx
	movl \k, %r8d
	movl \w, %r9d
	call em_broadcast
	.endm
# R_UNAL d, k, w, store, float, sss: the unaligned pair over the
# instruction's memory operand (sss and float pushed: an immediate or a
# 64-bit register; the rest loaded before the pushes).
	.macro R_UNAL d, k, w, store, float, sss
	movl \d, %esi
	movl \k, %ecx
	movl \w, %r8d
	movl \store, %r9d
	pushq \sss
	pushq \float
	movq %rbx, %rdi
	movq %r12, %rdx
	call em_unaligned
	addq $16, %rsp
	.endm
	.macro R_GPRS r, wide, off, store
	movq %rbx, %rdi
	movl \r, %esi
	movl \wide, %edx
	movl \off, %ecx
	movl \store, %r8d
	call em_gpr_scratch
	.endm
	.macro R_GPRR r, wide, off
	movq %rbx, %rdi
	movl \r, %esi
	movl \wide, %edx
	movl \off, %ecx
	call em_gpr_result
	.endm
	.macro R_FSOP bytes, n, reg, off
	movq %rbx, %rdi
	leaq \bytes(%rip), %rsi
	movl \n, %edx
	movl \reg, %ecx
	movl \off, %r8d
	call fs_op
	.endm
	.macro R_MOVEAX v
	movq %rbx, %rdi
	movl \v, %esi
	call em_mov_eax
	.endm

# ---- qword integer arithmetic in dword lanes ----

# xl_addsubq: vpaddq (XF_A FE) and vpsubq (FA): both halves of every
# qword added (subtracted), then the carry (borrow) of each low half
# into its high half: an unsigned compare of the low halves (the sum
# below a summand; the minuend below the subtrahend), kept on the even
# lanes and moved up a lane through eax; the high halves it marks take
# one more (less). (rewrite.rs add_sub_q.)
xl_addsubq:
	R_ENTER
	R_SRC2 $1, $0, .Lasq_notemp
	movl %eax, %r15d			# s2
	R_TEMP .Lasq_notemp
	movl %eax, %r14d			# r
	R_I0F XF_A(%r13), %r14d, FS1(%rsp), $RM_REG, %r15d
	R_EM em_flags
	R_EM em_k
	movl %eax, FR0(%rsp)			# k
	cmpl $0xfa, XF_A(%r13)
	je .Lasq_sub
	R_VPCMPUD FR0(%rsp), %r14d, $RM_REG, FS1(%rsp), $1	# the sum below s1: a carry
	jmp .Lasq_carry
.Lasq_sub:
	R_VPCMPUD FR0(%rsp), FS1(%rsp), $RM_REG, %r15d, $1	# s1 below s2: a borrow
.Lasq_carry:
	R_K2 em_kmov_r_k, $0, FR0(%rsp)
	R_BYTES .Lb_and5555_shl1, $7		# and eax, 0x5555; shl eax, 1
	R_K2 em_kmov_k_r, FR0(%rsp), $0
	R_CONST_DW $1, .Lasq_notemp
	movl %eax, FR1(%rsp)
	R_I0F XF_A(%r13), %r14d, %r14d, $RM_CONST, FR1(%rsp), FR0(%rsp)
	R_COMMIT FD(%rsp), %r14d, $1
	R_OK
.Lasq_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_shiftq: vpsrlq (XF_A 0), vpsllq (1), vpsraq (2) by immediate: the
# two halves of each qword shifted and combined; the destination in
# vvvv, the source in r/m or memory. (rewrite.rs shift_q.) The forms by
# a count in xmm are not taken.
xl_shiftq:
	R_ENTER
	testb $H_IMM, IN_HAS(%r12)
	jz .Lshq_shape
	R_SRC2 $1, $0, .Lshq_notemp
	movl %eax, %r15d			# s
	R_TEMP .Lshq_notemp
	movl %eax, %r14d			# r
	R_TEMP .Lshq_notemp
	movl %eax, FR0(%rsp)			# t
	movzbl IN_IMM(%r12), %eax
	movl %eax, FR1(%rsp)			# n
	movl $2, %eax				# the right shift's /n: 2 logical, 4 arithmetic
	cmpl $2, XF_A(%r13)
	jne .Lshq_which
	movl $4, %eax
.Lshq_which:
	movl %eax, FR3(%rsp)
	cmpl $1, XF_A(%r13)
	je .Lshq_left
	cmpl $64, FR1(%rsp)
	jb .Lshq_r64
	cmpl $2, XF_A(%r13)
	jne .Lshq_zero
	R_VPSHUFD %r14d, $RM_REG, %r15d, $0xf5	# the sign's dword in both lanes
	R_SHIFT $4, %r14d, $RM_REG, %r14d, $31
	jmp .Lshq_done
.Lshq_r64:
	cmpl $32, FR1(%rsp)
	jb .Lshq_r32
	# low <- high >> (n - 32); high <- 0 or the sign
	R_VPSHUFD %r14d, $RM_REG, %r15d, $0xf5
	R_MASK $0x5555
	movl %eax, FR2(%rsp)
	subl $32, FR1(%rsp)
	R_SHIFT FR3(%rsp), %r14d, $RM_REG, %r14d, FR1(%rsp), FR2(%rsp)
	R_MASK $0xaaaa
	movl %eax, FR2(%rsp)
	cmpl $2, XF_A(%r13)
	jne .Lshq_r64z
	R_SHIFT $4, %r14d, $RM_REG, %r14d, $31, FR2(%rsp)
	jmp .Lshq_done
.Lshq_r64z:
	R_ZERO %r14d, FR2(%rsp)
	jmp .Lshq_done
.Lshq_r32:
	cmpl $0, FR1(%rsp)
	jne .Lshq_rn
	R_VMOV %r14d, $RM_REG, %r15d
	jmp .Lshq_done
.Lshq_rn:
	# even lanes: (lo >> n) | (hi << (32 - n)); odd lanes: hi >> n
	R_SHIFT $2, %r14d, $RM_REG, %r15d, FR1(%rsp)
	cmpl $2, XF_A(%r13)
	jne .Lshq_rn2
	R_MASK $0xaaaa
	movl %eax, FR2(%rsp)
	R_SHIFT $4, %r14d, $RM_REG, %r15d, FR1(%rsp), FR2(%rsp)
.Lshq_rn2:
	R_VPSHUFD FR0(%rsp), $RM_REG, %r15d, $0xf5
	movl $32, %eax
	subl FR1(%rsp), %eax
	movl %eax, FR2(%rsp)
	R_SHIFT $6, FR0(%rsp), $RM_REG, FR0(%rsp), FR2(%rsp)
	R_MASK $0x5555
	movl %eax, FR2(%rsp)
	R_I0F $0xeb, %r14d, %r14d, $RM_REG, FR0(%rsp), FR2(%rsp)
	jmp .Lshq_done
.Lshq_left:
	cmpl $64, FR1(%rsp)
	jae .Lshq_zero
	cmpl $32, FR1(%rsp)
	jb .Lshq_l32
	R_VPSHUFD %r14d, $RM_REG, %r15d, $0xa0	# the low dword in both lanes
	R_MASK $0xaaaa
	movl %eax, FR2(%rsp)
	subl $32, FR1(%rsp)
	R_SHIFT $6, %r14d, $RM_REG, %r14d, FR1(%rsp), FR2(%rsp)
	R_MASK $0x5555
	movl %eax, FR2(%rsp)
	R_ZERO %r14d, FR2(%rsp)
	jmp .Lshq_done
.Lshq_l32:
	cmpl $0, FR1(%rsp)
	jne .Lshq_ln
	R_VMOV %r14d, $RM_REG, %r15d
	jmp .Lshq_done
.Lshq_ln:
	# odd lanes: (hi << n) | (lo >> (32 - n)); even lanes: lo << n
	R_SHIFT $6, %r14d, $RM_REG, %r15d, FR1(%rsp)
	R_VPSHUFD FR0(%rsp), $RM_REG, %r15d, $0xa0
	movl $32, %eax
	subl FR1(%rsp), %eax
	movl %eax, FR2(%rsp)
	R_SHIFT $2, FR0(%rsp), $RM_REG, FR0(%rsp), FR2(%rsp)
	R_MASK $0xaaaa
	movl %eax, FR2(%rsp)
	R_I0F $0xeb, %r14d, %r14d, $RM_REG, FR0(%rsp), FR2(%rsp)
	jmp .Lshq_done
.Lshq_zero:
	R_ZERO %r14d
.Lshq_done:
	R_COMMIT FS1(%rsp), %r14d, $1
	R_OK
.Lshq_shape:
	leaq s_shape(%rip), %rax
	R_LEAVE
.Lshq_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_muludq: vpmuludq: the 64-bit product of the even dword lanes as the
# low and high 32-bit products (vpmulld, vpmulhud) interleaved.
xl_muludq:
	R_ENTER
	R_SRC2 $1, $0, .Lmul_notemp
	movl %eax, %r15d			# s2
	R_TEMP .Lmul_notemp
	movl %eax, %r14d			# r
	R_TEMP .Lmul_notemp
	movl %eax, FR0(%rsp)			# t
	R_I38 $0x40, %r14d, FS1(%rsp), $RM_REG, %r15d		# the low products
	R_I38 $0x86, FR0(%rsp), FS1(%rsp), $RM_REG, %r15d	# the high products
	R_VPSHUFD FR0(%rsp), $RM_REG, FR0(%rsp), $0xa0
	R_MASK $0xaaaa
	movl %eax, FR1(%rsp)
	R_VMOV %r14d, $RM_REG, FR0(%rsp), FR1(%rsp)
	R_COMMIT FD(%rsp), %r14d, $1
	R_OK
.Lmul_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# q_lt_eq(em rbx, a esi, b edx, signed ecx): each qword lane of a
# against b: eq on the even bits of [fs:S_XFER], lt on the even bits of
# eax (the odd bits garbage: the callers mask them). rax, rcx and the
# flags saved; the scratch mask used. (rewrite.rs qword_lt_eq.)
q_lt_eq:
	pushq %r12
	pushq %r14
	pushq %r15
	subq $R_FRAME, %rsp
	movl %esi, %r14d
	movl %edx, %r15d
	movl %ecx, FR3(%rsp)
	R_EM em_k
	movl %eax, FR0(%rsp)
	R_EM em_flags
	R_EM em_rcx
	R_VPCMPEQD FR0(%rsp), %r14d, $RM_REG, %r15d
	R_K2 em_kmov_r_k, $0, FR0(%rsp)
	R_BYTES .Lb_andhalf, $6			# ecx = eq of both halves, on the even bits
	R_GPRS $1, $0, $S_XFER, $1
	R_BYTES .Lb_shr_eax1, $2		# the high halves' eq on the even bits
	R_VPCMPUD FR0(%rsp), %r14d, $RM_REG, %r15d, $1
	R_K2 em_kmov_r_k, $1, FR0(%rsp)
	R_BYTES .Lb_and_eax_ecx, $2		# high eq and low lt
	R_GPRS $0, $0, $S_XFER+8, $1
	cmpl $0, FR3(%rsp)
	je .Lqle_unsigned
	R_VPCMPD FR0(%rsp), %r14d, $RM_REG, %r15d, $1
	R_K2 em_kmov_r_k, $0, FR0(%rsp)
	jmp .Lqle_high
.Lqle_unsigned:
	R_BYTES .Lb_mov_eax_ecx, $2
.Lqle_high:
	R_BYTES .Lb_shr_eax1, $2		# the high halves' lt
	R_FSOP .Lb_or_r, $1, $0, $S_XFER+8	# or eax, [fs:S_XFER + 8]
	addq $R_FRAME, %rsp
	popq %r15
	popq %r14
	popq %r12
	ret

# xl_minmax_q: vpmaxsq (XF_A 3), vpminsq (2), vpmaxuq (1), vpminuq (0):
# the second source, then the first where it wins (q_lt_eq with the
# operands in the order that makes lt the first source winning), each
# qword's bit spread over its two dword lanes for the masked move.
xl_minmax_q:
	R_ENTER
	movl XF_A(%r13), %r14d			# bit 0 max, bit 1 signed
	R_SRC2 $1, $0, .Lmq_notemp
	movl %eax, %r15d			# s2
	R_TEMP .Lmq_notemp
	movl %eax, FR4(%rsp)			# r
	movl %r14d, %ecx
	shrl $1, %ecx
	andl $1, %ecx
	testl $1, %r14d
	jz .Lmq_min
	movl %r15d, %esi			# s2 < s1: s1 is the max
	movl FS1(%rsp), %edx
	call q_lt_eq
	jmp .Lmq_spread
.Lmq_min:
	movl FS1(%rsp), %esi			# s1 < s2: s1 is the min
	movl %r15d, %edx
	call q_lt_eq
.Lmq_spread:
	R_BYTES .Lb_spread_even, $11
	R_EM em_k
	movl %eax, FR0(%rsp)
	R_K2 em_kmov_k_r, FR0(%rsp), $0
	R_VMOV FR4(%rsp), $RM_REG, %r15d, $0, $1
	R_VMOV FR4(%rsp), $RM_REG, FS1(%rsp), FR0(%rsp), $0
	R_COMMIT FD(%rsp), FR4(%rsp), $1
	R_OK
.Lmq_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_cmpq_pred: vpcmpq (XF_A 1: signed), vpcmpuq (0) with a predicate,
# vpcmpgtq (3: signed, the predicate 6): q_lt_eq gives each qword's lt
# and eq; the predicates come from those two (le: lt or eq; neq, nlt,
# nle their complements; FALSE and TRUE constants), the bits are packed
# to one per qword, cut to the vector length and the write mask.
xl_cmpq_pred:
	R_ENTER
	movl XF_A(%r13), %r14d			# bit 0 signed, bit 1 the predicate is gt
	movl $6, %eax
	testl $2, %r14d
	jnz .Lcp_pred
	movzbl IN_IMM(%r12), %eax
	andl $7, %eax
.Lcp_pred:
	movl %eax, FR0(%rsp)
	R_LANES $1
	movl %eax, FR1(%rsp)
	movl FD(%rsp), %eax
	andl $7, %eax
	movl %eax, FR2(%rsp)			# kd
	cmpl $3, FR0(%rsp)
	jne .Lcp_src
	R_MOVEAX $0				# FALSE
	R_K2 em_kmov_k_r, FR2(%rsp), $0
	R_OK
.Lcp_src:
	R_SRC2 $1, $0, .Lcp_notemp
	movl %eax, %r15d
	cmpl $7, FR0(%rsp)
	jne .Lcp_cmp
	R_EM em_flags				# TRUE: the length's lanes
	R_EM em_rcx
	R_MOVEAX FR1(%rsp)
	jmp .Lcp_mask
.Lcp_cmp:
	movl FS1(%rsp), %esi
	movl %r15d, %edx
	movl %r14d, %ecx
	andl $1, %ecx
	call q_lt_eq
	movl FR0(%rsp), %eax
	cmpl $0, %eax
	je .Lcp_eq
	cmpl $1, %eax
	je .Lcp_pack
	cmpl $2, %eax
	je .Lcp_le
	cmpl $4, %eax
	je .Lcp_neq
	cmpl $5, %eax
	je .Lcp_not
	R_FSOP .Lb_or_r, $1, $0, $S_XFER	# nle: not (lt or eq)
	R_BYTES .Lb_not_eax, $2
	jmp .Lcp_pack
.Lcp_eq:
	R_GPRS $0, $0, $S_XFER, $0
	jmp .Lcp_pack
.Lcp_le:
	R_FSOP .Lb_or_r, $1, $0, $S_XFER
	jmp .Lcp_pack
.Lcp_neq:
	R_GPRS $0, $0, $S_XFER, $0
.Lcp_not:
	R_BYTES .Lb_not_eax, $2
.Lcp_pack:
	R_BYTES .Lb_pack_even, $40
	R_AND_EAX FR1(%rsp)
.Lcp_mask:
	cmpl $0, FAAA(%rsp)
	je .Lcp_write
	R_K2 em_kmov_r_k, $1, FAAA(%rsp)
	R_BYTES .Lb_and_eax_ecx, $2
.Lcp_write:
	R_K2 em_kmov_k_r, FR2(%rsp), $0
	R_OK
.Lcp_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_testm: vptestnmd (XF_A 1), vptestmq (2), vptestnmq (3): the card's
# vptestmd on the dword lanes; a qword is nonzero when either of its
# dwords is (the two bits or'd, then packed to one per qword), the nm
# forms are the complement, cut to the vector length and the write mask.
xl_testm:
	R_ENTER
	movl XF_A(%r13), %r14d			# bit 0 negate, bit 1 qword
	movl %r14d, %eax
	shrl $1, %eax
	andl $1, %eax
	movl %eax, FR1(%rsp)
	R_LANES FR1(%rsp)
	movl %eax, FR0(%rsp)			# the lanes
	R_SRC2 FR1(%rsp), $0, .Ltm_notemp
	movl %eax, %r15d
	R_EM em_k
	movl %eax, FR2(%rsp)
	R_EM em_flags
	R_EM em_rcx
	R_VPTESTMD FR2(%rsp), FS1(%rsp), $RM_REG, %r15d
	R_K2 em_kmov_r_k, $0, FR2(%rsp)
	testl $2, %r14d
	jz .Ltm_dword
	R_BYTES .Lb_orhalf, $6			# either dword of a qword nonzero
	testl $1, %r14d
	jz .Ltm_pack
	R_BYTES .Lb_not_eax, $2
.Ltm_pack:
	R_BYTES .Lb_pack_even, $40
	jmp .Ltm_cut
.Ltm_dword:
	testl $1, %r14d
	jz .Ltm_cut
	R_BYTES .Lb_not_eax, $2
.Ltm_cut:
	R_AND_EAX FR0(%rsp)
	cmpl $0, FAAA(%rsp)
	je .Ltm_write
	R_K2 em_kmov_r_k, $1, FAAA(%rsp)
	R_BYTES .Lb_and_eax_ecx, $2
.Ltm_write:
	movl FD(%rsp), %eax
	andl $7, %eax
	movl %eax, FR3(%rsp)
	R_K2 em_kmov_k_r, FR3(%rsp), $0
	R_OK
.Ltm_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# ---- widening and narrowing conversions ----

# xl_widen: vpmovzxbd (XF_A 4, XF_B 1 byte), vpmovsxbd (5, 1),
# vpmovzxwd (6, 2), vpmovsxwd (7, 2): the card's memory up-conversions,
# from memory through the unpack pair (the element's alignment only) or
# from a register through the scratch area. (rewrite.rs widen.)
xl_widen:
	R_ENTER
	movl FD(%rsp), %r14d			# r = d unless masked or narrow
	cmpl $0, FAAA(%rsp)
	jne .Lwd_temp
	cmpl $2, FLL(%rsp)
	je .Lwd_r
.Lwd_temp:
	R_TEMP .Lwd_notemp
	movl %eax, %r14d
.Lwd_r:
	R_LANES $0
	movl %eax, FR0(%rsp)			# the lanes
	movl $0, FR1(%rsp)			# the mask: none when full
	cmpl $2, FLL(%rsp)
	je .Lwd_k
	R_MASK FR0(%rsp)
	movl %eax, FR1(%rsp)
.Lwd_k:
	testb $H_MEM, IN_HAS(%r12)
	jz .Lwd_reg
	movl XF_A(%r13), %eax
	R_UNAL %r14d, FR1(%rsp), $0, $0, $0, %rax
	jmp .Lwd_commit
.Lwd_reg:
	# the source's elements (the lanes' count times the element's bytes) to the scratch slot
	popcntl FR0(%rsp), %eax
	imull XF_B(%r13), %eax
	addl $3, %eax
	shrl $2, %eax
	movl %eax, %ecx
	movl $1, %eax
	shll %cl, %eax
	decl %eax
	R_MASK %eax
	movl %eax, FR2(%rsp)
	R_MVEX $2, $1, $0, $0xd0, FRM(%rsp), $0, $RM_FS, $S_XFER, FR2(%rsp)
	movl XF_A(%r13), %eax
	movl %eax, FR2(%rsp)
	R_MVEX $1, $1, $0, $0x6f, %r14d, $0, $RM_FS, $S_XFER, FR1(%rsp), FR2(%rsp)
.Lwd_commit:
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Lwd_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_widen_dq: vpmovzxdq (XF_A 0), vpmovsxdq (1): dword j of the source
# to qword j, its high half zero or the sign: the dwords permuted into
# both halves of their qword (vpermd by 0, 0, 1, 1, ...) and the high
# halves zeroed or shifted to the sign (vpsrad 31). (rewrite.rs widen_dq.)
xl_widen_dq:
	R_ENTER
	R_TEMP .Lwq_notemp
	movl %eax, %r14d			# r
	R_TEMP .Lwq_notemp
	movl %eax, %r15d			# t
	movl FRM(%rsp), %eax
	movl %eax, FR0(%rsp)			# s
	testb $H_MEM, IN_HAS(%r12)
	jz .Lwq_perm
	R_TEMP .Lwq_notemp
	movl %eax, FR0(%rsp)
	R_LANES $1
	popcntl %eax, %ecx
	movl $1, %eax
	shll %cl, %eax
	decl %eax				# the source's dwords: half the destination's lanes
	R_MASK %eax
	movl %eax, FR1(%rsp)
	R_UNAL FR0(%rsp), FR1(%rsp), $0, $0, $0, $0
.Lwq_perm:
	R_CONST .Lc_idx_dq, .Lwq_notemp
	movl %eax, FR1(%rsp)
	R_VMOV %r15d, $RM_CONST, FR1(%rsp)
	R_VPERMD %r14d, %r15d, $RM_REG, FR0(%rsp)
	R_MASK $0xaaaa
	movl %eax, FR1(%rsp)
	cmpl $0, XF_A(%r13)
	je .Lwq_zero
	R_SHIFT $4, %r14d, $RM_REG, %r14d, $31, FR1(%rsp)
	jmp .Lwq_commit
.Lwq_zero:
	R_ZERO %r14d, FR1(%rsp)
.Lwq_commit:
	R_COMMIT FD(%rsp), %r14d, $1
	R_OK
.Lwq_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_cvt_to_int: vcvttps2dq (XF_A 1) and vcvtps2dq (0): the card's
# fixed-point conversion (truncation or MXCSR's rounding), then NaN and
# overflow made the integer indefinite 0x80000000, which the card does
# not produce for NaN or positive overflow. (rewrite.rs cvt_to_int.)
xl_cvt_to_int:
	R_ENTER
	R_SRC2 $0, $XB_FLOAT, .Lcti_notemp
	movl %eax, %r15d			# s
	R_TEMP .Lcti_notemp
	movl %eax, %r14d			# r
	movl $0, FR0(%rsp)
	cmpl $0, XF_A(%r13)
	je .Lcti_cvt
	movl $3, FR0(%rsp)			# truncation
.Lcti_cvt:
	R_MVEX $3, $1, $0, $0xcb, %r14d, $0, $RM_REG, %r15d, $0, $0, FR0(%rsp)
	R_CONST_DW $0x4f000000, .Lcti_notemp	# 2147483648.0f
	movl %eax, FR1(%rsp)
	R_EM em_k
	movl %eax, FR2(%rsp)
	R_VCMP FR2(%rsp), %r15d, $RM_CONST, FR1(%rsp), $5	# not less: too big, or unordered
	R_CONST_DW $0x80000000, .Lcti_notemp
	movl %eax, FR1(%rsp)
	R_VMOV %r14d, $RM_CONST, FR1(%rsp), FR2(%rsp)
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Lcti_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_cvt_pd2ps: vcvtpd2ps ymm, zmm/m512 (and the xmm forms): the card's
# vcvtpd2ps gives the floats in the low lanes (8, 4 or 2); the lanes
# above are zeroed, as the narrower destination requires; the write mask
# and {z} applied to the destination's lanes. (rewrite.rs cvt_pd2ps.)
xl_cvt_pd2ps:
	R_ENTER
	movl FRM(%rsp), %r15d
	testb $H_MEM, IN_HAS(%r12)
	jz .Lpdps_src
	R_TEMP .Lpdps_notemp
	movl %eax, %r15d
	movl $0, FR0(%rsp)
	cmpl $2, FLL(%rsp)
	je .Lpdps_load
	R_LANES $0
	R_MASK %eax
	movl %eax, FR0(%rsp)
.Lpdps_load:
	R_UNAL %r15d, FR0(%rsp), $0, $0, $0, $0
.Lpdps_src:
	movl FD(%rsp), %r14d
	cmpl $0, FAAA(%rsp)
	je .Lpdps_cvt
	R_TEMP .Lpdps_notemp
	movl %eax, %r14d
.Lpdps_cvt:
	R_MVEX $1, $1, $1, $0x5a, %r14d, $0, $RM_REG, %r15d
	movl $0xff, %eax			# the floats: 8 from 8 doubles, 4, 2
	cmpl $2, FLL(%rsp)
	je .Lpdps_lanes
	movl $0xf, %eax
	cmpl $1, FLL(%rsp)
	je .Lpdps_lanes
	movl $3, %eax
.Lpdps_lanes:
	movl %eax, FR1(%rsp)
	notl %eax
	andl $0xffff, %eax
	movl %eax, FR2(%rsp)			# the lanes above
	R_ZERO_LANES %r14d, FR2(%rsp)
	cmpl $0, FAAA(%rsp)
	je .Lpdps_ok
	R_MASK FR1(%rsp)
	movl %eax, FR3(%rsp)
	R_K2 em_kand, FR3(%rsp), FAAA(%rsp)
	R_VMOV FD(%rsp), $RM_REG, %r14d, FR3(%rsp)
	cmpb $0, IN_Z(%r12)
	je .Lpdps_upper
	R_K2 em_knot, FR3(%rsp), FR3(%rsp)
	R_ZERO FD(%rsp), FR3(%rsp)
	R_OK
.Lpdps_upper:
	R_ZERO_LANES FD(%rsp), FR2(%rsp)
.Lpdps_ok:
	R_OK
.Lpdps_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# ---- two operands: the card's own instruction ----

# xl_op2: d{k} = op(r/m, memory or a broadcast) with an immediate the
# program gives (XB_IMM) or the form fixes (XB_FIX: bits 8 to 15 of
# XF_B): vcvtdq2ps and vcvtudq2ps (the fixed-point conversions with no
# exponent adjust), vgetexpps, vgetmantps. The 512-bit form under {k},
# a narrower one under the length's lanes and {k}; {z} and the lanes
# above by commit. (rewrite.rs generic.)
xl_op2:
	R_ENTER
	movl XF_B(%r13), %r14d
	movl %r14d, %eax
	andl $XB_QWORD, %eax
	movl %eax, FR1(%rsp)			# qword lanes
	movl FRM(%rsp), %r15d
	testb $H_MEM, IN_HAS(%r12)
	jz .Lop2_reg
	movl %r14d, %edx
	andl $XB_FLOAT, %edx
	R_SRC2 FR1(%rsp), %edx, .Lop2_notemp
	movl %eax, %r15d
.Lop2_reg:
	movl $-1, %eax
	testl $XB_IMM, %r14d
	jz .Lop2_fix
	movzbl IN_IMM(%r12), %eax
	jmp .Lop2_imm
.Lop2_fix:
	testl $XB_FIX, %r14d
	jz .Lop2_imm
	movl %r14d, %eax
	shrl $8, %eax
	andl $0xff, %eax
.Lop2_imm:
	movl %eax, FR0(%rsp)
	movl FAAA(%rsp), %eax
	movl %eax, FR2(%rsp)			# the mask: {k} when full
	cmpl $2, FLL(%rsp)
	je .Lop2_enc
	R_LANES FR1(%rsp)
	R_MASK %eax
	movl %eax, FR2(%rsp)
	cmpl $0, FAAA(%rsp)
	je .Lop2_enc
	R_K2 em_kand, FR2(%rsp), FAAA(%rsp)
.Lop2_enc:
	movl XF_A(%r13), %eax
	movzbl %al, %ecx
	movl %ecx, FR3(%rsp)			# map
	movl %eax, %ecx
	shrl $8, %ecx
	movzbl %cl, %ecx
	movl %ecx, FR4(%rsp)			# pp
	movl %eax, %ecx
	shrl $16, %ecx
	movzbl %cl, %ecx
	movl %ecx, FR5(%rsp)			# w
	shrl $24, %eax
	movl %eax, %r14d			# op
	R_MVEX FR3(%rsp), FR4(%rsp), FR5(%rsp), %r14d, FD(%rsp), $0, $RM_REG, %r15d, FR2(%rsp), $0, FR0(%rsp)
	R_COMMIT FD(%rsp), FD(%rsp), FR1(%rsp)
	R_OK
.Lop2_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# ---- min and max, the fused add/subtract pairs ----

# xl_minmax: vminps/vminpd (XF_A 0), vmaxps/vmaxpd (1), XB_QWORD for
# pd: r = s2; r{s1 ordered-less s2} = s1 (max: s2 < s1), so the second
# source comes out when either is NaN, as AVX-512 defines. (rewrite.rs
# minmax.)
xl_minmax:
	R_ENTER
	movl XF_B(%r13), %eax
	andl $XB_QWORD, %eax
	movl %eax, FR1(%rsp)			# w
	R_SRC2 FR1(%rsp), $XB_FLOAT, .Lmm_notemp
	movl %eax, %r15d			# s2
	R_TEMP .Lmm_notemp
	movl %eax, %r14d			# r
	R_EM em_k
	movl %eax, FR0(%rsp)			# kc
	R_VMOV %r14d, $RM_REG, %r15d, $0, FR1(%rsp)
	cmpl $0, XF_A(%r13)
	je .Lmm_min
	R_VCMP FR0(%rsp), %r15d, $RM_REG, FS1(%rsp), $1, $0, FR1(%rsp)	# s2 < s1: s1 is the max
	jmp .Lmm_merge
.Lmm_min:
	R_VCMP FR0(%rsp), FS1(%rsp), $RM_REG, %r15d, $1, $0, FR1(%rsp)	# s1 < s2: s1 is the min
.Lmm_merge:
	R_VMOV %r14d, $RM_REG, FS1(%rsp), FR0(%rsp), FR1(%rsp)
	R_COMMIT FD(%rsp), %r14d, FR1(%rsp)
	R_OK
.Lmm_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_fma_addsub: vfmaddsub132/213/231ps/pd and vfmsubadd: the card's
# fused multiply-add over one copy of the destination and its fused
# multiply-subtract over another (two opcodes up and four up from the
# addsub line), merged under the lane parity (addsub subtracts on the
# even lanes, subadd on the odd). (rewrite.rs fma_addsub.)
xl_fma_addsub:
	R_ENTER
	movl XF_B(%r13), %eax
	andl $XB_QWORD, %eax
	movl %eax, FR1(%rsp)			# w
	R_SRC2 FR1(%rsp), $XB_FLOAT, .Lfas_notemp
	movl %eax, %r15d			# s2
	R_TEMP .Lfas_notemp
	movl %eax, %r14d			# r
	R_TEMP .Lfas_notemp
	movl %eax, FR0(%rsp)			# t
	R_VMOV %r14d, $RM_REG, FD(%rsp), $0, FR1(%rsp)
	R_VMOV FR0(%rsp), $RM_REG, FD(%rsp), $0, FR1(%rsp)
	movzbl IN_OP(%r12), %eax
	andl $0xfe, %eax
	movl %eax, FR2(%rsp)			# the addsub line: 96, A6, B6
	addl $2, %eax
	movl %eax, FR3(%rsp)
	R_FMA FR3(%rsp), %r14d, FS1(%rsp), $RM_REG, %r15d, FR1(%rsp)	# the fused multiply-add
	movl FR2(%rsp), %eax
	addl $4, %eax
	movl %eax, FR3(%rsp)
	R_FMA FR3(%rsp), FR0(%rsp), FS1(%rsp), $RM_REG, %r15d, FR1(%rsp)	# the fused multiply-subtract
	movzbl IN_OP(%r12), %eax
	andl $1, %eax				# subadd
	movl $0x5555, %ecx
	testl %eax, %eax
	jz .Lfas_width
	movl $0xaaaa, %ecx
.Lfas_width:
	cmpl $0, FR1(%rsp)
	je .Lfas_mask
	movl $0x3333, %ecx
	testl %eax, %eax
	jz .Lfas_mask
	movl $0xcccc, %ecx
.Lfas_mask:
	R_MASK %ecx
	movl %eax, FR2(%rsp)
	R_VMOV %r14d, $RM_REG, FR0(%rsp), FR2(%rsp)
	R_COMMIT FD(%rsp), %r14d, FR1(%rsp)
	R_OK
.Lfas_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# ---- blocks, lanes, bytes ----

# xl_shuf_blocks: vshuff32x4, vshufi32x4, vshuff64x2, vshufi64x2: the
# destination's low two 128-bit blocks from the first source and its
# high two from the second, each chosen by two bits of the immediate:
# two vpermf32x4, the second under the high half's mask. The 256-bit
# form takes one block from each source, chosen by one bit each.
xl_shuf_blocks:
	R_ENTER
	R_SRC2 $0, $0, .Lsb_notemp
	movl %eax, %r15d			# s2
	R_TEMP .Lsb_notemp
	movl %eax, %r14d			# r
	movzbl IN_IMM(%r12), %eax
	movl %eax, FR0(%rsp)
	cmpl $2, FLL(%rsp)
	jne .Lsb_half
	andl $0x0f, %eax
	movl %eax, FR1(%rsp)
	R_VPERMF %r14d, $RM_REG, FS1(%rsp), FR1(%rsp)
	R_MASK $0xff00
	movl %eax, FR2(%rsp)
	movl FR0(%rsp), %eax
	andl $0xf0, %eax
	movl %eax, FR1(%rsp)
	R_VPERMF %r14d, $RM_REG, %r15d, FR1(%rsp), FR2(%rsp)
	jmp .Lsb_commit
.Lsb_half:
	cmpl $1, FLL(%rsp)
	jne .Lsb_shape
	andl $1, %eax
	movl %eax, FR1(%rsp)
	R_VPERMF %r14d, $RM_REG, FS1(%rsp), FR1(%rsp)
	R_MASK $0x00f0
	movl %eax, FR2(%rsp)
	movl FR0(%rsp), %eax
	shrl $1, %eax
	andl $1, %eax
	shll $2, %eax
	movl %eax, FR1(%rsp)
	R_VPERMF %r14d, $RM_REG, %r15d, FR1(%rsp), FR2(%rsp)
.Lsb_commit:
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Lsb_shape:
	leaq s_shape(%rip), %rax
	R_LEAVE
.Lsb_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_insertps: the first source with one dword replaced, at lane
# imm[5:4], by lane imm[7:6] of the second source (its dword broadcast
# within the block with vpshufd) or by the one dword of a memory operand
# (vbroadcastss under the lane's mask); the lanes imm[3:0] zeroed, and
# the lanes above the xmm. (rewrite.rs insertps.)
xl_insertps:
	R_ENTER
	movzbl IN_IMM(%r12), %eax
	movl %eax, FR0(%rsp)
	R_TEMP .Lips_notemp
	movl %eax, %r14d			# r
	R_VMOV %r14d, $RM_REG, FS1(%rsp)
	movl FR0(%rsp), %ecx
	shrl $4, %ecx
	andl $3, %ecx
	movl $1, %eax
	shll %cl, %eax
	R_MASK %eax
	movl %eax, FR1(%rsp)			# the lane's mask
	testb $H_MEM, IN_HAS(%r12)
	jz .Lips_reg
	R_BCASTM %r14d, FR1(%rsp), $0
	jmp .Lips_zero
.Lips_reg:
	R_TEMP .Lips_notemp
	movl %eax, %r15d
	movl FR0(%rsp), %eax
	shrl $6, %eax
	andl $3, %eax
	imull $0x55, %eax
	movl %eax, FR2(%rsp)
	R_VPSHUFD %r15d, $RM_REG, FRM(%rsp), FR2(%rsp)
	R_VMOV %r14d, $RM_REG, %r15d, FR1(%rsp)
.Lips_zero:
	movl FR0(%rsp), %eax
	andl $0xf, %eax
	orl $0xfff0, %eax
	R_ZERO_LANES %r14d, %eax
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Lips_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_abs_d: vpabsd: (s ^ (s >> 31)) - (s >> 31).
xl_abs_d:
	R_ENTER
	R_SRC2 $0, $0, .Labs_notemp
	movl %eax, %r15d			# s
	R_TEMP .Labs_notemp
	movl %eax, %r14d			# r
	R_TEMP .Labs_notemp
	movl %eax, FR0(%rsp)			# t
	R_SHIFT $4, FR0(%rsp), $RM_REG, %r15d, $31		# t = s >> 31 (arithmetic)
	R_I0F $0xef, %r14d, %r15d, $RM_REG, FR0(%rsp)	# r = s ^ t
	R_I0F $0xfa, %r14d, %r14d, $RM_REG, FR0(%rsp)	# r = r - t
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Labs_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_byte_shift: vpsrldq (XF_A 0), vpslldq (1), vpalignr (2) with a
# shift that is a whole number of dwords: per-block rotations (vpshufd)
# merged or zero-filled under a mask; another shift is refused.
# (rewrite.rs byte_shift.)
xl_byte_shift:
	R_ENTER
	movzbl IN_IMM(%r12), %eax
	testl $3, %eax
	jnz .Lbs_bytes
	shrl $2, %eax
	movl %eax, FR0(%rsp)			# n: the shift in dwords
	R_TEMP .Lbs_notemp
	movl %eax, %r14d			# r
	cmpl $2, XF_A(%r13)
	je .Lbs_alignr
	# vpsrldq and vpslldq: the destination in vvvv, the source in r/m or memory
	movl FRM(%rsp), %r15d
	testb $H_MEM, IN_HAS(%r12)
	jz .Lbs_src
	R_SRC2 $0, $0, .Lbs_notemp
	movl %eax, %r15d
.Lbs_src:
	cmpl $4, FR0(%rsp)
	jb .Lbs_within
	R_ZERO %r14d
	jmp .Lbs_commit1
.Lbs_within:
	movl FR0(%rsp), %ecx
	cmpl $1, XF_A(%r13)
	jne .Lbs_right
	movl $4, %eax				# left: lane i from lane i - n, the rotation by 4 - n
	subl %ecx, %eax
	movl %eax, %ecx
	leaq .Lrot(%rip), %rax
	movzbl (%rax,%rcx), %eax
	movl %eax, FR1(%rsp)
	R_VPSHUFD %r14d, $RM_REG, %r15d, FR1(%rsp)
	movl FR0(%rsp), %ecx
	movl $1, %eax
	shll %cl, %eax
	decl %eax				# the vacated low lanes of every block
	imull $0x1111, %eax
	R_ZERO_LANES %r14d, %eax
	jmp .Lbs_commit1
.Lbs_right:
	leaq .Lrot(%rip), %rax
	movzbl (%rax,%rcx), %eax
	movl %eax, FR1(%rsp)
	R_VPSHUFD %r14d, $RM_REG, %r15d, FR1(%rsp)
	movl $4, %ecx
	subl FR0(%rsp), %ecx
	movl $0xf, %eax
	shll %cl, %eax
	andl $0xf, %eax				# the vacated high lanes
	imull $0x1111, %eax
	R_ZERO_LANES %r14d, %eax
.Lbs_commit1:
	R_COMMIT FS1(%rsp), %r14d, $0
	R_OK
.Lbs_alignr:
	# vpalignr d, a (vvvv), b (r/m), n: per block, the concatenation of a and b shifted right by n dwords
	R_SRC2 $0, $0, .Lbs_notemp
	movl %eax, %r15d			# b
	cmpl $8, FR0(%rsp)
	jb .Lbs_a8
	R_ZERO %r14d
	jmp .Lbs_commit2
.Lbs_a8:
	cmpl $4, FR0(%rsp)
	jb .Lbs_a4
	movl FR0(%rsp), %ecx
	subl $4, %ecx
	leaq .Lrot(%rip), %rax
	movzbl (%rax,%rcx), %eax
	movl %eax, FR1(%rsp)
	R_VPSHUFD %r14d, $RM_REG, FS1(%rsp), FR1(%rsp)
	movl $8, %ecx
	subl FR0(%rsp), %ecx
	movl $0xf, %eax
	shll %cl, %eax
	andl $0xf, %eax
	imull $0x1111, %eax
	R_ZERO_LANES %r14d, %eax
	jmp .Lbs_commit2
.Lbs_a4:
	R_TEMP .Lbs_notemp
	movl %eax, FR2(%rsp)			# t
	movl FR0(%rsp), %ecx
	leaq .Lrot(%rip), %rax
	movzbl (%rax,%rcx), %eax
	movl %eax, FR1(%rsp)
	R_VPSHUFD %r14d, $RM_REG, %r15d, FR1(%rsp)
	R_VPSHUFD FR2(%rsp), $RM_REG, FS1(%rsp), FR1(%rsp)
	movl $4, %ecx
	subl FR0(%rsp), %ecx
	movl $0xf, %eax
	shll %cl, %eax
	andl $0xf, %eax
	imull $0x1111, %eax			# the lanes that come from a
	R_MASK %eax
	movl %eax, FR1(%rsp)
	R_VMOV %r14d, $RM_REG, FR2(%rsp), FR1(%rsp)
.Lbs_commit2:
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Lbs_bytes:
	leaq s2_byteshift(%rip), %rax
	R_LEAVE
.Lbs_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_mov_u8: vmovdqu8 and vmovdqu16: the unaligned move when unmasked
# (the same bytes as vmovdqu32); a byte or word mask is refused.
xl_mov_u8:
	movq EM_IN(%rdi), %rax
	cmpb $0, IN_AAA(%rax)
	jne .Lmu8_mask
	jmp xl_mov_unaligned
.Lmu8_mask:
	leaq s_qmask(%rip), %rax
	ret

# ---- mask registers ----

# xl_kmovb: kmovb between mask registers, from and to a general
# register: the 16-bit move with the low byte kept, through eax (the
# flags saved; eax or ecx as the destination through the scratch slot
# and em_gpr_result). The memory forms are not taken.
xl_kmovb:
	R_ENTER
	testb $H_MEM, IN_HAS(%r12)
	jnz .Lkb_shape
	R_EM em_flags
	movzbl IN_OP(%r12), %eax
	cmpl $0x90, %eax
	je .Lkb_kk
	cmpl $0x92, %eax
	je .Lkb_kr
	cmpl $0x93, %eax
	jne .Lkb_shape
	# r32 = k
	R_K2 em_kmov_r_k, $0, FRM(%rsp)
	R_BYTES .Lb_and_eax_ff, $5
	cmpl $2, FD(%rsp)
	jb .Lkb_rk_low
	cmpl $8, FD(%rsp)
	jb .Lkb_rk_mov
	R_BYTE $0x41
.Lkb_rk_mov:
	R_BYTE $0x89				# mov r32, eax
	movl FD(%rsp), %eax
	andl $7, %eax
	orl $0xc0, %eax
	R_BYTE %eax
	R_OK
.Lkb_rk_low:
	R_GPRS $0, $0, $S_XFER, $1
	R_GPRR FD(%rsp), $0, $S_XFER
	R_OK
.Lkb_kk:
	R_K2 em_kmov_r_k, $0, FRM(%rsp)
	R_BYTES .Lb_and_eax_ff, $5
	R_K2 em_kmov_k_r, FD(%rsp), $0
	R_OK
.Lkb_kr:
	# k = the low byte of r32: eax = r32 (the program's rax from its slot)
	cmpl $0, FRM(%rsp)
	jne .Lkb_kr_reg
	R_GPRS $0, $0, $S_RAX, $0
	jmp .Lkb_kr_and
.Lkb_kr_reg:
	cmpl $8, FRM(%rsp)
	jb .Lkb_kr_mov
	R_BYTE $0x44
.Lkb_kr_mov:
	R_BYTE $0x89				# mov eax, r32
	movl FRM(%rsp), %eax
	andl $7, %eax
	shll $3, %eax
	orl $0xc0, %eax
	R_BYTE %eax
.Lkb_kr_and:
	R_BYTES .Lb_and_eax_ff, $5
	R_K2 em_kmov_k_r, FD(%rsp), $0
	R_OK
.Lkb_shape:
	leaq s_shape(%rip), %rax
	R_LEAVE

# xl_kshift: kshiftlw/lb/ld/lq (XF_A 1) and kshiftrw/rb/rd/rq (0) by
# immediate, XF_B the mask's width (8 or 16; the card's masks are 16
# bits, so the d and q forms are the w form): through eax with the
# flags saved; a count at or past the width gives zero, a byte form
# keeps its low 8 bits.
xl_kshift:
	R_ENTER
	R_EM em_flags
	R_K2 em_kmov_r_k, $0, FRM(%rsp)
	movzbl IN_IMM(%r12), %ecx
	cmpl XF_B(%r13), %ecx
	jb .Lks_shift
	R_BYTES .Lb_xor_eax, $2
	jmp .Lks_write
.Lks_shift:
	cmpl $8, XF_B(%r13)
	jne .Lks_op
	R_BYTES .Lb_and_eax_ff, $5		# a byte mask: its low 8 bits
.Lks_op:
	R_BYTE $0xc1
	movl $0xe8, %eax			# shr eax, n
	cmpl $0, XF_A(%r13)
	je .Lks_dir
	movl $0xe0, %eax			# shl eax, n
.Lks_dir:
	R_BYTE %eax
	movzbl IN_IMM(%r12), %eax
	R_BYTE %eax
	cmpl $0, XF_A(%r13)
	je .Lks_write
	cmpl $8, XF_B(%r13)
	jne .Lks_word
	R_BYTES .Lb_and_eax_ff, $5
	jmp .Lks_write
.Lks_word:
	R_BYTES .Lb_movzx_eax_ax, $3
.Lks_write:
	R_K2 em_kmov_k_r, FD(%rsp), $0
	R_OK

	.section .rodata
s2_byteshift:	.asciz "a byte shift within 128-bit blocks that is not a whole number of dwords: not expressed yet"
.Lb_and5555_shl1: .byte 0x25, 0x55, 0x55, 0x00, 0x00, 0xd1, 0xe0	# and eax, 0x5555; shl eax, 1
.Lb_orhalf:	.byte 0x89, 0xc1, 0xd1, 0xe9, 0x09, 0xc8	# mov ecx, eax; shr ecx, 1; or eax, ecx
.Lb_andhalf:	.byte 0x89, 0xc1, 0xd1, 0xe9, 0x21, 0xc1	# mov ecx, eax; shr ecx, 1; and ecx, eax
.Lb_not_eax:	.byte 0xf7, 0xd0
.Lb_shr_eax1:	.byte 0xd1, 0xe8
.Lb_mov_eax_ecx: .byte 0x89, 0xc8
.Lb_xor_eax:	.byte 0x31, 0xc0
.Lb_and_eax_ff:	.byte 0x25, 0xff, 0x00, 0x00, 0x00
.Lb_movzx_eax_ax: .byte 0x0f, 0xb7, 0xc0
.Lb_or_r:	.byte 0x0b				# or r32, r/m32
	# eax: the even bits packed down (bit 2j to bit j), the rest zero; ecx used
.Lb_pack_even:	.byte 0x25, 0x55, 0x55, 0x00, 0x00
	.byte 0x89, 0xc1, 0xd1, 0xe9, 0x09, 0xc8, 0x25, 0x33, 0x33, 0x00, 0x00
	.byte 0x89, 0xc1, 0xc1, 0xe9, 0x02, 0x09, 0xc8, 0x25, 0x0f, 0x0f, 0x00, 0x00
	.byte 0x89, 0xc1, 0xc1, 0xe9, 0x04, 0x09, 0xc8, 0x25, 0xff, 0x00, 0x00, 0x00
	# eax: each even bit copied to the odd bit above it, the rest zero; ecx used
.Lb_spread_even: .byte 0x25, 0x55, 0x55, 0x00, 0x00, 0x89, 0xc1, 0xd1, 0xe1, 0x09, 0xc8
.Lrot:		.byte 0xe4, 0x39, 0x4e, 0x93		# vpshufd: lane i from lane (i + by) mod 4, by 0 to 3
	.balign 64
.Lc_idx_dq:	.long 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7
	.text
