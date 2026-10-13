# sched.S: protocol v3's slot processes (vpu_fexec.h, proto.inc). The
# dispatcher forks -S processes before its own pool exists; each takes -C
# cores (-T threads a core) and serves one slot of the window: the host
# thread owning the slot writes its request block and its u16 of the
# SLOTSEQ line, the dispatcher reads that line with one load per poll,
# hands a posted slot its job through the shared page (SH_*, defs.inc)
# and wakes it, and the slot process writes the reply into the slot with
# two 64-byte stores, the line holding the sequence number last. A
# request's floor is what this file costs: the poll, the hand-off and the
# reply. See sched.md.

	.include "defs.inc"
	.include "proto.inc"

	.bss
	.balign 64
slotseq_now:	.skip 64		# the SLOTSEQ line as just read
slreq:	.skip 64			# a posted slot's first request line
reply_buf:	.skip 128		# the reply built here, stored in two lines
sum_buf:	.skip 64			# the summed counters for OFF_STATS
meminfo_buf:	.skip 4096
stats_calls:	.skip 8
slot_posts:	.skip 4			# slots_poll: posts handed over this call
sched_last:	.skip 8			# the slot process: the job sequence last served
sched_t0:	.skip 8

	.section .rodata
s_meminfo:	.asciz "/proc/meminfo"
s_memfree:	.asciz "MemFree:"
s_sl_nowindow:	.asciz "slots: no direct mapping of the window, so no slot processes (-S 0)"
s_sl_fork:	.asciz "slots: fork failed"
s_sl_clamp:	.asciz "slots: more slot cores than the card has; slots reduced to "
s_sl_up1:	.asciz "slots: "
s_sl_up2:	.asciz " slot processes of "
s_sl_up3:	.asciz " core(s), "
s_sl_up4:	.asciz " thread(s) a core; the wide pool keeps "
s_sl_up5:	.asciz " core(s)"
s_sl_slot1:	.asciz "slot "
s_sl_slot2:	.asciz ": cores "
s_sl_slot3:	.asciz " to "
s_sl_slot4:	.asciz ", pool threads "
s_sl_slot5:	.asciz ", polling"
s_sl_post1:	.asciz "slot "
s_sl_post2:	.asciz " posted seq "
s_sl_post3:	.asciz " kind "
s_sl_job1:	.asciz "slot "
s_sl_job2:	.asciz ": job seq "
s_sl_job3:	.asciz " done, status "

	.text

# ---- the dispatcher's side ----

# slots_start: the shared page, the free-memory word, then one fork per
# slot; sets core_base and core_count for this process's own pool.
	.globl slots_start
slots_start:
	pushq %rbx
	pushq %r12
	pushq %r13
	cmpq $0, window(%rip)
	jne 1f
	leaq s_sl_nowindow(%rip), %rsi
	call say
	movl $0, nslots(%rip)
	jmp 9f
1:	xorl %edi, %edi
	movl $SH_BYTES, %esi
	movl $PROT_READ | PROT_WRITE, %edx
	movl $MAP_SHARED | MAP_ANONYMOUS, %r10d
	movq $-1, %r8
	xorl %r9d, %r9d
	SYS SYS_mmap
	cmpq $MAP_FAILED_MAX, %rax
	ja .Lslots_fork_fail
	movq %rax, shared(%rip)
	movq %rax, %rbx
	call meminfo_free
	movq %rax, SHG_FREE_BYTES(%rbx)
	# the SLOTSEQ line as it is now: a post left by an earlier worker's
	# run is not replayed
	leaq slotseq_seen(%rip), %rdi
	movq ctrl(%rip), %rsi
	addq $OFF_SLOTSEQ, %rsi
	movl $1, %edx
	call phi_copy64
	# the slots' cores: core 56 is the dispatcher's and stays out of them
	movl nslots(%rip), %r12d
	movl slot_cores(%rip), %eax
	imull %r12d, %eax
	cmpl $NCORES - 1, %eax
	jle 2f
	movl $NCORES - 1, %eax
	xorl %edx, %edx
	divl slot_cores(%rip)
	movl %eax, %r12d
	movl %eax, nslots(%rip)
	call l_begin
	leaq s_sl_clamp(%rip), %rsi
	call w_str
	movl %r12d, %edi
	call w_dec
	movl $1, %edi
	call l_end
2:	movl %r12d, SHG_NSLOTS(%rbx)
	xorl %r13d, %r13d			# s
3:	cmpl %r12d, %r13d
	jge 5f
	SYS SYS_fork
	testq %rax, %rax
	js .Lslots_fork_fail
	jnz 4f
	# the child: its slot, its cores, then its life
	movl %r13d, slot_index(%rip)
	movl slot_cores(%rip), %eax
	imull %r13d, %eax
	movl %eax, core_base(%rip)
	movl slot_cores(%rip), %eax
	movl %eax, core_count(%rip)
	movl %r13d, %edi
	jmp sched_main
