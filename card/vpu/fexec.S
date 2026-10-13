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
	.set CTX_SIGINFO, 2296			# a fault's signal number | si_code << 8
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
fx_ctx:	.skip (MAX_POOL + 1) * CTX_BYTES	# a context per thread of the slot: slice s at s * CTX_BYTES
	.balign 64
fx_base:	.skip CTX_BYTES			# the file as landed, copied per slice
fx_lo:	.skip 8				# the split: the counter's first value, the bound, the step, the slices
fx_hi:	.skip 8
fx_step:	.skip 8
fx_per:	.skip 8
fx_rip:	.skip 8
fx_flags:	.skip 8			# the request's flags (FXF_*)
fx_ind_reg:	.skip 8
fx_bound_reg:	.skip 8
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
	movq $(MAX_POOL + 1) * FX_STACK, %rsi		# a run stack per thread of the slot
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
	# the exit stub's address in every thread's TLS block
	leaq tls_blocks(%rip), %rdi
	leaq fx_exit_jmp(%rip), %rax
	movl $MAX_POOL + 1, %ecx
1:	movq %rax, TE_EXIT(%rdi)
	addq $TLS_BYTES, %rdi
	decl %ecx
	jnz 1b
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
	subq $16, %rsp
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
	# the register file as landed, kept for every slice
	leaq fx_base(%rip), %rdi
	movq %r14, %rsi
	movl $REGS_BYTES / 64 + 1, %edx
	call phi_copy64
	movq %r15, fx_rip(%rip)
	movl SL_FLAGS(%rbx), %eax
	movq %rax, fx_flags(%rip)
	# the program's stack-protector canary into every thread's TLS (fs:0x28 as glibc has it)
	movq SL_CANARY(%rbx), %rax
	leaq tls_blocks(%rip), %rcx
	movl $MAX_POOL + 1, %edx
31:	movq %rax, TLS_CANARY(%rcx)
	addq $TLS_BYTES, %rcx
	decl %edx
	jnz 31b
	# the refresh: the lines the host changed since the last run, copied
	# in by this core from the slot data (SL_REFRESH_N ranges of
	# SD_REFRESH_TAB, their bytes in order at SD_REFRESH). A core's stores
	# are coherent with the pool's caches; a DMA fill is not against a
	# line a core holds dirty (the card's GOLS protocol serves a dirty
	# line to the engine without writing it back).
	movl SL_REFRESH_N(%rbx), %eax
	testl %eax, %eax
	jz 32f
	cmpl $512, %eax
	ja 32f
	pushq %r14
	pushq %r15
	movl %eax, %r14d			# ranges left
	movq %r12, %r15
	shlq $20, %r15
	addq $OFF_SLOTDATA, %r15
	addq window(%rip), %r15			# the slot data
	leaq SD_REFRESH(%r15), %rsi		# the bytes
	addq $SD_REFRESH_TAB, %r15		# the table
33:	movq 0(%r15), %rdi			# the address
	movq 8(%r15), %rdx			# the bytes, a multiple of 64
	pushq %rsi
	pushq %rdx
	shrq $6, %rdx
	call phi_copy64
	popq %rdx
	popq %rsi
	addq %rdx, %rsi
	addq $16, %r15
	decl %r14d
	jnz 33b
	popq %r15
	popq %r14
32:
	# the split: threads (the request's, at most this slot's pool plus
	# this thread), over [counter, bound) in steps of step; a step of 0
	# is one slice
	movl SL_THREADS(%rbx), %r14d
	testl %r14d, %r14d
	jnz 21f
	movl $1, %r14d
21:	movl nthreads(%rip), %eax
	incl %eax
	cmpl %eax, %r14d
	jbe 22f
	movl %eax, %r14d
22:	movq SL_STEP(%rbx), %rax
	movq %rax, fx_step(%rip)
	testq %rax, %rax
	jnz 23f
	movl $1, %r14d				# not split: the file runs as it is
	movq $0, fx_lo(%rip)
	movq $0, fx_hi(%rip)
	movq $0, fx_per(%rip)
	jmp 25f
