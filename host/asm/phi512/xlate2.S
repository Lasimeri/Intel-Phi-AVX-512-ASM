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
	.set R_FRAME, 176
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
	.set FBUF, MV_BYTES + 72		# 64 bytes: a constant built here, then em_const

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
	movl XF_B(%r13), %eax
	andl $XB_QWORD, %eax
	movl %eax, FR3(%rsp)
	R_COMMIT FD(%rsp), %r14d, FR3(%rsp)
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

# ---- batch 2b: blends, the word forms, the byte-to-word widening, the saturating packs ----

	.macro R_CONST_BUF fail
	movq %rbx, %rdi
	leaq FBUF(%rsp), %rsi
	call em_const
	cmpl $-1, %eax
	je \fail
	.endm

# xl_blendd: vpblendd (VEX, by immediate): r = s1; r{the immediate's
# lanes, cut to the length} = s2.
xl_blendd:
	R_ENTER
	R_SRC2 $0, $0, .Lbd_notemp
	movl %eax, %r15d			# s2
	R_TEMP .Lbd_notemp
	movl %eax, %r14d			# r
	R_VMOV %r14d, $RM_REG, FS1(%rsp)
	R_LANES $0
	movl %eax, FR1(%rsp)
	movzbl IN_IMM(%r12), %eax
	andl FR1(%rsp), %eax
	R_MASK %eax
	movl %eax, FR0(%rsp)
	R_VMOV %r14d, $RM_REG, %r15d, FR0(%rsp)
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Lbd_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_blendw: vpblendw (by immediate): bit i of the immediate takes word
# i of every 128-bit block from the second source: a constant M of word
# masks (dword j of a block: 0xffff for bit 2j, 0xffff0000 for bit
# 2j + 1), then r = (s1 and not M) or (s2 and M).
xl_blendw:
	R_ENTER
	R_SRC2 $0, $0, .Lbw_notemp
	movl %eax, %r15d			# s2
	R_TEMP .Lbw_notemp
	movl %eax, %r14d			# r
	R_TEMP .Lbw_notemp
	movl %eax, FR0(%rsp)			# u: the mask vector
	movzbl IN_IMM(%r12), %edx
	xorl %ecx, %ecx				# j
.Lbw_const:
	movl %edx, %eax
	andl $3, %eax				# the two bits of word pair j
	shrl $2, %edx
	leaq .Lbw_tab(%rip), %rsi
	movl (%rsi,%rax,4), %eax
	movl %eax, FBUF(%rsp,%rcx,4)
	movl %eax, FBUF + 16(%rsp,%rcx,4)
	movl %eax, FBUF + 32(%rsp,%rcx,4)
	movl %eax, FBUF + 48(%rsp,%rcx,4)
	incl %ecx
	cmpl $4, %ecx
	jb .Lbw_const
	R_CONST_BUF .Lbw_notemp
	movl %eax, FR1(%rsp)
	R_VMOV FR0(%rsp), $RM_CONST, FR1(%rsp)			# u = M
	R_I0F $0xdf, %r14d, FR0(%rsp), $RM_REG, FS1(%rsp)	# r = not u and s1
	R_I0F $0xdb, FR0(%rsp), FR0(%rsp), $RM_REG, %r15d	# u = u and s2
	R_I0F $0xeb, %r14d, %r14d, $RM_REG, FR0(%rsp)		# r = r or u
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Lbw_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_blendv: vblendvps (XF_A 0), vblendvpd (1), vpblendvb (2): the
# blend by the sign bits of a fourth register (imm[7:4]): the mask
# vector u is every element's sign spread over it (a dword's by an
# arithmetic shift, a qword's from its high dword, a byte's by the
# sign bits masked to one per byte and multiplied by 255), then
# r = (s1 and not u) or (s2 and u).
xl_blendv:
	R_ENTER
	R_SRC2 $0, $0, .Lbv_notemp
	movl %eax, %r15d			# s2
	R_TEMP .Lbv_notemp
	movl %eax, %r14d			# r
	R_TEMP .Lbv_notemp
	movl %eax, FR0(%rsp)			# u
	movzbl IN_IMM(%r12), %eax
	shrl $4, %eax
	movl %eax, FR1(%rsp)			# the mask register
	cmpl $2, XF_A(%r13)
	je .Lbv_bytes
	cmpl $1, XF_A(%r13)
	jne .Lbv_dwords
	R_VPSHUFD FR0(%rsp), $RM_REG, FR1(%rsp), $0xf5		# each qword's high dword in both lanes
	R_SHIFT $4, FR0(%rsp), $RM_REG, FR0(%rsp), $31
	jmp .Lbv_blend
.Lbv_dwords:
	R_SHIFT $4, FR0(%rsp), $RM_REG, FR1(%rsp), $31
	jmp .Lbv_blend
.Lbv_bytes:
	R_SHIFT $2, FR0(%rsp), $RM_REG, FR1(%rsp), $7		# the sign bits to bit 0 of every byte
	R_CONST_DW $0x01010101, .Lbv_notemp
	movl %eax, FR2(%rsp)
	R_I0F $0xdb, FR0(%rsp), FR0(%rsp), $RM_CONST, FR2(%rsp)
	R_CONST_DW $0xff, .Lbv_notemp
	movl %eax, FR2(%rsp)
	R_I38 $0x40, FR0(%rsp), FR0(%rsp), $RM_CONST, FR2(%rsp)	# times 255: a byte's mask
.Lbv_blend:
	R_I0F $0xdf, %r14d, FR0(%rsp), $RM_REG, FS1(%rsp)	# r = not u and s1
	R_I0F $0xdb, FR0(%rsp), FR0(%rsp), $RM_REG, %r15d	# u = u and s2
	R_I0F $0xeb, %r14d, %r14d, $RM_REG, FR0(%rsp)
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Lbv_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_shiftw: vpsrlw (XF_A 0), vpsllw (1), vpsraw (2) by immediate, the
# destination in vvvv: the dword shift with the bits that crossed a
# word masked off (a constant of the surviving bits per word); the
# arithmetic form shifts each word's sign-extension separately (the
# low word through the top of its dword). A count at or past 16 gives
# zero, or every word its sign.
xl_shiftw:
	R_ENTER
	testb $H_IMM, IN_HAS(%r12)
	jz .Lsw_shape
	movl FRM(%rsp), %r15d
	testb $H_MEM, IN_HAS(%r12)
	jz .Lsw_src
	R_SRC2 $0, $0, .Lsw_notemp
	movl %eax, %r15d
.Lsw_src:
	R_TEMP .Lsw_notemp
	movl %eax, %r14d			# r
	movzbl IN_IMM(%r12), %eax
	movl %eax, FR0(%rsp)			# n
	cmpl $16, %eax
	jb .Lsw_n
	cmpl $2, XF_A(%r13)
	jne .Lsw_zero
	movl $15, FR0(%rsp)
	jmp .Lsw_n
.Lsw_zero:
	R_ZERO %r14d
	jmp .Lsw_commit
.Lsw_n:
	cmpl $0, XF_A(%r13)
	jne .Lsw_left
	R_SHIFT $2, %r14d, $RM_REG, %r15d, FR0(%rsp)
	movl FR0(%rsp), %ecx
	movl $0xffff, %eax
	shrl %cl, %eax
	imull $0x10001, %eax
	R_CONST_DW %eax, .Lsw_notemp
	movl %eax, FR1(%rsp)
	R_I0F $0xdb, %r14d, %r14d, $RM_CONST, FR1(%rsp)
	jmp .Lsw_commit
.Lsw_left:
	cmpl $1, XF_A(%r13)
	jne .Lsw_arith
	R_SHIFT $6, %r14d, $RM_REG, %r15d, FR0(%rsp)
	movl FR0(%rsp), %ecx
	movl $0xffff, %eax
	shll %cl, %eax
	andl $0xffff, %eax
	imull $0x10001, %eax
	R_CONST_DW %eax, .Lsw_notemp
	movl %eax, FR1(%rsp)
	R_I0F $0xdb, %r14d, %r14d, $RM_CONST, FR1(%rsp)
	jmp .Lsw_commit
.Lsw_arith:
	R_TEMP .Lsw_notemp
	movl %eax, FR2(%rsp)			# t: the low words
	R_SHIFT $6, FR2(%rsp), $RM_REG, %r15d, $16
	movl FR0(%rsp), %eax
	addl $16, %eax
	movl %eax, FR3(%rsp)
	R_SHIFT $4, FR2(%rsp), $RM_REG, FR2(%rsp), FR3(%rsp)
	R_CONST_DW $0xffff, .Lsw_notemp
	movl %eax, FR1(%rsp)
	R_I0F $0xdb, FR2(%rsp), FR2(%rsp), $RM_CONST, FR1(%rsp)
	R_SHIFT $4, %r14d, $RM_REG, %r15d, FR0(%rsp)		# the high words
	R_CONST_DW $0xffff0000, .Lsw_notemp
	movl %eax, FR1(%rsp)
	R_I0F $0xdb, %r14d, %r14d, $RM_CONST, FR1(%rsp)
	R_I0F $0xeb, %r14d, %r14d, $RM_REG, FR2(%rsp)
.Lsw_commit:
	R_COMMIT FS1(%rsp), %r14d, $0
	R_OK
.Lsw_shape:
	leaq s_shape(%rip), %rax
	R_LEAVE
.Lsw_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_addw: vpaddw (XF_A 0) and vpsubw (1): the dword sum (difference)
# with the low word's carry (borrow) into the high word taken back:
# t = (a and 0xffff) op (b and 0xffff), its bit 16 the carry (the
# borrow); r = (a op b) minus (plus) that bit.
xl_addw:
	R_ENTER
	R_SRC2 $0, $0, .Law_notemp
	movl %eax, %r15d			# b
	R_TEMP .Law_notemp
	movl %eax, %r14d			# r
	R_TEMP .Law_notemp
	movl %eax, FR0(%rsp)			# t
	R_TEMP .Law_notemp
	movl %eax, FR1(%rsp)			# u
	R_CONST_DW $0xffff, .Law_notemp
	movl %eax, FR2(%rsp)
	R_I0F $0xdb, FR0(%rsp), FS1(%rsp), $RM_CONST, FR2(%rsp)
	R_I0F $0xdb, FR1(%rsp), %r15d, $RM_CONST, FR2(%rsp)
	movl $0xfe, %eax
	cmpl $0, XF_A(%r13)
	je .Law_op
	movl $0xfa, %eax
.Law_op:
	movl %eax, FR3(%rsp)			# the dword operation
	R_I0F FR3(%rsp), FR0(%rsp), FR0(%rsp), $RM_REG, FR1(%rsp)
	R_CONST_DW $0x10000, .Law_notemp
	movl %eax, FR2(%rsp)
	R_I0F $0xdb, FR0(%rsp), FR0(%rsp), $RM_CONST, FR2(%rsp)	# the carry (borrow) bit
	R_I0F FR3(%rsp), %r14d, FS1(%rsp), $RM_REG, %r15d
	movl $0xfa, %eax			# add: minus the carry; sub: plus the borrow
	cmpl $0, XF_A(%r13)
	je .Law_fix
	movl $0xfe, %eax
