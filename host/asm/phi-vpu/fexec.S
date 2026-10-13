# fexec.S: phi-vpu-fexec, the first function through protocol v3's slots:
# a hand-written blob (vaddps zmm0, zmm1, zmm2 in the card's MVEX encoding,
# then rdi + rsi into rax, then ret) loaded into a slot's arena with
# K_LOAD and run N times with K_FEXEC, each run's register file checked
# (zmm0 every lane 3.0, rax 12) and timed from the doorbell store to the
# reply. See fexec.md.
#
#   phi-vpu-fexec [--card N] [--slot S] [-n COUNT]

	.include "common.inc"
	.include "proto.inc"

	.set SYS_exit, 60
	.set FX_LOAD_PER_SLOT, 512 * 1024
	.set FX_REGS_PULL, 2368

	.bss
	.balign 64
card:	.skip 8
slot:	.skip 8
count:	.skip 8
base:	.skip 8
slotp:	.skip 8				# the slot's block in the window
datap:	.skip 8				# the slot's SLOTDATA
seq:	.skip 8
min_ns:	.skip 8
max_ns:	.skip 8
sum_ns:	.skip 8
fails:	.skip 8
	.balign 64
hist:	.skip 100000 * 4

	.section .rodata
	.balign 64
# The blob: MVEX vaddps zmm0{k0}, zmm1, zmm2 (62 f1 70 08 58 c2: the EVEX
# form with P1 bit 2 clear and the MVEX P2 byte, docs/research/avx512-on-knc.md),
# then lea rax, [rdi + rsi]; ret.
blob:	.byte 0x62, 0xf1, 0x70, 0x08, 0x58, 0xc2
	.byte 0x48, 0x8d, 0x04, 0x37		# lea (%rdi,%rsi,1), %rax
	.byte 0xc3				# ret
blob_end:
s_card:	.asciz "--card"
s_c:	.asciz "-c"
s_slot:	.asciz "--slot"
s_n:	.asciz "-n"
s_usage:	.asciz "usage: phi-vpu-fexec [--card N] [--slot S] [-n COUNT]"
s_nowindow:	.asciz "phi-vpu-fexec: no window for the card"
s_notready:	.asciz "phi-vpu-fexec: no worker polling on the card"
s_loadfail:	.asciz "phi-vpu-fexec: K_LOAD failed, status "
s_loaded:	.asciz "fexec: blob loaded at card address "
s_timeout:	.asciz "phi-vpu-fexec: timeout waiting for the reply to seq "
s_bad:	.asciz "fexec: WRONG result at run "
s_bad2:	.asciz ": rax "
s_bad3:	.asciz " lane0 bits "
s_bad4:	.asciz " exit kind "
s_res1:	.asciz "fexec: "
s_res2:	.asciz " runs on slot "
s_res3:	.asciz " of card "
s_res4:	.asciz ": min "
s_res5:	.asciz " us median "
s_res6:	.asciz " us p99 "
s_res7:	.asciz " us max "
s_res8:	.asciz " us, wrong results "
s_pass:	.asciz "fexec: PASS, every run returned rax 12 and zmm0 = 3.0 in all 16 lanes"
s_fail:	.asciz "fexec: FAIL"

	.text
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
	movq $OFF_RESIDENT, %rsi		# the window up to the end of LOADAREA
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
	# K_LOAD: the blob into this slot's part of LOADAREA, then the request
	movq slot(%rip), %rdi
	imulq $FX_LOAD_PER_SLOT, %rdi, %rdi
	addq $OFF_LOADAREA, %rdi
	addq base(%rip), %rdi
	leaq blob(%rip), %rsi
	movl $blob_end - blob, %edx
	call mem_copy
	movq slotp(%rip), %rdi
	movq $1, SL_FN_ID(%rdi)
	movq $blob_end - blob, SL_ENTRY(%rdi)
	movl $K_LOAD, %esi
	call post_and_wait			# rax: the round trip in ns, or -1
	testq %rax, %rax
	js .Lload_fail
	movq slotp(%rip), %rdi
	movl SLOT_REPLY + SR_STATUS(%rdi), %eax
	testl %eax, %eax
	jnz .Lload_fail
	call l_begin
	leaq s_loaded(%rip), %rsi
	call w_str
	movq slotp(%rip), %rdi
	movq SLOT_REPLY + SR_EXIT_AUX(%rdi), %rdi
	call w_hex
	movl $1, %edi
	call l_end
	# the runs
	movq $-1, min_ns(%rip)
	xorl %ebx, %ebx
