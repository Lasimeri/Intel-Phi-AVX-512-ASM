# sigill.S: the SIGILL handler: the faulting instruction is the first
# AVX-512 instruction of a function the library has a seed for (seeds.S),
# so the whole function from there is one instance on the cards: the
# register file built from the signal frame, the operands' chunks made
# resident on each card that runs a stripe, the stripes posted to the
# cards at once and waited for, the written ranges fetched back, and the
# frame set as the function's `ret` would have left it: rip the return
# address, rsp past it, rax and xmm0 the function's. See sigill.md.

	.include "common.inc"
	.include "proto.inc"
	.include "defs.inc"

	.bss
	.balign 64
file_in:	.skip 4096			# the register file sent (REGS_BYTES)
stripe_lo:	.skip MAX_CARDS * 8
stripe_hi:	.skip MAX_CARDS * 8
	.globl ymm_off, stat_calls, stat_call_ns, verbose
ymm_off:	.skip 8				# where YMM_Hi128 lies in the XSAVE area (CPUID 0xD/2 EBX)
stat_calls:	.skip 8
stat_call_ns:	.skip 8
verbose:	.skip 8

	.section .rodata
s_unknown1:	.asciz "phi512: SIGILL at "
s_unknown2:	.asciz " is not at a seed's entry: no blob for it (the program dies as it would have)"
s_fail1:	.asciz "phi512: card "
s_fail2:	.asciz " refused an instance of "
s_fail3:	.asciz ": status "
s_fail4:	.asciz ", exit kind "
s_fail5:	.asciz ", step rc "
s_fail6:	.asciz ", exit rip "
s_fail7:	.asciz ", fault address "
	.globl s_blob1, s_blob2, s_blob3
s_blob1:	.asciz "phi512: card "
s_blob2:	.asciz ": blob "
s_blob3:	.asciz " at "
s_led1:	.asciz "phi512: "
s_led2:	.asciz ": "
s_led3:	.asciz " elements in "
s_led4:	.asciz " stripe(s) on "
s_led5:	.asciz " card(s), "
s_led6:	.asciz " chunk(s) made resident, "
s_led7:	.asciz " us"

	.text

	.globl phi512_sig_restorer
phi512_sig_restorer:
	movl $SYS_rt_sigreturn, %eax
	syscall

# phi512_sigill(sig edi, info rsi, uc rdx)
	.globl phi512_sigill
phi512_sigill:
	pushq %rbx
	pushq %rbp
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $64, %rsp
	movq %rdx, %rbx				# uc
	call now_ns
	movq %rax, 56(%rsp)			# t0
	movq UC_GREGS + 8 * G_RIP(%rbx), %r12	# rip
	call seed_of				# r12 -> the seed in rax, or 0
	testq %rax, %rax
	jz .Lunknown
	movq %rax, %r13				# the seed
	# the register file from the frame
	leaq file_in(%rip), %rdi
	movq %rbx, %rsi
	call file_from_frame
	# the stripes: one per card when the seed splits, else one
	movq ncards(%rip), %r14			# stripes
	cmpl $0, SD_STEP(%r13)
	jne 1f
	movl $1, %r14d
1:	leaq file_in(%rip), %rdx
	movl SD_IND(%r13), %eax
	movq REGS_GPR(%rdx,%rax,8), %r8		# the counter's value
	movl SD_BOUND(%r13), %eax
	movq REGS_GPR(%rdx,%rax,8), %r9		# the bound
	movq %r9, %rax
	subq %r8, %rax				# the elements
	movq %rax, 48(%rsp)
	# per = ceil(elements / stripes / step) * step
	xorl %edx, %edx
	divq %r14
	movl SD_STEP(%r13), %ecx
	testl %ecx, %ecx
	jnz 2f
	movl $1, %ecx
2:	addq %rcx, %rax
	decq %rax
	xorl %edx, %edx
	divq %rcx
	imulq %rcx, %rax			# per
	xorl %r15d, %r15d			# s
3:	cmpq %r14, %r15
	jae 4f
	leaq stripe_lo(%rip), %rcx
	movq %r8, (%rcx,%r15,8)
	leaq (%r8,%rax), %rdx
	cmpq %r9, %rdx
	jbe 31f
	movq %r9, %rdx