.Law_fix:
	movl %eax, FR3(%rsp)
	R_I0F FR3(%rsp), %r14d, %r14d, $RM_REG, FR0(%rsp)
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Law_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_mullw: vpmullw: the low 16 bits of each word product: the low
# words' product masked, the high words' product shifted up.
xl_mullw:
	R_ENTER
	R_SRC2 $0, $0, .Lmw_notemp
	movl %eax, %r15d			# b
	R_TEMP .Lmw_notemp
	movl %eax, %r14d			# r
	R_TEMP .Lmw_notemp
	movl %eax, FR0(%rsp)			# t
	R_TEMP .Lmw_notemp
	movl %eax, FR1(%rsp)			# u
	R_CONST_DW $0xffff, .Lmw_notemp
	movl %eax, FR2(%rsp)
	R_I0F $0xdb, %r14d, FS1(%rsp), $RM_CONST, FR2(%rsp)
	R_I0F $0xdb, FR0(%rsp), %r15d, $RM_CONST, FR2(%rsp)
	R_I38 $0x40, %r14d, %r14d, $RM_REG, FR0(%rsp)		# the low products
	R_I0F $0xdb, %r14d, %r14d, $RM_CONST, FR2(%rsp)
	R_SHIFT $2, FR0(%rsp), $RM_REG, FS1(%rsp), $16
	R_SHIFT $2, FR1(%rsp), $RM_REG, %r15d, $16
	R_I38 $0x40, FR0(%rsp), FR0(%rsp), $RM_REG, FR1(%rsp)	# the high products
	R_SHIFT $6, FR0(%rsp), $RM_REG, FR0(%rsp), $16
	R_I0F $0xeb, %r14d, %r14d, $RM_REG, FR0(%rsp)
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Lmw_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_movlh: vmovlps and vmovlpd (XF_A 0: the low qword), vmovhps and
# vmovhpd (1: the high qword) with a memory operand: a load takes the
# rest of the xmm from the first source and the two dwords from memory
# through the unpack pair under the qword's lanes (a 4-byte alignment);
# a store (the odd opcode) is the pack pair under them.
xl_movlh:
	R_ENTER
	movl $0x3, %eax
	cmpl $0, XF_A(%r13)
	je .Lml_lanes
	movl $0xc, %eax
.Lml_lanes:
	R_MASK %eax
	movl %eax, FR0(%rsp)
	movzbl IN_OP(%r12), %eax
	testl $1, %eax
	jnz .Lml_store
	R_TEMP .Lml_notemp
	movl %eax, %r14d
	R_VMOV %r14d, $RM_REG, FS1(%rsp)
	R_UNAL %r14d, FR0(%rsp), $0, $0, $0, $0
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Lml_store:
	R_UNAL FD(%rsp), FR0(%rsp), $0, $1, $0, $0
	R_OK
