# resident.S: phi-vpu-resident, a function over the program's memory made
# resident on the card: two chunks of 2 MiB staged in the window and made
# resident at two program addresses with K_RESIDENT, a five-instruction
# blob loaded with K_LOAD that reads the first and writes the second, run
# -n times with K_FEXEC with one write-back range, each run's register
# file and write-back line checked. See resident.md.
#
#   phi-vpu-resident [--card N] [--slot S] [-n COUNT]

	.include "common.inc"
	.include "proto.inc"
	.include "mvex.inc"

	.set SYS_exit, 60
	.set FX_LOAD_PER_SLOT, 512 * 1024
	.set CHUNK, 2097152
	.set ADDR_A, 0x7e0000000000
	.set ADDR_B, 0x7e0000200000

	.bss
	.balign 64
card:	.skip 8
slot:	.skip 8
count:	.skip 8
base:	.skip 8
slotp:	.skip 8
datap:	.skip 8
seq:	.skip 8
min_ns:	.skip 8
max_ns:	.skip 8
fails:	.skip 8
	.balign 64
hist:	.skip 100000 * 4

	.section .rodata
	.balign 64
blob:
	VMOVAPS 0, 7, 0				# zmm0 <- [rdi]
	.byte 0x62, 0xf1, 0x78, 0x08, 0x58, 0xc0	# vaddps zmm0, zmm0, zmm0 (MVEX)
	VMOVAPS_ST 6, 0, 0			# [rsi] <- zmm0
	.byte 0x48, 0x8b, 0x87, 0x00, 0x10, 0x00, 0x00	# mov rax, [rdi + 4096]
	.byte 0xc3
blob_end:
s_card:	.asciz "--card"
s_c:	.asciz "-c"
s_slot:	.asciz "--slot"
s_n:	.asciz "-n"
s_usage:	.asciz "usage: phi-vpu-resident [--card N] [--slot S] [-n COUNT]"
s_nowindow:	.asciz "phi-vpu-resident: no window for the card"
s_notready:	.asciz "phi-vpu-resident: no worker polling on the card"
s_fail_req:	.asciz "phi-vpu-resident: a request failed: kind "
s_fail_st:	.asciz " status "
s_res1:	.asciz "resident: chunk at "
s_res2:	.asciz " is pool page "
s_res3:	.asciz " after "
s_us:	.asciz " us"
s_loaded:	.asciz "resident: blob loaded at card address "
s_bad:	.asciz "resident: WRONG result at run "
s_bad2:	.asciz ": rax "
s_bad3:	.asciz " lane15 "
s_bad4:	.asciz " wb lane15 "
s_bad5:	.asciz " exit "
s_bad6:	.asciz " wb_n "
s_r1:	.asciz "resident: "
s_r2:	.asciz " runs on slot "
s_r3:	.asciz " of card "
s_r4:	.asciz ": min "
s_r5:	.asciz " us median "
s_r6:	.asciz " us p99 "
s_r7:	.asciz " us max "
s_r8:	.asciz " us, wrong results "
s_pass:	.asciz "resident: PASS, every run read the resident chunk, wrote the other and sent the line back"
s_failed:	.asciz "resident: FAIL"

	.text

# open_slot(slot rdi): the slot's u16 to 0 (the dispatcher takes a 0 as
# no job) and its stale reply sequence number to 0, so a program whose
# numbers start again at 1 is seen as new; then a millisecond for the
# dispatcher to record the 0.
open_slot:
	movq base(%rip), %rax
	movw $0, OFF_SLOTSEQ(%rax,%rdi,2)
	shlq $12, %rdi
	movq $0, OFF_SLOTS + SLOT_REPLY + SR_SEQ(%rax,%rdi)
	FENCE
	movl $1000000, %edi
	call sleep_ns
	ret

	.globl _start
_start:
	movq $1000, count(%rip)
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
	leaq s_slot(%rip), %rdi
	call str_eq
	testl %eax, %eax
	jz 4f
	call opt_value
	cmpq $NSLOTS, %rax
	jb 31f
	xorl %eax, %eax
31:	movq %rax, slot(%rip)
	jmp 8f
4:	movq (%rbx), %rsi
	leaq s_n(%rip), %rdi
	call str_eq
	testl %eax, %eax
	jz 7f
	call opt_value
	movq %rax, count(%rip)
	jmp 8f
7:	leaq s_usage(%rip), %rsi
	call say
	movl $2, %edi
	SYS SYS_exit_group
8:	addq $8, %rbx
	decq %r12
	jmp 1b
