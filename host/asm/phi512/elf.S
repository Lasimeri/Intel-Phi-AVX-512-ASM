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
	.set MAPS_CAP, 1048576			# /proc/self/maps whole (a read returns a page of lines at a time: maps_read loops)

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
	call maps_read
	testq %rax, %rax
	jle 9f
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
	call maps_read
	testq %rax, %rax
	jle 9f
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
14:	call maps_read
	testq %rax, %rax
	jle 9f
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

	.text
# elf_func_at(addr rdi): the function (a FUNC symbol of .symtab with a
# size) of the loaded object that holds the address, the executable or
# a shared object (obj_at): rax its loaded address (0 when none), rdx
# its size, rcx its name (in the file's string table, mapped for good).
	.globl elf_func_at
elf_func_at:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $8, %rsp				# the object's entry
	movq %rdi, %r15
	call obj_at
	testq %rax, %rax
	jz 9f
	movq %rax, (%rsp)
	subq OBJ_BASE(%rax), %r15		# the offset in the object
	movq OBJ_MAP(%rax), %rbx
	movq EH_SHOFF(%rbx), %r12
	addq %rbx, %r12
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
2:	movl SH_LINK(%rax), %ecx
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
	cmpq $0, ST_SIZE(%rdx)
	je 5f
	movq ST_VALUE(%rdx), %rax
	cmpq %rax, %r15
	jb 5f
	addq ST_SIZE(%rdx), %rax
	cmpq %rax, %r15
	jae 5f
	movq ST_VALUE(%rdx), %rax
	movq (%rsp), %rdi
	addq OBJ_BASE(%rdi), %rax
	movl ST_NAME(%rdx), %esi
	addq %rsi, %rcx				# the name
	movq ST_SIZE(%rdx), %rdx
	jmp 8f
5:	addq $ST_BYTES, %rdx
	jmp 3b
9:	xorl %eax, %eax
	xorl %edx, %edx
	xorl %ecx, %ecx
8:	addq $8, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# The loaded objects seen so far: the executable and the shared objects
# a fault has landed in, each mapped whole from its file for its symbol
# table, with its load base (the mapping's start less its file offset:
# the text segment's virtual address equals its file offset) and the
# span of its mappings.
	.bss
	.balign 64
obj_tab:	.skip OBJ_MAX * OBJ_BYTES
obj_n:		.skip 8
	.text

# maps_fields(rsi just after a line's END field): rax the line's file
# offset, rsi at its path (or at the line's end when it has none).
maps_fields:
	addq $6, %rsi				# ' ', the four permission characters, ' '
	call parse_hex				# the offset
	pushq %rax
	incq %rsi
1:	cmpb $' ', (%rsi)			# the device
	je 2f
	incq %rsi
	jmp 1b
2:	incq %rsi
3:	movzbl (%rsi), %ecx			# the inode
	cmpl $' ', %ecx
	je 4f
	cmpl $'\n', %ecx
	je 5f
	testl %ecx, %ecx
	jz 5f
	incq %rsi
	jmp 3b
4:	cmpb $' ', (%rsi)			# the spaces before the path
	jne 5f
	incq %rsi
	jmp 4b
5:	popq %rax
	ret

# obj_at(addr rdi): the loaded object (a file-backed mapping) holding
# the address: its entry (OBJ_*), or 0 (not a file, or not an ELF file,
# or the table full).
	.globl obj_at
obj_at:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %r12
	leaq obj_tab(%rip), %rbx
	movq obj_n(%rip), %rcx
1:	testq %rcx, %rcx
	jz 2f
	cmpq OBJ_LO(%rbx), %r12
	jb 11f
	cmpq OBJ_HI(%rbx), %r12
	jae 11f
	movq %rbx, %rax
	jmp 8f
11:	addq $OBJ_BYTES, %rbx
	decq %rcx
	jmp 1b
2:	call maps_read
	testq %rax, %rax
	jle 9f
	leaq maps_buf(%rip), %rsi
3:	cmpb $0, (%rsi)
	je 9f
	call parse_hex
	movq %rax, %r13				# start
	incq %rsi
	call parse_hex
	movq %rax, %r14				# end
	cmpq %r13, %r12
	jb 4f
	cmpq %r14, %r12
	jae 4f
	call maps_fields
	movq %rax, %r15				# the file offset
	cmpb $'/', (%rsi)
	jne 9f					# not a file
	jmp 5f
4:	movzbl (%rsi), %ecx
	testl %ecx, %ecx
	jz 9f
	incq %rsi
	cmpl $'\n', %ecx
	jne 4b
	jmp 3b