31:	leaq stripe_hi(%rip), %rcx
	movq %rdx, (%rcx,%r15,8)
	movq %rdx, %r8
	incq %r15
	jmp 3b
4:	# residency, then the post, stripe by stripe (a stripe with no
	# elements is skipped)
	movq stat_resident(%rip), %rax
	movq %rax, 40(%rsp)
	xorl %r15d, %r15d
5:	cmpq %r14, %r15
	jae 6f
	leaq stripe_lo(%rip), %rcx
	movq (%rcx,%r15,8), %rdi
	leaq stripe_hi(%rip), %rcx
	cmpq (%rcx,%r15,8), %rdi
	jae 51f
	movq %r15, %rdi
	movq %r13, %rsi
	call stripe_resident
	movl %eax, 32(%rsp)
	testl %eax, %eax
	jnz .Lfailed
	movq %r15, %rdi
	imulq $CD_BYTES, %rdi, %rdi
	leaq cards(%rip), %rax
	addq %rax, %rdi
	movq %r13, %rsi
	leaq file_in(%rip), %rdx
	leaq stripe_lo(%rip), %rcx
	movq (%rcx,%r15,8), %rcx
	leaq stripe_hi(%rip), %r8
	movq (%r8,%r15,8), %r8
	call card_fexec_post
51:	incq %r15
	jmp 5b
6:	# every instance waited for, its exit checked
	xorl %r15d, %r15d
7:	cmpq %r14, %r15
	jae 8f
	leaq stripe_lo(%rip), %rcx
	movq (%rcx,%r15,8), %rdi
	leaq stripe_hi(%rip), %rcx
	cmpq (%rcx,%r15,8), %rdi
	jae 71f
	movq %r15, %rdi
	imulq $CD_BYTES, %rdi, %rdi
	leaq cards(%rip), %rax
	addq %rax, %rdi
	movq %rdi, %rbp
	call card_wait
	movl %eax, 32(%rsp)
	testl %eax, %eax
	jnz .Lfailed
	movq CD_SLOTP(%rbp), %rcx
	movl SLOT_REPLY + SR_EXIT_KIND(%rcx), %eax
	addl $1000, %eax			# the exit kind as seen here, in the failure line
	movl %eax, 32(%rsp)
	cmpl $X_RET, SLOT_REPLY + SR_EXIT_KIND(%rcx)
	jne .Lfailed
71:	incq %r15
	jmp 7b
8:	# the written ranges back, stripe by stripe
	xorl %r15d, %r15d
9:	cmpq %r14, %r15
	jae 10f
	leaq stripe_lo(%rip), %rcx
	movq (%rcx,%r15,8), %rdi
	leaq stripe_hi(%rip), %rcx
	cmpq (%rcx,%r15,8), %rdi
	jae 91f
	movq %r15, %rdi
	movq %r13, %rsi
	call stripe_push
	movl %eax, 32(%rsp)
	testl %eax, %eax
	jnz .Lfailed
91:	incq %r15
	jmp 9b
10:	# the frame as the function's ret leaves it: the first stripe's file
	# gives rax and xmm0; the upper halves of every ymm are zero (the
	# function's vzeroupper); rip the return address, rsp past it
	leaq cards(%rip), %rbp
	movq CD_DATAP(%rbp), %rsi
	movq SD_REGS_OUT + REGS_GPR + 8 * R_RAX(%rsi), %rax
	movq %rax, UC_GREGS + 8 * G_RAX(%rbx)
	movq UC_FPREGS(%rbx), %rdi
	testq %rdi, %rdi
	jz 11f
	movq SD_REGS_OUT + REGS_ZMM(%rsi), %rax
	movq %rax, FX_XMM0(%rdi)
	movq SD_REGS_OUT + REGS_ZMM + 8(%rsi), %rax
	movq %rax, FX_XMM0 + 8(%rdi)
	movq ymm_off(%rip), %rcx
	testq %rcx, %rcx
	jz 11f
	leaq (%rdi,%rcx), %rcx
	xorl %eax, %eax
	movl $32, %edx
101:	movq %rax, (%rcx)
	addq $8, %rcx
	decl %edx
	jnz 101b
	orq $1 << XSTATE_YMM_BIT, XSAVE_HEADER(%rdi)
