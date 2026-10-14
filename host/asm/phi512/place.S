# place.S: the four-card pool's placement (2026-10-14, the user: pool the
# four Phis' memory, each card holding different weights): which card
# owns a byte of the mmapped model. PHI512_PLACE names a text file of
# lines "card offset bytes path" (decimal, '#' comments; tools/gguf-place.c
# writes it from the GGUF headers, a layer's tensors to one card).
# chunk_owner(address) is the card of the line whose file range holds the
# address's file offset, -1 when no line does (a DSO's constants, the
# token embeddings: whichever card runs takes them). The model is mapped
# after the preload starts, so a mapping is resolved against
# /proc/self/maps the first time an address in it is asked about
# (own_examine: its path and file offset, every placement line of that
# path made an address range in own_tab) and never read again (ex_tab).
# Without PHI512_PLACE every chunk is unowned, as before. See place.md.

	.include "common.inc"

	.set PL_MAX, 4096
	.set PL_BYTES, 32			# card, file offset, bytes, path
	.set OWN_MAX, 8192
	.set OWN_BYTES, 24			# lo, hi, card
	.set EX_MAX, 1024
	.set PLF_CAP, 1048576

	.bss
	.balign 64
pl_tab:		.skip PL_MAX * PL_BYTES
pl_n:		.skip 8
pl_state:	.skip 8			# 0 not read yet, 1 read, 2 none (unset, unreadable or empty)
own_tab:	.skip OWN_MAX * OWN_BYTES
own_n:		.skip 8
ex_tab:		.skip EX_MAX * 8
ex_n:		.skip 8
plf_buf:	.skip PLF_CAP
	.section .rodata
s_env_place:	.asciz "PHI512_PLACE"
s_pl1:	.asciz "phi512: placement "
s_pl2:	.asciz ": "
s_pl3:	.asciz " line(s): a chunk of the model lives on its owner card only (the four-card pool)"
s_pl4:	.asciz "phi512: placement: "
s_pl5:	.asciz " -> "
s_pl6:	.asciz " owned range(s) from "
	.text

# place_load: the placement file read and parsed, once.
	.globl place_load
place_load:
	cmpq $0, pl_state(%rip)
	je 1f
	ret
1:	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	movq $2, pl_state(%rip)
	leaq s_env_place(%rip), %rdi
	call env_get
	testq %rax, %rax
	jz 9f
	movq %rax, %r12				# the file's name
	movq %rax, %rdi
	movl $O_RDONLY | O_CLOEXEC, %esi
	xorl %edx, %edx
	SYS SYS_open
	testq %rax, %rax
	js 9f
	movq %rax, %rbx
	xorl %r13d, %r13d			# bytes read
2:	movl %ebx, %edi
	leaq plf_buf(%rip), %rsi
	addq %r13, %rsi
	movl $PLF_CAP - 1, %edx
	subq %r13, %rdx
	jle 3f
	SYS SYS_read
	testq %rax, %rax
	jle 3f
	addq %rax, %r13
	jmp 2b
3:	movl %ebx, %edi
	SYS SYS_close
	leaq plf_buf(%rip), %rsi
	movb $0, (%rsi,%r13)
	xorl %r14d, %r14d			# lines
4:	# a line: blanks and empty lines skipped, '#' to its end
	movzbl (%rsi), %eax
	testl %eax, %eax
	jz 8f
	cmpl $' ', %eax
	je 41f
	cmpl $'\t', %eax
	je 41f
	cmpl $'\n', %eax
	je 41f
	cmpl $'#', %eax
	je 5f
	cmpq $PL_MAX, %r14
	jae 8f
	movq %r14, %rbx
	shlq $5, %rbx				# PL_BYTES
	leaq pl_tab(%rip), %rax
	addq %rax, %rbx				# the entry
	call pl_dec
	movq %rax, 0(%rbx)			# card
	call pl_blank
	call pl_dec
	movq %rax, 8(%rbx)			# file offset
	call pl_blank
	call pl_dec
	movq %rax, 16(%rbx)			# bytes
	call pl_blank
	movq %rsi, 24(%rbx)			# the path, to the line's end