.Lml_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_widen_bw: vpmovzxbw (XF_A 4: the card's uint8 up-conversion) and
# vpmovsxbw (5: sint8): the source's bytes (twice the destination's
# dword count) up-converted sixteen at a time into dword vectors (from
# memory through the unpack pair, from a register through the scratch
# slot), then each destination dword takes byte 2i in its low word
# (masked to 16 bits for the sign-extended form) and byte 2i + 1 in its
# high word, by vpermd over the even and the odd lanes.
xl_widen_bw:
	R_ENTER
	R_TEMP .Lwb_notemp
	movl %eax, %r14d			# r
	R_TEMP .Lwb_notemp
	movl %eax, %r15d			# t0: bytes 0 to 15
	R_TEMP .Lwb_notemp
	movl %eax, FR0(%rsp)			# o: the odd bytes
	R_TEMP .Lwb_notemp
	movl %eax, FR1(%rsp)			# ix
	movl $0, FR2(%rsp)			# t1: bytes 16 to 31 (the 512-bit form), 0 none
	cmpl $2, FLL(%rsp)
	jne .Lwb_src
	R_TEMP .Lwb_notemp
	movl %eax, FR2(%rsp)
.Lwb_src:
	R_LANES $0
	movl %eax, FR3(%rsp)			# the destination's lanes
	movl $0xffff, %eax			# the bytes to convert per load: 16, or 8 for an xmm result
	cmpl $0, FLL(%rsp)
	jne .Lwb_cnt
	movl $0xff, %eax
.Lwb_cnt:
	R_MASK %eax
	movl %eax, FR4(%rsp)
	testb $H_MEM, IN_HAS(%r12)
	jz .Lwb_reg
	movl XF_A(%r13), %eax
	R_UNAL %r15d, FR4(%rsp), $0, $0, $0, %rax
	cmpl $0, FR2(%rsp)
	je .Lwb_perm
	addq $16, IN_DISP(%r12)
	movl XF_A(%r13), %eax
	R_UNAL FR2(%rsp), FR4(%rsp), $0, $0, $0, %rax
	subq $16, IN_DISP(%r12)
	jmp .Lwb_perm
.Lwb_reg:
	# the source's bytes to the scratch slot (2, 4 or 8 dwords), then up-converted from it
	popcntl FR3(%rsp), %eax
	shrl $1, %eax
	movl %eax, %ecx
	movl $1, %eax
	shll %cl, %eax
	decl %eax
	R_MASK %eax
	movl %eax, FR5(%rsp)
	R_MVEX $2, $1, $0, $0xd0, FRM(%rsp), $0, $RM_FS, $S_XFER, FR5(%rsp)
	R_MASK FR4(%rsp)
	movl %eax, FR4(%rsp)
	movl XF_A(%r13), %eax
	movl %eax, FR5(%rsp)
	R_MVEX $1, $1, $0, $0x6f, %r15d, $0, $RM_FS, $S_XFER, FR4(%rsp), FR5(%rsp)
	cmpl $0, FR2(%rsp)
	je .Lwb_perm
	R_MVEX $1, $1, $0, $0x6f, FR2(%rsp), $0, $RM_FS, $S_XFER+16, FR4(%rsp), FR5(%rsp)
.Lwb_perm:
	R_CONST .Lc_idx_even, .Lwb_notemp
	movl %eax, FR5(%rsp)
	R_VMOV FR1(%rsp), $RM_CONST, FR5(%rsp)
	R_VPERMD %r14d, FR1(%rsp), $RM_REG, %r15d
	cmpl $0, FR2(%rsp)
	je .Lwb_odd
	R_MASK $0xff00
	movl %eax, FR5(%rsp)
	R_VPERMD %r14d, FR1(%rsp), $RM_REG, FR2(%rsp), FR5(%rsp)
.Lwb_odd:
	cmpl $4, XF_A(%r13)
	je .Lwb_odd2
	R_CONST_DW $0xffff, .Lwb_notemp				# the sign-extended low byte cut to its word
	movl %eax, FR5(%rsp)
	R_I0F $0xdb, %r14d, %r14d, $RM_CONST, FR5(%rsp)
.Lwb_odd2:
	R_CONST .Lc_idx_odd, .Lwb_notemp
	movl %eax, FR5(%rsp)
	R_VMOV FR1(%rsp), $RM_CONST, FR5(%rsp)
	R_VPERMD FR0(%rsp), FR1(%rsp), $RM_REG, %r15d
	cmpl $0, FR2(%rsp)
	je .Lwb_join
	R_MASK $0xff00
	movl %eax, FR5(%rsp)
	R_VPERMD FR0(%rsp), FR1(%rsp), $RM_REG, FR2(%rsp), FR5(%rsp)
.Lwb_join:
	R_SHIFT $6, FR0(%rsp), $RM_REG, FR0(%rsp), $16
	R_I0F $0xeb, %r14d, %r14d, $RM_REG, FR0(%rsp)
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Lwb_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_packusdw: vpackusdw: per 128-bit block the first source's four
# dwords then the second's as eight words, each saturated to 0..65535
# (vpmaxsd 0, vpminsd 65535), the pairs packed into the block's lanes
# 0 and 2 (the next lane shifted up and or'd), and the two sources'
# packed lanes gathered by one vpermd each, the second under the mask
# of the block's upper lanes.
xl_packusdw:
	R_ENTER
	R_SRC2 $0, $0, .Lpd_notemp
	movl %eax, %r15d			# b
	R_TEMP .Lpd_notemp
	movl %eax, %r14d			# ra
	R_TEMP .Lpd_notemp
	movl %eax, FR0(%rsp)			# rb
	R_TEMP .Lpd_notemp
	movl %eax, FR1(%rsp)			# t
	R_TEMP .Lpd_notemp
	movl %eax, FR2(%rsp)			# ix
	R_CONST_DW $0, .Lpd_notemp
	movl %eax, FR3(%rsp)
	R_CONST_DW $0xffff, .Lpd_notemp
	movl %eax, FR4(%rsp)
	R_I38 $0x3d, %r14d, FS1(%rsp), $RM_CONST, FR3(%rsp)
	R_I38 $0x39, %r14d, %r14d, $RM_CONST, FR4(%rsp)
	R_VPSHUFD FR1(%rsp), $RM_REG, %r14d, $0x39
	R_SHIFT $6, FR1(%rsp), $RM_REG, FR1(%rsp), $16
	R_I0F $0xeb, %r14d, %r14d, $RM_REG, FR1(%rsp)
	R_I38 $0x3d, FR0(%rsp), %r15d, $RM_CONST, FR3(%rsp)
	R_I38 $0x39, FR0(%rsp), FR0(%rsp), $RM_CONST, FR4(%rsp)
	R_VPSHUFD FR1(%rsp), $RM_REG, FR0(%rsp), $0x39
	R_SHIFT $6, FR1(%rsp), $RM_REG, FR1(%rsp), $16
	R_I0F $0xeb, FR0(%rsp), FR0(%rsp), $RM_REG, FR1(%rsp)
	R_CONST .Lc_idx_pack, .Lpd_notemp
	movl %eax, FR5(%rsp)
	R_VMOV FR2(%rsp), $RM_CONST, FR5(%rsp)
	R_VPERMD FR1(%rsp), FR2(%rsp), $RM_REG, %r14d
	R_MASK $0xcccc
	movl %eax, FR5(%rsp)
	R_VPERMD FR1(%rsp), FR2(%rsp), $RM_REG, FR0(%rsp), FR5(%rsp)
	R_COMMIT FD(%rsp), FR1(%rsp), $0
	R_OK
.Lpd_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_packuswb: vpackuswb: per block the first source's eight words then
# the second's as sixteen bytes, each saturated to 0..255: a source's
# low words (shifted up and back, arithmetically) and high words
# (shifted down) clamped (vpmaxsd 0, vpminsd 255), joined as two bytes
# a dword, the dword pairs packed into the block's lanes 0 and 2, and
# the sources gathered as in vpackusdw.
xl_packuswb:
	R_ENTER
	R_SRC2 $0, $0, .Lpb_notemp
	movl %eax, %r15d			# b
	R_TEMP .Lpb_notemp
	movl %eax, %r14d			# ra
	R_TEMP .Lpb_notemp
	movl %eax, FR0(%rsp)			# rb
	R_TEMP .Lpb_notemp
	movl %eax, FR1(%rsp)			# t
	R_TEMP .Lpb_notemp
	movl %eax, FR2(%rsp)			# ix (later), u first
	R_CONST_DW $0, .Lpb_notemp
	movl %eax, FR3(%rsp)
	R_CONST_DW $0xff, .Lpb_notemp
	movl %eax, FR4(%rsp)
	# a: low words in t, high words in ra
	R_SHIFT $6, FR1(%rsp), $RM_REG, FS1(%rsp), $16
	R_SHIFT $4, FR1(%rsp), $RM_REG, FR1(%rsp), $16
	R_SHIFT $4, %r14d, $RM_REG, FS1(%rsp), $16
	R_I38 $0x3d, FR1(%rsp), FR1(%rsp), $RM_CONST, FR3(%rsp)
	R_I38 $0x39, FR1(%rsp), FR1(%rsp), $RM_CONST, FR4(%rsp)
	R_I38 $0x3d, %r14d, %r14d, $RM_CONST, FR3(%rsp)
	R_I38 $0x39, %r14d, %r14d, $RM_CONST, FR4(%rsp)
	R_SHIFT $6, %r14d, $RM_REG, %r14d, $8
	R_I0F $0xeb, %r14d, %r14d, $RM_REG, FR1(%rsp)
	R_VPSHUFD FR1(%rsp), $RM_REG, %r14d, $0x39
	R_SHIFT $6, FR1(%rsp), $RM_REG, FR1(%rsp), $16
	R_I0F $0xeb, %r14d, %r14d, $RM_REG, FR1(%rsp)
	# b the same into rb
	R_SHIFT $6, FR1(%rsp), $RM_REG, %r15d, $16
	R_SHIFT $4, FR1(%rsp), $RM_REG, FR1(%rsp), $16
	R_SHIFT $4, FR0(%rsp), $RM_REG, %r15d, $16
	R_I38 $0x3d, FR1(%rsp), FR1(%rsp), $RM_CONST, FR3(%rsp)
	R_I38 $0x39, FR1(%rsp), FR1(%rsp), $RM_CONST, FR4(%rsp)
	R_I38 $0x3d, FR0(%rsp), FR0(%rsp), $RM_CONST, FR3(%rsp)
	R_I38 $0x39, FR0(%rsp), FR0(%rsp), $RM_CONST, FR4(%rsp)
	R_SHIFT $6, FR0(%rsp), $RM_REG, FR0(%rsp), $8
	R_I0F $0xeb, FR0(%rsp), FR0(%rsp), $RM_REG, FR1(%rsp)
	R_VPSHUFD FR1(%rsp), $RM_REG, FR0(%rsp), $0x39
	R_SHIFT $6, FR1(%rsp), $RM_REG, FR1(%rsp), $16
	R_I0F $0xeb, FR0(%rsp), FR0(%rsp), $RM_REG, FR1(%rsp)
	R_CONST .Lc_idx_pack, .Lpb_notemp
	movl %eax, FR5(%rsp)
	R_VMOV FR2(%rsp), $RM_CONST, FR5(%rsp)
	R_VPERMD FR1(%rsp), FR2(%rsp), $RM_REG, %r14d
	R_MASK $0xcccc
	movl %eax, FR5(%rsp)
	R_VPERMD FR1(%rsp), FR2(%rsp), $RM_REG, FR0(%rsp), FR5(%rsp)
	R_COMMIT FD(%rsp), FR1(%rsp), $0
	R_OK
.Lpb_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_cvtps2pd: vcvtps2pd zmm{k}, ymm/m256 (and the ymm, xmm/m128 and
# xmm, xmm/m64 forms): the card's vcvtps2pd converts the low half of
# the lanes; a memory source is loaded under those lanes.
xl_cvtps2pd:
	R_ENTER
	movl FRM(%rsp), %r15d
	testb $H_MEM, IN_HAS(%r12)
	jz .Lp2d_src
	R_TEMP .Lp2d_notemp
	movl %eax, %r15d
	R_LANES $1
	R_MASK %eax
	movl %eax, FR0(%rsp)
	R_UNAL %r15d, FR0(%rsp), $0, $0, $0, $0
.Lp2d_src:
	movl FD(%rsp), %r14d
	cmpl $0, FAAA(%rsp)
	jne .Lp2d_temp
	cmpl $2, FLL(%rsp)
	je .Lp2d_cvt
.Lp2d_temp:
	R_TEMP .Lp2d_notemp
	movl %eax, %r14d
.Lp2d_cvt:
	R_MVEX $1, $0, $0, $0x5a, %r14d, $0, $RM_REG, %r15d
	R_COMMIT FD(%rsp), %r14d, $1
	R_OK
.Lp2d_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_sminmax: vminss (XF_A 0), vmaxss (1), the sd forms by XB_QWORD:
# the second source (broadcast from memory), then the first where it
# wins an ordered compare, into lane 0; lanes 1 to 3 from the first
# source; the lanes above zero. A write mask is not taken.
xl_sminmax:
	R_ENTER
	cmpl $0, FAAA(%rsp)
	jne .Lsmm_shape
	movl XF_B(%r13), %eax
	andl $XB_QWORD, %eax
	movl %eax, FR1(%rsp)			# w
	movl FRM(%rsp), %r15d
	testb $H_MEM, IN_HAS(%r12)
	jz .Lsmm_src
	R_TEMP .Lsmm_notemp
	movl %eax, %r15d
	R_BCASTM %r15d, $0, FR1(%rsp)
.Lsmm_src:
	R_TEMP .Lsmm_notemp
	movl %eax, %r14d			# r
	R_EM em_k
	movl %eax, FR0(%rsp)
	R_VMOV %r14d, $RM_REG, %r15d, $0, FR1(%rsp)
	cmpl $0, XF_A(%r13)
	je .Lsmm_min
	R_VCMP FR0(%rsp), %r15d, $RM_REG, FS1(%rsp), $1, $0, FR1(%rsp)
	jmp .Lsmm_merge
.Lsmm_min:
	R_VCMP FR0(%rsp), FS1(%rsp), $RM_REG, %r15d, $1, $0, FR1(%rsp)
.Lsmm_merge:
	R_VMOV %r14d, $RM_REG, FS1(%rsp), FR0(%rsp), FR1(%rsp)
	R_MASK $1
	movl %eax, FR2(%rsp)
	R_VMOV FD(%rsp), $RM_REG, %r14d, FR2(%rsp), FR1(%rsp)
	movl FD(%rsp), %eax
	cmpl FS1(%rsp), %eax
	je .Lsmm_upper
	movl $0xe, %eax
	cmpl $0, FR1(%rsp)
	je .Lsmm_rest
	movl $2, %eax
.Lsmm_rest:
	R_MASK %eax
	movl %eax, FR2(%rsp)
	R_VMOV FD(%rsp), $RM_REG, FS1(%rsp), FR2(%rsp), FR1(%rsp)
.Lsmm_upper:
	R_ZERO_LANES FD(%rsp), $0xfff0
	R_OK
.Lsmm_shape:
	leaq s_shape(%rip), %rax
	R_LEAVE
.Lsmm_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

	.section .rodata
.Lbw_tab:	.long 0, 0xffff, 0xffff0000, 0xffffffff
	.balign 64
.Lc_idx_even:	.long 0, 2, 4, 6, 8, 10, 12, 14, 0, 2, 4, 6, 8, 10, 12, 14
.Lc_idx_odd:	.long 1, 3, 5, 7, 9, 11, 13, 15, 1, 3, 5, 7, 9, 11, 13, 15
.Lc_idx_pack:	.long 0, 2, 0, 2, 4, 6, 4, 6, 8, 10, 8, 10, 12, 14, 12, 14
	.text

# ---- batch 2c: the byte narrowing, gathers and scatters, the half-float conversions, scalef, valignq, rounding ----

# xl_narrow_db: vpmovdb: every dword's low byte, packed in lane order:
# the dwords masked to a byte, each block's four packed into its first
# dword (the block rotated by one lane and shifted by 8, or'd; by two
# lanes and 16, or'd), the four first dwords gathered by vpermd into
# lanes 0 to 3: to an xmm with the lanes above zeroed, or to memory
# through the scratch slot and scalar stores (any alignment). A write
# mask would be a byte mask: refused. (rewrite.rs narrow_db.)
xl_narrow_db:
	R_ENTER
	cmpl $0, FAAA(%rsp)
	jne .Lnb_qmask
	R_TEMP .Lnb_notemp
	movl %eax, %r14d			# r
	R_TEMP .Lnb_notemp
	movl %eax, %r15d			# t
	R_CONST_DW $0xff, .Lnb_notemp
	movl %eax, FR0(%rsp)
	R_I0F $0xdb, %r14d, FD(%rsp), $RM_CONST, FR0(%rsp)
	R_VPSHUFD %r15d, $RM_REG, %r14d, $0x39		# lane i from lane i + 1
	R_SHIFT $6, %r15d, $RM_REG, %r15d, $8
	R_I0F $0xeb, %r14d, %r14d, $RM_REG, %r15d
	R_VPSHUFD %r15d, $RM_REG, %r14d, $0x4e		# lane i from lane i + 2
	R_SHIFT $6, %r15d, $RM_REG, %r15d, $16
	R_I0F $0xeb, %r14d, %r14d, $RM_REG, %r15d
	R_CONST .Lc_idx_db, .Lnb_notemp
	movl %eax, FR0(%rsp)
	R_VMOV %r15d, $RM_CONST, FR0(%rsp)
	R_VPERMD %r14d, %r15d, $RM_REG, %r14d
	R_LANES $0
	popcntl %eax, %eax
	shrl $2, %eax
	movl %eax, FR1(%rsp)			# the dwords of bytes: 4, 2 or 1
	movl %eax, %ecx
	movl $1, %eax
	shll %cl, %eax
	decl %eax
	movl %eax, FR2(%rsp)			# their span
	R_MASK FR2(%rsp)
	movl %eax, FR3(%rsp)
	testb $H_MEM, IN_HAS(%r12)
	jz .Lnb_reg
	R_MVEX $2, $1, $0, $0xd0, %r14d, $0, $RM_FS, $S_XFER, FR3(%rsp)
	R_EM em_rax
	R_EM em_rcx
	movq %rbx, %rdi
	movq %r12, %rsi
	call em_addr_regs
	movq %rbx, %rdi
	movl $1, %esi
	movq %r12, %rdx
	call em_lea				# lea rcx, [m]
	movl $0, FR4(%rsp)			# done
	movl FR1(%rsp), %eax
	shll $2, %eax
	movl %eax, FR5(%rsp)			# the bytes
.Lnb_store:
	movl FR5(%rsp), %eax
	subl FR4(%rsp), %eax
	cmpl $8, %eax
	setae %cl
	movzbl %cl, %ecx
	movl %ecx, FR2(%rsp)			# wide: 8 bytes
	movl $S_XFER, %eax
	addl FR4(%rsp), %eax
	movl %eax, FR0(%rsp)
	R_GPRS $0, FR2(%rsp), FR0(%rsp), $0	# rax or eax from the slot
	cmpl $0, FR2(%rsp)
	je .Lnb_mov
	R_BYTE $0x48
.Lnb_mov:
	R_BYTE $0x89				# mov [rcx + done], rax or eax
	R_BYTE $0x41
	R_BYTE FR4(%rsp)
	movl FR4(%rsp), %eax
	addl $4, %eax
	cmpl $0, FR2(%rsp)
	je .Lnb_next
	addl $4, %eax
.Lnb_next:
	movl %eax, FR4(%rsp)
	cmpl FR5(%rsp), %eax
	jb .Lnb_store
	R_OK
.Lnb_reg:
	R_VMOV FRM(%rsp), $RM_REG, %r14d, FR3(%rsp)
	movl FR2(%rsp), %eax
	notl %eax
	andl $0xffff, %eax
	R_ZERO_LANES FRM(%rsp), %eax
	R_OK
.Lnb_qmask:
	leaq s_qmask(%rip), %rax
	R_LEAVE
.Lnb_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_gather: vpgatherdd, vgatherdps, vpgatherdq, vgatherdpd and the
# scatters: the card has each with the same bytes after the prefix
# rewrite (P1 bit 2 cleared; P2 keeps V' and the mask), but completes a
# subset of the mask's elements per issue, clearing their bits
# (327364-001, VPSCATTERDD), so the instruction is repeated while the
# mask is not zero with jknzd (VEX.NDS.128.0F.W0 85 rel32, the mask in
# vvvv), which reads no flag and no general register. The 512-bit form
# with a mask only. (rewrite.rs gather_scatter.)
xl_gather:
	R_ENTER
	cmpl $0, FAAA(%rsp)
	je .Lga_mask
	cmpl $2, FLL(%rsp)
	jne .Lga_shape
	cmpq $0, IN_SRC(%r12)
	je .Lga_shape
	movq IN_SRC(%r12), %rsi
	movzbl IN_LEN(%r12), %r14d
	xorl %ecx, %ecx
.Lga_copy:
	movzbl (%rsi,%rcx), %eax
	movb %al, FBUF(%rsp,%rcx)
	incl %ecx
	cmpl %r14d, %ecx
	jb .Lga_copy
	andb $~0x04, FBUF + 2(%rsp)
	andb $0x0f, FBUF + 3(%rsp)
	movq EM_OUT(%rbx), %r15			# the instruction's start
	movq %rbx, %rdi
	leaq FBUF(%rsp), %rsi
	movl %r14d, %edx
	call em_bytes
	movl FAAA(%rsp), %eax
	notl %eax
	andl $0xf, %eax
	shll $3, %eax
	orl $0x80, %eax
	movl %eax, FR0(%rsp)
	R_BYTE $0xc5
	R_BYTE FR0(%rsp)
	R_BYTE $0x85
	movq EM_OUT(%rbx), %rax
	addq $4, %rax
	subq %rax, %r15				# rel32 = start - (the end of the jump)
	movq %rbx, %rdi
	movl %r15d, %eax
	call em_dword
	R_OK
.Lga_mask:
	leaq s2_gather_mask(%rip), %rax
	R_LEAVE
.Lga_shape:
	leaq s_shape(%rip), %rax
	R_LEAVE

# xl_cvt_ph2ps: vcvtph2ps: the card's float16 up-conversion, from
# memory through the unpack pair (any alignment) or from a register
# through the scratch slot (the halves as 8, 4 or 2 dwords).
xl_cvt_ph2ps:
	R_ENTER
	movl FD(%rsp), %r14d
	cmpl $0, FAAA(%rsp)
	jne .Lph_temp
	cmpl $2, FLL(%rsp)
	je .Lph_r
.Lph_temp:
	R_TEMP .Lph_notemp
	movl %eax, %r14d
.Lph_r:
	R_LANES $0
	movl %eax, FR0(%rsp)
	movl $0, FR1(%rsp)
	cmpl $2, FLL(%rsp)
	je .Lph_k
	R_MASK FR0(%rsp)
	movl %eax, FR1(%rsp)
.Lph_k:
	testb $H_MEM, IN_HAS(%r12)
	jz .Lph_reg
	R_UNAL %r14d, FR1(%rsp), $0, $0, $1, $3
	jmp .Lph_commit
.Lph_reg:
	movl $0xff, %eax
	cmpl $2, FLL(%rsp)
	je .Lph_halves
	movl $0xf, %eax
	cmpl $1, FLL(%rsp)
	je .Lph_halves
	movl $3, %eax
.Lph_halves:
	R_MASK %eax
	movl %eax, FR2(%rsp)
	R_MVEX $2, $1, $0, $0xd0, FRM(%rsp), $0, $RM_FS, $S_XFER, FR2(%rsp)
	R_MVEX $1, $0, $0, $0x28, %r14d, $0, $RM_FS, $S_XFER, FR1(%rsp), $3
.Lph_commit:
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Lph_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_cvt_ps2ph: vcvtps2ph: the card's float16 store down-conversion
# (MXCSR rounding, which the immediate's 0 and 4 both mean here): to
# memory by the pack pair (a masked store refused: the pack store
# compresses through its mask), to a register through the scratch
# slot, the halves back as 8, 4 or 2 dwords, the lanes above zero.
xl_cvt_ps2ph:
	R_ENTER
	movzbl IN_IMM(%r12), %eax
	testl $3, %eax
	jz .Lps_round
	testl $4, %eax
	jz .Lps_rounding
.Lps_round:
	R_LANES $0
	movl %eax, FR0(%rsp)
	movl $0, FR1(%rsp)
	cmpl $2, FLL(%rsp)
	je .Lps_k
	R_MASK FR0(%rsp)
	movl %eax, FR1(%rsp)
.Lps_k:
	testb $H_MEM, IN_HAS(%r12)
	jz .Lps_reg
	cmpl $0, FAAA(%rsp)
	jne .Lps_masked
	R_UNAL FD(%rsp), FR1(%rsp), $0, $1, $1, $3
	R_OK
.Lps_reg:
	R_MVEX $1, $0, $0, $0x29, FD(%rsp), $0, $RM_FS, $S_XFER, FR1(%rsp), $3
	movl FRM(%rsp), %r14d
	cmpl $0, FAAA(%rsp)
	je .Lps_lanes
	R_TEMP .Lps_notemp
	movl %eax, %r14d
.Lps_lanes:
	movl $0xff, %eax
	cmpl $2, FLL(%rsp)
	je .Lps_back
	movl $0xf, %eax
	cmpl $1, FLL(%rsp)
	je .Lps_back
	movl $3, %eax
.Lps_back:
	movl %eax, FR2(%rsp)			# the result's lanes
	R_MASK %eax
	movl %eax, FR3(%rsp)
	R_VMOV %r14d, $RM_FS, $S_XFER, FR3(%rsp)
	movl FR2(%rsp), %eax
	notl %eax
	andl $0xffff, %eax
	movl %eax, FR4(%rsp)
	R_ZERO_LANES %r14d, FR4(%rsp)
	cmpl $0, FAAA(%rsp)
	je .Lps_ok
	R_MASK FR2(%rsp)
	movl %eax, FR3(%rsp)
	R_K2 em_kand, FR3(%rsp), FAAA(%rsp)
	R_VMOV FRM(%rsp), $RM_REG, %r14d, FR3(%rsp)
	cmpb $0, IN_Z(%r12)
	je .Lps_upper
	R_K2 em_knot, FR3(%rsp), FR3(%rsp)
	R_ZERO FRM(%rsp), FR3(%rsp)
	R_OK
.Lps_upper:
	R_ZERO_LANES FRM(%rsp), FR4(%rsp)
.Lps_ok:
	R_OK
.Lps_rounding:
	leaq s2_ph_rounding(%rip), %rax
	R_LEAVE
.Lps_masked:
	leaq s2_ph_masked(%rip), %rax
	R_LEAVE
.Lps_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_scalef: vscalefps: x times 2 to the floor of y: the card's vscaleps
# (MVEX.NDS.512.66.0F38.W0 84) takes the exponent as an int32 vector:
# floor(y) as an integer first (vcvtfxpntps2dq rounding down).
xl_scalef:
	R_ENTER
	R_SRC2 $0, $XB_FLOAT, .Lsc_notemp
	movl %eax, %r15d			# s2
	R_TEMP .Lsc_notemp
	movl %eax, %r14d			# t
	R_TEMP .Lsc_notemp
	movl %eax, FR0(%rsp)			# r
	R_MVEX $3, $1, $0, $0xcb, %r14d, $0, $RM_REG, %r15d, $0, $0, $1
	R_MVEX $2, $1, $0, $0x84, FR0(%rsp), FS1(%rsp), $RM_REG, %r14d
	R_COMMIT FD(%rsp), FR0(%rsp), $0
	R_OK
.Lsc_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_valignq: valignq: the card's valignd by twice the count; a
# narrower form first joins the two sources' low halves at the vector
# length, then aligns within it.
xl_valignq:
	R_ENTER
	R_SRC2 $1, $0, .Lvq_notemp
	movl %eax, %r15d			# s2
	R_TEMP .Lvq_notemp
	movl %eax, %r14d			# r
	movzbl IN_IMM(%r12), %eax
	andl $7, %eax
	addl %eax, %eax
	movl %eax, FR0(%rsp)			# the count in dwords
	cmpl $2, FLL(%rsp)
	jne .Lvq_narrow
	R_VALIGND %r14d, FS1(%rsp), $RM_REG, %r15d, FR0(%rsp)
	jmp .Lvq_commit
.Lvq_narrow:
	R_TEMP .Lvq_notemp
	movl %eax, FR1(%rsp)			# t = [s2 low half | s1 low half]
	R_VMOV FR1(%rsp), $RM_REG, %r15d
	movl $0x4e, %eax
	movl $0xff00, %ecx
	cmpl $1, FLL(%rsp)
	je .Lvq_join
	movl $0, %eax
	movl $0xf0, %ecx
.Lvq_join:
	movl %eax, FR2(%rsp)
	R_MASK %ecx
	movl %eax, FR3(%rsp)
	R_VPERMF FR1(%rsp), $RM_REG, FS1(%rsp), FR2(%rsp), FR3(%rsp)
	R_VALIGND %r14d, FR1(%rsp), $RM_REG, FR1(%rsp), FR0(%rsp)
.Lvq_commit:
	R_COMMIT FD(%rsp), %r14d, $1
	R_OK
.Lvq_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_rndscale: vrndscaleps (XF_A 0), vrndscalepd (1), vrndscaless (2),
# vrndscalesd (3) with M = 0 (to an integer) and an explicit rounding
# mode: the card's vrndfxpntps/pd (MVEX.512.66.0F3A 52 ib; W1 for pd),
# whose immediate takes the same two rounding-mode bits. A scalar form
# works lane 0 (a memory element as a broadcast), keeps lanes 1 to 3
# from the first source and zeroes above; its masked form is refused.
xl_rndscale:
	R_ENTER
	movzbl IN_IMM(%r12), %eax
	testl $0xf0, %eax
	jnz .Lrs_frac
	testl $4, %eax
	jnz .Lrs_mxcsr
	andl $3, %eax
	movl %eax, FR0(%rsp)			# the rounding mode
	movl XF_A(%r13), %eax
	andl $1, %eax
	movl %eax, FR1(%rsp)			# w
	testl $2, XF_A(%r13)
	jz .Lrs_packed
	cmpl $0, FAAA(%rsp)
	jne .Lrs_masked
	R_MASK $1
	movl %eax, FR2(%rsp)
	testb $H_MEM, IN_HAS(%r12)
	jz .Lrs_sreg
	R_MVEXM $3, $1, FR1(%rsp), $0x52, FD(%rsp), $0, FR2(%rsp), $1, FR0(%rsp)
	jmp .Lrs_merge
.Lrs_sreg:
	R_MVEX $3, $1, FR1(%rsp), $0x52, FD(%rsp), $0, $RM_REG, FRM(%rsp), FR2(%rsp), $0, FR0(%rsp)
.Lrs_merge:
	movl FD(%rsp), %eax
	cmpl FS1(%rsp), %eax
	je .Lrs_upper
	movl $0xe, %eax
	cmpl $0, FR1(%rsp)
	je .Lrs_rest
	movl $2, %eax
.Lrs_rest:
	R_MASK %eax
	movl %eax, FR2(%rsp)
	R_VMOV FD(%rsp), $RM_REG, FS1(%rsp), FR2(%rsp), FR1(%rsp)
.Lrs_upper:
	R_ZERO_LANES FD(%rsp), $0xfff0
	R_OK
.Lrs_packed:
	R_SRC2 $0, $XB_FLOAT, .Lrs_notemp
	movl %eax, %r15d
	movl FD(%rsp), %r14d
	cmpl $0, FAAA(%rsp)
	jne .Lrs_temp
	cmpl $2, FLL(%rsp)
	je .Lrs_round
.Lrs_temp:
	R_TEMP .Lrs_notemp
	movl %eax, %r14d
.Lrs_round:
	R_MVEX $3, $1, FR1(%rsp), $0x52, %r14d, $0, $RM_REG, %r15d, $0, $0, FR0(%rsp)
	R_COMMIT FD(%rsp), %r14d, FR1(%rsp)
	R_OK
.Lrs_frac:
	leaq s2_rnd_frac(%rip), %rax
	R_LEAVE
.Lrs_mxcsr:
	leaq s2_rnd_mxcsr(%rip), %rax
	R_LEAVE
.Lrs_masked:
	leaq s2_masked_scalar(%rip), %rax
	R_LEAVE
.Lrs_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

	.section .rodata
s2_gather_mask:	.asciz "a gather or scatter without a mask"
s2_ph_rounding:	.asciz "vcvtps2ph with a rounding other than nearest: not expressed yet"
s2_ph_masked:	.asciz "a masked float16 store: the pack store compresses through the mask"
s2_rnd_frac:	.asciz "vrndscale to a fraction of a bit (M above 0): not expressed yet"
s2_rnd_mxcsr:	.asciz "vrndscale with the MXCSR rounding mode: not expressed yet"
s2_masked_scalar: .asciz "a masked scalar form: not expressed yet"
	.balign 64
.Lc_idx_db:	.long 0, 4, 8, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
	.text

# ---- batch 2c (continued): the permutes, the scalar conversions ----

	.macro R_X87 op, reg, off
	movq %rbx, %rdi
	movl \op, %esi
	movl \reg, %edx
	movl \off, %ecx
	call x87_fs
	.endm

# xl_permute: the permutes the card composes from vpermd (indices, bits
# 3:0) and vptestmd. XF_A: 0 vpermi2d/ps and 1 vpermt2d/ps (two tables
# of dwords: the index in reg, or in vvvv), 2 vpermi2q/pd and 3
# vpermt2q/pd (a qword index vector as a dword one: lane 2i gets 2q,
# lane 2i + 1 gets 2q + 1, bit 4 keeps the table selector), 4 vpermq
# and vpermpd (by immediate: per 256-bit half, qword j from qword
# (imm >> 2j) and 3 of the same half; by vector: 3-bit qword indices),
# 5 vpermilpd (by immediate: bit 2b + j picks the qword of block b's
# lane j; by vector: bit 1 of each qword index), 6 vpermilps by vector
# (two bits of each dword index within its block), 7 the narrow vpermd
# and vpermps (3-bit indices for ymm, 2-bit for xmm). (rewrite.rs
# permute.)
xl_permute:
	R_ENTER
	R_TEMP .Lpm_notemp
	movl %eax, %r14d			# r
	R_TEMP .Lpm_notemp
	movl %eax, %r15d			# t
	movl XF_A(%r13), %eax
	cmpl $4, %eax
	jb .Lpm_two
	je .Lpm_q
	cmpl $5, %eax
	je .Lpm_ilpd
	cmpl $6, %eax
	je .Lpm_ilps
	# 7: the narrow vpermd: the index uses 3 bits (ymm) or 2 (xmm)
	R_SRC2 $0, $0, .Lpm_notemp
	movl %eax, FR0(%rsp)
	movl $7, %eax
	cmpl $1, FLL(%rsp)
	je .Lpm_nmask
	movl $3, %eax
.Lpm_nmask:
	R_CONST_DW %eax, .Lpm_notemp
	movl %eax, FR1(%rsp)
	R_I0F $0xdb, %r15d, FS1(%rsp), $RM_CONST, FR1(%rsp)
	R_VPERMD %r14d, %r15d, $RM_REG, FR0(%rsp)
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Lpm_two:
	R_SRC2 $0, $0, .Lpm_notemp
	movl %eax, FR0(%rsp)			# s2
	movl FD(%rsp), %eax			# vpermi2: the index in reg, the first table in vvvv
	movl FS1(%rsp), %ecx
	testl $1, XF_A(%r13)
	jz .Lpm_roles
	xchgl %eax, %ecx			# vpermt2: the first table in reg, the index in vvvv
.Lpm_roles:
	movl %eax, FR1(%rsp)			# the index
	movl %ecx, FR2(%rsp)			# the first table
	cmpl $2, XF_A(%r13)
	jb .Lpm_sel
	# a qword index vector as a dword one
	R_VPSHUFD %r15d, $RM_REG, FR1(%rsp), $0xa0
	R_SHIFT $6, %r15d, $RM_REG, %r15d, $1
	R_CONST .Lc_odd01, .Lpm_notemp
	movl %eax, FR3(%rsp)
	R_I0F $0xfe, %r15d, %r15d, $RM_CONST, FR3(%rsp)
	movl %r15d, FR1(%rsp)
.Lpm_sel:
	R_CONST_DW $0x10, .Lpm_notemp
	movl %eax, FR3(%rsp)
	R_EM em_k
	movl %eax, FR4(%rsp)
	R_VPTESTMD FR4(%rsp), FR1(%rsp), $RM_CONST, FR3(%rsp)	# the lanes that read the second table
	R_VPERMD %r14d, FR1(%rsp), $RM_REG, FR2(%rsp)
	R_VPERMD %r14d, FR1(%rsp), $RM_REG, FR0(%rsp), FR4(%rsp)
	movl $0, %eax
	cmpl $2, XF_A(%r13)
	jb .Lpm_commit2
	movl $1, %eax
.Lpm_commit2:
	movl %eax, FR5(%rsp)
	R_COMMIT FD(%rsp), %r14d, FR5(%rsp)
	R_OK
.Lpm_q:
	testb $H_IMM, IN_HAS(%r12)
	jz .Lpm_qvec
	# per 256-bit half: qword j from qword (imm >> 2j) & 3 of the same half
	movzbl IN_IMM(%r12), %edx
	xorl %ecx, %ecx				# i, the dword lane
.Lpm_qc:
	movl %ecx, %eax
	shrl $3, %eax
	shll $3, %eax				# half * 8
	movl %ecx, %esi
	shrl $1, %esi
	andl $3, %esi				# q
	addl %esi, %esi				# 2q
	pushq %rcx
	movl %esi, %ecx
	movl %edx, %esi
	shrl %cl, %esi
	popq %rcx
	andl $3, %esi				# the source qword
	addl %esi, %esi
	addl %esi, %eax
	movl %ecx, %esi
	andl $1, %esi
	addl %esi, %eax
	movl %eax, FBUF(%rsp,%rcx,4)
	incl %ecx
	cmpl $16, %ecx
	jb .Lpm_qc
	R_CONST_BUF .Lpm_notemp
	movl %eax, FR3(%rsp)
	R_SRC2 $0, $0, .Lpm_notemp
	movl %eax, FR0(%rsp)
	R_VMOV %r15d, $RM_CONST, FR3(%rsp)
	R_VPERMD %r14d, %r15d, $RM_REG, FR0(%rsp)
	R_COMMIT FD(%rsp), %r14d, $1
	R_OK
.Lpm_qvec:
	R_SRC2 $0, $0, .Lpm_notemp
	movl %eax, FR0(%rsp)
	R_VPSHUFD %r15d, $RM_REG, FS1(%rsp), $0xa0
	R_SHIFT $6, %r15d, $RM_REG, %r15d, $1
	R_CONST .Lc_odd01, .Lpm_notemp
	movl %eax, FR3(%rsp)
	R_I0F $0xfe, %r15d, %r15d, $RM_CONST, FR3(%rsp)
	R_VPERMD %r14d, %r15d, $RM_REG, FR0(%rsp)
	R_COMMIT FD(%rsp), %r14d, $1
	R_OK
.Lpm_ilpd:
	testb $H_IMM, IN_HAS(%r12)
	jz .Lpm_ilpdvec
	# bit (2b + j) of the immediate picks the qword for lane j of block b
	movzbl IN_IMM(%r12), %edx
	xorl %ecx, %ecx
.Lpm_pc:
	movl %ecx, %eax
	shrl $2, %eax				# b
	movl %eax, %esi
	addl %esi, %esi				# 2b
	movl %ecx, %edi
	shrl $1, %edi
	andl $1, %edi				# j
	addl %edi, %esi				# 2b + j
	pushq %rcx
	movl %esi, %ecx
	movl %edx, %esi
	shrl %cl, %esi
	popq %rcx
	andl $1, %esi				# sel
	shll $2, %eax				# b * 4
	addl %esi, %esi
	addl %esi, %eax
	movl %ecx, %esi
	andl $1, %esi
	addl %esi, %eax
	movl %eax, FBUF(%rsp,%rcx,4)
	incl %ecx
	cmpl $16, %ecx
	jb .Lpm_pc
	R_CONST_BUF .Lpm_notemp
	movl %eax, FR3(%rsp)
	R_SRC2 $0, $0, .Lpm_notemp
	movl %eax, FR0(%rsp)
	R_VMOV %r15d, $RM_CONST, FR3(%rsp)
	R_VPERMD %r14d, %r15d, $RM_REG, FR0(%rsp)
	R_COMMIT FD(%rsp), %r14d, $1
	R_OK
.Lpm_ilpdvec:
	# bit 1 of each qword index picks the qword within its 128-bit block
	R_SRC2 $0, $0, .Lpm_notemp
	movl %eax, FR0(%rsp)
	R_VPSHUFD %r15d, $RM_REG, FR0(%rsp), $0xa0
	R_SHIFT $2, %r15d, $RM_REG, %r15d, $1
	R_CONST_DW $1, .Lpm_notemp
	movl %eax, FR3(%rsp)
	R_I0F $0xdb, %r15d, %r15d, $RM_CONST, FR3(%rsp)
	R_SHIFT $6, %r15d, $RM_REG, %r15d, $1
	R_CONST .Lc_base_pd, .Lpm_notemp
	movl %eax, FR3(%rsp)
	R_I0F $0xfe, %r15d, %r15d, $RM_CONST, FR3(%rsp)
	R_VPERMD %r14d, %r15d, $RM_REG, FS1(%rsp)
	R_COMMIT FD(%rsp), %r14d, $1
	R_OK
.Lpm_ilps:
	# two bits of each dword index pick the dword within its block
	R_SRC2 $0, $0, .Lpm_notemp
	movl %eax, FR0(%rsp)
	R_CONST_DW $3, .Lpm_notemp
	movl %eax, FR3(%rsp)
	R_I0F $0xdb, %r15d, FR0(%rsp), $RM_CONST, FR3(%rsp)
	R_CONST .Lc_base_ps, .Lpm_notemp
	movl %eax, FR3(%rsp)
	R_I0F $0xfe, %r15d, %r15d, $RM_CONST, FR3(%rsp)
	R_VPERMD %r14d, %r15d, $RM_REG, FS1(%rsp)
	R_COMMIT FD(%rsp), %r14d, $0
	R_OK
.Lpm_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_permilps2: vpermilps by immediate (xl_permilps) or by vector
# (xl_permute, 6).
xl_permilps2:
	movq EM_IN(%rdi), %rax
	testb $H_IMM, IN_HAS(%rax)
	jz 1f
	jmp xl_permilps
1:	leaq xf2_permilps_var(%rip), %rsi
	jmp xl_permute
# xl_permd2: vpermd and vpermps: the card's vpermd at 512 bits
# (xl_nds), the narrow forms through xl_permute (7).
xl_permd2:
	movq EM_IN(%rdi), %rax
	EV_LL %ecx, %rax
	cmpl $2, %ecx
	jne 1f
	leaq xf2_vpermd_nds(%rip), %rsi
	jmp xl_nds
1:	leaq xf2_permd_narrow(%rip), %rsi
	jmp xl_permute

# xl_cvti2s: vcvtsi2ss (XF_A 0), vcvtsi2sd (1), vcvtusi2ss (2),
# vcvtusi2sd (3) from a general register or memory, 32 or 64 bits: the
# integer to the scratch slot as a qword (sign- or zero-extended),
# fild, for an unsigned 64-bit value 2^64 added when its top bit is set
# (chosen without a branch: the sign spread over rax masks the double),
# fstp at the width (the one rounding), then the lane in. (rewrite.rs
# scalar_cvt.)
xl_cvti2s:
	R_ENTER
	cmpb $0, IN_B(%r12)
	je .Lci_b
	cmpb $3, IN_MOD(%r12)
	je .Lci_rounding
.Lci_b:
	movl XF_A(%r13), %r14d
	movzbl IN_W(%r12), %r15d		# wide
	testb $H_MEM, IN_HAS(%r12)
	jz .Lci_reg
	R_EM em_rax
	R_EM em_rcx
	movq %rbx, %rdi
	movq %r12, %rsi
	call em_addr_regs
	movq %rbx, %rdi
	movl $1, %esi
	movq %r12, %rdx
	call em_lea				# lea rcx, [m]
	testl %r15d, %r15d
	jz .Lci_m32
	R_BYTES .Lb_mov_rax_rcx, $3		# mov rax, [rcx]
	jmp .Lci_slot
.Lci_m32:
	testl $2, %r14d
	jz .Lci_msx
	R_BYTES .Lb_mov_eax_rcxm, $2		# mov eax, [rcx]: zero-extended
	jmp .Lci_slot
.Lci_msx:
	R_BYTES .Lb_movsxd_rax_rcx, $3		# movsxd rax, [rcx]
	jmp .Lci_slot
.Lci_reg:
	testl %r15d, %r15d
	jz .Lci_r32
	R_GPRS FRM(%rsp), $1, $S_XFER, $1	# the qword straight to the slot
	jmp .Lci_fild
.Lci_r32:
	R_EM em_rax
	testl $2, %r14d
	jz .Lci_rsx
	cmpl $0, FRM(%rsp)
	je .Lci_slot				# eax itself: already zero-extended in rax? no: mov eax, eax
	cmpl $8, FRM(%rsp)
	jb .Lci_rzx
	R_BYTE $0x41
.Lci_rzx:
	R_BYTE $0x8b				# mov eax, r32
	movl FRM(%rsp), %eax
	andl $7, %eax
	orl $0xc0, %eax
	R_BYTE %eax
	jmp .Lci_slot
.Lci_rsx:
	movl FRM(%rsp), %eax
	shrl $3, %eax
	andl $1, %eax
	orl $0x48, %eax
	R_BYTE %eax
	R_BYTE $0x63				# movsxd rax, r32
	movl FRM(%rsp), %eax
	andl $7, %eax
	orl $0xc0, %eax
	R_BYTE %eax
.Lci_slot:
	R_GPRS $0, $1, $S_XFER, $1
.Lci_fild:
	R_X87 $0xdf, $5, $S_XFER		# fild qword
	testl $2, %r14d
	jz .Lci_store
	testl %r15d, %r15d
	jz .Lci_store
	R_EM em_flags
	R_GPRS $0, $1, $S_XFER, $0		# mov rax, [slot]
	R_BYTES .Lb_sar_rax_63, $4
	R_EM em_rcx
	R_BYTES .Lb_mov_rcx_2p64, $10		# mov rcx, 2^64 as a double
	R_BYTES .Lb_and_rax_rcx, $3
	R_GPRS $0, $1, $S_XFER+8, $1
	R_X87 $0xdc, $0, $S_XFER+8		# fadd qword
.Lci_store:
	movl $0xd9, %eax			# fstp dword
	testl $1, %r14d
	jz .Lci_fstp
	movl $0xdd, %eax			# fstp qword
.Lci_fstp:
	movl %eax, FR0(%rsp)
	R_X87 FR0(%rsp), $3, $S_XFER
	movl %r14d, %ecx
	andl $1, %ecx
	movq %rbx, %rdi
	movl FD(%rsp), %esi
	movl FS1(%rsp), %edx
	call scalar_in
	R_OK
.Lci_rounding:
	leaq s2_rounding(%rip), %rax
	R_LEAVE

# xl_cvts2i: vcvtss2si (XF_A 0), vcvttss2si (1), vcvtsd2si (2),
# vcvttsd2si (3) and the usi forms (4 to 7): to a 32-bit signed result
# the card's fixed-point conversion with NaN and overflow made the
# integer indefinite; to a 64-bit or unsigned result the x87 unit
# (exact, the integer indefinite for NaN and overflow), the rounding
# control set to truncation around the fistp when the form truncates.
# The float from a register, or broadcast from memory. (rewrite.rs
# scalar_cvt.)
xl_cvts2i:
	R_ENTER
	movl XF_A(%r13), %r14d
	movl %r14d, %eax
	shrl $1, %eax
	andl $1, %eax
	movl %eax, FR0(%rsp)			# from a double
	movl FRM(%rsp), %r15d
	testb $H_MEM, IN_HAS(%r12)
	jz .Lcs_src
	R_TEMP .Lcs_notemp
	movl %eax, %r15d
	R_BCASTM %r15d, $0, FR0(%rsp)
.Lcs_src:
	cmpb $0, IN_W(%r12)
	jne .Lcs_x87
	testl $4, %r14d
	jnz .Lcs_x87
	R_TEMP .Lcs_notemp
	movl %eax, FR1(%rsp)			# t
	movl %r14d, %eax
	andl $1, %eax
	imull $3, %eax
	movl %eax, FR2(%rsp)			# the rounding: truncation (3) or MXCSR's (0)
	cmpl $0, FR0(%rsp)
	jne .Lcs_pd
	R_MVEX $3, $1, $0, $0xcb, FR1(%rsp), $0, $RM_REG, %r15d, $0, $0, FR2(%rsp)
	R_CONST_DW $0x4f000000, .Lcs_notemp
	movl %eax, FR3(%rsp)
	R_EM em_k
	movl %eax, FR4(%rsp)
	R_VCMP FR4(%rsp), %r15d, $RM_CONST, FR3(%rsp), $5
	jmp .Lcs_ind
.Lcs_pd:
	R_MVEX $3, $3, $1, $0xe6, FR1(%rsp), $0, $RM_REG, %r15d, $0, $0, FR2(%rsp)
	R_CONST .Lc_2p31_d, .Lcs_notemp
	movl %eax, FR3(%rsp)
	R_EM em_k
	movl %eax, FR4(%rsp)
	R_VCMP FR4(%rsp), %r15d, $RM_CONST, FR3(%rsp), $5, $0, $1
.Lcs_ind:
	R_CONST_DW $0x80000000, .Lcs_notemp
	movl %eax, FR3(%rsp)
	R_VMOV FR1(%rsp), $RM_CONST, FR3(%rsp), FR4(%rsp)
	R_MASK $1
	movl %eax, FR3(%rsp)
	R_MVEX $2, $1, $0, $0xd0, FR1(%rsp), $0, $RM_FS, $S_XFER, FR3(%rsp)
	R_GPRR FD(%rsp), $0, $S_XFER
	R_OK
.Lcs_x87:
	R_TEMP .Lcs_notemp
	movl %eax, FR1(%rsp)
	R_VMOV FR1(%rsp), $RM_REG, %r15d, $0, FR0(%rsp)
	R_MVEX $2, $1, $0, $0xd0, FR1(%rsp), $0, $RM_FS, $S_XFER	# the lanes to the slot
	movl $0xd9, %eax			# fld dword
	cmpl $0, FR0(%rsp)
	je .Lcs_fld
	movl $0xdd, %eax			# fld qword
.Lcs_fld:
	movl %eax, FR2(%rsp)
	R_X87 FR2(%rsp), $0, $S_XFER
	testl $1, %r14d
	jz .Lcs_fistp
	R_EM em_flags
	R_X87 $0xd9, $7, $S_CW			# fnstcw [cw]
	R_FSOP .Lb_movzx_w, $2, $0, $S_CW	# movzx eax, word [cw]
	R_BYTES .Lb_or_ah_0c, $3		# round toward zero
	R_BYTE $0x66
	R_FSOP .Lb_mov_rm_r, $1, $0, $S_CW2	# mov [cw2], ax
	R_X87 $0xd9, $5, $S_CW2			# fldcw [cw2]
.Lcs_fistp:
	R_X87 $0xdf, $7, $S_XFER		# fistp qword
	testl $1, %r14d
	jz .Lcs_result
	R_X87 $0xd9, $5, $S_CW			# fldcw [cw]: back
.Lcs_result:
	movzbl IN_W(%r12), %eax
	movl %eax, FR2(%rsp)
	R_GPRR FD(%rsp), FR2(%rsp), $S_XFER
	R_OK
.Lcs_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

	.data
	.balign 8
xf2_permilps_var:	FORM MN_Vpermilps, xl_permute, 6, 0
xf2_permd_narrow:	FORM MN_Vpermd, xl_permute, 7, 0
xf2_vpermd_nds:		FORM MN_Vpermd, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x36 << 24)), 0
	.section .rodata