9:	movq card(%rip), %rdi
	movq $OFF_RESIDENT + RESIDENT_BYTES, %rsi
	call window_open
	testq %rax, %rax
	jz .Lno_window
	movq %rax, base(%rip)
	movq %rax, %rdi
	movq $2000000000, %rsi
	call wait_ready
	testl %eax, %eax
	jz .Lnot_ready
	movq base(%rip), %rax
	movq slot(%rip), %rcx
	shlq $12, %rcx
	leaq OFF_SLOTS(%rax,%rcx), %rcx
	movq %rcx, slotp(%rip)
	movq slot(%rip), %rcx
	shlq $20, %rcx
	addq $OFF_SLOTDATA, %rcx
	addq %rax, %rcx
	movq %rcx, datap(%rip)
	movq slot(%rip), %rdi
	call open_slot
	# K_FLUSH: the previous program's residency dropped (the pool is
	# finite and nothing evicts yet)
	call clear_request
	movl $K_FLUSH, %esi
	call post_and_wait
	# staging chunk 0: float i at dword i (the sums stay normal numbers);
	# chunk 1: zeros
	movq base(%rip), %rdi
	addq $OFF_RESIDENT, %rdi
	xorl %eax, %eax
	movl $CHUNK / 4, %ecx
1:	cvtsi2ss %eax, %xmm0
	movss %xmm0, (%rdi)
	addq $4, %rdi
	incl %eax
	decl %ecx
	jnz 1b
	movq base(%rip), %rdi
	addq $OFF_RESIDENT + CHUNK, %rdi
	xorl %eax, %eax
	movl $CHUNK / 8, %ecx
	rep stosq
	# K_RESIDENT twice
	movq $ADDR_A, %rdi
	xorl %esi, %esi			# staging 0
	xorl %edx, %edx			# class 0
	call make_resident
	movq $ADDR_B, %rdi
	movl $1, %esi
	movl $1, %edx
	call make_resident
	# K_LOAD
	movq slot(%rip), %rdi
	imulq $FX_LOAD_PER_SLOT, %rdi, %rdi
	addq $OFF_LOADAREA, %rdi
	addq base(%rip), %rdi
	leaq blob(%rip), %rsi
	movl $blob_end - blob, %edx
	call mem_copy
	call clear_request
	movq slotp(%rip), %rdi
	movq $2, SL_FN_ID(%rdi)
	movq $blob_end - blob, SL_ENTRY(%rdi)
	movl $K_LOAD, %esi
	call post_and_wait
	testq %rax, %rax
	js .Lreq_fail
	movq slotp(%rip), %rdi
	cmpl $0, SLOT_REPLY + SR_STATUS(%rdi)
	jne .Lreq_fail
	call l_begin
	leaq s_loaded(%rip), %rsi
	call w_str
	movq slotp(%rip), %rdi
	movq SLOT_REPLY + SR_EXIT_AUX(%rdi), %rdi
	call w_hexn
	movl $1, %edi
	call l_end
	# the write-back table: one range, ADDR_B for 64 bytes
	movq datap(%rip), %rdi
	movabsq $ADDR_B, %rax
	movq %rax, SD_WB_TAB(%rdi)
	movq $64, SD_WB_TAB + 8(%rdi)
	# the runs
	movq $-1, min_ns(%rip)
	xorl %ebx, %ebx
.Lrun:	cmpq count(%rip), %rbx
	jae .Lreport
	incq %rbx
	call fill_regs
	# the write-back line cleared, so a stale one cannot pass
	movq datap(%rip), %rdi
	movq $0, SD_WB + 60(%rdi)
	call clear_request
	movq slotp(%rip), %rdi
	movq $2, SL_FN_ID(%rdi)
	movq $0, SL_ENTRY(%rdi)
	movl $1, SL_THREADS(%rdi)
	movl $1, SL_WB_N(%rdi)
	movl $64, SL_WB_BYTES(%rdi)
	movl $K_FEXEC, %esi
	call post_and_wait
	testq %rax, %rax
	js .Lreq_fail
	addq $0, %rax
	cmpq min_ns(%rip), %rax
	jae 1f
	movq %rax, min_ns(%rip)
1:	cmpq max_ns(%rip), %rax
	jbe 2f
	movq %rax, max_ns(%rip)
2:	xorl %edx, %edx
	movl $1000, %ecx
	divq %rcx
	cmpq $99999, %rax
	jb 3f
	movq $99999, %rax
