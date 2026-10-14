# sigill.S: the SIGILL handler: the faulting instruction is inside a
# function the library has a seed for (seeds.S), so the whole function
# from there is one call on the cards: the register file built from the
# signal frame, the loop split into a stripe per card, the units of the
# program's memory each stripe reads made resident on its card (and a
# page for what it writes), the instances posted to the cards at once
# and waited for, the written ranges fetched back, and the frame set as
# the function's `ret` would have left it: rip the return address, rsp
# past it, rax and xmm0 the function's. Residency and pushes go in
# rounds, one request in flight per card, so the four cards move
# together. See sigill.md.

	.include "common.inc"
	.include "proto.inc"
	.include "defs.inc"

	.bss
	.balign 64
file_in:	.skip 4096			# the register file sent (REGS_BYTES)
stripe_lo:	.skip MAX_CARDS * 8
stripe_hi:	.skip MAX_CARDS * 8
	.globl need_q, need_n, need_i, need_overflow
need_q:	.skip MAX_CARDS * NEED_MAX * NQ_BYTES
need_n:	.skip MAX_CARDS * 8
need_i:	.skip MAX_CARDS * 8
push_q:	.skip MAX_CARDS * PUSH_MAX * PQ_BYTES
push_n:	.skip MAX_CARDS * 8
	.globl ymm_off, stat_calls, stat_call_ns, verbose, heapcheck
ymm_off:	.skip 8				# where YMM_Hi128 lies in the XSAVE area (CPUID 0xD/2 EBX)
stat_calls:	.skip 8
stat_call_ns:	.skip 8
heapcheck:	.skip 8			# PHI512_HEAPCHECK: region.S walks the heap around every region
verbose:	.skip 8
cur_entry:	.skip 8				# the blob offset the current call enters at

	.section .rodata
s_unknown1:	.asciz "phi512: SIGILL at "
s_unknown2:	.asciz " is not inside a seeded function: no blob for it (the program dies as it would have)"
s_unknown3:	.asciz "phi512:   the address is in "
s_unknown4:	.asciz " at file offset "
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
s_led6:	.asciz " fill(s), "
s_led7:	.asciz " KiB, "
s_led8:	.asciz " us"
s_led9:	.asciz " (resident "
s_led10:	.asciz ", run "
s_led11:	.asciz ", push "
s_led12:	.asciz " us; a card's run at most "

	.text

	.globl phi512_sig_restorer
phi512_sig_restorer:
	movl $SYS_rt_sigreturn, %eax
	syscall

# phi512_sigill(sig edi, info rsi, uc rdx). Frame: 0 t0, 8 elements,
# 16 fills before, 24 the failed step's code, 32 the failed card.
	.globl phi512_sigill
phi512_sigill:
	pushq %rbx
	pushq %rbp
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $80, %rsp
	movl %edi, 72(%rsp)			# the signal (SIGTRAP: the single step after a host-run instruction)
	movq %rdx, %rbx				# uc
	# one thread at a time (the translation, the region path, the units,
	# the refresh list and the cards' slots are the process's): a
	# test-and-test-and-set spin, released at .Lout
97:	cmpq $0, sigill_lock(%rip)
	je 98f
	pause
	jmp 97b
98:	movl $1, %eax
	xchgq %rax, sigill_lock(%rip)		# (xchg with memory is locked)
	testq %rax, %rax
	jnz 97b
	call alt_check				# on this thread's alternate stack? (one made if none)
	pushq %rax
	call maps_invalidate			# the mappings read afresh once per fault (elf.S maps_load)
	popq %rax
	movq %rax, on_alt(%rip)
	call now_ns
	movq %rax, 0(%rsp)
	movq UC_GREGS + 8 * G_RIP(%rbx), %r12	# rip
	cmpl $5, 72(%rsp)			# SIGTRAP: the host ran one instruction for a region (X_HOST, TF set):
	jne 97f					# the card takes the function back at the next one
	andq $~0x100, UC_GREGS + 8 * G_EFL(%rbx)
	movq %r12, %rdi
	call blob_seed_at
	testq %rax, %rax
	jz .Lout				# no blob there: on natively
	movq %rax, %r13
	movq %rdx, %rax
	incq stat_sstep(%rip)
	jmp 95f
