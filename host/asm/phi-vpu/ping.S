# ping.S: phi-vpu-ping, the floor of a protocol v3 request measured from
# the host: S threads, each owning a slot of a card's window, post N
# K_PING requests one after another and time each from the SLOTSEQ store
# to the reply's sequence number; the samples go into a histogram of
# microsecond bins and the program prints min, median, p99 and max, per
# slot and over all. No libc: the common modules (host/asm/common) and
# raw system calls. See ping.md.
#
#   phi-vpu-ping [--card N] [-n COUNT] [--slots S] [--timeout MS]

	.include "common.inc"
	.include "proto.inc"

	.set MAX_THREADS, 32
	.set BINS, 100000			# 1 us bins up to 100 ms
	.set T_STACK, 1048576
	.set SYS_clone, 56
	.set SYS_futex, 202
	.set SYS_exit, 60
	.set CLONE_VM, 0x100
	.set CLONE_FS, 0x200
	.set CLONE_FILES, 0x400
	.set CLONE_SIGHAND, 0x800
	.set CLONE_THREAD, 0x10000
	.set CLONE_SYSVSEM, 0x40000
	.set CLONE_FLAGS, CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD | CLONE_SYSVSEM
	.set FUTEX_WAIT, 0
	.set FUTEX_WAKE, 1
# a thread's record: slot, count done, min, max, sum, timeouts, histogram
	.set TR_SLOT, 0
	.set TR_DONE, 8
	.set TR_MIN, 16
	.set TR_MAX, 24
	.set TR_SUM, 32
	.set TR_TIMEOUTS, 40
	.set TR_HIST, 64
	.set TR_BYTES, 64 + BINS * 4

	.bss
	.balign 64
card:	.skip 8
count:	.skip 8
nslots_opt:	.skip 8
timeout_ns:	.skip 8
base:	.skip 8
finished:	.skip 4			# threads done (the futex word)
	.balign 64
recs:	.skip MAX_THREADS * TR_BYTES
total_hist:	.skip BINS * 4
total_rec:	.skip 64

	.section .rodata
s_card:	.asciz "--card"
s_c:	.asciz "-c"
s_n:	.asciz "-n"
s_slots:	.asciz "--slots"
s_timeout:	.asciz "--timeout"
s_usage:	.asciz "usage: phi-vpu-ping [--card N] [-n COUNT] [--slots S] [--timeout MS]"
s_nowindow:	.asciz "phi-vpu-ping: no window for the card (is the card up?)"
s_notready:	.asciz "phi-vpu-ping: no worker polling on the card"
s_thread:	.asciz "phi-vpu-ping: could not create a thread"
s_head1:	.asciz "ping: "
s_head2:	.asciz " x "
s_head3:	.asciz " slots on card "
s_slot:	.asciz "slot "
s_all:	.asciz "all slots"
s_sep:	.asciz ": "
s_min:	.asciz " min "
s_med:	.asciz " median "
s_p99:	.asciz " p99 "
s_max:	.asciz " max "
s_us:	.asciz " us"
s_mean:	.asciz " mean "
s_to:	.asciz ", timeouts "
s_done:	.asciz " done"

	.text
	.globl _start
_start:
	movq $1000, count(%rip)
	movq $1, nslots_opt(%rip)
	movq $1000000000, timeout_ns(%rip)
	movq (%rsp), %r12
	leaq 16(%rsp), %rbx
	decq %r12
1:	testq %r12, %r12
	jle 9f
	movq (%rbx), %rsi
	leaq s_card(%rip), %rdi
	call str_eq
	testl %eax, %eax
	jnz 2f
	movq (%rbx), %rsi
	leaq s_c(%rip), %rdi
	call str_eq
	testl %eax, %eax
	jz 3f
2:	call opt_value
	movq %rax, card(%rip)
	jmp 8f