s2_rounding:	.asciz "a scalar form with embedded rounding: not expressed yet"
.Lb_mov_rax_rcx:	.byte 0x48, 0x8b, 0x01
.Lb_mov_eax_rcxm:	.byte 0x8b, 0x01
.Lb_movsxd_rax_rcx:	.byte 0x48, 0x63, 0x01
.Lb_sar_rax_63:		.byte 0x48, 0xc1, 0xf8, 0x3f
.Lb_mov_rcx_2p64:	.byte 0x48, 0xb9, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x43
.Lb_and_rax_rcx:	.byte 0x48, 0x21, 0xc8
.Lb_movzx_w:		.byte 0x0f, 0xb7
.Lb_or_ah_0c:		.byte 0x80, 0xcc, 0x0c
.Lb_mov_rm_r:		.byte 0x89
	.balign 64
.Lc_odd01:	.long 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1
.Lc_base_pd:	.long 0, 1, 0, 1, 4, 5, 4, 5, 8, 9, 8, 9, 12, 13, 12, 13
.Lc_base_ps:	.long 0, 0, 0, 0, 4, 4, 4, 4, 8, 8, 8, 8, 12, 12, 12, 12
.Lc_2p31_d:	.quad 0x41e0000000000000, 0x41e0000000000000, 0x41e0000000000000, 0x41e0000000000000
		.quad 0x41e0000000000000, 0x41e0000000000000, 0x41e0000000000000, 0x41e0000000000000
	.text