6:	movzbl (%rsi), %eax
	testl %eax, %eax
	jz 61f
	cmpl $'\n', %eax
	je 62f
	incq %rsi
	jmp 6b
62:	movb $0, (%rsi)
	incq %rsi
61:	cmpq $0, 16(%rbx)
	je 4b					# an empty range is no line
	incq %r14
	jmp 4b
41:	incq %rsi
	jmp 4b
5:	movzbl (%rsi), %eax			# a comment
	testl %eax, %eax
	jz 8f
	incq %rsi
	cmpl $'\n', %eax
	jne 5b
	jmp 4b
8:	movq %r14, pl_n(%rip)
	testq %r14, %r14
	jz 9f
	movq $1, pl_state(%rip)
	call l_begin
	leaq s_pl1(%rip), %rsi
	call w_str
	movq %r12, %rsi
	call w_str
	leaq s_pl2(%rip), %rsi
	call w_str
	movq %r14, %rdi
	call w_dec
	leaq s_pl3(%rip), %rsi
	call w_str
	movl $2, %edi
	call l_end
9:	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# pl_dec: the decimal number at rsi, in rax; rsi past it (rcx clobbered).
pl_dec:
	xorl %eax, %eax
1:	movzbl (%rsi), %ecx
	subl $'0', %ecx
	cmpl $9, %ecx
	ja 9f
	imulq $10, %rax, %rax
	addq %rcx, %rax
	incq %rsi
	jmp 1b
9:	ret

# pl_blank: rsi past spaces and tabs.
pl_blank:
	movzbl (%rsi), %eax
	cmpl $' ', %eax
	je 1f
	cmpl $'\t', %eax
	je 1f
	ret
1:	incq %rsi
	jmp pl_blank

# chunk_owner(address rdi): eax the card that owns the byte (an index
# into PHI512_CARDS' list), -1 when none does or there is no placement.
# rax, rcx, rdx, rsi, rdi, r8 to r11 clobbered.
	.globl chunk_owner
chunk_owner:
	pushq %rbx
	movq %rdi, %rbx
	call place_load
	cmpq $1, pl_state(%rip)
	jne 8f
	movq %rbx, %rdi
	call own_lookup
	cmpl $-2, %eax
	jne 9f
	movq %rbx, %rdi
	call own_examine
	testl %eax, %eax
	jz 8f
	movq %rbx, %rdi
	call own_lookup
	cmpl $-2, %eax
	jne 9f
8:	movl $-1, %eax
9:	popq %rbx
	ret

# own_lookup(address rdi): eax the card of the owned range holding it,
# -2 when none does.
own_lookup:
	leaq own_tab(%rip), %rcx
	movq own_n(%rip), %rdx
1:	testq %rdx, %rdx
	jz 8f
	cmpq 0(%rcx), %rdi
	jb 2f
	cmpq 8(%rcx), %rdi
	jae 2f
	movl 16(%rcx), %eax
	ret
2:	addq $OWN_BYTES, %rcx
	decq %rdx
	jmp 1b
8:	movl $-2, %eax
	ret

# own_examine(address rdi): the mapping holding the address, unless it
# was examined before: its line of /proc/self/maps (start, end, file
# offset, path) and every placement line of that path made an owned
# range (the overlap of the line's file range and the mapping's). eax 1
# when the mapping was examined now, 0 otherwise.
own_examine:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $16, %rsp				# 0 the path's length
	movq %rdi, %rbx
	call mapped_range			# the mapping's start from the cached table: one examined before costs no read
	testq %rax, %rax
	jz 80f
	leaq ex_tab(%rip), %rcx
	movq ex_n(%rip), %rdx
11:	testq %rdx, %rdx
	jz 12f
	cmpq (%rcx), %rax
	je 80f
	addq $8, %rcx
	decq %rdx
	jmp 11b
12:	call maps_read
	testq %rax, %rax
	jle 80f
	leaq maps_buf(%rip), %rsi