97:	leaq phi512_tramp(%rip), %rax		# a plain callee returned through the trap (region.S tramp_setup):
	cmpq %rax, %r12				# its caller goes on on the card at the return site
	jne 96f
	movq %rbx, %rdi
	call tramp_resume
	testq %rax, %rax
	jz .Lunknown
	movq %rax, %r13
	movq %rdx, %rax
	jmp 95f
96:	call seed_of				# r12 -> the seed in rax, or 0
	testq %rax, %rax
	jz .Lunknown
	movq %rax, %r13				# the seed
	movq %r13, %rdi				# translated on first use (xlfn.S); the blob offset of rip
	movq %r12, %rsi
	call seed_prepare
	cmpq $-1, %rax
	je .Lunknown
95:	movq %rax, cur_entry(%rip)
	# a seed without a plan (every function found at a fault): the region path
	cmpl $OPK_NONE, SD_OPS + OP_KIND(%r13)
	jne 0f
	cmpq $0, handblobs(%rip)
	jne 0f
	movq %rbx, %rdi
	movq %r13, %rsi
	movq %rax, %rdx
94:	call region_run
	cmpl $2, %eax				# it ended in another function with a blob: go on there
	jne 93f
	movq next_seed(%rip), %r13
	movq %rbx, %rdi
	movq %r13, %rsi
	movq next_entry(%rip), %rdx
	jmp 94b
93:	testl %eax, %eax
	jz .Lout
	movl %eax, 24(%rsp)
	movq $0, 32(%rsp)
	jmp .Lfailed_card
0:
	leaq file_in(%rip), %rdi
	movq %rbx, %rsi
	call file_from_frame
	# the stripes: one per card when the seed splits, else one
	movq ncards(%rip), %r14
	cmpl $0, SD_STEP(%r13)
	jne 1f
	movl $1, %r14d
1:	leaq file_in(%rip), %rdx
	movl SD_IND(%r13), %eax
	movq REGS_GPR(%rdx,%rax,8), %r8		# the counter's value
	movl SD_BOUND(%r13), %eax
	movq REGS_GPR(%rdx,%rax,8), %r9		# the bound
	movq %r9, %rax
	subq %r8, %rax
	movq %rax, 8(%rsp)			# the elements
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
	imulq %rcx, %rax			# per stripe
	xorl %r15d, %r15d
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
4:	# residency: every stripe's needs queued on its card, then rounds
	movq stat_resident(%rip), %rax
	movq %rax, 16(%rsp)
	leaq need_n(%rip), %rdi
	movl $MAX_CARDS * 2, %ecx
	xorl %eax, %eax
	rep stosq				# need_n and need_i
	leaq push_n(%rip), %rdi
	movl $MAX_CARDS, %ecx
	rep stosq
	movq $0, need_overflow(%rip)
	movq $0, 64(%rsp)			# the cards' longest run
	xorl %r15d, %r15d
5:	cmpq %r14, %r15
	jae 6f
	call stripe_empty
	jnz 51f
	movq %r15, %rdi
	movq %r13, %rsi
	call stripe_needs
	movq %r15, %rdi
	movq %r13, %rsi
	call stripe_pushes
51:	incq %r15
	jmp 5b
6:	call now_ns
	movq %rax, 40(%rsp)			# t: needs queued
	movl $2, 24(%rsp)
	movq $0, failed_card(%rip)
	cmpq $0, need_overflow(%rip)
	jne .Lfailed_card			# step rc 2: more chunks than a call may need
	call resident_rounds
	movl %eax, 24(%rsp)
	testl %eax, %eax
	jnz .Lfailed_card
	call now_ns
	movq %rax, 48(%rsp)			# t: resident
	# the instances, posted on every card, then waited for
	xorl %r15d, %r15d
7:	cmpq %r14, %r15
	jae 8f
	call stripe_empty
	jnz 71f
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
	movq cur_entry(%rip), %r9
	call card_fexec_post
71:	incq %r15
	jmp 7b
8:	xorl %r15d, %r15d
9:	cmpq %r14, %r15
	jae 10f
	call stripe_empty
	jnz 91f
	movq %r15, %rdi
	imulq $CD_BYTES, %rdi, %rdi
	leaq cards(%rip), %rax
	addq %rax, %rdi
	movq %rdi, %rbp
	call card_wait
	movl %eax, 24(%rsp)
	movq %r15, 32(%rsp)
	testl %eax, %eax
	jnz .Lfailed
	movq CD_SLOTP(%rbp), %rcx
	movq SLOT_REPLY + SR_RUN_NS(%rcx), %rax
	cmpq 64(%rsp), %rax
	jbe 92f
	movq %rax, 64(%rsp)