11:	movq UC_GREGS + 8 * G_RSP(%rbx), %rax
	movq (%rax), %rcx
	movq %rcx, UC_GREGS + 8 * G_RIP(%rbx)
	addq $8, %rax
	movq %rax, UC_GREGS + 8 * G_RSP(%rbx)
	incq stat_calls(%rip)
	call now_ns
	subq 56(%rsp), %rax
	addq %rax, stat_call_ns(%rip)
	cmpq $0, verbose(%rip)
	je .Lout
	movq %rax, %r12				# ns
	call l_begin
	leaq s_led1(%rip), %rsi
	call w_str
	movq SD_NAME(%r13), %rsi
	call w_str
	leaq s_led2(%rip), %rsi
	call w_str
	movq 48(%rsp), %rdi
	call w_dec
	leaq s_led3(%rip), %rsi
	call w_str
	movq %r14, %rdi
	call w_dec
	leaq s_led4(%rip), %rsi
	call w_str
	movq ncards(%rip), %rdi
	call w_dec
	leaq s_led5(%rip), %rsi
	call w_str
	movq stat_resident(%rip), %rdi
	subq 40(%rsp), %rdi
	call w_dec
	leaq s_led6(%rip), %rsi
	call w_str
	movq %r12, %rax
	xorl %edx, %edx
	movl $1000, %ecx
	divq %rcx
	movq %rax, %rdi
	call w_dec
	leaq s_led7(%rip), %rsi
	call w_str
	movl $2, %edi
	call l_end
.Lout:	addq $64, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbp
	popq %rbx
	ret
.Lunknown:
	call l_begin
	leaq s_unknown1(%rip), %rsi
	call w_str
	movq %r12, %rdi
	call w_hexn
	leaq s_unknown2(%rip), %rsi
	call w_str
	movl $2, %edi
	call l_end
	jmp .Ldie
.Lfailed:
	call l_begin
	leaq s_fail1(%rip), %rsi
	call w_str
	movq %r15, %rdi
	call w_dec
	leaq s_fail2(%rip), %rsi
	call w_str
	movq SD_NAME(%r13), %rsi
	call w_str
	leaq s_fail3(%rip), %rsi
	call w_str
	movq %r15, %rcx
	imulq $CD_BYTES, %rcx, %rcx
	leaq cards(%rip), %rax
	addq %rcx, %rax
	movq CD_SLOTP(%rax), %rcx
	movl SLOT_REPLY + SR_STATUS(%rcx), %edi
	pushq %rcx
	call w_sdec
	popq %rcx
	leaq s_fail4(%rip), %rsi
	call w_str
	movl SLOT_REPLY + SR_EXIT_KIND(%rcx), %edi
	call w_dec
	leaq s_fail5(%rip), %rsi
	call w_str
	movl 32(%rsp), %edi
	call w_sdec
	leaq s_fail6(%rip), %rsi
	call w_str
	movq %r15, %rcx
	imulq $CD_BYTES, %rcx, %rcx
	leaq cards(%rip), %rax
	addq %rcx, %rax
	movq CD_SLOTP(%rax), %rcx
	movq SLOT_REPLY + SR_EXIT_RIP(%rcx), %rdi
	pushq %rcx
	call w_hexn
	popq %rcx
	leaq s_fail7(%rip), %rsi
	call w_str
	movq SLOT_REPLY + SR_EXIT_AUX(%rcx), %rdi
	call w_hexn
	movl $2, %edi
	call l_end
.Ldie:	# the signal back to its default action: the fault repeats and ends
	# the program as it would have
	subq $SA_BYTES, %rsp
	movq $0, SA_HANDLER(%rsp)
	movq $0, SA_FLAGS(%rsp)
	movq $0, SA_RESTORER_OFF(%rsp)
	movq $0, SA_MASK(%rsp)
	movl $SIGILL, %edi
	movq %rsp, %rsi
	xorl %edx, %edx
	movl $SIGSET_BYTES, %r10d
	SYS SYS_rt_sigaction
	addq $SA_BYTES, %rsp
	jmp .Lout

# seed_of: the seed whose entry is at r12 (its function resolved on first
# use), in rax, or 0.
seed_of:
	pushq %rbx
	pushq %r13
	leaq seeds(%rip), %rbx
	xorl %r13d, %r13d
