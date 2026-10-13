# fexec.S: a slot process runs a translated function (protocol v3,
# vpu_fexec.h): K_LOAD puts a position-independent blob the host staged
# in LOADAREA into this process's executable arena and names it by id;
# K_FEXEC loads the register file the dispatcher's DMA landed for this
# slot (sched.S), enters the blob at its entry offset on this process's
# run stack with the return stub as the return address, and comes back
# through that stub (X_RET) or through the signal handlers (X_FAULT,
# X_REFUSED), with the register file captured either way and stored into
# the slot's SLOTDATA for the host. The first increment of stage 2 of the
# restart: no resident program memory yet (the blob touches only its
# registers and this process's memory). See fexec.md.

	.include "defs.inc"
	.include "proto.inc"
	.include "mvex.inc"

	.set FX_ARENA, 16 * 1048576
	.set FX_STACK, 1048576
	.set FX_ALTSTACK, 65536
	.set FX_TAB_MAX, 256
	.set FT_ID, 0
	.set FT_ADDR, 8
	.set FT_LEN, 16
	.set FT_BYTES, 24
	.globl FX_LAND_PER_SLOT, FX_REGS_PULL
	.set FX_LAND_PER_SLOT, 65536		# of the DMA landing area, per slot (32 x 64 KiB = 2 MiB)
	.set FX_REGS_PULL, 2368			# the register block, whole lines (REGS_BYTES 2256 rounded up)
	.set FX_LOAD_PER_SLOT, 512 * 1024	# of LOADAREA, per slot
# One run's context: the register file first (the stubs know), then this
# process's own stack pointer, the exit, the kind, the raw flags.
	.set CTX_REGS, 0
	.set CTX_SAVED_RSP, 2256
	.set CTX_EXIT_RIP, 2264
	.set CTX_FAULT, 2272
	.set CTX_KIND, 2280
	.set CTX_FLAGS_RAW, 2288
	.set CTX_BYTES, 2304
	.set TE_CTX, TLS_EXEC
	.set TE_SCRATCH, TLS_EXEC + 8
	.set TE_SCRATCH2, TLS_EXEC + 16
	.set CTX_KIND_STUB, 100
# The kernel's signal frame (exec.S has the same numbers).
	.set UC_GREGS, 40
	.set G_R8, 0
	.set G_R9, 1
	.set G_R10, 2
	.set G_R11, 3
	.set G_R12, 4
	.set G_R13, 5
	.set G_R14, 6
	.set G_R15, 7
	.set G_RDI, 8
	.set G_RSI, 9
	.set G_RBP, 10
	.set G_RBX, 11
	.set G_RDX, 12
	.set G_RAX, 13
	.set G_RCX, 14
	.set G_RSP, 15
	.set G_RIP, 16
	.set G_EFL, 17
	.set SI_ADDR, 16
	.set SA_HANDLER, 0
	.set SA_FLAGS, 8
	.set SA_RESTORER_OFF, 16
	.set SA_MASK, 24
	.set SA_BYTES, 32
	.set SIGSET_BYTES, 8

	.macro FX_VPU_SAVE
	.set i, 0
	.rept 32
	VMOVAPS_ST rax, 64*i, i
	.set i, i + 1
	.endr
	.set i, 0
	.rept 8
	KMOV_RK ecx, i
	movw %cx, REGS_K + 2 * i(%rax)
	.set i, i + 1
	.endr
	.endm
	.macro FX_VPU_RESTORE
	.set i, 0
	.rept 32
	VMOVAPS i, rax, 64*i
	.set i, i + 1
	.endr
	.set i, 0
	.rept 8
	movzwl REGS_K + 2 * i(%rax), %ecx
	KMOV_KR i, ecx
	.set i, i + 1
	.endr
	.endm

	.bss
	.balign 4096
fx_ctx:	.skip CTX_BYTES
	.balign 64
fx_tab:	.skip FX_TAB_MAX * FT_BYTES
fx_ntab:	.skip 8
fx_arena:	.skip 8
fx_arena_used:	.skip 8
fx_stack:	.skip 8
fx_altstack:	.skip 8
fx_in_run:	.skip 8
fx_sa:	.skip SA_BYTES
fx_ss:	.skip 32

	.section .rodata