23:	movl SL_IND_REG(%rbx), %eax
	andl $15, %eax
	movq %rax, fx_ind_reg(%rip)
	movq fx_base + REGS_GPR(,%rax,8), %rcx
	movq %rcx, fx_lo(%rip)
	movl SL_BOUND_REG(%rbx), %eax
	andl $15, %eax
	movq %rax, fx_bound_reg(%rip)
	movq fx_base + REGS_GPR(,%rax,8), %rdx
	movq %rdx, fx_hi(%rip)
	movq %rdx, %rax
	subq %rcx, %rax
	jg 24f
	movl $1, %r14d				# nothing to split
	xorl %eax, %eax
24:	xorl %edx, %edx
	divq %r14				# elements a slice, rounded up to a step
	addq fx_step(%rip), %rax
	decq %rax
	xorl %edx, %edx
	divq fx_step(%rip)
	imulq fx_step(%rip), %rax
	movq %rax, fx_per(%rip)
25:	movq $1, fx_in_run(%rip)
	call now_ns
	movq %rax, 8(%rsp)
	leaq fx_slice(%rip), %rdi
	xorl %esi, %esi
	movl %r14d, %edx
	cmpl $1, %r14d
	jne 241f
	movl $2, %edx				# one slice: on pool thread 0 (this thread's
						# core is the control plane's), the second empty
241:	call vpu_pool_map
	call now_ns
	subq 8(%rsp), %rax
	movq %rax, SR_RUN_NS(%r13)
	movq $0, fx_in_run(%rip)
	movq $0, %fs:TE_CTX
	# the exit: the first slice that did not return normally, else X_RET;
	# the file out is the last slice's (this thread's)
	movl $X_RET, SR_EXIT_KIND(%r13)
	xorl %ecx, %ecx
28:	cmpl %r14d, %ecx
	jae 27f
	movq %rcx, %rax
	imulq $CTX_BYTES, %rax, %rax
	leaq fx_ctx(%rip), %rdx
	addq %rax, %rdx
	cmpl $CTX_KIND_STUB, CTX_KIND(%rdx)
	je 26f
	movl CTX_KIND(%rdx), %eax
	movl %eax, SR_EXIT_KIND(%r13)
	movq CTX_REGS + REGS_RIP(%rdx), %rax
	movq %rax, SR_EXIT_RIP(%r13)
	movq CTX_FAULT(%rdx), %rax
	movq %rax, SR_EXIT_AUX(%r13)
	movl CTX_SIGINFO(%rdx), %eax
	movl %eax, SR_SIGINFO(%r13)
	jmp 27f
26:	incl %ecx
	jmp 28b
27:	leal -1(%r14d), %eax
	cmpq $0, fx_step(%rip)
	jne 271f
	xorl %eax, %eax				# not split: slice 0's file
271:	imulq $CTX_BYTES, %rax, %rsi
	leaq fx_ctx(%rip), %rax
	addq %rax, %rsi				# the last slice's context
	movq CTX_FLAGS_RAW(%rsi), %rax
	movq %rax, CTX_REGS + REGS_RFLAGS(%rsi)
	movq %r12, %rdi
	shlq $20, %rdi
	addq $OFF_SLOTDATA + SD_REGS_OUT, %rdi
	addq window(%rip), %rdi
	movl $REGS_BYTES / 64 + 1, %edx
	call phi_copy64
	movl %r14d, SR_THREADS_RAN(%r13)
	xorl %eax, %eax
	jmp 9f
.Lfr_request:
	movl $E_REQUEST, %eax
9:	addq $16, %rsp
	popq %r15
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