3:	leaq hist(%rip), %rcx
	incl (%rcx,%rax,4)
	# the checks: status 0, X_RET, wb_n 1, rax = qword at A + 4096 =
	# dwords 1024 and 1025, zmm0 lane 15 = 30.0 (0x41f00000), the
	# write-back line's lane 15 the same
	movq slotp(%rip), %rcx
	cmpl $0, SLOT_REPLY + SR_STATUS(%rcx)
	jne .Lwrong
	cmpl $X_RET, SLOT_REPLY + SR_EXIT_KIND(%rcx)
	jne .Lwrong
	cmpl $1, SLOT_REPLY + SR_WB_N(%rcx)
	jne .Lwrong
	movq datap(%rip), %rcx
	movabsq $0x4480200044800000, %rax		# floats 1024.0, 1025.0
	cmpq %rax, SD_REGS_OUT + REGS_GPR(%rcx)
	jne .Lwrong
	cmpl $0x41f00000, SD_REGS_OUT + REGS_ZMM + 60(%rcx)
	jne .Lwrong
	cmpl $0x41f00000, SD_WB + 60(%rcx)
	jne .Lwrong
	jmp .Lrun
.Lwrong:
	incq fails(%rip)
	cmpq $4, fails(%rip)
	ja .Lrun
	call l_begin
	leaq s_bad(%rip), %rsi
	call w_str
	movq %rbx, %rdi
	call w_dec
	leaq s_bad2(%rip), %rsi
	call w_str
	movq datap(%rip), %rcx
	movq SD_REGS_OUT + REGS_GPR(%rcx), %rdi
	call w_hexn
	leaq s_bad3(%rip), %rsi
	call w_str
	movq datap(%rip), %rcx
	movl SD_REGS_OUT + REGS_ZMM + 60(%rcx), %edi
	call w_hexn
	leaq s_bad4(%rip), %rsi
	call w_str
	movq datap(%rip), %rcx
	movl SD_WB + 60(%rcx), %edi
	call w_hexn
	leaq s_bad5(%rip), %rsi
	call w_str
	movq slotp(%rip), %rcx
	movl SLOT_REPLY + SR_EXIT_KIND(%rcx), %edi
	call w_dec
	leaq s_bad6(%rip), %rsi
	call w_str
	movq slotp(%rip), %rcx
	movl SLOT_REPLY + SR_WB_N(%rcx), %edi
	call w_dec
	leaq s_fail_st(%rip), %rsi
	call w_str
	movq slotp(%rip), %rcx
	movl SLOT_REPLY + SR_STATUS(%rcx), %edi
	call w_sdec
	movl $1, %edi
	call l_end
	jmp .Lrun
.Lreport:
	call l_begin
	leaq s_r1(%rip), %rsi
	call w_str
	movq count(%rip), %rdi
	call w_dec
	leaq s_r2(%rip), %rsi
	call w_str
	movq slot(%rip), %rdi
	call w_dec
	leaq s_r3(%rip), %rsi
	call w_str
	movq card(%rip), %rdi
	call w_dec
	leaq s_r4(%rip), %rsi
	call w_str
	movq min_ns(%rip), %rdi
	call w_us
	leaq s_r5(%rip), %rsi
	call w_str
	movq count(%rip), %rdi
	shrq $1, %rdi
	call percentile
	movq %rax, %rdi
	call w_dec
	leaq s_r6(%rip), %rsi
	call w_str
	movq count(%rip), %rax
	imulq $99, %rax, %rax
	xorl %edx, %edx
	movl $100, %ecx
	divq %rcx
	movq %rax, %rdi
	call percentile
	movq %rax, %rdi
	call w_dec
	leaq s_r7(%rip), %rsi
	call w_str
	movq max_ns(%rip), %rdi
	call w_us
	leaq s_r8(%rip), %rsi
	call w_str
	movq fails(%rip), %rdi
	call w_dec
	movl $1, %edi
	call l_end
	cmpq $0, fails(%rip)
	jne 1f
	call l_begin
	leaq s_pass(%rip), %rsi
	call w_str
	movl $1, %edi
	call l_end
	xorl %edi, %edi
	SYS SYS_exit_group
1:	call l_begin
	leaq s_failed(%rip), %rsi
	call w_str
	movl $1, %edi
	call l_end
	movl $1, %edi
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
.Lreq_fail:
	call l_begin
	leaq s_fail_req(%rip), %rsi
	call w_str
	movq slotp(%rip), %rdi
	movl SL_KIND(%rdi), %edi
	call w_dec
	leaq s_fail_st(%rip), %rsi
	call w_str
	movq slotp(%rip), %rdi
	movl SLOT_REPLY + SR_STATUS(%rdi), %edi
	call w_sdec
	movl $1, %edi
	call l_end
	movl $1, %edi
	SYS SYS_exit_group