s_fx_mmap:	.asciz "fexec: mmap failed"
s_fx_sig:	.asciz "fexec: sigaction failed"

	.text

# fexec_init: the arena, the run stack, the alternate signal stack and the
# handlers of this slot process. Dies on failure.
	.globl fexec_init
fexec_init:
	pushq %rbx
	xorl %edi, %edi
	movl $FX_ARENA, %esi
	movl $PROT_READ | PROT_WRITE | PROT_EXEC, %edx
	movl $MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, %r10d
	movq $-1, %r8
	xorl %r9d, %r9d
	SYS SYS_mmap
	cmpq $MAP_FAILED_MAX, %rax
	ja .Lfx_mmap_fail
	movq %rax, fx_arena(%rip)
	xorl %edi, %edi
	movl $FX_STACK, %esi
	movl $PROT_READ | PROT_WRITE, %edx
	movl $MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, %r10d
	movq $-1, %r8
	xorl %r9d, %r9d
	SYS SYS_mmap
	cmpq $MAP_FAILED_MAX, %rax
	ja .Lfx_mmap_fail
	movq %rax, fx_stack(%rip)
	xorl %edi, %edi
	movl $FX_ALTSTACK, %esi
	movl $PROT_READ | PROT_WRITE, %edx
	movl $MAP_PRIVATE | MAP_ANONYMOUS, %r10d
	movq $-1, %r8
	xorl %r9d, %r9d
	SYS SYS_mmap
	cmpq $MAP_FAILED_MAX, %rax
	ja .Lfx_mmap_fail
	movq %rax, fx_altstack(%rip)
	leaq fx_ss(%rip), %rdi
	movq %rax, (%rdi)
	movl $0, 8(%rdi)
	movq $FX_ALTSTACK, 16(%rdi)
	xorl %esi, %esi
	SYS SYS_sigaltstack
	# the handlers: SIGSEGV, SIGBUS and SIGILL, on the alternate stack
	leaq fx_sa(%rip), %rbx
	leaq fx_on_fault(%rip), %rax
	movq %rax, SA_HANDLER(%rbx)
	movq $SA_SIGINFO | SA_ONSTACK | SA_RESTORER, SA_FLAGS(%rbx)
	leaq fx_sig_restorer(%rip), %rax
	movq %rax, SA_RESTORER_OFF(%rbx)
	movq $0, SA_MASK(%rbx)
	movl $SIGSEGV, %edi
	call fx_sig_install
	movl $SIGBUS, %edi
	call fx_sig_install
	leaq fx_on_ill(%rip), %rax
	movq %rax, SA_HANDLER(%rbx)
	movl $SIGILL, %edi
	call fx_sig_install
	movq $0, %fs:TE_CTX
	popq %rbx
	ret
.Lfx_mmap_fail:
	leaq s_fx_mmap(%rip), %rsi
	jmp die

fx_sig_install:
	leaq fx_sa(%rip), %rsi
	xorl %edx, %edx
	movl $SIGSET_BYTES, %r10d
	SYS SYS_rt_sigaction
	testq %rax, %rax
	jnz 1f
	ret
1:	leaq s_fx_sig(%rip), %rsi
	jmp die

fx_sig_restorer:
	movl $SYS_rt_sigreturn, %eax
	syscall

# fexec_load(request line rdi, slot esi, reply rdx): K_LOAD: `entry`
# bytes of the blob from this slot's part of LOADAREA into the arena,
# named `fn_id` (an existing id is replaced by the new bytes: the host
# re-translated). The reply's exit_aux is the blob's address in this
# process; eax the status (E_ALLOC when the arena or the table is full,
# E_REQUEST for a length over the slot's part).
	.globl fexec_load
fexec_load:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	movq %rdi, %rbx
	movl %esi, %r12d
	movq %rdx, %r13
	movq SL_ENTRY(%rbx), %r14		# bytes
	testq %r14, %r14
	jz .Lfl_request
	cmpq $FX_LOAD_PER_SLOT, %r14
	ja .Lfl_request
	# round to a line; room in the arena
	addq $63, %r14
	andq $-64, %r14
	movq fx_arena_used(%rip), %rax
	addq %r14, %rax
	cmpq $FX_ARENA, %rax
	ja .Lfl_alloc
	# the table entry: the id's own, or a new one
	leaq fx_tab(%rip), %rcx
	xorl %edx, %edx