.Lrun:	cmpq count(%rip), %rbx
	jae .Lreport
	incq %rbx
	call fill_regs
	movq slotp(%rip), %rdi
	movq $1, SL_FN_ID(%rdi)
	movq $0, SL_ENTRY(%rdi)
	movl $1, SL_THREADS(%rdi)
	movl $K_FEXEC, %esi
	call post_and_wait			# rax: the round trip in ns, or -1
	testq %rax, %rax
	js .Lrun_timeout
	# the sample
	addq %rax, sum_ns(%rip)
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
	# the result: rax 12, zmm0 lane 0 and lane 15 = 3.0f (0x40400000)
	movq datap(%rip), %rcx
	movq SD_REGS_OUT + REGS_GPR(%rcx), %rax
	cmpq $12, %rax
	jne .Lwrong
	movl SD_REGS_OUT + REGS_ZMM(%rcx), %eax
	cmpl $0x40400000, %eax
	jne .Lwrong
	movl SD_REGS_OUT + REGS_ZMM + 60(%rcx), %eax
	cmpl $0x40400000, %eax
	jne .Lwrong
	movq slotp(%rip), %rcx
	cmpl $X_RET, SLOT_REPLY + SR_EXIT_KIND(%rcx)
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
	call w_dec
	leaq s_bad3(%rip), %rsi
	call w_str
	movq datap(%rip), %rcx
	movl SD_REGS_OUT + REGS_ZMM(%rcx), %edi
	call w_hex
	leaq s_bad4(%rip), %rsi
	call w_str
	movq slotp(%rip), %rcx
	movl SLOT_REPLY + SR_EXIT_KIND(%rcx), %edi
	call w_dec
	movl $1, %edi
	call l_end
	jmp .Lrun
.Lrun_timeout:
	call l_begin
	leaq s_timeout(%rip), %rsi
	call w_str
	movq seq(%rip), %rdi
	call w_dec
	movl $1, %edi
	call l_end
	movl $1, %edi
	SYS SYS_exit_group
.Lreport:
	call l_begin
	leaq s_res1(%rip), %rsi
	call w_str
	movq count(%rip), %rdi
	call w_dec
	leaq s_res2(%rip), %rsi
	call w_str
	movq slot(%rip), %rdi
	call w_dec
	leaq s_res3(%rip), %rsi
	call w_str
	movq card(%rip), %rdi
	call w_dec
	leaq s_res4(%rip), %rsi
	call w_str
	movq min_ns(%rip), %rdi
	call w_us
	leaq s_res5(%rip), %rsi
	call w_str
	movq count(%rip), %rdi
	shrq $1, %rdi
	call percentile
	movq %rax, %rdi
	call w_dec
	leaq s_res6(%rip), %rsi
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
	leaq s_res7(%rip), %rsi
	call w_str
	movq max_ns(%rip), %rdi
	call w_us
	leaq s_res8(%rip), %rsi
	call w_str
	movq fails(%rip), %rdi
	call w_dec
	movl $1, %edi
	call l_end
	cmpq $0, fails(%rip)
	jne 1f
	leaq s_pass(%rip), %rsi
	call say
	xorl %edi, %edi
	SYS SYS_exit_group
1:	leaq s_fail(%rip), %rsi
	call say
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
.Lload_fail:
	call l_begin
	leaq s_loadfail(%rip), %rsi
	call w_str
	movq slotp(%rip), %rdi
	movl SLOT_REPLY + SR_STATUS(%rdi), %edi
	call w_sdec
	movl $1, %edi
	call l_end
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

# fill_regs: the register file in: zmm1 = 1.0f x 16, zmm2 = 2.0f x 16,
# zmm0 = 0, k0 = 0xffff (the MVEX {k0} form writes every lane; the mask
# registers are loaded as given), rdi 5, rsi 7, rflags 0x202.
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
	leaq REGS_ZMM + 64(%rdi), %rcx		# zmm1
	movl $0x3f800000, %eax
	movl $16, %edx
2:	movl %eax, (%rcx)
	addq $4, %rcx
	decl %edx
	jnz 2b
	leaq REGS_ZMM + 128(%rdi), %rcx		# zmm2
	movl $0x40000000, %eax
	movl $16, %edx
3:	movl %eax, (%rcx)
	addq $4, %rcx
	decl %edx
	jnz 3b
	movw $0xffff, REGS_K(%rdi)
	movq $5, REGS_GPR + 56(%rdi)		# rdi
	movq $7, REGS_GPR + 48(%rdi)		# rsi
	movq $0x202, REGS_RFLAGS(%rdi)
	ret

# post_and_wait(kind esi): the slot's request sequence number bumped, the
# kind written, a fence, the u16 (kind in its top four bits, the sequence
# number in the low twelve) into the SLOTSEQ line; then a spin on the
# reply's sequence number, 1 s at most. rax the round trip in ns, or -1
# on timeout.
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
	movl $0, SL_FLAGS(%rbx)
	FENCE
	call now_ns
	movq %rax, %r13
	movq seq(%rip), %rax
	andl $0xfff, %eax
	movl %r12d, %ecx
	shll $12, %ecx
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
	cmpq $1000000000, %rax
	jb 1b
	movq $-1, %rax
	jmp 3f
2:	call now_ns
	subq %r13, %rax
3:	popq %r13
	popq %r12
	popq %rbx
	ret

# percentile(rank rdi): the bin of the rank-th sample, in rax.
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

# w_us(ns rdi): "N.d" microseconds.
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