5:	movq obj_n(%rip), %rax
	cmpq $OBJ_MAX, %rax
	jae 9f
	imulq $OBJ_BYTES, %rax, %rbx
	leaq obj_tab(%rip), %rax
	addq %rax, %rbx				# the new entry
	leaq OBJ_PATH(%rbx), %rdi
	xorl %ecx, %ecx
51:	movzbl (%rsi,%rcx), %eax
	cmpl $'\n', %eax
	je 52f
	testl %eax, %eax
	jz 52f
	cmpl $OBJ_PATH_CAP - 1, %ecx
	jae 52f
	movb %al, (%rdi,%rcx)
	incl %ecx
	jmp 51b
52:	movb $0, (%rdi,%rcx)
	leaq OBJ_PATH(%rbx), %rdi
	movl $O_RDONLY | O_CLOEXEC, %esi
	xorl %edx, %edx
	SYS SYS_open
	testq %rax, %rax
	js 9f
	movq %rax, %r14				# the file
	movl %r14d, %edi
	leaq stat_buf(%rip), %rsi
	SYS SYS_fstat
	testq %rax, %rax
	jnz 53f
	movq stat_buf + STAT_SIZE(%rip), %rsi
	movq %rsi, OBJ_LEN(%rbx)
	xorl %edi, %edi
	movl $PROT_READ, %edx
	movl $MAP_PRIVATE, %r10d
	movq %r14, %r8
	xorl %r9d, %r9d
	SYS SYS_mmap
	movq %rax, OBJ_MAP(%rbx)
	movl %r14d, %edi
	SYS SYS_close
	movq OBJ_MAP(%rbx), %rax
	cmpq $MAP_FAILED_MAX, %rax
	ja 9f
	cmpl $0x464c457f, (%rax)		# "\177ELF"
	jne 9f
	movq %r13, %rax
	subq %r15, %rax
	movq %rax, OBJ_BASE(%rbx)
	# the span: every line of the maps with this path
	movq $-1, OBJ_LO(%rbx)
	movq $0, OBJ_HI(%rbx)
	leaq maps_buf(%rip), %rsi
6:	cmpb $0, (%rsi)
	je 7f
	call parse_hex
	movq %rax, %r13
	incq %rsi
	call parse_hex
	movq %rax, %r14
	call maps_fields
	movq %r13, %rdx
	subq %rax, %rdx
	cmpq OBJ_BASE(%rbx), %rdx		# a mapping of the loaded object: start less file offset is the base (another mapping of the same file is not)
	jne 63f
	leaq OBJ_PATH(%rbx), %rdi
	xorl %ecx, %ecx
61:	movzbl (%rdi,%rcx), %eax
	movzbl (%rsi,%rcx), %edx
	testl %eax, %eax
	jz 62f
	cmpl %eax, %edx
	jne 63f
	incl %ecx
	jmp 61b
62:	cmpl $'\n', %edx
	je 64f
	testl %edx, %edx
	jnz 63f
64:	cmpq OBJ_LO(%rbx), %r13
	jae 65f
	movq %r13, OBJ_LO(%rbx)
65:	cmpq OBJ_HI(%rbx), %r14
	jbe 63f
	movq %r14, OBJ_HI(%rbx)
63:	movzbl (%rsi), %ecx
	testl %ecx, %ecx
	jz 7f
	incq %rsi
	cmpl $'\n', %ecx
	jne 63b
	jmp 6b
7:	incq obj_n(%rip)
	movq %rbx, %rax
	jmp 8f
53:	movl %r14d, %edi
	SYS SYS_close
9:	xorl %eax, %eax
8:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

	.text
# maps_read: /proc/self/maps whole into maps_buf, NUL-terminated; rax
# the bytes, 0 or negative when it cannot be read. One read returns a
# page of whole lines at a time (4051 bytes measured on the rack kernel
# 7.2.9, 2026-10-13), so the reads loop to the end of the file; the
# stack is the last line, and a short read lost it once.
	.globl maps_read
maps_read:
	pushq %rbx
	pushq %r12
	leaq s_maps(%rip), %rdi
	movl $O_RDONLY | O_CLOEXEC, %esi
	xorl %edx, %edx
	SYS SYS_open
	testq %rax, %rax
	js 9f
	movq %rax, %rbx
	xorl %r12d, %r12d			# the bytes so far
1:	movl %ebx, %edi
	leaq maps_buf(%rip), %rsi
	addq %r12, %rsi
	movl $MAPS_CAP - 1, %edx
	subq %r12, %rdx
	jle 2f					# full
	SYS SYS_read
	testq %rax, %rax
	jle 2f
	addq %rax, %r12
	jmp 1b
2:	movl %ebx, %edi
	SYS SYS_close
	leaq maps_buf(%rip), %rax
	movb $0, (%rax,%r12)
	movq %r12, %rax
9:	popq %r12
	popq %rbx
	ret