# ---- batch 2c (continued): the compare predicates above 7 ----

# xl_cmp_ext: vcmpps/vcmppd with a predicate from 8 to 31, and vpcmpd/
# vpcmpud with FALSE (3) or TRUE (7): the card's eight predicates with
# the operands swapped, or two compares joined by kor, where AVX-512
# has thirty-two; the constants from the length's lanes and the write
# mask. (rewrite.rs compare.)
xl_cmp_ext:
	R_ENTER
	movl XF_B(%r13), %eax
	andl $XB_QWORD, %eax
	movl %eax, FR1(%rsp)			# w
	movl FD(%rsp), %eax
	andl $7, %eax
	movl %eax, FR2(%rsp)			# kd
	movl FAAA(%rsp), %eax
	movl %eax, FR3(%rsp)			# keff: {k} when full, else the lanes and {k}
	cmpl $2, FLL(%rsp)
	je .Lce_pred
	R_LANES FR1(%rsp)
	R_MASK %eax
	movl %eax, FR3(%rsp)
	cmpl $0, FAAA(%rsp)
	je .Lce_pred
	R_K2 em_kand, FR3(%rsp), FAAA(%rsp)
.Lce_pred:
	movzbl IN_IMM(%r12), %eax
	movl %eax, FR0(%rsp)
	cmpb $3, IN_MAP(%r12)
	jne .Lce_float
	andl $7, %eax
	cmpl $3, %eax
	jne .Lce_true