4:	movq %r13, %rcx
	imulq $SH_SLOT_BYTES, %rcx, %rcx
	movq %rax, SH_SLOT0 + SH_PID(%rbx,%rcx)
	incl %r13d
	jmp 3b
5:	# this process's pool: the cores after the slots'
	movl slot_cores(%rip), %eax
	imull %r12d, %eax
	movl %eax, core_base(%rip)
	movl $NCORES, %ecx
	subl %eax, %ecx
	movl %ecx, core_count(%rip)
	call l_begin
	leaq s_sl_up1(%rip), %rsi
	call w_str
	movl %r12d, %edi
	call w_dec
	leaq s_sl_up2(%rip), %rsi
	call w_str
	movl slot_cores(%rip), %edi
	call w_dec
	leaq s_sl_up3(%rip), %rsi
	call w_str
	movl slot_tpc(%rip), %edi
	call w_dec
	leaq s_sl_up4(%rip), %rsi
	call w_str
	movl core_count(%rip), %edi
	call w_dec
	leaq s_sl_up5(%rip), %rsi
	call w_str
	movl $1, %edi
	call l_end
9:	popq %r13
	popq %r12
	popq %rbx
	ret
.Lslots_fork_fail:
	leaq s_sl_fork(%rip), %rsi
	jmp die

# slots_poll: the SLOTSEQ line read once; every slot whose u16 moved gets
# its job word written (the u16 widened) and its process woken when
# parked; eax the posts handed over. Clobbers the caller-saved registers;
# rbx is preserved (main_loop's ctrl).
	.globl slots_poll
slots_poll:
	pushq %rbx
	pushq %r12
	pushq %r13
	leaq slotseq_now(%rip), %rdi
	movq ctrl(%rip), %rsi
	addq $OFF_SLOTSEQ, %rsi
	movl $1, %edx
	call phi_copy64
	movl $0, slot_posts(%rip)
	xorl %r12d, %r12d			# s
1:	cmpl nslots(%rip), %r12d
	jge 9f
	leaq slotseq_now(%rip), %rax
	movzwl (%rax,%r12,2), %ecx
	leaq slotseq_seen(%rip), %rdx
	cmpw %cx, (%rdx,%r12,2)
	je 8f
	movw %cx, (%rdx,%r12,2)
	# the job word: the u16 widened (consecutive posts differ); the slot
	# reads its request block itself, on its own core
	movq shared(%rip), %r13
	movq %r12, %rax
	imulq $SH_SLOT_BYTES, %rax, %rax
	leaq SH_SLOT0(%r13,%rax), %r13		# the slot's block
	movq %rcx, SH_JOB_SEQ(%r13)
	FENCE
	incl slot_posts(%rip)
	cmpl $2, vpu_verbose(%rip)
	jl 7f
	call l_begin
	leaq s_sl_post1(%rip), %rsi
	call w_str
	movl %r12d, %edi
	call w_dec
	leaq s_sl_post2(%rip), %rsi
	call w_str
	movq SH_JOB_SEQ(%r13), %rdi
	call w_dec
	movl $1, %edi
	call l_end
7:	cmpl $0, SH_PARKED(%r13)
	je 8f
	leaq SH_JOB_SEQ(%r13), %rdi
	movl $FUTEX_WAKE, %esi
	movl $1, %edx
	xorl %r10d, %r10d
	SYS SYS_futex
8:	incl %r12d
	jmp 1b
9:	movl slot_posts(%rip), %eax
	popq %r13
	popq %r12
	popq %rbx
	ret

# slots_stats: the dispatcher's own counters plus every slot's, as one
# line at OFF_STATS (phitop reads it); the free-memory word refreshed
# every 2048 calls (about every fifth of a second of idle polling).
	.globl slots_stats
slots_stats:
	pushq %rbx
	pushq %r12
	pushq %r13
	incq stats_calls(%rip)
	testq $2047, stats_calls(%rip)
	jnz 1f
	call meminfo_free
	movq shared(%rip), %rcx
	movq %rax, SHG_FREE_BYTES(%rcx)
1:	leaq sum_buf(%rip), %rdi
	leaq stats(%rip), %rsi
	movl $1, %edx				# one line: ST_BYTES is 64
	call phi_copy64
	leaq sum_buf(%rip), %rbx
	movq shared(%rip), %r13
	xorl %r12d, %r12d