1:	cmpb $0, (%rsi)
	je 80f
	call parse_hex
	movq %rax, %r12				# start
	incq %rsi				# '-'
	call parse_hex
	movq %rax, %r13				# end
	cmpq %r12, %rbx
	jb 2f
	cmpq %r13, %rbx
	jb 3f
2:	movzbl (%rsi), %eax			# not this one: to the next line
	testl %eax, %eax
	jz 80f
	incq %rsi
	cmpl $'\n', %eax
	jne 2b
	jmp 1b
3:	# examined before?
	leaq ex_tab(%rip), %rcx
	movq ex_n(%rip), %rdx
31:	testq %rdx, %rdx
	jz 32f
	cmpq (%rcx), %r12
	je 80f
	addq $8, %rcx
	decq %rdx
	jmp 31b
32:	movq ex_n(%rip), %rdx
	cmpq $EX_MAX, %rdx
	jae 33f
	leaq ex_tab(%rip), %rcx
	movq %r12, (%rcx,%rdx,8)
	incq ex_n(%rip)
33:	addq $6, %rsi				# " rwxp "
	call parse_hex
	movq %rax, %r14				# the file offset of start
	call pl_blank				# the device, the inode, then the path
34:	movzbl (%rsi), %eax
	cmpl $' ', %eax
	je 35f
	testl %eax, %eax
	jz 80f
	cmpl $'\n', %eax
	je 79f
	incq %rsi
	jmp 34b
35:	call pl_blank
36:	movzbl (%rsi), %eax
	cmpl $' ', %eax
	je 37f
	testl %eax, %eax
	jz 80f
	cmpl $'\n', %eax
	je 79f
	incq %rsi
	jmp 36b
37:	call pl_blank
	movq %rsi, %r15				# the path
	xorl %ecx, %ecx
38:	movzbl (%r15,%rcx), %eax
	testl %eax, %eax
	jz 39f
	cmpl $'\n', %eax
	je 39f
	incq %rcx
	jmp 38b
39:	movq %rcx, 0(%rsp)
	testq %rcx, %rcx
	jz 79f					# an anonymous mapping
	# every placement line of this path
	xorl %r8d, %r8d
4:	cmpq pl_n(%rip), %r8
	jae 79f
	movq %r8, %r9
	shlq $5, %r9
	leaq pl_tab(%rip), %rax
	addq %rax, %r9				# the line
	movq 24(%r9), %r10			# its path (NUL-terminated)
	xorl %ecx, %ecx
41:	cmpq 0(%rsp), %rcx
	jae 42f
	movzbl (%r10,%rcx), %eax
	cmpb (%r15,%rcx), %al
	jne 49f
	incq %rcx
	jmp 41b
42:	cmpb $0, (%r10,%rcx)
	jne 49f
	# the overlap of [off, off + bytes) and [r14, r14 + end - start)
	movq 8(%r9), %rax			# lo = max(off, r14)
	cmpq %r14, %rax
	jae 43f
	movq %r14, %rax
43:	movq 8(%r9), %rdx
	addq 16(%r9), %rdx			# hi = min(off + bytes, r14 + end - start)
	movq %r13, %rcx
	subq %r12, %rcx
	addq %r14, %rcx
	cmpq %rcx, %rdx
	jbe 44f
	movq %rcx, %rdx
44:	cmpq %rdx, %rax
	jae 49f
	movq own_n(%rip), %rcx
	cmpq $OWN_MAX, %rcx
	jae 79f
	imulq $OWN_BYTES, %rcx, %rcx
	leaq own_tab(%rip), %r10
	addq %r10, %rcx
	subq %r14, %rax
	addq %r12, %rax
	movq %rax, 0(%rcx)			# the address range
	subq %r14, %rdx
	addq %r12, %rdx
	movq %rdx, 8(%rcx)
	movq 0(%r9), %rax
	movq %rax, 16(%rcx)
	incq own_n(%rip)
49:	incq %r8
	jmp 4b
79:	movl $1, %eax
	jmp 90f
80:	xorl %eax, %eax
90:	addq $16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
	.section .note.GNU-stack,"",@progbits