.Lce_false:
	R_MOVEAX $0
	R_K2 em_kmov_k_r, FR2(%rsp), $0
	R_OK
.Lce_true:
	cmpl $2, FLL(%rsp)
	jne .Lce_copy
	cmpl $0, FAAA(%rsp)
	jne .Lce_copy
	R_MOVEAX $0xffff
	R_K2 em_kmov_k_r, FR2(%rsp), $0
	R_OK
.Lce_copy:
	R_K2 em_kmov_kk, FR2(%rsp), FR3(%rsp)
	R_OK
.Lce_float:
	cmpl $8, %eax
	jb .Lce_shape
	cmpl $32, %eax
	jae .Lce_shape
	subl $8, %eax
	leaq .Lce_plan(%rip), %rcx
	movzbl (%rcx,%rax,2), %edx
	movzbl 1(%rcx,%rax,2), %esi
	movl %edx, FR4(%rsp)			# the plan: predicate | swap << 4 | kind << 5
	movl %esi, FR5(%rsp)			# the second compare: predicate | swap << 4
	movl %edx, %eax
	shrl $5, %eax
	cmpl $1, %eax
	je .Lce_false
	cmpl $2, %eax
	je .Lce_true
	R_SRC2 FR1(%rsp), $XB_FLOAT, .Lce_notemp
	movl %eax, %r15d			# s2
	movl FR4(%rsp), %eax
	andl $0xf, %eax
	movl %eax, FR0(%rsp)
	testl $0x10, FR4(%rsp)
	jnz .Lce_swap
	R_VCMP FR2(%rsp), FS1(%rsp), $RM_REG, %r15d, FR0(%rsp), FR3(%rsp), FR1(%rsp)
	jmp .Lce_second
.Lce_swap:
	R_VCMP FR2(%rsp), %r15d, $RM_REG, FS1(%rsp), FR0(%rsp), FR3(%rsp), FR1(%rsp)
.Lce_second:
	movl FR4(%rsp), %eax
	shrl $5, %eax
	cmpl $3, %eax
	jne .Lce_cut
	# a second mask register: from k7 down, not kd, the scratch mask or {k}; its value kept in ecx
	movl $7, %ecx
.Lce_pick:
	cmpl FR2(%rsp), %ecx
	je .Lce_next
	movzbl EM_KSCR(%rbx), %eax
	cmpl %eax, %ecx
	je .Lce_next
	cmpl FAAA(%rsp), %ecx
	je .Lce_next
	jmp .Lce_picked
.Lce_next:
	decl %ecx
	jnz .Lce_pick
	movl $1, %ecx
.Lce_picked:
	movl %ecx, FR4(%rsp)			# k2
	R_EM em_rcx
	R_K2 em_kmov_r_k, $1, FR4(%rsp)
	movl FR5(%rsp), %eax
	andl $0xf, %eax
	movl %eax, FR0(%rsp)
	testl $0x10, FR5(%rsp)
	jnz .Lce_swap2
	R_VCMP FR4(%rsp), FS1(%rsp), $RM_REG, %r15d, FR0(%rsp), FR3(%rsp), FR1(%rsp)
	jmp .Lce_join
.Lce_swap2:
	R_VCMP FR4(%rsp), %r15d, $RM_REG, FS1(%rsp), FR0(%rsp), FR3(%rsp), FR1(%rsp)
.Lce_join:
	R_K2 em_kor, FR2(%rsp), FR4(%rsp)
	R_K2 em_kmov_k_r, FR4(%rsp), $1
.Lce_cut:
	cmpl $2, FLL(%rsp)
	jne .Lce_and
	cmpl $0, FAAA(%rsp)
	je .Lce_ok
.Lce_and:
	R_K2 em_kand, FR2(%rsp), FR3(%rsp)