1:	cmpq nseeds(%rip), %r13
	jae 8f
	cmpq $0, SD_ADDR(%rbx)
	jne 2f
	movq SD_NAME(%rbx), %rdi
	call elf_find
	testq %rax, %rax
	jz 3f
	movq %rax, SD_ADDR(%rbx)
	movq %rdx, SD_LEN(%rbx)
2:	# inside the function: the hand-translated blobs expect the state
	# at the function's first AVX-512 instruction, wherever gcc put it
	movq SD_ADDR(%rbx), %rax
	cmpq %rax, %r12
	jb 3f
	addq SD_LEN(%rbx), %rax
	cmpq %rax, %r12
	jb 9f
3:	addq $SD_BYTES, %rbx
	incq %r13
	jmp 1b
8:	xorl %eax, %eax
	popq %r13
	popq %rbx
	ret
9:	movq %rbx, %rax
	popq %r13
	popq %rbx
	ret

# file_from_frame(file rdi, uc rsi): the register file for the card: the
# integers and flags from the frame, xmm0..15 and their ymm halves from
# the FXSAVE/XSAVE area, the upper 256 bits of every zmm and zmm16..31
# zero (the host has none), the masks zero.
file_from_frame:
	pushq %rbx
	pushq %r12
	movq %rdi, %rbx
	movq %rsi, %r12
	movl $REGS_BYTES / 8, %ecx
	xorl %eax, %eax
1:	movq %rax, (%rdi)
	addq $8, %rdi
	decl %ecx
	jnz 1b
	movq UC_GREGS + 8 * G_RAX(%r12), %rax
	movq %rax, REGS_GPR + 0(%rbx)
	movq UC_GREGS + 8 * G_RCX(%r12), %rax
	movq %rax, REGS_GPR + 8(%rbx)
	movq UC_GREGS + 8 * G_RDX(%r12), %rax
	movq %rax, REGS_GPR + 16(%rbx)
	movq UC_GREGS + 8 * G_RBX(%r12), %rax
	movq %rax, REGS_GPR + 24(%rbx)
	movq UC_GREGS + 8 * G_RSP(%r12), %rax
	movq %rax, REGS_GPR + 32(%rbx)
	movq UC_GREGS + 8 * G_RBP(%r12), %rax
	movq %rax, REGS_GPR + 40(%rbx)
	movq UC_GREGS + 8 * G_RSI(%r12), %rax
	movq %rax, REGS_GPR + 48(%rbx)
	movq UC_GREGS + 8 * G_RDI(%r12), %rax
	movq %rax, REGS_GPR + 56(%rbx)
	movq UC_GREGS + 8 * G_R8(%r12), %rax
	movq %rax, REGS_GPR + 64(%rbx)
	movq UC_GREGS + 8 * G_R9(%r12), %rax
	movq %rax, REGS_GPR + 72(%rbx)
	movq UC_GREGS + 8 * G_R10(%r12), %rax
	movq %rax, REGS_GPR + 80(%rbx)
	movq UC_GREGS + 8 * G_R11(%r12), %rax
	movq %rax, REGS_GPR + 88(%rbx)
	movq UC_GREGS + 8 * G_R12(%r12), %rax
	movq %rax, REGS_GPR + 96(%rbx)
	movq UC_GREGS + 8 * G_R13(%r12), %rax
	movq %rax, REGS_GPR + 104(%rbx)
	movq UC_GREGS + 8 * G_R14(%r12), %rax
	movq %rax, REGS_GPR + 112(%rbx)
	movq UC_GREGS + 8 * G_R15(%r12), %rax
	movq %rax, REGS_GPR + 120(%rbx)
	movq UC_GREGS + 8 * G_EFL(%r12), %rax
	movq %rax, REGS_RFLAGS(%rbx)
	movq UC_FPREGS(%r12), %rsi
	testq %rsi, %rsi
	jz 9f
	# xmm0..15: 16 bytes each at FX_XMM0; ymm halves at ymm_off
	xorl %ecx, %ecx