3:	movq (%rbx), %rsi
	leaq s_n(%rip), %rdi
	call str_eq
	testl %eax, %eax
	jz 4f
	call opt_value
	movq %rax, count(%rip)
	jmp 8f
4:	movq (%rbx), %rsi
	leaq s_slots(%rip), %rdi
	call str_eq
	testl %eax, %eax
	jz 5f
	call opt_value
	cmpq $MAX_THREADS, %rax
	jbe 41f
	movq $MAX_THREADS, %rax
41:	testq %rax, %rax
	jnz 42f
	movl $1, %eax
42:	movq %rax, nslots_opt(%rip)
	jmp 8f
5:	movq (%rbx), %rsi
	leaq s_timeout(%rip), %rdi
	call str_eq
	testl %eax, %eax
	jz 7f
	call opt_value
	imulq $1000000, %rax, %rax
	movq %rax, timeout_ns(%rip)
	jmp 8f
7:	leaq s_usage(%rip), %rsi
	call say
	movl $2, %edi
	SYS SYS_exit_group
8:	addq $8, %rbx
	decq %r12
	jmp 1b
9:	# the window: the control words and the slots lie in its first 1 MiB
	movq card(%rip), %rdi
	movq $OFF_SLOTS + NSLOTS * SLOT_BYTES, %rsi
	call window_open
	testq %rax, %rax
	jz .Lno_window
	movq %rax, base(%rip)
	movq %rax, %rdi
	movq $2000000000, %rsi
	call wait_ready
	testl %eax, %eax
	jz .Lnot_ready
	# the threads, one per slot
	xorl %ebx, %ebx
1:	cmpq nslots_opt(%rip), %rbx
	jae 2f
	movq %rbx, %rdi
	call start_thread
	incq %rbx
	jmp 1b
2:	# wait for them all
3:	movl finished(%rip), %eax
	cmpq nslots_opt(%rip), %rax
	jae 4f
	leaq finished(%rip), %rdi
	movl $FUTEX_WAIT, %esi
	movl %eax, %edx
	xorl %r10d, %r10d
	SYS SYS_futex
	jmp 3b
4:	call report
	xorl %edi, %edi
	SYS SYS_exit_group

.Lno_window:
	leaq s_nowindow(%rip), %rsi
	call say
	movl $1, %edi
	SYS SYS_exit_group
.Lnot_ready:
	leaq s_notready(%rip), %rsi
	call say
	movl $1, %edi
	SYS SYS_exit_group

# opt_value: the number after the option at (rbx); advances rbx and r12.
opt_value:
	cmpq $2, %r12
	jl 1f
	addq $8, %rbx
	decq %r12
	movq (%rbx), %rsi
	call parse_u64
	ret
1:	xorl %eax, %eax
	ret

# start_thread(slot rdi): a stack, then clone into ping_thread with the
# slot's record in r12.
start_thread:
	pushq %rbx
	pushq %r12
	movq %rdi, %r12
	xorl %edi, %edi
	movl $T_STACK, %esi
	movl $PROT_READ | PROT_WRITE, %edx
	movl $MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, %r10d
	movq $-1, %r8
	xorl %r9d, %r9d
	SYS SYS_mmap
	cmpq $MAP_FAILED_MAX, %rax
	ja 9f
	leaq T_STACK(%rax), %rsi
	movq %r12, -8(%rsi)			# the slot, at the new stack's top
	subq $8, %rsi
	movl $CLONE_FLAGS, %edi
	xorl %edx, %edx
	xorl %r10d, %r10d
	xorl %r8d, %r8d
	SYS SYS_clone
	testq %rax, %rax
	jz ping_thread
	js 9f
	popq %r12
	popq %rbx
	ret
9:	leaq s_thread(%rip), %rsi
	call say
	movl $1, %edi
	SYS SYS_exit_group