.Lce_ok:
	R_OK
.Lce_shape:
	leaq s_shape(%rip), %rax
	R_LEAVE
.Lce_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

# xl_cmp_k2: vcmpps, vcmppd, vpcmpd, vpcmpud: the card's own predicates
# through xl_cmp_k, the rest through xl_cmp_ext.
xl_cmp_k2:
	movq EM_IN(%rdi), %rax
	movzbl IN_IMM(%rax), %ecx
	cmpb $3, IN_MAP(%rax)
	jne 1f
	andl $7, %ecx
	cmpl $3, %ecx
	je xl_cmp_ext
	cmpl $7, %ecx
	je xl_cmp_ext
	jmp xl_cmp_k
1:	cmpl $8, %ecx
	jae xl_cmp_ext
	jmp xl_cmp_k

	.section .rodata
	# the plan per predicate 8 to 31: the card's predicate | swap << 4 | kind << 5 (0 one compare, 1 FALSE, 2 TRUE, 3 two compares); the second compare's predicate | swap << 4
.Lce_plan:
	.byte 0x60, 0x03			# 8 EQ_UQ: eq or unordered
	.byte 0x16, 0x00			# 9 NGE_US: nle(s2, s1)
	.byte 0x15, 0x00			# 10 NGT_US: nlt(s2, s1)
	.byte 0x20, 0x00			# 11 FALSE_OQ
	.byte 0x61, 0x11			# 12 NEQ_OQ: lt or gt
	.byte 0x12, 0x00			# 13 GE_OS: le(s2, s1)
	.byte 0x11, 0x00			# 14 GT_OS: lt(s2, s1)
	.byte 0x40, 0x00			# 15 TRUE_UQ
	.byte 0x00, 0x00			# 16 EQ_OS
	.byte 0x01, 0x00			# 17 LT_OQ
	.byte 0x02, 0x00			# 18 LE_OQ
	.byte 0x03, 0x00			# 19 UNORD_S
	.byte 0x04, 0x00			# 20 NEQ_US
	.byte 0x05, 0x00			# 21 NLT_UQ
	.byte 0x06, 0x00			# 22 NLE_UQ
	.byte 0x07, 0x00			# 23 ORD_S
	.byte 0x60, 0x03			# 24 EQ_US
	.byte 0x16, 0x00			# 25 NGE_UQ
	.byte 0x15, 0x00			# 26 NGT_UQ
	.byte 0x20, 0x00			# 27 FALSE_OS
	.byte 0x61, 0x11			# 28 NEQ_OS
	.byte 0x12, 0x00			# 29 GE_OQ
	.byte 0x11, 0x00			# 30 GT_OQ
	.byte 0x40, 0x00			# 31 TRUE_US
	.text

# ---- batch 2c (continued): division and square root ----

# dexp(e, x): a double's biased exponent field (bits 62:52) into the odd
# (high) dword lanes of e (the even lanes garbage), from x.
	.macro R_DEXP e, x, fail
	R_SHIFT $2, \e, $RM_REG, \x, $20
	R_CONST_DW $0x7ff, \fail
	movl %eax, FR5(%rsp)
	R_I0F $0xdb, \e, \e, $RM_CONST, FR5(%rsp)
	.endm
# dsetexp(out, x, expo, t): x with its exponent field replaced: out = x,
# the odd lanes = (x and 0x800fffff) or (expo << 20).
	.macro R_DSETEXP out, x, expo, t, fail
	R_MASK $0xaaaa
	movl %eax, FR4(%rsp)
	R_CONST_DW $0x800fffff, \fail
	movl %eax, FR5(%rsp)
	R_VMOV \out, $RM_REG, \x
	R_I0F $0xdb, \out, \out, $RM_CONST, FR5(%rsp), FR4(%rsp)
	R_SHIFT $6, \t, $RM_REG, \expo, $20
	R_I0F $0xeb, \out, \out, $RM_REG, \t, FR4(%rsp)
	.endm
# dpow2(out, expo): a power of two as a double vector: 2^(expo - 1023),
# expo the biased exponent in the odd lanes (the even lanes become zero).
	.macro R_DPOW2 out, expo
	R_SHIFT $6, \out, $RM_REG, \expo, $20
	R_MASK $0x5555
	movl %eax, FR4(%rsp)
	R_ZERO \out, FR4(%rsp)
	.endm
# recip_ps(r, b, e): 1/b to float precision: vrcp23ps, one Newton step
# (r = r + r (1 - b r)).
	.macro R_RECIP r, b, e, fail
	R_MVEX $2, $1, $0, $0xca, \r, $0, $RM_REG, \b
	R_CONST_DW $0x3f800000, \fail
	movl %eax, FR5(%rsp)
	R_VMOV \e, $RM_CONST, FR5(%rsp)
	R_FMA $0xbc, \e, \b, $RM_REG, \r		# e = 1 - b r
	R_FMA $0xb8, \r, \e, $RM_REG, \r		# r = e r + r
	.endm

# xl_divsqrt: vdivps (XF_A 0), vdivpd (1), vsqrtps (2), vsqrtpd (3),
# which the card lacks: Newton-Raphson from its 23-bit estimates
# (vrcp23ps, vrsqrt23ps), then one residual step with a fused
# multiply-add. Doubles are first scaled by a power of two into [1, 4)
# through their exponent field (so the float seed cannot overflow or
# underflow), seeded through float, refined twice, and scaled back
# exactly. Zero, infinity and NaN operands are fixed up from the
# operands themselves. (rewrite.rs divsqrt; the scalar forms are
# xl_divs and xl_sqrts.) Registers: r14 = r, r15 = e; the frame: FR0 q,
# FR1 ex, FR2 kx, FR3 a or b, FR4 and FR5 masks and constants.
xl_divsqrt:
	R_ENTER
	cmpb $0, IN_B(%r12)
	je .Lds_b
	cmpb $3, IN_MOD(%r12)
	je .Lds_rounding
.Lds_b:
	R_SRC2 $0, $XB_FLOAT, .Lds_notemp
	movl %eax, FR3(%rsp)			# the divisor b, or the operand a of a square root
	R_TEMP .Lds_notemp
	movl %eax, %r14d			# r
	R_TEMP .Lds_notemp
	movl %eax, %r15d			# e
	R_TEMP .Lds_notemp
	movl %eax, FR0(%rsp)			# q
	R_EM em_k
	movl %eax, FR2(%rsp)			# kx
	movl XF_A(%r13), %eax
	cmpl $1, %eax
	je .Lds_divpd
	cmpl $2, %eax
	je .Lds_sqrtps
	cmpl $3, %eax
	je .Lds_sqrtpd
	# vdivps: a / b, a = s1 (vvvv)
	R_RECIP %r14d, FR3(%rsp), %r15d, .Lds_notemp
	R_VMULP FR0(%rsp), FS1(%rsp), $RM_REG, %r14d	# q = a r
	R_VMOV %r15d, $RM_REG, FS1(%rsp)
	R_FMA $0xbc, %r15d, FR3(%rsp), $RM_REG, FR0(%rsp)	# e = a - b q
	R_FMA $0xb8, FR0(%rsp), %r15d, $RM_REG, %r14d		# q = e r + q
	# b zero or infinite (the refinement made NaN of it): a times the raw estimate
	R_MVEX $2, $1, $0, $0xca, %r14d, $0, $RM_REG, FR3(%rsp)
	R_VMULP %r14d, FS1(%rsp), $RM_REG, %r14d
	R_CONST_DW $0x7fffffff, .Lds_notemp
	movl %eax, FR4(%rsp)
	R_I0F $0xdb, %r15d, FR3(%rsp), $RM_CONST, FR4(%rsp)	# e = |b|
	R_CONST_DW $0, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_VCMP FR2(%rsp), %r15d, $RM_CONST, FR5(%rsp), $0
	R_VMOV FR0(%rsp), $RM_REG, %r14d, FR2(%rsp)
	R_CONST_DW $0x7f800000, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_VCMP FR2(%rsp), %r15d, $RM_CONST, FR5(%rsp), $0
	R_VMOV FR0(%rsp), $RM_REG, %r14d, FR2(%rsp)
	# a infinite: the residual is inf - inf; the raw product is right
	R_I0F $0xdb, %r15d, FS1(%rsp), $RM_CONST, FR4(%rsp)	# e = |a|
	R_VCMP FR2(%rsp), %r15d, $RM_CONST, FR5(%rsp), $0
	R_VMOV FR0(%rsp), $RM_REG, %r14d, FR2(%rsp)
	R_COMMIT FD(%rsp), FR0(%rsp), $0
	R_OK
.Lds_divpd:
	R_TEMP .Lds_notemp
	movl %eax, FR1(%rsp)			# ex
	# r = b' (b with the exponent 1023: in [1, 2)); ex = a times 2^(1023 - E), exact
	R_DEXP FR1(%rsp), FR3(%rsp), .Lds_notemp
	R_CONST_DW $1023, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_VMOV %r15d, $RM_CONST, FR5(%rsp)
	R_DSETEXP %r14d, FR3(%rsp), %r15d, FR0(%rsp), .Lds_notemp
	R_CONST_DW $2046, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_VMOV %r15d, $RM_CONST, FR5(%rsp)
	R_I0F $0xfa, %r15d, %r15d, $RM_REG, FR1(%rsp)
	R_DPOW2 FR1(%rsp), %r15d
	R_VMULP FR1(%rsp), FR1(%rsp), $RM_REG, FS1(%rsp), $1
	# q = 1 / b': seeded through float, two Newton steps
	R_MVEX $1, $1, $1, $0x5a, %r15d, $0, $RM_REG, %r14d		# vcvtpd2ps
	R_MVEX $2, $1, $0, $0xca, %r15d, $0, $RM_REG, %r15d		# vrcp23ps
	R_MVEX $1, $0, $0, $0x5a, FR0(%rsp), $0, $RM_REG, %r15d	# vcvtps2pd
	R_CONST .Lc_one_d, .Lds_notemp
	movl %eax, FR5(%rsp)
	movl $2, FR4(%rsp)
.Lds_newton_d:
	R_VMOV %r15d, $RM_CONST, FR5(%rsp), $0, $1
	R_FMA $0xbc, %r15d, %r14d, $RM_REG, FR0(%rsp), $1		# e = 1 - b' q
	R_FMA $0xb8, FR0(%rsp), %r15d, $RM_REG, FR0(%rsp), $1	# q = e q + q
	decl FR4(%rsp)
	jnz .Lds_newton_d
	# e = the quotient; ex = the residual; e += residual times reciprocal
	R_VMULP %r15d, FR1(%rsp), $RM_REG, FR0(%rsp), $1
	R_FMA $0xbc, FR1(%rsp), %r14d, $RM_REG, %r15d, $1		# ex = aS - b' e
	R_FMA $0xb8, %r15d, FR1(%rsp), $RM_REG, FR0(%rsp), $1	# e = ex q + e
	# fix-ups: b zero (a signed infinity, NaN for 0/0), b infinite (a signed zero), NaN in
	R_I0F $0xef, FR0(%rsp), FS1(%rsp), $RM_REG, FR3(%rsp), $0, $1
	R_CONST .Lc_sign_d, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_I0F $0xdb, FR0(%rsp), FR0(%rsp), $RM_CONST, FR5(%rsp), $0, $1	# q = the result's sign
	R_CONST .Lc_abs_d, .Lds_notemp
	movl %eax, FR4(%rsp)
	R_I0F $0xdb, %r14d, FR3(%rsp), $RM_CONST, FR4(%rsp), $0, $1	# r = |b|
	R_CONST .Lc_zero_d, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_VCMP FR2(%rsp), %r14d, $RM_CONST, FR5(%rsp), $0, $0, $1
	R_CONST .Lc_inf_d, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_I0F $0xeb, FR1(%rsp), FR0(%rsp), $RM_CONST, FR5(%rsp), $0, $1
	R_VMOV %r15d, $RM_REG, FR1(%rsp), FR2(%rsp), $1		# a / 0 = a signed infinity
	R_VCMP FR2(%rsp), %r14d, $RM_CONST, FR5(%rsp), $0, $0, $1
	R_VMOV %r15d, $RM_REG, FR0(%rsp), FR2(%rsp), $1		# a / inf = a signed zero
	R_I0F $0xdb, FR1(%rsp), FS1(%rsp), $RM_CONST, FR4(%rsp), $0, $1	# ex = |a|
	R_MVEX $1, $1, $1, $0x58, %r14d, %r14d, $RM_REG, FR1(%rsp)	# |a| + |b|
	R_CONST .Lc_zero_d, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_VCMP FR2(%rsp), %r14d, $RM_CONST, FR5(%rsp), $0, $0, $1
	R_CONST .Lc_nan_d, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_VMOV %r15d, $RM_CONST, FR5(%rsp), FR2(%rsp), $1		# 0 / 0
	R_VCMP FR2(%rsp), FS1(%rsp), $RM_REG, FS1(%rsp), $3, $0, $1
	R_VMOV %r15d, $RM_REG, FS1(%rsp), FR2(%rsp), $1
	R_VCMP FR2(%rsp), FR3(%rsp), $RM_REG, FR3(%rsp), $3, $0, $1
	R_VMOV %r15d, $RM_REG, FR3(%rsp), FR2(%rsp), $1
	R_COMMIT FD(%rsp), %r15d, $1
	R_OK