2:	cmpl $16, %ecx
	jae 3f
	movq %rcx, %rax
	shlq $4, %rax
	movq FX_XMM0(%rsi,%rax), %rdx
	movq %rcx, %rdi
	shlq $6, %rdi
	movq %rdx, REGS_ZMM(%rbx,%rdi)
	movq FX_XMM0 + 8(%rsi,%rax), %rdx
	movq %rdx, REGS_ZMM + 8(%rbx,%rdi)
	cmpq $0, ymm_off(%rip)
	je 21f
	addq ymm_off(%rip), %rax
	movq (%rsi,%rax), %rdx
	movq %rdx, REGS_ZMM + 16(%rbx,%rdi)
	movq 8(%rsi,%rax), %rdx
	movq %rdx, REGS_ZMM + 24(%rbx,%rdi)
21:	incl %ecx
	jmp 2b
3:
9:	popq %r12
	popq %rbx
	ret

# stripe_resident(stripe rdi, seed rsi): every chunk the stripe's
# operands touch, resident on the stripe's card; eax 0 or a status.
stripe_resident:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %r12
	movq %rsi, %r13
	movq %r12, %rbx
	imulq $CD_BYTES, %rbx, %rbx
	leaq cards(%rip), %rax
	addq %rax, %rbx				# the card
	xorl %r14d, %r14d			# op
1:	cmpl $4, %r14d
	jae 8f
	movq %r14, %r15
	shlq $4, %r15
	leaq SD_OPS(%r13,%r15), %r15		# the op
	movl OP_KIND(%r15), %eax
	testl %eax, %eax
	jz 7f
	movl OP_REG(%r15), %ecx
	leaq file_in(%rip), %r8
	movq REGS_GPR(%r8,%rcx,8), %rdi		# the pointer
	cmpl $OPK_FIXED, %eax
	je 2f
	movl OP_STRIDE(%r15), %ecx
	leaq stripe_lo(%rip), %rdx
	movq (%rdx,%r12,8), %rsi
	imulq %rcx, %rsi
	leaq stripe_hi(%rip), %rdx
	movq (%rdx,%r12,8), %rdx
	imulq %rcx, %rdx
	addq %rdi, %rdx				# end
	addq %rsi, %rdi				# start
	jmp 3f
2:	movl OP_LEN(%r15), %edx
	addq %rdi, %rdx
3:	# every chunk of [rdi, rdx)
	andq $-CHUNK, %rdi
4:	cmpq %rdx, %rdi
	jae 7f
	pushq %rdi
	pushq %rdx
	movq %rdi, %rsi
	movq %rbx, %rdi
	movl OP_KIND(%r15), %edx
	cmpl $OPK_WRITE, %edx
	sete %dl
	movzbl %dl, %edx
	call card_resident
	popq %rdx
	popq %rdi
	testl %eax, %eax
	jnz 9f
	addq $CHUNK, %rdi
	jmp 4b
7:	incl %r14d
	jmp 1b
8:	xorl %eax, %eax
9:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# stripe_push(stripe rdi, seed rsi): the stripe's written operands back
# from its card; eax 0 or a status.
stripe_push:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %r12
	movq %rsi, %r13
	movq %r12, %rbx
	imulq $CD_BYTES, %rbx, %rbx
	leaq cards(%rip), %rax
	addq %rax, %rbx
	xorl %r14d, %r14d
1:	cmpl $4, %r14d
	jae 8f
	movq %r14, %r15
	shlq $4, %r15
	leaq SD_OPS(%r13,%r15), %r15
	cmpl $OPK_WRITE, OP_KIND(%r15)
	jne 7f
	movl OP_REG(%r15), %ecx
	leaq file_in(%rip), %r8
	movq REGS_GPR(%r8,%rcx,8), %rsi
	movl OP_STRIDE(%r15), %ecx
	leaq stripe_lo(%rip), %rdx
	movq (%rdx,%r12,8), %rax
	imulq %rcx, %rax
	addq %rax, %rsi				# the address
	leaq stripe_hi(%rip), %rdx
	movq (%rdx,%r12,8), %rdx
	leaq stripe_lo(%rip), %rax
	subq (%rax,%r12,8), %rdx
	imulq %rcx, %rdx			# the bytes
	movq %rbx, %rdi
	call card_push
	testl %eax, %eax
	jnz 9f
7:	incl %r14d
	jmp 1b
8:	xorl %eax, %eax
9:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
