# elf.S: where a function is in this process: the executable mapped
# through /proc/self/exe is read for its symbol table (.symtab, which a
# binary keeps unless stripped), and the load address of the executable
# comes from /proc/self/maps (the first mapping of a file at offset 0:
# the ELF header's). A symbol's address is its value plus that base (a
# position-independent executable's segments keep p_vaddr = p_offset
# aside from the page they share; the first mapping starts at the base).
# See elf.md.

	.include "common.inc"
	.include "defs.inc"

	.set EH_SHOFF, 40
	.set EH_SHENTSIZE, 58
	.set EH_SHNUM, 60
	.set EH_SHSTRNDX, 62
	.set SH_NAME, 0
	.set SH_TYPE, 4
	.set SH_OFFSET, 24
	.set SH_SIZE, 32
	.set SH_LINK, 40
	.set SH_ENTSIZE, 56
	.set SH_BYTES, 64
	.set SHT_SYMTAB, 2
	.set ST_NAME, 0
	.set ST_INFO, 4
	.set ST_VALUE, 8
	.set ST_SIZE, 16
	.set ST_BYTES, 24
	.set STT_FUNC, 2
	.set MAPS_CAP, 65536

	.bss
	.balign 64
exe_map:	.skip 8			# the executable's file, mapped whole
exe_len:	.skip 8
exe_base:	.skip 8			# where the executable is loaded
maps_buf:	.skip MAPS_CAP
stat_buf:	.skip STAT_BYTES
mem_fd:	.skip 8			# /proc/self/mem, opened at the first copy

	.section .rodata
s_exe:	.asciz "/proc/self/exe"
s_maps:	.asciz "/proc/self/maps"
s_mem:	.asciz "/proc/self/mem"

	.text

# elf_init: the executable mapped, its base found; eax 0, or -1.
	.globl elf_init
elf_init:
	pushq %rbx
	pushq %r12
	cmpq $0, exe_map(%rip)
	jne 8f
	leaq s_exe(%rip), %rdi
	movl $O_RDONLY | O_CLOEXEC, %esi
	xorl %edx, %edx
	SYS SYS_open
	testq %rax, %rax
	js 9f
	movq %rax, %rbx
	movl %ebx, %edi
	leaq stat_buf(%rip), %rsi
	SYS SYS_fstat
	testq %rax, %rax
	jnz 9f
	movq stat_buf + STAT_SIZE(%rip), %r12
	xorl %edi, %edi
	movq %r12, %rsi
	movl $PROT_READ, %edx
	movl $MAP_PRIVATE, %r10d
	movq %rbx, %r8
	xorl %r9d, %r9d
	SYS SYS_mmap
	movq %rax, %rdx
	movl %ebx, %edi
	SYS SYS_close
	cmpq $MAP_FAILED_MAX, %rdx
	ja 9f
	movq %rdx, exe_map(%rip)
	movq %r12, exe_len(%rip)
	# the base: the first line of /proc/self/maps whose offset field is
	# 00000000 and whose path is a file (the executable is mapped first)
	leaq s_maps(%rip), %rdi
	movl $O_RDONLY | O_CLOEXEC, %esi
	xorl %edx, %edx
	SYS SYS_open
	testq %rax, %rax
	js 9f
	movq %rax, %rbx
	movl %ebx, %edi
	leaq maps_buf(%rip), %rsi
	movl $MAPS_CAP - 1, %edx
	SYS SYS_read
	movq %rax, %r12
	movl %ebx, %edi
	SYS SYS_close
	testq %r12, %r12
	jle 9f
	leaq maps_buf(%rip), %rax
	movb $0, (%rax,%r12)
	# the first line: "START-END perms OFFSET dev inode path"
	leaq maps_buf(%rip), %rsi
	call parse_hex
	movq %rax, exe_base(%rip)
8:	xorl %eax, %eax
	popq %r12
	popq %rbx
	ret
9:	movl $-1, %eax
	popq %r12
	popq %rbx
	ret

# parse_hex: the hexadecimal number at rsi, in rax; rsi past it.
parse_hex:
	xorl %eax, %eax
1:	movzbl (%rsi), %ecx
	subl $'0', %ecx
	cmpl $9, %ecx
	jbe 2f
	movzbl (%rsi), %ecx
	orl $0x20, %ecx
	subl $'a', %ecx
	cmpl $5, %ecx
	ja 3f
	addl $10, %ecx
2:	shlq $4, %rax
	orq %rcx, %rax
	incq %rsi
	jmp 1b
3:	ret

# elf_find(name rdi): the function symbol's address in rax and size in
# rdx, or rax 0. Walks .symtab of the mapped executable.
	.globl elf_find
elf_find:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %r15				# the name
	movq exe_map(%rip), %rbx
	testq %rbx, %rbx
	jz 9f
	movq EH_SHOFF(%rbx), %r12
	addq %rbx, %r12				# section headers
	movzwl EH_SHNUM(%rbx), %r13d
	xorl %r14d, %r14d
1:	cmpl %r13d, %r14d
	jae 9f
	movq %r14, %rax
	shlq $6, %rax
	addq %r12, %rax
	cmpl $SHT_SYMTAB, SH_TYPE(%rax)
	je 2f
	incl %r14d
	jmp 1b
2:	# the symbol table at rax, its string table through sh_link
	movl SH_LINK(%rax), %ecx
	shlq $6, %rcx
	addq %r12, %rcx
	movq SH_OFFSET(%rcx), %rcx
	addq %rbx, %rcx				# strtab
	movq SH_OFFSET(%rax), %rdx
	addq %rbx, %rdx				# symbols
	movq SH_SIZE(%rax), %r8
	addq %rdx, %r8				# end