92:	movl SLOT_REPLY + SR_EXIT_KIND(%rcx), %eax
	addl $1000, %eax			# the exit kind as seen here, in the failure line
	movl %eax, 24(%rsp)
	cmpl $X_RET, SLOT_REPLY + SR_EXIT_KIND(%rcx)
	jne .Lfailed
91:	incq %r15
	jmp 9b
10:	call now_ns
	movq %rax, 56(%rsp)			# t: ran
	call push_rounds
	movl %eax, 24(%rsp)
	testl %eax, %eax
	jnz .Lfailed_card
	# the frame as the function's ret leaves it: the first stripe's file
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
	subq 0(%rsp), %rax
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
	movq 8(%rsp), %rdi
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
	subq 16(%rsp), %rdi
	call w_dec
	leaq s_led6(%rip), %rsi
	call w_str
	movq stat_resident_bytes(%rip), %rdi
	shrq $10, %rdi
	call w_dec
	leaq s_led7(%rip), %rsi
	call w_str
	movq %r12, %rax
	xorl %edx, %edx
	movl $1000, %ecx
	divq %rcx
	movq %rax, %rdi
	call w_dec
	leaq s_led8(%rip), %rsi
	call w_str
	leaq s_led9(%rip), %rsi
	call w_str
	movq 48(%rsp), %rdi
	subq 40(%rsp), %rdi
	call w_us
	leaq s_led10(%rip), %rsi
	call w_str
	movq 56(%rsp), %rdi
	subq 48(%rsp), %rdi
	call w_us
	leaq s_led11(%rip), %rsi
	call w_str
	call now_ns
	movq %rax, %rdi
	subq 56(%rsp), %rdi
	call w_us
	leaq s_led12(%rip), %rsi
	call w_str
	movq 64(%rsp), %rdi
	call w_us
	leaq s_led8(%rip), %rsi
	call w_str
	movl $2, %edi
	call l_end
.Lout:	movq $0, sigill_lock(%rip)		# released (a store is a release on x86-64)
	addq $80, %rsp
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
	movq %r12, %rdi
	call obj_at
	testq %rax, %rax
	jz .Ldie
	movq %rax, %r13
	call l_begin
	leaq s_unknown3(%rip), %rsi
	call w_str
	leaq OBJ_PATH(%r13), %rsi
	call w_str
	leaq s_unknown4(%rip), %rsi
	call w_str
	movq %r12, %rdi
	subq OBJ_BASE(%r13), %rdi
	call w_hexn
	movl $2, %edi
	call l_end
	jmp .Ldie
.Lfailed_card:
	movq failed_card(%rip), %rax
	movq %rax, 32(%rsp)
.Lfailed:
	call l_begin
	leaq s_fail1(%rip), %rsi
	call w_str
	movq 32(%rsp), %rdi
	call w_dec
	leaq s_fail2(%rip), %rsi
	call w_str
	movq SD_NAME(%r13), %rsi
	call w_str
	leaq s_fail3(%rip), %rsi
	call w_str
	movq 32(%rsp), %rcx
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
	pushq %rcx
	call w_dec
	popq %rcx
	leaq s_fail5(%rip), %rsi
	call w_str
	movl 24(%rsp), %edi
	pushq %rcx
	call w_sdec
	popq %rcx
	leaq s_fail6(%rip), %rsi
	call w_str
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

	.bss
	.balign 64
sigill_lock:	.skip 64			# the handler's lock, a line of its own
failed_card:	.skip 8
need_overflow:	.skip 8
	.text

# stripe_empty: ZF set when stripe r15 has elements (jnz = skip it).
stripe_empty:
	leaq stripe_lo(%rip), %rcx
	movq (%rcx,%r15,8), %rax
	leaq stripe_hi(%rip), %rcx
	cmpq (%rcx,%r15,8), %rax
	jae 1f
	xorl %eax, %eax				# ZF: not empty
	ret
1:	testq %rsp, %rsp			# not ZF: empty
	ret

# seed_of: the seed whose function holds r12 (resolved on first use), in
# rax, or 0. The hand-translated blobs expect the state at the function's
# first AVX-512 instruction, wherever gcc put it.
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
2:	movq SD_ADDR(%rbx), %rax
	cmpq %rax, %r12
	jb 3f
	addq SD_LEN(%rbx), %rax
	cmpq %rax, %r12
	jb 9f
