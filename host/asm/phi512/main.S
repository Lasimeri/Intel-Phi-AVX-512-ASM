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
	.globl incall_off
incall_off:	.skip 8			# 1: blobs leave the card at every call (PHI512_INCALL=0)

	.section .rodata
s_env_verbose:	.asciz "PHI512_VERBOSE"
s_env_disable:	.asciz "PHI512_DISABLE"
s_env_handblobs: .asciz "PHI512_HANDBLOBS"
s_env_heapcheck: .asciz "PHI512_HEAPCHECK"
s_env_incall:	.asciz "PHI512_INCALL"
s_env_cardwb:	.asciz "PHI512_CARDWB"
s_env_promote:	.asciz "PHI512_PROMOTE"
s_env_cont:	.asciz "PHI512_CONT"
s_env_tany:	.asciz "PHI512_TRAMP_ANY"
s_env_dirty:	.asciz "PHI512_DIRTY"
s_env_catom:	.asciz "PHI512_CARD_ATOMICS"
s_nocards:	.asciz "phi512: no card (no window, no worker): AVX-512 instructions will end the program"
s_up1:	.asciz "phi512: "
s_up2:	.asciz " card(s), the handler installed; seeds: "
s_fin1:	.asciz "phi512: the cards ran "
s_fin2:	.asciz " call(s) in "
s_fin3:	.asciz " ms; "
s_fin4:	.asciz " chunk(s) made resident in "
s_fin5:	.asciz " ms; outputs fetched in "
s_fin6:	.asciz " ms"
s_fin7:	.asciz "phi512: "
s_fin8:	.asciz " region(s); write-backs from the card's own diff "
s_fin9:	.asciz ", lists that overflowed (units pulled) "
s_fin10:	.asciz ", lines written back "
s_fin11:	.asciz ""
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
	leaq s_env_heapcheck(%rip), %rdi
	call env_set
	movl %eax, %eax
	movq %rax, heapcheck(%rip)
	leaq s_env_incall(%rip), %rdi		# PHI512_INCALL=0: every call leaves the card (blob.S .Lincall)
	movl $1, %esi
	call env_u64
	xorl %ecx, %ecx
	testq %rax, %rax
	sete %cl
	movq %rcx, incall_off(%rip)
	leaq s_env_cardwb(%rip), %rdi		# PHI512_CARDWB=0: the host pulls every unit back after a region (region.S wu_writeback)
	movl $1, %esi
	call env_u64
	xorl %ecx, %ecx
	testq %rax, %rax
	sete %cl
	movq %rcx, cardwb_off(%rip)
	leaq s_env_promote(%rip), %rdi		# PHI512_PROMOTE=0: no caller promotion (region.S promote_check)
	movl $1, %esi
	call env_u64
	xorl %ecx, %ecx
	testq %rax, %rax
	sete %cl
	movq %rcx, promote_off(%rip)
	leaq s_env_cont(%rip), %rdi		# PHI512_CONT=0: no continuation after a return, no trampoline (region.S)
	movl $1, %esi
	call env_u64
	xorl %ecx, %ecx
	testq %rax, %rax
	sete %cl
	movq %rcx, cont_off(%rip)
	leaq s_env_tany(%rip), %rdi
	xorl %esi, %esi
	call env_u64
	movq %rax, tramp_any(%rip)
	leaq s_env_dirty(%rip), %rdi		# PHI512_DIRTY=0: the refresh reads every unit back (region.S dt_*)
	movl $1, %esi
	call env_u64
	xorl %ecx, %ecx
	testq %rax, %rax
	sete %cl
	movq %rcx, dt_off(%rip)
	leaq s_env_catom(%rip), %rdi		# PHI512_CARD_ATOMICS=1: atomics run on the card (blob.S; one compute thread only)
	xorl %esi, %esi
	call env_u64
	movq %rax, card_atomics(%rip)
	movq verbose(%rip), %rax
	testq %rax, %rax
	jz 11f
	leaq s_t1(%rip), %rsi
	call say
11:
	call now_ns				# the progress line's clock (region.S heartbeat)
	movq %rax, hb_t0(%rip)
	movq %rax, hb_last(%rip)
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
14:	call alt_install			# the main thread's alternate signal stack (the others get theirs at their first fault)
	leaq sa(%rip), %rbx
	leaq phi512_sigill(%rip), %rax
	movq %rax, SA_HANDLER(%rbx)
	movq $SA_SIGINFO | SA_RESTORER | SA_ONSTACK, SA_FLAGS(%rbx)
	leaq phi512_sig_restorer(%rip), %rax
	movq %rax, SA_RESTORER_OFF(%rbx)
	movq $0, SA_MASK(%rbx)
	movl $SIGILL, %edi
	movq %rbx, %rsi
	xorl %edx, %edx
	movl $SIGSET_BYTES, %r10d
	SYS SYS_rt_sigaction
	movl $5, %edi				# SIGTRAP: the single step after an instruction the host ran (region.S)
	leaq sa(%rip), %rsi
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
	cmpq $0, ncards(%rip)
	je 9f
	cmpq $0, stat_regions(%rip)		# always, when regions ran: their count and how their write-backs came
	je 1f
	call l_begin				# the regions and how their write-backs came
	leaq s_fin7(%rip), %rsi
	call w_str
	movq stat_regions(%rip), %rdi
	call w_dec
	leaq s_fin8(%rip), %rsi
	call w_str
	movq stat_cardwb(%rip), %rdi
	call w_dec
	leaq s_fin9(%rip), %rsi
	call w_str
	movq stat_cardwb_full(%rip), %rdi
	call w_dec
	leaq s_fin10(%rip), %rsi
	call w_str
	movq stat_wb_lines(%rip), %rdi
	call w_dec
	leaq s_fin11(%rip), %rsi
	call w_str
	movl $2, %edi
	call l_end
1:	cmpq $0, verbose(%rip)
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