1:	cmpq fx_ntab(%rip), %rdx
	jae 2f
	movq SL_FN_ID(%rbx), %rax
	cmpq FT_ID(%rcx), %rax
	je 3f
	addq $FT_BYTES, %rcx
	incq %rdx
	jmp 1b
2:	cmpq $FX_TAB_MAX, %rdx
	jae .Lfl_alloc
	incq fx_ntab(%rip)
	movq SL_FN_ID(%rbx), %rax
	movq %rax, FT_ID(%rcx)
3:	movq fx_arena(%rip), %rax
	addq fx_arena_used(%rip), %rax
	movq %rax, FT_ADDR(%rcx)
	movq %r14, FT_LEN(%rcx)
	addq %r14, fx_arena_used(%rip)
	# the bytes: this slot's part of LOADAREA, in lines, through the
	# window's mapping (a load is rare; the DMA engine is the
	# dispatcher's)
	movq %rax, %rdi
	movq %r12, %rsi
	imulq $FX_LOAD_PER_SLOT, %rsi, %rsi
	addq $OFF_LOADAREA, %rsi
	addq window(%rip), %rsi
	movq %r14, %rdx
	shrq $6, %rdx
	movq %rax, %r14				# the address
	call phi_copy64
	movq %r14, SR_EXIT_AUX(%r13)
	xorl %eax, %eax
	jmp 9f
.Lfl_request:
	movl $E_REQUEST, %eax
	jmp 9f
.Lfl_alloc:
	movl $E_ALLOC, %eax
9:	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# fexec_run(request line rdi, slot esi, reply rdx, landed regs rcx):
# K_FEXEC: the register file from the landing area into the context, rip
# the blob's entry, rsp this process's run stack with the return stub
# pushed, then into the blob; back through the stub or a handler. The
# register file as left goes to the slot's SD_REGS_OUT; the reply's exit
# fields say how it left. eax the status (E_REQUEST: no such fn_id or
# an entry past the blob).
	.globl fexec_run
fexec_run:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %rbx
	movl %esi, %r12d
	movq %rdx, %r13
	movq %rcx, %r14
	# the blob
	leaq fx_tab(%rip), %rcx
	xorl %edx, %edx
1:	cmpq fx_ntab(%rip), %rdx
	jae .Lfr_request
	movq SL_FN_ID(%rbx), %rax
	cmpq FT_ID(%rcx), %rax
	je 2f
	addq $FT_BYTES, %rcx
	incq %rdx
	jmp 1b
2:	movq SL_ENTRY(%rbx), %rax
	cmpq FT_LEN(%rcx), %rax
	jae .Lfr_request
	addq FT_ADDR(%rcx), %rax
	movq %rax, %r15				# rip
	# the register file: REGS_BYTES from the landing area
	leaq fx_ctx(%rip), %rdi
	movq %r14, %rsi
	movl $REGS_BYTES / 64 + 1, %edx
	call phi_copy64
	leaq fx_ctx(%rip), %rdi
	movq %r15, CTX_REGS + REGS_RIP(%rdi)
	# the run stack: the return stub's address on top
	movq fx_stack(%rip), %rax
	addq $FX_STACK - 64, %rax
	leaq fx_ret_stub(%rip), %rcx
	movq %rcx, (%rax)
	movq %rax, CTX_REGS + REGS_GPR + 32(%rdi)
	movl $0, CTX_KIND(%rdi)
	movq $0, CTX_FAULT(%rdi)
	movq %rdi, %fs:TE_CTX
	movq $1, fx_in_run(%rip)
	call now_ns
	movq %rax, %r14
	leaq fx_ctx(%rip), %rdi
	call fx_enter
	call now_ns
	subq %r14, %rax
	movq %rax, SR_RUN_NS(%r13)
	movq $0, fx_in_run(%rip)
	movq $0, %fs:TE_CTX
	# the exit, and the register file out
	leaq fx_ctx(%rip), %rcx
	movl CTX_KIND(%rcx), %eax
	cmpl $CTX_KIND_STUB, %eax
	jne 3f
	movl $X_RET, %eax
	# the stub kept the raw flags: into the file
	movq CTX_FLAGS_RAW(%rcx), %rdx
	movq %rdx, CTX_REGS + REGS_RFLAGS(%rcx)