3:	addq $SD_BYTES, %rbx
	incq %r13
	jmp 1b
8:	# not a static seed: the executable's function at rip, as a dynamic seed (xlfn.S)
	movq %r12, %rdi
	call seed_dyn_add
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
	.globl file_from_frame
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
	xorl %ecx, %ecx
2:	cmpl $16, %ecx
	jae 9f
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
9:	popq %r12
	popq %rbx
	ret

# op_range(op r15, stripe r12): the bytes the operand covers for the
# stripe: start in rdi, end in rdx (a fixed operand: its bytes; an
# indexed one: the stripe's elements times the stride).
op_range:
	movl OP_REG(%r15), %ecx
	leaq file_in(%rip), %r8
	movq REGS_GPR(%r8,%rcx,8), %rdi		# the pointer
	cmpl $OPK_FIXED, OP_KIND(%r15)
	je 1f
	movl OP_STRIDE(%r15), %ecx
	leaq stripe_lo(%rip), %rdx
	movq (%rdx,%r12,8), %rsi
	imulq %rcx, %rsi
	leaq stripe_hi(%rip), %rdx
	movq (%rdx,%r12,8), %rdx
	imulq %rcx, %rdx
	addq %rdi, %rdx				# end
	addq %rsi, %rdi				# start
	ret
1:	movl OP_LEN(%r15), %edx
	addq %rdi, %rdx
	ret

# stripe_needs(stripe rdi, seed rsi): every chunk the stripe's operands
# touch, queued on the stripe's card with the units it reads (none for a
# written operand) that the card does not hold yet.
stripe_needs:
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
	cmpl $OPK_NONE, OP_KIND(%r15)
	je 7f
	call op_range				# rdi start, rdx end
	movq %rdi, %r8
	andq $-CHUNK, %r8			# the first chunk
2:	cmpq %rdx, %r8
	jae 7f
	# the units of [start, end) within this chunk
	movq %rdi, %rax
	cmpq %r8, %rax
	jae 21f
	movq %r8, %rax
21:	subq %r8, %rax				# low offset in the chunk
	shrq $16, %rax				# low unit
	movq %rdx, %rcx
	leaq CHUNK(%r8), %rsi
	cmpq %rsi, %rcx
	jbe 22f
	movq %rsi, %rcx
22:	subq %r8, %rcx				# high offset
	addq $UNIT - 1, %rcx
	shrq $16, %rcx				# high unit (exclusive)
	movl $1, %esi
	shlq %cl, %rsi
	decq %rsi				# (1 << hi) - 1
	movl $1, %r9d
	movl %eax, %ecx
	shlq %cl, %r9
	decq %r9				# (1 << lo) - 1
	notq %r9
	andq %r9, %rsi				# the units
	xorl %r9d, %r9d				# class 0: read
	cmpl $OPK_WRITE, OP_KIND(%r15)
	jne 23f
	xorl %esi, %esi				# written: the page only
	movl $1, %r9d
23:	pushq %rdi				# start
	pushq %rdx				# end
	pushq %r8				# chunk
	pushq %r9				# class
	pushq %rsi				# units
	movq %rbx, %rdi
	movq %r8, %rsi
	movl 0(%rsp), %edx
	call card_need				# eax needed units, edx 1 = no entry
	movl %eax, %r10d
	movl %edx, %r11d
	popq %rsi
	popq %r9
	testl %r10d, %r10d
	jnz 24f
	testl %r11d, %r11d
	jz 25f
24:	movq %r12, %rdi
	movq 0(%rsp), %rsi			# chunk
	movl %r10d, %edx
	movl %r9d, %ecx
	call need_add
25:	popq %r8
	popq %rdx
	popq %rdi
	addq $CHUNK, %r8
	jmp 2b
7:	incl %r14d
	jmp 1b
8:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# need_add(card index rdi, chunk rsi, units edx, class ecx): into the
# card's queue, merged with an entry for the same chunk.
	.globl need_add
need_add:
	movq %rdi, %rax
	imulq $NEED_MAX * NQ_BYTES, %rax, %rax
	leaq need_q(%rip), %r8
	addq %rax, %r8				# the queue
	leaq need_n(%rip), %r9
	movq (%r9,%rdi,8), %r10			# its count
	xorl %eax, %eax
1:	cmpq %r10, %rax
	jae 2f
	movq %rax, %r11
	shlq $4, %r11
	cmpq NQ_CHUNK(%r8,%r11), %rsi
	je 3f
	incq %rax
	jmp 1b