# make_resident(rdi program address, esi staging index, edx class): one
# K_RESIDENT, its reply checked, a line with the pool page and the time.
make_resident:
	pushq %rbx
	pushq %r12
	pushq %r13
	movq %rdi, %rbx
	movl %esi, %r12d
	movl %edx, %r13d
	call clear_request
	movq slotp(%rip), %rdi
	movq %rbx, SL_FN_ID(%rdi)
	movq %r12, SL_ENTRY(%rdi)
	movl %r13d, SL_THREADS(%rdi)
	movq $0, SL_FILL_OFF(%rdi)		# the whole chunk filled
	movq $CHUNK, SL_FILL_LEN(%rdi)
	movl $K_RESIDENT, %esi
	call post_and_wait
	testq %rax, %rax
	js .Lreq_fail
	movq %rax, %r12				# ns
	movq slotp(%rip), %rdi
	cmpl $0, SLOT_REPLY + SR_STATUS(%rdi)
	jne .Lreq_fail
	call l_begin
	leaq s_res1(%rip), %rsi
	call w_str
	movq %rbx, %rdi
	call w_hexn
	leaq s_res2(%rip), %rsi
	call w_str
	movq slotp(%rip), %rdi
	movq SLOT_REPLY + SR_EXIT_AUX(%rdi), %rdi
	call w_dec
	leaq s_res3(%rip), %rsi
	call w_str
	movq %r12, %rdi
	call w_us
	leaq s_us(%rip), %rsi
	call w_str
	movl $1, %edi
	call l_end
	popq %r13
	popq %r12
	popq %rbx
	ret

# clear_request: the slot's request block zeroed but for seq.
clear_request:
	movq slotp(%rip), %rdi
	addq $8, %rdi
	movl $(SL_REQ_BYTES - 8) / 8, %ecx
	xorl %eax, %eax
	rep stosq
	ret

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

# fill_regs: the file in: zmm all zero, k0 0xffff, rdi ADDR_A, rsi ADDR_B,
# rflags 0x202.
fill_regs:
	movq datap(%rip), %rdi
	addq $SD_REGS_IN, %rdi
	movq %rdi, %rcx
	movl $REGS_BYTES / 8, %edx
	xorl %eax, %eax
1:	movq %rax, (%rcx)
	addq $8, %rcx
	decl %edx
	jnz 1b
	movw $0xffff, REGS_K(%rdi)
	movabsq $ADDR_A, %rax
	movq %rax, REGS_GPR + 56(%rdi)
	movabsq $ADDR_B, %rax
	movq %rax, REGS_GPR + 48(%rdi)
	movq $0x202, REGS_RFLAGS(%rdi)
	ret

# post_and_wait(kind esi): as phi-vpu-fexec's; rax the round trip in ns,
# or -1 on timeout (3 s: a K_RESIDENT moves 2 MiB).
post_and_wait:
	pushq %rbx
	pushq %r12
	pushq %r13
	movl %esi, %r12d
	movq slotp(%rip), %rbx
	incq seq(%rip)
	movq seq(%rip), %rax
	movq %rax, SL_SEQ(%rbx)
	movl %r12d, SL_KIND(%rbx)
	FENCE
	call now_ns
	movq %rax, %r13
	movq seq(%rip), %rax
	andl $0x7ff, %eax
	movl %r12d, %ecx
	shll $11, %ecx
	orl %ecx, %eax
	movq base(%rip), %rcx
	movq slot(%rip), %rdx
	movw %ax, OFF_SLOTSEQ(%rcx,%rdx,2)
	FENCE
1:	movq seq(%rip), %rax
	cmpq SLOT_REPLY + SR_SEQ(%rbx), %rax
	je 2f
	pause
	call now_ns
	subq %r13, %rax
	movabsq $3000000000, %rcx
	cmpq %rcx, %rax
	jb 1b
	movq $-1, %rax
	jmp 3f
2:	call now_ns
	subq %r13, %rax
3:	popq %r13
	popq %r12
	popq %rbx
	ret

percentile:
	leaq hist(%rip), %rsi
	xorl %eax, %eax
	xorl %ecx, %ecx
1:	cmpl $100000, %eax
	jae 2f
	movl (%rsi,%rax,4), %edx
	addq %rdx, %rcx
	cmpq %rdi, %rcx
	ja 2f
	incl %eax
	jmp 1b
2:	ret

w_us:
	pushq %rbx
	movq %rdi, %rax
	xorl %edx, %edx
	movl $100, %ecx
	divq %rcx
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
	popq %rbx
	ret