3:	movl %eax, SR_EXIT_KIND(%r13)
	movq CTX_REGS + REGS_RIP(%rcx), %rax
	movq %rax, SR_EXIT_RIP(%r13)
	movq CTX_FAULT(%rcx), %rax
	movq %rax, SR_EXIT_AUX(%r13)
	movq %r12, %rdi
	shlq $20, %rdi
	addq $OFF_SLOTDATA + SD_REGS_OUT, %rdi
	addq window(%rip), %rdi
	leaq fx_ctx(%rip), %rsi
	movl $REGS_BYTES / 64 + 1, %edx
	call phi_copy64
	movl $1, SR_THREADS_RAN(%r13)
	xorl %eax, %eax
	jmp 9f
.Lfr_request:
	movl $E_REQUEST, %eax
9:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# fx_enter(context rdi): callee-saved registers pushed and this stack kept
# in the context, the file loaded (vector unit, flags, integers, rsp
# last), control to regs.rip. Returns 0 through the return stub or the
# exit stub.
fx_enter:
	pushq %rbx
	pushq %rbp
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rsp, CTX_SAVED_RSP(%rdi)
	movq %rdi, %rax
	FX_VPU_RESTORE
	pushq REGS_RFLAGS(%rax)
	popfq
	movq REGS_GPR + 8(%rax), %rcx
	movq REGS_GPR + 16(%rax), %rdx
	movq REGS_GPR + 24(%rax), %rbx
	movq REGS_GPR + 40(%rax), %rbp
	movq REGS_GPR + 48(%rax), %rsi
	movq REGS_GPR + 56(%rax), %rdi
	movq REGS_GPR + 64(%rax), %r8
	movq REGS_GPR + 72(%rax), %r9
	movq REGS_GPR + 80(%rax), %r10
	movq REGS_GPR + 88(%rax), %r11
	movq REGS_GPR + 96(%rax), %r12
	movq REGS_GPR + 104(%rax), %r13
	movq REGS_GPR + 112(%rax), %r14
	movq REGS_GPR + 120(%rax), %r15
	movq REGS_GPR + 32(%rax), %rsp
	pushq REGS_RIP(%rax)
	movq REGS_GPR(%rax), %rax
	ret					# into the blob, rax loaded too

# fx_ret_stub: the blob's `ret` lands here: rax and the flags kept first,
# the integers stored, the file's rip the return address (the stack
# pointer as the blob left it, past the return address), the vector unit
# stored on this process's stack, and back to fexec_run.
fx_ret_stub:
	movq %rax, %fs:TE_SCRATCH
	lahf
	seto %al
	movq %rax, %fs:TE_SCRATCH2
	movq %fs:TE_CTX, %rax
	movq %rcx, REGS_GPR + 8(%rax)
	movq %rdx, REGS_GPR + 16(%rax)
	movq %rbx, REGS_GPR + 24(%rax)
	movq %rsp, REGS_GPR + 32(%rax)
	movq %rbp, REGS_GPR + 40(%rax)
	movq %rsi, REGS_GPR + 48(%rax)
	movq %rdi, REGS_GPR + 56(%rax)
	movq %r8, REGS_GPR + 64(%rax)
	movq %r9, REGS_GPR + 72(%rax)
	movq %r10, REGS_GPR + 80(%rax)
	movq %r11, REGS_GPR + 88(%rax)
	movq %r12, REGS_GPR + 96(%rax)
	movq %r13, REGS_GPR + 104(%rax)
	movq %r14, REGS_GPR + 112(%rax)
	movq %r15, REGS_GPR + 120(%rax)
	movq %fs:TE_SCRATCH, %rcx
	movq %rcx, REGS_GPR(%rax)
	movq %fs:TE_SCRATCH2, %rcx
	movq %rcx, CTX_FLAGS_RAW(%rax)
	leaq fx_ret_stub(%rip), %rcx
	movq %rcx, REGS_RIP(%rax)
	movl $CTX_KIND_STUB, CTX_KIND(%rax)
	movq CTX_SAVED_RSP(%rax), %rsp
	FX_VPU_SAVE
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbp
	popq %rbx
	xorl %eax, %eax
	ret