.Lds_sqrtps:
	# sqrt(a) = a rsqrt(a), refined; 0 and infinity give themselves
	R_MVEX $2, $1, $0, $0xcb, %r14d, $0, $RM_REG, FR3(%rsp)	# vrsqrt23ps
	R_CONST_DW $0x3f000000, .Lds_notemp
	movl %eax, FR4(%rsp)			# 0.5
	R_CONST_DW $0x3fc00000, .Lds_notemp
	movl %eax, FR5(%rsp)			# 1.5
	R_VMULP %r15d, FR3(%rsp), $RM_REG, %r14d
	R_VMULP %r15d, %r15d, $RM_REG, %r14d
	R_VMOV FR0(%rsp), $RM_CONST, FR5(%rsp)
	R_FMA $0xbc, FR0(%rsp), %r15d, $RM_CONST, FR4(%rsp)
	R_VMULP %r14d, %r14d, $RM_REG, FR0(%rsp)
	R_VMULP FR0(%rsp), FR3(%rsp), $RM_REG, %r14d
	R_VMOV %r15d, $RM_REG, FR3(%rsp)
	R_FMA $0xbc, %r15d, FR0(%rsp), $RM_REG, FR0(%rsp)
	R_VMULP %r14d, %r14d, $RM_CONST, FR4(%rsp)
	R_FMA $0xb8, FR0(%rsp), %r15d, $RM_REG, %r14d
	R_CONST_DW $0, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_VCMP FR2(%rsp), FR3(%rsp), $RM_CONST, FR5(%rsp), $0
	R_VMOV FR0(%rsp), $RM_REG, FR3(%rsp), FR2(%rsp)
	R_CONST_DW $0x7f800000, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_VCMP FR2(%rsp), FR3(%rsp), $RM_CONST, FR5(%rsp), $0
	R_VMOV FR0(%rsp), $RM_REG, FR3(%rsp), FR2(%rsp)
	R_COMMIT FD(%rsp), FR0(%rsp), $0
	R_OK
.Lds_sqrtpd:
	R_TEMP .Lds_notemp
	movl %eax, FR1(%rsp)			# ex
	# r = a' = a with the exponent 1023 + p, p the parity of E - 1023, so a' is in [1, 4)
	# and the shift back is even; ex = 2^((E - 1023 - p) / 2)
	R_DEXP FR1(%rsp), FR3(%rsp), .Lds_notemp
	R_CONST_DW $1, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_I0F $0xfe, %r15d, FR1(%rsp), $RM_CONST, FR5(%rsp)
	R_I0F $0xdb, %r15d, %r15d, $RM_CONST, FR5(%rsp)		# p
	R_CONST_DW $1023, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_I0F $0xfe, %r15d, %r15d, $RM_CONST, FR5(%rsp)		# 1023 + p
	R_DSETEXP %r14d, FR3(%rsp), %r15d, FR0(%rsp), .Lds_notemp
	R_I0F $0xfa, FR0(%rsp), FR1(%rsp), $RM_REG, %r15d		# E - (1023 + p)
	R_CONST_DW $2046, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_I0F $0xfe, FR0(%rsp), FR0(%rsp), $RM_CONST, FR5(%rsp)	# + 2046
	R_SHIFT $4, FR0(%rsp), $RM_REG, FR0(%rsp), $1		# / 2: the biased exponent of the scale
	R_DPOW2 FR1(%rsp), FR0(%rsp)
	# q = rsqrt(a') seeded through float, two Newton steps: y = 1.5 y - 0.5 a' y^3
	R_MVEX $1, $1, $1, $0x5a, %r15d, $0, $RM_REG, %r14d
	R_MVEX $2, $1, $0, $0xcb, %r15d, $0, $RM_REG, %r15d
	R_MVEX $1, $0, $0, $0x5a, FR0(%rsp), $0, $RM_REG, %r15d
	R_CONST .Lc_half_d, .Lds_notemp
	movl %eax, FR4(%rsp)
	R_CONST .Lc_mhalf_d, .Lds_notemp
	movl %eax, FR5(%rsp)
	movl $2, FR3 + 4(%rsp)			# the iteration count (FR3's high dword; a is still in its low)
.Lds_newton_s:
	R_VMULP %r15d, %r14d, $RM_REG, FR0(%rsp), $1
	R_VMULP %r15d, %r15d, $RM_REG, FR0(%rsp), $1
	R_VMULP %r15d, %r15d, $RM_REG, FR0(%rsp), $1
	R_VMULP %r15d, %r15d, $RM_CONST, FR5(%rsp), $1		# -0.5 a' y^3
	R_FMA $0xb8, FR0(%rsp), FR0(%rsp), $RM_CONST, FR4(%rsp), $1	# q = 0.5 q + q
	R_MVEX $1, $1, $1, $0x58, FR0(%rsp), FR0(%rsp), $RM_REG, %r15d	# + e
	decl FR3 + 4(%rsp)
	jnz .Lds_newton_s
	# s = a' y; s += (a' - s s) 0.5 y; then scaled
	R_VMULP %r15d, %r14d, $RM_REG, FR0(%rsp), $1
	R_VMULP FR0(%rsp), FR0(%rsp), $RM_CONST, FR4(%rsp), $1
	R_FMA $0xbc, %r14d, %r15d, $RM_REG, %r15d, $1		# r = a' - s s
	R_FMA $0xb8, %r15d, %r14d, $RM_REG, FR0(%rsp), $1		# e = r q + e
	R_VMULP %r15d, %r15d, $RM_REG, FR1(%rsp), $1
	R_CONST .Lc_zero_d, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_VCMP FR2(%rsp), FR3(%rsp), $RM_CONST, FR5(%rsp), $0, $0, $1
	R_VMOV %r15d, $RM_REG, FR3(%rsp), FR2(%rsp), $1
	R_CONST .Lc_inf_d, .Lds_notemp
	movl %eax, FR5(%rsp)
	R_VCMP FR2(%rsp), FR3(%rsp), $RM_CONST, FR5(%rsp), $0, $0, $1
	R_VMOV %r15d, $RM_REG, FR3(%rsp), FR2(%rsp), $1
	R_VCMP FR2(%rsp), FR3(%rsp), $RM_REG, FR3(%rsp), $3, $0, $1
	R_VMOV %r15d, $RM_REG, FR3(%rsp), FR2(%rsp), $1
	R_COMMIT FD(%rsp), %r15d, $1
	R_OK
.Lds_rounding:
	leaq s2_rounding(%rip), %rax
	R_LEAVE
.Lds_notemp:
	leaq s_no_temp(%rip), %rax
	R_LEAVE

	.section .rodata
	.balign 64
.Lc_one_d:	.quad 0x3ff0000000000000, 0x3ff0000000000000, 0x3ff0000000000000, 0x3ff0000000000000, 0x3ff0000000000000, 0x3ff0000000000000, 0x3ff0000000000000, 0x3ff0000000000000
.Lc_half_d:	.quad 0x3fe0000000000000, 0x3fe0000000000000, 0x3fe0000000000000, 0x3fe0000000000000, 0x3fe0000000000000, 0x3fe0000000000000, 0x3fe0000000000000, 0x3fe0000000000000
.Lc_mhalf_d:	.quad 0xbfe0000000000000, 0xbfe0000000000000, 0xbfe0000000000000, 0xbfe0000000000000, 0xbfe0000000000000, 0xbfe0000000000000, 0xbfe0000000000000, 0xbfe0000000000000
.Lc_abs_d:	.quad 0x7fffffffffffffff, 0x7fffffffffffffff, 0x7fffffffffffffff, 0x7fffffffffffffff, 0x7fffffffffffffff, 0x7fffffffffffffff, 0x7fffffffffffffff, 0x7fffffffffffffff
.Lc_sign_d:	.quad 0x8000000000000000, 0x8000000000000000, 0x8000000000000000, 0x8000000000000000, 0x8000000000000000, 0x8000000000000000, 0x8000000000000000, 0x8000000000000000
.Lc_zero_d:	.quad 0, 0, 0, 0, 0, 0, 0, 0
.Lc_inf_d:	.quad 0x7ff0000000000000, 0x7ff0000000000000, 0x7ff0000000000000, 0x7ff0000000000000, 0x7ff0000000000000, 0x7ff0000000000000, 0x7ff0000000000000, 0x7ff0000000000000
.Lc_nan_d:	.quad 0xfff8000000000000, 0xfff8000000000000, 0xfff8000000000000, 0xfff8000000000000, 0xfff8000000000000, 0xfff8000000000000, 0xfff8000000000000, 0xfff8000000000000
	.text

# xl_cmp_vec: vcmpps, vcmppd, vpcmpeqd, vpcmpgtd: the EVEX forms into a
# mask register (xl_cmp_k2); a VEX form writes a vector of all-ones and
# zero lanes: the compare into the scratch mask (its number put in the
# block's reg field for the mask recipe, the destination restored
# after), the destination zeroed and set to all ones under it.
xl_cmp_vec:
	movq EM_IN(%rdi), %rax
	cmpb $2, IN_ENC(%rax)
	jne 1f
	jmp xl_cmp_k2
1:	R_ENTER
	R_EM em_k
	movl %eax, FR0(%rsp)			# ks
	movb %al, IN_REG(%r12)
	movq %rbx, %rdi
	movq %r13, %rsi
	call xl_cmp_k2
	movl FD(%rsp), %ecx
	movb %cl, IN_REG(%r12)
	testq %rax, %rax
	jnz .Lcv_out
	R_CONST_DW $-1, .Lcv_notemp
	movl %eax, FR2(%rsp)
	movl XF_B(%r13), %eax
	andl $XB_QWORD, %eax
	movl %eax, FR3(%rsp)
	R_ZERO FD(%rsp)
	R_VMOV FD(%rsp), $RM_CONST, FR2(%rsp), FR0(%rsp), FR3(%rsp)
	R_OK
.Lcv_notemp:
	leaq s_no_temp(%rip), %rax
.Lcv_out:
	R_LEAVE

# xl_cmpq_vec: vpcmpgtq: the EVEX form into a mask (xl_cmpq_pred); the
# VEX form into a vector of all-ones and zero qwords: the compare into
# the scratch mask, the destination zeroed and set under it (W1: the
# mask per qword).
xl_cmpq_vec:
	movq EM_IN(%rdi), %rax
	cmpb $2, IN_ENC(%rax)
	jne 1f
	jmp xl_cmpq_pred
1:	R_ENTER
	R_EM em_k
	movl %eax, FR0(%rsp)
	movb %al, IN_REG(%r12)
	movq %rbx, %rdi
	movq %r13, %rsi
	call xl_cmpq_pred
	movl FD(%rsp), %ecx
	movb %cl, IN_REG(%r12)
	testq %rax, %rax
	jnz .Lcqv_out
	R_CONST_DW $-1, .Lcqv_notemp
	movl %eax, FR2(%rsp)
	R_ZERO FD(%rsp)
	R_VMOV FD(%rsp), $RM_CONST, FR2(%rsp), FR0(%rsp), $1
	R_OK
.Lcqv_notemp:
	leaq s_no_temp(%rip), %rax
.Lcqv_out:
	R_LEAVE