2:	cmpq $NEED_MAX, %r10
	jb 21f
	movq $1, need_overflow(%rip)		# full: the call fails before it runs
	jmp 9f
21:
	movq %r10, %r11
	shlq $4, %r11
	movq %rsi, NQ_CHUNK(%r8,%r11)
	movl $0, NQ_UNITS(%r8,%r11)
	movl %ecx, NQ_CLASS(%r8,%r11)
	incq (%r9,%rdi,8)
3:	orl %edx, NQ_UNITS(%r8,%r11)
	cmpl NQ_CLASS(%r8,%r11), %ecx
	jae 9f
	movl %ecx, NQ_CLASS(%r8,%r11)		# a read wins
9:	ret

# resident_rounds: while a card has needs queued, one K_RESIDENT per
# card posted, then each waited for; eax 0, else the status with the
# card in failed_card.
	.globl resident_rounds
resident_rounds:
	pushq %rbx
	pushq %r12
	pushq %r13
1:	xorl %r13d, %r13d			# posted this round
	xorl %ebx, %ebx
2:	cmpq ncards(%rip), %rbx
	jae 4f
	leaq need_i(%rip), %rax
	movq (%rax,%rbx,8), %rcx
	leaq need_n(%rip), %rax
	cmpq (%rax,%rbx,8), %rcx
	jae 3f
	movq %rbx, %rax
	imulq $NEED_MAX * NQ_BYTES, %rax, %rax
	leaq need_q(%rip), %r8
	addq %rax, %r8
	shlq $4, %rcx
	addq %rcx, %r8				# the entry
	leaq need_i(%rip), %rax
	incq (%rax,%rbx,8)
	movq %rbx, %rdi
	imulq $CD_BYTES, %rdi, %rdi
	leaq cards(%rip), %rax
	addq %rax, %rdi
	movq NQ_CHUNK(%r8), %rsi
	movl NQ_UNITS(%r8), %edx
	movl NQ_CLASS(%r8), %ecx
	call card_resident_post
	incl %r13d
3:	incq %rbx
	jmp 2b
4:	testl %r13d, %r13d
	jz 8f
	xorl %ebx, %ebx
5:	cmpq ncards(%rip), %rbx
	jae 1b
	movq %rbx, %rdi
	imulq $CD_BYTES, %rdi, %rdi
	leaq cards(%rip), %rax
	addq %rax, %rdi
	cmpq $0, CD_POSTED(%rdi)
	je 6f
	call card_resident_done
	testl %eax, %eax
	jnz 9f
6:	incq %rbx
	jmp 5b
8:	xorl %eax, %eax
	jmp 10f
9:	movq %rbx, failed_card(%rip)
10:	popq %r13
	popq %r12
	popq %rbx
	ret

# stripe_pushes(stripe rdi, seed rsi): the stripe's written ranges queued
# on its card.
stripe_pushes:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %r12
	movq %rsi, %r13
	xorl %r14d, %r14d
1:	cmpl $4, %r14d
	jae 8f
	movq %r14, %r15
	shlq $4, %r15
	leaq SD_OPS(%r13,%r15), %r15
	cmpl $OPK_WRITE, OP_KIND(%r15)
	jne 7f
	call op_range				# rdi start, rdx end
	subq %rdi, %rdx				# the bytes
	movq %r12, %rax
	imulq $PUSH_MAX * PQ_BYTES, %rax, %rax
	leaq push_q(%rip), %r8
	addq %rax, %r8
	leaq push_n(%rip), %r9
	movq (%r9,%r12,8), %rcx
	cmpq $PUSH_MAX, %rcx
	jae 7f
	imulq $PQ_BYTES, %rcx, %rcx
	movq %rdi, PQ_ADDR(%r8,%rcx)
	movq %rdx, PQ_LEN(%r8,%rcx)
	movq $0, PQ_DONE(%r8,%rcx)
	incq (%r9,%r12,8)
7:	incl %r14d
	jmp 1b
8:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# push_rounds: while a card has bytes to fetch, one K_PUSH piece per
# card posted, then each waited for and copied out; eax 0, else the
# status with the card in failed_card.
push_rounds:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
1:	xorl %r13d, %r13d			# posted this round
	xorl %ebx, %ebx
