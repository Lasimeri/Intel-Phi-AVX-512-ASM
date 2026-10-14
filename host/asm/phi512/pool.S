# pool.S: the host's worker threads for the region path, 16 per card
# (PHI512_CARDS): the per-unit work of a region (the refresh's reads of
# the program's memory and the compares against the shadows) split over
# the card's group instead of one thread doing every unit in turn (that
# thread, llama-server's main thread in its SIGILL handler, sat at 100 %
# of a core, 41 % of it re-reading /proc/self/maps and 32 % in the
# kernel's reads of /proc/self/mem, 2026-10-14). The library has no libc:
# the workers are raw clone threads (CLONE_VM | FS | FILES | SIGHAND |
# THREAD | SYSVSEM, a 256 KiB mmap'd stack each) made at the first region
# (inside the SIGILL handler, where pthread_create would not be
# async-signal-safe), every signal blocked in them, running only this
# library's code and system calls; a process forked after them (the pid
# differs) runs its jobs inline. See pool.md.
	.include "common.inc"
	.include "defs.inc"

	.set POOL_PER_CARD, 16
	.set POOL_GROUPS, 4
	.set POOL_STACK, 262144
	.set POOL_STAGE, 65536			# a worker's buffer (a unit)
	.set SYS_clone, 56
	.set SYS_futex, 202
	.set SYS_getpid_n, 39
	.set SYS_rt_sigprocmask_n, 14
	.set FUTEX_WAIT_PRIV, 128
	.set FUTEX_WAKE_PRIV, 129
	.set CLONE_FLAGS, 0x50f00		# VM | FS | FILES | SIGHAND | THREAD | SYSVSEM
	# a group's job block, a line each field
	.set PG_GEN, 0				# u32: the job's generation (the futex word)
	.set PG_NEXT, 64			# u64: the next item
	.set PG_DONE, 128			# u64: the items done
	.set PG_IDLE, 192			# u64: the workers back from the job
	.set PG_N, 256				# u64: the items
	.set PG_FN, 264				# fn(item rdi, buffer rsi)
	.set PG_BYTES, 320

	.bss
	.balign 64
pool_groups:	.skip POOL_GROUPS * PG_BYTES
pool_workers:	.skip 8			# per group (0: no pool, jobs inline)
pool_pid:	.skip 8
pool_oldmask:	.skip 8			# the creating thread's mask during pool_start
pool_bufs:	.skip 8			# (POOL_GROUPS * POOL_PER_CARD + 1) buffers of POOL_STAGE: the last is the caller's
	.text

# pool_start(groups edi): POOL_PER_CARD workers for each of the first
# groups (at most POOL_GROUPS), once per process; eax the workers per
# group (0 when none could be made: jobs run inline).
	.globl pool_start
pool_start:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movl %edi, %r14d
	cmpl $POOL_GROUPS, %r14d
	jbe 1f
	movl $POOL_GROUPS, %r14d
1:	movl $SYS_getpid_n, %eax
	syscall
	movq %rax, %r15
	cmpq $0, pool_workers(%rip)
	je 2f
	cmpq pool_pid(%rip), %r15
	je 8f					# made already in this process
	movq $0, pool_workers(%rip)		# a fork's child: none of its parent's threads came along
2:	testl %r14d, %r14d
	jz 9f
	# the buffers
	xorl %edi, %edi
	movq $(POOL_GROUPS * POOL_PER_CARD + 1) * POOL_STAGE, %rsi
	movl $PROT_READ | PROT_WRITE, %edx
	movl $MAP_PRIVATE | MAP_ANONYMOUS, %r10d
	movq $-1, %r8
	xorl %r9d, %r9d
	movl $SYS_mmap, %eax
	syscall
	cmpq $MAP_FAILED_MAX, %rax
	ja 9f
	movq %rax, pool_bufs(%rip)
	# every signal blocked around the clones: a worker starts with this
	# thread's mask, so none can take a signal before it blocks them itself
	subq $16, %rsp
	movq $-1, (%rsp)
	movl $2, %edi				# SIG_SETMASK
	movq %rsp, %rsi
	leaq pool_oldmask(%rip), %rdx
	movl $8, %r10d
	movl $SYS_rt_sigprocmask_n, %eax
	syscall
	addq $16, %rsp
	# the workers: group g, index k -> worker number g * POOL_PER_CARD + k
	xorl %ebx, %ebx				# worker number
3:	movl %r14d, %eax
	imull $POOL_PER_CARD, %eax
	cmpl %eax, %ebx
	jae 7f
	xorl %edi, %edi
	movl $POOL_STACK, %esi
	movl $PROT_READ | PROT_WRITE, %edx
	movl $MAP_PRIVATE | MAP_ANONYMOUS, %r10d
	movq $-1, %r8
	xorl %r9d, %r9d
	movl $SYS_mmap, %eax
	syscall
	cmpq $MAP_FAILED_MAX, %rax
	ja 91f
	leaq POOL_STACK - 16(%rax), %rsi	# the child's stack: its worker number on top
	movq %rbx, (%rsi)
	movl $CLONE_FLAGS, %edi
	xorl %edx, %edx
	xorl %r10d, %r10d
	xorl %r8d, %r8d
	movl $SYS_clone, %eax
	syscall
	testq %rax, %rax
	jz .Lpool_child				# the child, on its own stack
	js 91f
	incl %ebx
	jmp 3b