2:	cmpl nslots(%rip), %r12d
	jge 5f
	movq %r12, %rax
	imulq $SH_SLOT_BYTES, %rax, %rax
	leaq SH_SLOT0(%r13,%rax), %rcx
	movq SH_REQUESTS(%rcx), %rax
	addq %rax, ST_REQUESTS(%rbx)
	movq SH_ERRORS(%rcx), %rax
	addq %rax, ST_ERRORS(%rbx)
	movq SH_BUSY_NS(%rcx), %rax
	addq %rax, ST_BUSY_NS(%rbx)
	movq SH_RUN_NS(%rcx), %rax
	addq %rax, ST_COMPUTE_NS(%rbx)
	movq SH_FETCH_NS(%rcx), %rax
	addq %rax, ST_PULL_NS(%rbx)
	movq SH_WB_NS(%rcx), %rax
	addq %rax, ST_PUSH_NS(%rbx)
	movq SH_LAST_SEQ(%rcx), %rax
	cmpq ST_LAST_SEQ(%rbx), %rax
	jbe 4f
	movq %rax, ST_LAST_SEQ(%rbx)
	movl SH_LAST_KIND(%rcx), %eax
	movl %eax, ST_LAST_KERNEL(%rbx)
	movl SH_LAST_THREADS(%rcx), %eax
	movl %eax, ST_LAST_THREADS(%rbx)
4:	incl %r12d
	jmp 2b
5:	movq ctrl(%rip), %rdi
	addq $OFF_STATS, %rdi
	movq %rbx, %rsi
	movl $1, %edx
	call phi_copy64
	popq %r13
	popq %r12
	popq %rbx
	ret

# meminfo_free: MemFree of /proc/meminfo in bytes, in rax (0 when it
# cannot be read).
meminfo_free:
	pushq %rbx
	pushq %r12
	leaq s_meminfo(%rip), %rdi
	movl $O_RDONLY, %esi
	xorl %edx, %edx
	SYS SYS_open
	testq %rax, %rax
	js 9f
	movl %eax, %ebx
	movl %ebx, %edi
	leaq meminfo_buf(%rip), %rsi
	movl $4095, %edx
	SYS SYS_read
	movq %rax, %r12
	movl %ebx, %edi
	SYS SYS_close
	testq %r12, %r12
	jle 9f
	leaq meminfo_buf(%rip), %rax
	movb $0, (%rax,%r12)
	# the line "MemFree:" (8 bytes) then spaces then the number in kB
	leaq meminfo_buf(%rip), %rax
	subq $8, %r12
	jle 9f
	movabsq $0x3a656572466d654d, %rdx		# "MemFree:" little-endian
3:	cmpq %rdx, (%rax)
	je 4f
	incq %rax
	decq %r12
	jnz 3b
	jmp 9f
4:	addq $8, %rax
1:	movb (%rax), %cl
	cmpb $' ', %cl
	jne 2f
	incq %rax
	jmp 1b
2:	movq %rax, %rsi
	call parse_u64
	shlq $10, %rax
	popq %r12
	popq %rbx
	ret
9:	xorl %eax, %eax
	popq %r12
	popq %rbx
	ret

# ---- a slot process ----

# sched_main(slot edi): never returns. Pins itself to the last hardware
# thread of its first core, starts its pool over its cores, then serves
# its job line: wait (spin, then a futex park after spin_ns), run the
# kind, reply, count.
sched_main:
	movl %edi, %r12d
	# this thread: core core_base, hardware thread 3 (CPU 4 core + 4)
	leaq tls_blocks + MAX_POOL * TLS_BYTES(%rip), %rdi
	movl core_base(%rip), %eax
	movq %rax, TLS_CORE(%rdi)
	movq $3, TLS_MATE(%rdi)
	movl core_base(%rip), %edi
	shll $2, %edi
	addl $4, %edi
	call pin_cpu
	movl slot_cores(%rip), %edi
	imull slot_tpc(%rip), %edi
	call pool_start
	movq $0, sched_last(%rip)
	movq shared(%rip), %r13
	movq %r12, %rax
	imulq $SH_SLOT_BYTES, %rax, %rax
	leaq SH_SLOT0(%r13,%rax), %r13		# this slot's block
	movq %r12, %r14
	shlq $12, %r14
	addq window(%rip), %r14
	addq $OFF_SLOTS, %r14			# this slot in the window
	call l_begin
	leaq s_sl_slot1(%rip), %rsi
	call w_str
	movl %r12d, %edi
	call w_dec
	leaq s_sl_slot2(%rip), %rsi
	call w_str
	movl core_base(%rip), %edi
	call w_dec
	leaq s_sl_slot3(%rip), %rsi
	call w_str
	movl core_base(%rip), %edi
	addl core_count(%rip), %edi
	decl %edi
	call w_dec
	leaq s_sl_slot4(%rip), %rsi
	call w_str
	movl nthreads(%rip), %edi
	call w_dec
	leaq s_sl_slot5(%rip), %rsi
	call w_str
	movl $1, %edi
	call l_end