# ping_thread: on its own stack, the slot at (rsp). count requests,
# each timed; then finished++ and a wake.
ping_thread:
	movq (%rsp), %r12			# slot
	movq %r12, %rax
	imulq $TR_BYTES, %rax, %rax
	leaq recs(%rip), %r13
	addq %rax, %r13				# the record
	movq %r12, TR_SLOT(%r13)
	movq $-1, TR_MIN(%r13)
	movq base(%rip), %r14
	movq %r12, %rax
	shlq $12, %rax
	leaq OFF_SLOTS(%r14,%rax), %r15		# the slot in the window
	xorl %ebx, %ebx				# seq
1:	cmpq count(%rip), %rbx
	jae 8f
	incq %rbx
	# the request: kind, then seq, a fence, then the u16 doorbell
	movl $K_PING, SL_KIND(%r15)
	movl $0, SL_FLAGS(%r15)
	movq %rbx, SL_SEQ(%r15)
	FENCE
	call now_ns
	pushq %rax				# t0 (now_ns clobbers the caller-saved registers)
	movw %bx, OFF_SLOTSEQ(%r14,%r12,2)
	FENCE
2:	cmpq SLOT_REPLY + SR_SEQ(%r15), %rbx
	je 3f
	pause
	call now_ns
	subq (%rsp), %rax
	cmpq timeout_ns(%rip), %rax
	jb 2b
	addq $8, %rsp
	incq TR_TIMEOUTS(%r13)
	jmp 1b
3:	call now_ns
	popq %rcx
	subq %rcx, %rax				# ns
	incq TR_DONE(%r13)
	addq %rax, TR_SUM(%r13)
	cmpq TR_MIN(%r13), %rax
	jae 4f
	movq %rax, TR_MIN(%r13)
4:	cmpq TR_MAX(%r13), %rax
	jbe 5f
	movq %rax, TR_MAX(%r13)
5:	xorl %edx, %edx
	movl $1000, %ecx
	divq %rcx				# us
	cmpq $BINS - 1, %rax
	jb 6f
	movq $BINS - 1, %rax
6:	incl TR_HIST(%r13,%rax,4)
	jmp 1b
8:	lock incl finished(%rip)
	leaq finished(%rip), %rdi
	movl $FUTEX_WAKE, %esi
	movl $1, %edx
	xorl %r10d, %r10d
	SYS SYS_futex
	xorl %edi, %edi
	SYS SYS_exit

# report: a line per slot and one over all slots.
report:
	pushq %rbx
	pushq %r12
	call l_begin
	leaq s_head1(%rip), %rsi
	call w_str
	movq count(%rip), %rdi
	call w_dec
	leaq s_head2(%rip), %rsi
	call w_str
	movq nslots_opt(%rip), %rdi
	call w_dec
	leaq s_head3(%rip), %rsi
	call w_str
	movq card(%rip), %rdi
	call w_dec
	movl $1, %edi
	call l_end
	# the total record: sums and the merged histogram
	leaq total_rec(%rip), %rdi
	movq $-1, TR_MIN(%rdi)
	xorl %ebx, %ebx
1:	cmpq nslots_opt(%rip), %rbx
	jae 5f
	movq %rbx, %rax
	imulq $TR_BYTES, %rax, %rax
	leaq recs(%rip), %r12
	addq %rax, %r12
	movq %r12, %rdi
	leaq TR_HIST(%r12), %rsi
	call report_one
	leaq total_rec(%rip), %rdi
	movq TR_DONE(%r12), %rax
	addq %rax, TR_DONE(%rdi)
	movq TR_SUM(%r12), %rax
	addq %rax, TR_SUM(%rdi)
	movq TR_TIMEOUTS(%r12), %rax
	addq %rax, TR_TIMEOUTS(%rdi)
	movq TR_MIN(%r12), %rax
	cmpq TR_MIN(%rdi), %rax
	jae 2f
	movq %rax, TR_MIN(%rdi)