# fx_exit_stub: where fx_leave sends the interrupted context: rdi the
# context, rsp this process's own; the vector unit stored after sigreturn
# (kernel patch 0030 keeps it across the handler).
fx_exit_stub:
	movq %rdi, %rax
	FX_VPU_SAVE
	movq CTX_SAVED_RSP(%rdi), %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbp
	popq %rbx
	xorl %eax, %eax
	ret

# fx_leave(frame rdi, kind esi, fault rdx): the frame's registers into the
# context, the frame pointed at the exit stub.
fx_leave:
	movq %fs:TE_CTX, %rax
	movl %esi, CTX_KIND(%rax)
	movq UC_GREGS + 8 * G_RIP(%rdi), %rcx
	movq %rcx, CTX_EXIT_RIP(%rax)
	movq %rcx, CTX_REGS + REGS_RIP(%rax)
	movq %rdx, CTX_FAULT(%rax)
	movq UC_GREGS + 8 * G_RAX(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 0(%rax)
	movq UC_GREGS + 8 * G_RCX(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 8(%rax)
	movq UC_GREGS + 8 * G_RDX(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 16(%rax)
	movq UC_GREGS + 8 * G_RBX(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 24(%rax)
	movq UC_GREGS + 8 * G_RSP(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 32(%rax)
	movq UC_GREGS + 8 * G_RBP(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 40(%rax)
	movq UC_GREGS + 8 * G_RSI(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 48(%rax)
	movq UC_GREGS + 8 * G_RDI(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 56(%rax)
	movq UC_GREGS + 8 * G_R8(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 64(%rax)
	movq UC_GREGS + 8 * G_R9(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 72(%rax)
	movq UC_GREGS + 8 * G_R10(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 80(%rax)
	movq UC_GREGS + 8 * G_R11(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 88(%rax)
	movq UC_GREGS + 8 * G_R12(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 96(%rax)
	movq UC_GREGS + 8 * G_R13(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 104(%rax)
	movq UC_GREGS + 8 * G_R14(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 112(%rax)
	movq UC_GREGS + 8 * G_R15(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_GPR + 120(%rax)
	movq UC_GREGS + 8 * G_EFL(%rdi), %rcx
	movq %rcx, CTX_REGS + REGS_RFLAGS(%rax)
	leaq fx_exit_stub(%rip), %rcx
	movq %rcx, UC_GREGS + 8 * G_RIP(%rdi)
	movq CTX_SAVED_RSP(%rax), %rcx
	movq %rcx, UC_GREGS + 8 * G_RSP(%rdi)
	movq %rax, UC_GREGS + 8 * G_RDI(%rdi)
	ret

# fx_on_fault: SIGSEGV and SIGBUS (edi signal, rsi siginfo, rdx ucontext)
# inside a run: X_FAULT with the address; outside: the default action.
fx_on_fault:
	cmpq $0, fx_in_run(%rip)
	je 1f
	cmpq $0, %fs:TE_CTX
	je 1f
	movq SI_ADDR(%rsi), %rax
	movq %rdx, %rdi
	movl $X_FAULT, %esi
	movq %rax, %rdx
	jmp fx_leave
1:	jmp fx_sig_default

# fx_on_ill: SIGILL inside a run: an instruction the card refused
# (X_REFUSED, rip in the file).
fx_on_ill:
	cmpq $0, fx_in_run(%rip)
	je 1f
	cmpq $0, %fs:TE_CTX
	je 1f
	movq %rdx, %rdi
	movl $X_REFUSED, %esi
	movq UC_GREGS + 8 * G_RIP(%rdi), %rdx
	jmp fx_leave
1:	jmp fx_sig_default

# fx_sig_default(signal edi): the signal back to its default action: the
# fault repeats and ends the process the normal way.
fx_sig_default:
	subq $SA_BYTES, %rsp
	movq $0, SA_HANDLER(%rsp)
	movq $0, SA_FLAGS(%rsp)
	movq $0, SA_RESTORER_OFF(%rsp)
	movq $0, SA_MASK(%rsp)
	movq %rsp, %rsi
	xorl %edx, %edx
	movl $SIGSET_BYTES, %r10d
	SYS SYS_rt_sigaction
	addq $SA_BYTES, %rsp
	ret