7:	movq %r15, pool_pid(%rip)
	movq $POOL_PER_CARD, pool_workers(%rip)
	movl $2, %edi				# this thread's mask back
	leaq pool_oldmask(%rip), %rsi
	xorl %edx, %edx
	movl $8, %r10d
	movl $SYS_rt_sigprocmask_n, %eax
	syscall
8:	movq pool_workers(%rip), %rax
	jmp 10f
9:	xorl %eax, %eax
	jmp 10f
91:	movl $2, %edi				# a failure after the block: this thread's mask back first
	leaq pool_oldmask(%rip), %rsi
	xorl %edx, %edx
	movl $8, %r10d
	movl $SYS_rt_sigprocmask_n, %eax
	syscall
	xorl %eax, %eax
10:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
.Lpool_child:
	popq %rdi				# the worker number
	andq $-16, %rsp
	call pool_worker
	movl $SYS_exit, %eax			# (never: the worker loops)
	xorl %edi, %edi
	syscall

# pool_worker(number rdi): every signal blocked; then for each job of
# its group (a new generation): items taken by lock xadd until none is
# left, each run as fn(item, this worker's buffer) and counted done; the
# worker counted idle, then asleep on the generation word.
pool_worker:
	movq %rdi, %r12				# the worker number
	subq $16, %rsp
	movq $-1, (%rsp)			# the set: every signal
	xorl %edi, %edi				# SIG_BLOCK
	movq %rsp, %rsi
	xorl %edx, %edx
	movl $8, %r10d
	movl $SYS_rt_sigprocmask_n, %eax
	syscall
	addq $16, %rsp
	movq %r12, %rax
	xorl %edx, %edx
	movl $POOL_PER_CARD, %ecx
	divq %rcx				# the group
	imulq $PG_BYTES, %rax, %rax
	leaq pool_groups(%rip), %r13
	addq %rax, %r13				# its job block
	movq %r12, %r14
	imulq $POOL_STAGE, %r14, %r14
	addq pool_bufs(%rip), %r14		# this worker's buffer
	xorl %r15d, %r15d			# the generation seen
1:	movl PG_GEN(%r13), %eax
	cmpl %r15d, %eax
	jne 2f
	leaq PG_GEN(%r13), %rdi			# asleep until the generation moves
	movl $FUTEX_WAIT_PRIV, %esi
	movl %r15d, %edx
	xorl %r10d, %r10d
	movl $SYS_futex, %eax
	syscall
	jmp 1b
2:	movl %eax, %r15d
3:	movl $1, %eax
	lock xaddq %rax, PG_NEXT(%r13)
	cmpq PG_N(%r13), %rax
	jae 4f
	movq %rax, %rdi
	movq %r14, %rsi
	call *PG_FN(%r13)
	lock incq PG_DONE(%r13)
	jmp 3b
4:	lock incq PG_IDLE(%r13)
	jmp 1b

# pool_run(group edi, fn rsi, items rdx): fn(item, a buffer) for every
# item, over the group's workers and this thread; back when every item
# is done and every worker of the group has left the job (so no worker
# of this job can take an item of the next). Without workers (none made,
# or a forked child) the items run here.
	.globl pool_run
pool_run:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rsi, %r12				# fn
	movq %rdx, %r14				# items
	movl %edi, %eax
	imulq $PG_BYTES, %rax, %rax
	leaq pool_groups(%rip), %r13
	addq %rax, %r13
	cmpq $0, pool_workers(%rip)
	je .Lpr_inline
	movl $SYS_getpid_n, %eax
	syscall
	cmpq pool_pid(%rip), %rax
	jne .Lpr_inline
	movq pool_bufs(%rip), %r15
	addq $POOL_GROUPS * POOL_PER_CARD * POOL_STAGE, %r15	# this thread's buffer
	movq %r12, PG_FN(%r13)
	movq %r14, PG_N(%r13)
	movq $0, PG_DONE(%r13)
	movq $0, PG_IDLE(%r13)
	movq $0, PG_NEXT(%r13)
	lock incl PG_GEN(%r13)
	leaq PG_GEN(%r13), %rdi
	movl $FUTEX_WAKE_PRIV, %esi
	movl $0x7fffffff, %edx
	movl $SYS_futex, %eax
	syscall
1:	movl $1, %eax
	lock xaddq %rax, PG_NEXT(%r13)
	cmpq %r14, %rax
	jae 2f
	movq %rax, %rdi
	movq %r15, %rsi
	call *%r12
	lock incq PG_DONE(%r13)
	jmp 1b
2:	cmpq %r14, PG_DONE(%r13)
	jae 3f
	pause
	jmp 2b
3:	cmpq $POOL_PER_CARD, PG_IDLE(%r13)
	jae 9f
	pause
	jmp 3b
.Lpr_inline:
	xorl %ebx, %ebx
4:	cmpq %r14, %rbx
	jae 9f
	movq %rbx, %rdi
	leaq pool_inline_buf(%rip), %rsi
	call *%r12
	incq %rbx
	jmp 4b
9:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

	.bss
	.balign 64
pool_inline_buf:	.skip POOL_STAGE
	.section .note.GNU-stack,"",@progbits