# fx_exit_jmp: a translated blob leaves through `jmp *%fs:FX_EXIT_TPOFF`
# with the exit's kind in the scratch's FX_S_KIND, the address the host
# resumes at in FX_S_SITE (a call site, a return address popped, a branch
# target) and an aux in FX_S_XFER (the callee, the target): the file as
# fx_ret_stub stores it, the kind as the context's, the aux as the fault
# address field, back to fexec_run.
	.if TLS_EXEC + 24 != FX_EXIT_TPOFF
	.error "FX_EXIT_TPOFF is not TLS_EXEC + 24"
	.endif
	.set TE_EXIT, TLS_EXEC + 24
fx_exit_jmp:
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
	movq %fs:FX_SCRATCH_TPOFF + FX_S_SITE, %rcx
	movq %rcx, REGS_RIP(%rax)
	movq %rcx, CTX_EXIT_RIP(%rax)
	movl %fs:FX_SCRATCH_TPOFF + FX_S_KIND, %ecx
	movl %ecx, CTX_KIND(%rax)
	movq %fs:FX_SCRATCH_TPOFF + FX_S_XFER, %rcx
	movq %rcx, CTX_FAULT(%rax)
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
	movl 0(%rsi), %ecx			# si_signo
	movl 8(%rsi), %eax			# si_code
	shll $8, %eax
	orl %eax, %ecx
	movq %fs:TE_CTX, %rax
	movl %ecx, CTX_SIGINFO(%rax)
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

# fx_slice(arg rdi, slice esi, nslices edx): one slice of the instance on
# this thread: its context is the landed file with the counter and bound
# registers at the slice's range, rip the entry, rsp this thread's own
# run stack with the return stub on top; then fx_enter. A slice past the
# end (fewer elements than slices) is marked returned and skipped.
fx_slice:
	pushq %rbx
	pushq %r12
	movl %esi, %r12d
	movq %r12, %rbx
	imulq $CTX_BYTES, %rbx, %rbx
	leaq fx_ctx(%rip), %rax
	addq %rax, %rbx				# this slice's context
	movq %rbx, %rdi
	leaq fx_base(%rip), %rsi
	movl $REGS_BYTES / 64 + 1, %edx
	call phi_copy64
	# the range: lo + s * per .. min(lo + (s + 1) * per, hi)
	movq fx_per(%rip), %rax
	imulq %r12, %rax
	addq fx_lo(%rip), %rax
	movq %rax, %rcx
	addq fx_per(%rip), %rcx
	cmpq fx_hi(%rip), %rcx
	jbe 1f
	movq fx_hi(%rip), %rcx
1:	movl $CTX_KIND_STUB, CTX_KIND(%rbx)
	cmpq $0, fx_step(%rip)
	jne 11f
	testl %r12d, %r12d
	jnz 9f					# not split: slice 0 runs the file as it is, the rest nothing
	jmp 2f
11:	cmpq %rcx, %rax
	jae 9f					# empty: nothing to run
	movq %rax, %r8
	movq %rcx, %r9
	movq fx_ind_reg(%rip), %rax
	movq %r8, CTX_REGS + REGS_GPR(%rbx,%rax,8)
	movq fx_bound_reg(%rip), %rax
	movq %r9, CTX_REGS + REGS_GPR(%rbx,%rax,8)
2:	movq fx_rip(%rip), %rax
	movq %rax, CTX_REGS + REGS_RIP(%rbx)
	testq $FXF_IDSTACK, fx_flags(%rip)
	jnz 21f					# the program's own stack: rsp as the file has it, the blob leaves through the exit stub
	movq %r12, %rax
	imulq $FX_STACK, %rax, %rax
	addq fx_stack(%rip), %rax
	addq $FX_STACK - 64, %rax
	leaq fx_ret_stub(%rip), %rcx
	movq %rcx, (%rax)
	movq %rax, CTX_REGS + REGS_GPR + 32(%rbx)
21:	movl $0, CTX_KIND(%rbx)
	movq $0, CTX_FAULT(%rbx)
	movl $0, CTX_SIGINFO(%rbx)
	movq %rbx, %fs:TE_CTX
	movq %rbx, %rdi
	call fx_enter
	movq $0, %fs:TE_CTX
9:	popq %r12
	popq %rbx
	ret