3:	cmpq %r8, %rdx
	jae 9f
	movzbl ST_INFO(%rdx), %eax
	andl $0xf, %eax
	cmpl $STT_FUNC, %eax
	jne 5f
	movl ST_NAME(%rdx), %eax
	leaq (%rcx,%rax), %rsi
	movq %r15, %rdi
	pushq %rcx
	pushq %rdx
	pushq %r8
	call str_eq
	popq %r8
	popq %rdx
	popq %rcx
	testl %eax, %eax
	jz 5f
	movq ST_VALUE(%rdx), %rax
	addq exe_base(%rip), %rax
	movq ST_SIZE(%rdx), %rdx
	jmp 8f
5:	addq $ST_BYTES, %rdx
	jmp 3b
9:	xorl %eax, %eax
	xorl %edx, %edx
8:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# mapped_range(address rdi): the mapping holding it, start in rax and end
# in rdx, or both 0: /proc/self/maps read and scanned each call (a line
# is "START-END perms ..."; the file is small for a program of a few
# mappings; a cache comes with the residency table's host side).
	.globl mapped_range
mapped_range:
	pushq %rbx
	pushq %r12
	pushq %r13
	movq %rdi, %r13
	leaq s_maps(%rip), %rdi
	movl $O_RDONLY | O_CLOEXEC, %esi
	xorl %edx, %edx
	SYS SYS_open
	testq %rax, %rax
	js 9f
	movq %rax, %rbx
	movl %ebx, %edi
	leaq maps_buf(%rip), %rsi
	movl $MAPS_CAP - 1, %edx
	SYS SYS_read
	movq %rax, %r12
	movl %ebx, %edi
	SYS SYS_close
	testq %r12, %r12
	jle 9f
	leaq maps_buf(%rip), %rax
	movb $0, (%rax,%r12)
	leaq maps_buf(%rip), %rsi
1:	cmpb $0, (%rsi)
	je 9f
	call parse_hex				# start
	movq %rax, %r8
	incq %rsi				# '-'
	call parse_hex				# end
	cmpq %r8, %r13
	jb 2f
	cmpq %rax, %r13
	jae 2f
	movq %rax, %rdx
	movq %r8, %rax
	jmp 8f
2:	# to the next line
	movzbl (%rsi), %ecx
	testl %ecx, %ecx
	jz 9f
	incq %rsi
	cmpl $'\n', %ecx
	jne 2b
	jmp 1b
9:	xorl %eax, %eax
	xorl %edx, %edx
8:	popq %r13
	popq %r12
	popq %rbx
	ret

# copy_mapped(dst rdi, src rsi, len rdx): the parts of [src, src + len)
# the program has mapped readable, copied to dst at the same offsets (a
# chunk of the program's memory staged for the card: an array may start
# or end inside it, with nothing, or a guard page, beside it). The copy
# goes through /proc/self/mem (pread), so a mapping that cannot be read
# after all (a file mapping past its file's end: SIGBUS on a load) ends
# as a short read, never a signal. /proc/self/maps is read and scanned
# per call. rax the bytes copied.
	.globl copy_mapped
copy_mapped:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %r12				# dst
	movq %rsi, %r13				# src
	leaq (%rsi,%rdx), %r14			# src end
	xorl %r15d, %r15d			# copied
	cmpq $0, mem_fd(%rip)
	jne 14f
	leaq s_mem(%rip), %rdi
	movl $O_RDONLY | O_CLOEXEC, %esi
	xorl %edx, %edx
	SYS SYS_open
	testq %rax, %rax
	js 9f
	movq %rax, mem_fd(%rip)
14:	leaq s_maps(%rip), %rdi
	movl $O_RDONLY | O_CLOEXEC, %esi
	xorl %edx, %edx
	SYS SYS_open
	testq %rax, %rax
	js 9f
	movq %rax, %rbx
	movl %ebx, %edi
	leaq maps_buf(%rip), %rsi
	movl $MAPS_CAP - 1, %edx
	SYS SYS_read
	movq %rax, %rcx
	movl %ebx, %edi
	pushq %rcx
	SYS SYS_close
	popq %rcx
	testq %rcx, %rcx
	jle 9f
	leaq maps_buf(%rip), %rax
	movb $0, (%rax,%rcx)
	leaq maps_buf(%rip), %rsi
1:	cmpb $0, (%rsi)
	je 9f
	call parse_hex				# start
	movq %rax, %r8
	incq %rsi
	call parse_hex				# end
	movq %rax, %r9
	incq %rsi				# ' '
	cmpb $'r', (%rsi)
	jne 2f
	# the overlap of [r8, r9) with [r13, r14)
	cmpq %r13, %r8
	jae 11f
	movq %r13, %r8
11:	cmpq %r14, %r9
	jbe 12f
	movq %r14, %r9
12:	cmpq %r9, %r8
	jae 2f
	pushq %rsi
	movq %r8, %rsi
	subq %r13, %rsi
	addq %r12, %rsi				# dst + (start - src)
	movq %r9, %rdx
	subq %r8, %rdx				# bytes
	movq %r8, %r10				# the offset = the address
	movq mem_fd(%rip), %rdi
	SYS SYS_pread64
	testq %rax, %rax
	js 13f
	addq %rax, %r15
13:	popq %rsi
2:	movzbl (%rsi), %ecx
	testl %ecx, %ecx
	jz 9f
	incq %rsi
	cmpl $'\n', %ecx
	jne 2b
	jmp 1b
9:	movq %r15, %rax
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