2:	movq TR_MAX(%r12), %rax
	cmpq TR_MAX(%rdi), %rax
	jbe 3f
	movq %rax, TR_MAX(%rdi)
3:	xorl %ecx, %ecx
	leaq total_hist(%rip), %rdx
4:	cmpl $BINS, %ecx
	jae 41f
	movl TR_HIST(%r12,%rcx,4), %eax
	addl %eax, (%rdx,%rcx,4)
	incl %ecx
	jmp 4b
41:	incq %rbx
	jmp 1b
5:	leaq total_rec(%rip), %rdi
	movq $-1, TR_SLOT(%rdi)
	leaq total_hist(%rip), %rsi
	call report_one
	popq %r12
	popq %rbx
	ret

# report_one(record rdi, histogram rsi): one line.
report_one:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	movq %rdi, %rbx
	movq %rsi, %r12
	call l_begin
	cmpq $-1, TR_SLOT(%rbx)
	je 1f
	leaq s_slot(%rip), %rsi
	call w_str
	movq TR_SLOT(%rbx), %rdi
	call w_dec
	jmp 2f
1:	leaq s_all(%rip), %rsi
	call w_str
2:	leaq s_sep(%rip), %rsi
	call w_str
	movq TR_DONE(%rbx), %rdi
	call w_dec
	leaq s_done(%rip), %rsi
	call w_str
	leaq s_min(%rip), %rsi
	call w_str
	movq TR_MIN(%rbx), %rdi
	call w_us
	leaq s_med(%rip), %rsi
	call w_str
	movq TR_DONE(%rbx), %rdi
	shrq $1, %rdi
	movq %r12, %rsi
	call percentile
	movq %rax, %rdi
	call w_bin_us
	leaq s_p99(%rip), %rsi
	call w_str
	movq TR_DONE(%rbx), %rax
	imulq $99, %rax, %rax
	xorl %edx, %edx
	movl $100, %ecx
	divq %rcx
	movq %rax, %rdi
	movq %r12, %rsi
	call percentile
	movq %rax, %rdi
	call w_bin_us
	leaq s_max(%rip), %rsi
	call w_str
	movq TR_MAX(%rbx), %rdi
	call w_us
	leaq s_mean(%rip), %rsi
	call w_str
	movq TR_DONE(%rbx), %rcx
	testq %rcx, %rcx
	jz 3f
	movq TR_SUM(%rbx), %rax
	xorl %edx, %edx
	divq %rcx
	movq %rax, %rdi
	call w_us
3:	leaq s_to(%rip), %rsi
	call w_str
	movq TR_TIMEOUTS(%rbx), %rdi
	call w_dec
	movl $1, %edi
	call l_end
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# percentile(rank rdi, histogram rsi): the bin holding the rank-th sample
# (0-based), in rax.
percentile:
	xorl %eax, %eax
	xorl %ecx, %ecx
1:	cmpl $BINS, %eax
	jae 2f
	movl (%rsi,%rax,4), %edx
	addq %rdx, %rcx
	cmpq %rdi, %rcx
	ja 2f
	incl %eax
	jmp 1b
2:	ret

# w_us(ns rdi): "N.d us" with one decimal of a microsecond.
w_us:
	pushq %rbx
	movq %rdi, %rax
	xorl %edx, %edx
	movl $100, %ecx
	divq %rcx				# tenths of a microsecond
	movq %rax, %rbx
	xorl %edx, %edx
	movl $10, %ecx
	divq %rcx
	movq %rdx, %rbx
	movq %rax, %rdi
	call w_dec
	movb $'.', %al
	call w_byte
	leal '0'(%rbx), %eax
	call w_byte
	leaq s_us(%rip), %rsi
	call w_str
	popq %rbx
	ret

# w_bin_us(bin rdi): "N us" (a histogram bin is a whole microsecond).
w_bin_us:
	call w_dec
	leaq s_us(%rip), %rsi
	call w_str
	ret
