# main.S: libphi512-asm.so's entry: a constructor (.init_array) that reads
# the environment, finds the cards, maps the executable's symbols and
# installs the SIGILL handler (sigill.S), and a destructor that reports
# what ran. The assembly preload of the restart's stage 2; the Rust
# libphi512.so stays beside it until stage 3. See main.md.

	.include "common.inc"
	.include "proto.inc"
	.include "defs.inc"

	.bss
	.balign 64
sa:	.skip SA_BYTES

	.section .rodata
s_env_verbose:	.asciz "PHI512_VERBOSE"
s_env_disable:	.asciz "PHI512_DISABLE"
s_env_handblobs: .asciz "PHI512_HANDBLOBS"
s_nocards:	.asciz "phi512: no card (no window, no worker): AVX-512 instructions will end the program"
s_up1:	.asciz "phi512: "
s_up2:	.asciz " card(s), the handler installed; seeds: "
s_fin1:	.asciz "phi512: the cards ran "
s_fin2:	.asciz " call(s) in "
s_fin3:	.asciz " ms; "
s_fin4:	.asciz " chunk(s) made resident in "
s_fin5:	.asciz " ms; outputs fetched in "
s_fin6:	.asciz " ms"
s_t1:	.asciz "phi512: init: environment read"
s_t2:	.asciz "phi512: init: cpuid done"
s_t3:	.asciz "phi512: init: executable mapped"
s_t4:	.asciz "phi512: init: cards opened"
s_t5:	.asciz "phi512: init: handler installed"

	.section .init_array,"aw"
	.quad phi512_init
	.section .fini_array,"aw"
	.quad phi512_fini

	.text

phi512_init:
	pushq %rbx
	pushq %r12
	leaq s_env_disable(%rip), %rdi
	call env_set
	testl %eax, %eax
	jnz 9f
	# a host with AVX-512 needs nothing: CPUID leaf 7, EBX bit 16
	movl $7, %eax
	xorl %ecx, %ecx
	cpuid
	btl $16, %ebx
	jc 9f
	leaq s_env_verbose(%rip), %rdi
	call env_set
	movl %eax, %eax
	movq %rax, verbose(%rip)
	leaq s_env_handblobs(%rip), %rdi
	call env_set
	movl %eax, %eax
	movq %rax, handblobs(%rip)
	movq verbose(%rip), %rax
	testq %rax, %rax
	jz 11f
	leaq s_t1(%rip), %rsi
	call say
11:
	# where the YMM halves lie in an XSAVE area: CPUID 0xD, subleaf 2, EBX
	movl $0xd, %eax
	movl $2, %ecx
	cpuid
	movl %ebx, %ebx
	movq %rbx, ymm_off(%rip)
	cmpq $0, verbose(%rip)
	je 12f
	leaq s_t2(%rip), %rsi
	call say
12:	call elf_init
	cmpq $0, verbose(%rip)
	je 13f
	leaq s_t3(%rip), %rsi
	call say
13:	call cards_init
	testq %rax, %rax
	jnz 1f
	leaq s_nocards(%rip), %rsi
	call say
	jmp 9f
1:	cmpq $0, verbose(%rip)
	je 14f
	leaq s_t4(%rip), %rsi
	call say
14:	leaq sa(%rip), %rbx
	leaq phi512_sigill(%rip), %rax
	movq %rax, SA_HANDLER(%rbx)
	movq $SA_SIGINFO | SA_RESTORER, SA_FLAGS(%rbx)
	leaq phi512_sig_restorer(%rip), %rax
	movq %rax, SA_RESTORER_OFF(%rbx)
	movq $0, SA_MASK(%rbx)
	movl $SIGILL, %edi
	movq %rbx, %rsi
	xorl %edx, %edx
	movl $SIGSET_BYTES, %r10d
	SYS SYS_rt_sigaction
	cmpq $0, verbose(%rip)
	je 9f
	call l_begin
	leaq s_up1(%rip), %rsi
	call w_str
	movq ncards(%rip), %rdi
	call w_dec
	leaq s_up2(%rip), %rsi
	call w_str
	movq nseeds(%rip), %rdi
	call w_dec
	movl $2, %edi
	call l_end
9:	popq %r12
	popq %rbx
	ret

phi512_fini:
	cmpq $0, verbose(%rip)
	je 9f
	cmpq $0, ncards(%rip)
	je 9f
	call l_begin
	leaq s_fin1(%rip), %rsi
	call w_str
	movq stat_calls(%rip), %rdi
	call w_dec
	leaq s_fin2(%rip), %rsi
	call w_str
	movq stat_call_ns(%rip), %rdi
	call w_ms
	leaq s_fin3(%rip), %rsi
	call w_str
	movq stat_resident(%rip), %rdi
	call w_dec
	leaq s_fin4(%rip), %rsi
	call w_str
	movq stat_resident_ns(%rip), %rdi
	call w_ms
	leaq s_fin5(%rip), %rsi
	call w_str
	movq stat_push_ns(%rip), %rdi
	call w_ms
	leaq s_fin6(%rip), %rsi
	call w_str
	movl $2, %edi
	call l_end
9:	ret