.Lsched_loop:
	call sched_wait			# the job word moved
	call now_ns
	movq %rax, sched_t0(%rip)
	# the request's first line, read here on this core: seq, kind, flags,
	# fn_id, entry, threads, nstripes
	leaq slreq(%rip), %rdi
	movq %r14, %rsi
	movl $1, %edx
	call phi_copy64
	movq slreq + SL_SEQ(%rip), %r15
	movl slreq + SL_KIND(%rip), %eax
	movl %eax, SH_JOB_KIND(%r13)
	# the reply, built aside: status by kind
	leaq reply_buf(%rip), %rdi
	movl $16, %ecx
	xorl %eax, %eax
	rep stosq				# 128 bytes: both lines
	movl SH_JOB_KIND(%r13), %eax
	cmpl $K_PING, %eax
	je 1f
	movl $E_KERNEL, reply_buf + SR_STATUS(%rip)
1:	movq shared(%rip), %rcx
	movq SHG_FREE_BYTES(%rcx), %rax
	movq %rax, reply_buf + SR_FREE_BYTES(%rip)
	movl nthreads(%rip), %eax
	movl %eax, reply_buf + SR_THREADS_RAN(%rip)
	call now_ns
	subq sched_t0(%rip), %rax
	movq %rax, reply_buf + SR_TOTAL_NS(%rip)
	movq %r15, reply_buf + SR_SEQ(%rip)
	# the second line first, then the line with the sequence number
	leaq SLOT_REPLY + 64(%r14), %rdi
	leaq reply_buf + 64(%rip), %rsi
	movl $1, %edx
	call phi_copy64
	FENCE
	leaq SLOT_REPLY(%r14), %rdi
	leaq reply_buf(%rip), %rsi
	movl $1, %edx
	call phi_copy64
	# the counters, then the done word
	incq SH_REQUESTS(%r13)
	cmpl $0, reply_buf + SR_STATUS(%rip)
	je 2f
	incq SH_ERRORS(%r13)
2:	movq reply_buf + SR_TOTAL_NS(%rip), %rax
	addq %rax, SH_BUSY_NS(%r13)
	movq reply_buf + SR_RUN_NS(%rip), %rax
	addq %rax, SH_RUN_NS(%r13)
	movq reply_buf + SR_FETCH_NS(%rip), %rax
	addq %rax, SH_FETCH_NS(%r13)
	movq reply_buf + SR_WB_NS(%rip), %rax
	addq %rax, SH_WB_NS(%r13)
	movl SH_JOB_KIND(%r13), %eax
	movl %eax, SH_LAST_KIND(%r13)
	movl nthreads(%rip), %eax
	movl %eax, SH_LAST_THREADS(%r13)
	movq %r15, SH_LAST_SEQ(%r13)
	FENCE
	movq %r15, SH_DONE_SEQ(%r13)
	cmpl $2, vpu_verbose(%rip)
	jl .Lsched_loop
	call l_begin
	leaq s_sl_job1(%rip), %rsi
	call w_str
	movl %r12d, %edi
	call w_dec
	leaq s_sl_job2(%rip), %rsi
	call w_str
	movq %r15, %rdi
	call w_dec
	leaq s_sl_job3(%rip), %rsi
	call w_str
	movl reply_buf + SR_STATUS(%rip), %edi
	call w_sdec
	movl $1, %edi
	call l_end
	jmp .Lsched_loop

# sched_wait: until the job sequence number moves past sched_last; the
# new number in rax and in sched_last. Spins SPIN_ROUNDS looks with
# `delay` between them, parks in a futex on the word after spin_ns.
sched_wait:
	pushq %rbx
	call now_ns
	movq %rax, %rbx				# since
1:	movl $SPIN_ROUNDS, %ecx
2:	movq SH_JOB_SEQ(%r13), %rax
	cmpq sched_last(%rip), %rax
	jne 9f
	pushq %rcx
	movl $WAIT_DELAY, %eax
	DELAY_EAX
	popq %rcx
	decl %ecx
	jnz 2b
	call now_ns
	subq %rbx, %rax
	cmpq spin_ns(%rip), %rax
	jb 1b
	movl $1, SH_PARKED(%r13)
	FENCE
	movq SH_JOB_SEQ(%r13), %rax
	cmpq sched_last(%rip), %rax
	jne 8f
	leaq SH_JOB_SEQ(%r13), %rdi
	movl $FUTEX_WAIT, %esi
	movl sched_last(%rip), %edx		# the word's low half, as the futex sees it
	xorl %r10d, %r10d
	SYS SYS_futex
8:	movl $0, SH_PARKED(%r13)
	call now_ns
	movq %rax, %rbx
	jmp 1b
9:	movq %rax, sched_last(%rip)
	popq %rbx
	ret