2:	cmpq ncards(%rip), %rbx
	jae 5f
	# the card's first range with bytes left
	movq %rbx, %rax
	imulq $PUSH_MAX * PQ_BYTES, %rax, %rax
	leaq push_q(%rip), %r8
	addq %rax, %r8
	leaq push_n(%rip), %r9
	movq (%r9,%rbx,8), %r10
	xorl %ecx, %ecx
3:	cmpq %r10, %rcx
	jae 4f
	movq %rcx, %r11
	imulq $PQ_BYTES, %r11, %r11
	movq PQ_LEN(%r8,%r11), %rdx
	subq PQ_DONE(%r8,%r11), %rdx
	jnz 31f
	incq %rcx
	jmp 3b
31:	leaq (%r8,%r11), %r14			# the range
	movq PQ_ADDR(%r14), %rsi
	addq PQ_DONE(%r14), %rsi		# the piece: to the chunk's end at most
	movq %rsi, %rax
	andq $CHUNK - 1, %rax
	movq $CHUNK, %rcx
	subq %rax, %rcx
	cmpq %rcx, %rdx
	jbe 32f
	movq %rcx, %rdx
32:
	addq %rdx, PQ_DONE(%r14)
	movq %rbx, %rdi
	imulq $CD_BYTES, %rdi, %rdi
	leaq cards(%rip), %rax
	addq %rax, %rdi
	call card_push_post
	incl %r13d
4:	incq %rbx
	jmp 2b
5:	testl %r13d, %r13d
	jz 8f
	xorl %ebx, %ebx
6:	cmpq ncards(%rip), %rbx
	jae 1b
	movq %rbx, %rdi
	imulq $CD_BYTES, %rdi, %rdi
	leaq cards(%rip), %rax
	addq %rax, %rdi
	cmpq $0, CD_POSTED(%rdi)
	je 7f
	call card_push_done
	testl %eax, %eax
	jnz 9f
7:	incq %rbx
	jmp 6b
8:	xorl %eax, %eax
	jmp 10f
9:	movq %rbx, failed_card(%rip)
10:	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# w_us(rdi ns): the nanoseconds as microseconds, appended.
	.globl w_us
w_us:
	movq %rdi, %rax
	xorl %edx, %edx
	movl $1000, %ecx
	divq %rcx
	movq %rax, %rdi
	jmp w_dec

	.text
	.set ALT_BYTES, 262144
	.set SS_ONSTACK, 1
	.set SS_DISABLE, 2
# alt_install: an alternate signal stack for the calling thread (256 KiB,
# mmap'd), so the SIGILL handler (SA_ONSTACK) and the kernel's signal
# frame are off the program's stack: the region path can then write back
# below the frame's rsp (a region that moves rsp down, a call's stack
# arguments: region.md). eax 0, or 1 when it could not be made.
	.globl alt_install
alt_install:
	subq $40, %rsp
	xorl %edi, %edi
	movl $ALT_BYTES, %esi
	movl $PROT_READ | PROT_WRITE, %edx
	movl $MAP_PRIVATE | MAP_ANONYMOUS, %r10d
	movq $-1, %r8
	xorl %r9d, %r9d
	movl $SYS_mmap, %eax
	syscall
	cmpq $MAP_FAILED_MAX, %rax
	ja 8f
	movq %rax, 0(%rsp)			# ss_sp
	movq $0, 8(%rsp)			# ss_flags
	movq $ALT_BYTES, 16(%rsp)		# ss_size
	movq %rsp, %rdi
	xorl %esi, %esi
	movl $SYS_sigaltstack, %eax
	syscall
	testq %rax, %rax
	jnz 8f
	xorl %eax, %eax
	addq $40, %rsp
	ret
8:	movl $1, %eax
	addq $40, %rsp
	ret

# alt_check: eax 1 when this fault's handler runs on the thread's
# alternate stack; a thread without one gets one for its next faults
# (this one runs on the program's stack: eax 0).
alt_check:
	subq $40, %rsp
	xorl %edi, %edi
	movq %rsp, %rsi
	movl $SYS_sigaltstack, %eax
	syscall
	testq %rax, %rax
	jnz 2f
	testl $SS_DISABLE, 8(%rsp)
	jnz 1f
	movl 8(%rsp), %eax
	andl $SS_ONSTACK, %eax
	addq $40, %rsp
	ret
1:	call alt_install
2:	xorl %eax, %eax
	addq $40, %rsp
	ret

	.bss
	.balign 8
	.globl on_alt
on_alt:	.skip 8					# this fault's handler is on the alternate stack (under sigill_lock)
	.text
