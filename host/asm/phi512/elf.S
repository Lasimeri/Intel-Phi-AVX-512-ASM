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
	.globl copy_mapped_pages
copy_mapped_pages: .skip 2		# the pages of the last copy_mapped's first 64 KiB that were readable (bit per 4 KiB)
	.globl copy_mapped_wpages
copy_mapped_wpages: .skip 2		# ... and writable
	.balign 8

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
	cmpq $0, maps_valid(%rip)
	jne 1f
	pushq %rdi
	call maps_load
	popq %rdi
1:	leaq maps_tab(%rip), %rcx
	movq maps_n(%rip), %r8
2:	testq %r8, %r8
	jz 9f
	cmpq 0(%rcx), %rdi
	jb 3f
	cmpq 8(%rcx), %rdi
	jae 3f
	movq 0(%rcx), %rax
	movq 8(%rcx), %rdx
	ret
3:	addq $MAPT_BYTES, %rcx
	decq %r8
	jmp 2b
9:	xorl %eax, %eax
	xorl %edx, %edx
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
	pushq %rbp
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %r12				# dst
	movq %rsi, %r13				# src
	leaq (%rsi,%rdx), %r14			# src end
	xorl %r15d, %r15d			# copied
	xorl %ebp, %ebp				# the pages (bits 0-15) and the writable ones (16-31): in a register, the workers call this at once (pool.S)
	cmpq $0, mem_fd(%rip)
	jne 14f
	leaq s_mem(%rip), %rdi
	movl $O_RDONLY | O_CLOEXEC, %esi
	xorl %edx, %edx
	SYS SYS_open
	testq %rax, %rax
	js 9f
	movq %rax, mem_fd(%rip)
14:	cmpq $0, maps_valid(%rip)
	jne 141f
	call maps_load
141:	leaq maps_tab(%rip), %rsi		# the parsed mappings (maps_load: one read of /proc/self/maps a fault)
	movq maps_n(%rip), %rbx
1:	testq %rbx, %rbx
	jz 9f
	movq 0(%rsi), %r8			# start
	movq 8(%rsi), %r9			# end
	testb $MAPF_R, 16(%rsi)
	jz 2f
	# the overlap of [r8, r9) with [r13, r14)
	cmpq %r13, %r8
	jae 11f
	movq %r13, %r8
11:	cmpq %r14, %r9
	jbe 12f
	movq %r14, %r9
12:	cmpq %r9, %r8
	jae 2f
	# the pages of [r8, r9) within src's first 64 KiB, for a unit's bitmap
	movq %r8, %rax
	subq %r13, %rax
	shrq $12, %rax
	movq %r9, %rcx
	subq %r13, %rcx
	decq %rcx
	shrq $12, %rcx
	cmpq $16, %rcx
	jb 15f
	movq $15, %rcx
15:	cmpq %rcx, %rax
	ja 16f
	btsl %eax, %ebp
	testb $MAPF_W, 16(%rsi)
	jz 17f
	leal 16(%rax), %r11d
	btsl %r11d, %ebp
17:	incq %rax
	jmp 15b
16:	pushq %rsi
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
2:	addq $MAPT_BYTES, %rsi
	decq %rbx
	jmp 1b
9:	movq %r15, %rax
	movw %bp, copy_mapped_pages(%rip)	# (the single-threaded callers read these)
	movl %ebp, %edx
	shrl $16, %edx
	movw %dx, copy_mapped_wpages(%rip)
	movl %ebp, %edx				# the bitmaps returned: pages, writable pages << 16
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbp
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

	.text
# heap_bounds: the program's [heap] mapping (the main arena's brk heap),
# start in rax and end in rdx, or both 0 (for region.S's heap walk).
	.globl heap_bounds
heap_bounds:
	pushq %rbx
	pushq %r12
	pushq %r13
	call maps_read
	testq %rax, %rax
	jle 9f
	leaq maps_buf(%rip), %rsi
1:	cmpb $0, (%rsi)
	je 9f
	call parse_hex
	movq %rax, %r12				# start
	incq %rsi				# '-'
	call parse_hex
	movq %rax, %r13				# end
2:	movzbl (%rsi), %ecx			# the rest of the line: "[heap]"?
	testl %ecx, %ecx
	jz 9f
	incq %rsi
	cmpl $'\n', %ecx
	je 1b
	cmpl $'[', %ecx
	jne 2b
	cmpl $0x70616568, (%rsi)		# "heap"
	jne 2b
	cmpb $']', 4(%rsi)
	jne 2b
	movq %r12, %rax
	movq %r13, %rdx
	jmp 8f
9:	xorl %eax, %eax
	xorl %edx, %edx
8:	popq %r13
	popq %r12
	popq %rbx
	ret

	.text
	.set MAPT_MAX, 16384
	.set MAPT_BYTES, 24			# start, end, flags (MAPF_*)
	.set MAPF_R, 1
	.set MAPF_W, 2
# maps_load: /proc/self/maps read once and parsed into maps_tab (every
# mapping's start, end, readable and writable bits), maps_valid set:
# copy_mapped and mapped_range consult the table instead of reading and
# parsing the file per call (that was 41 % of the faulting thread's time
# in llama-server, a read per unit per region, 2026-10-14); sigill.S
# invalidates it at every fault (maps_invalidate). eax the mappings.
	.globl maps_load, maps_invalidate
maps_load:
	pushq %rbx
	pushq %r12
	pushq %r13
	movq $0, maps_n(%rip)
	call maps_read
	testq %rax, %rax
	jle 8f
	leaq maps_buf(%rip), %rsi
	leaq maps_tab(%rip), %r12
	xorl %ebx, %ebx
1:	cmpb $0, (%rsi)
	je 8f
	cmpq $MAPT_MAX, %rbx
	jae 8f
	call parse_hex
	movq %rax, 0(%r12)
	incq %rsi				# '-'
	call parse_hex
	movq %rax, 8(%r12)
	incq %rsi				# ' '
	xorl %eax, %eax
	cmpb $'r', 0(%rsi)
	jne 2f
	orl $MAPF_R, %eax
2:	cmpb $'w', 1(%rsi)
	jne 3f
	orl $MAPF_W, %eax
3:	movq %rax, 16(%r12)
	addq $MAPT_BYTES, %r12
	incq %rbx
4:	movzbl (%rsi), %ecx			# to the next line
	testl %ecx, %ecx
	jz 8f
	incq %rsi
	cmpl $'\n', %ecx
	jne 4b
	jmp 1b
8:	movq %rbx, maps_n(%rip)
	movq $1, maps_valid(%rip)
	movl %ebx, %eax
	popq %r13
	popq %r12
	popq %rbx
	ret
maps_invalidate:
	movq $0, maps_valid(%rip)
	ret
	.bss
	.balign 64
maps_tab:	.skip MAPT_MAX * MAPT_BYTES
maps_n:		.skip 8
maps_valid:	.skip 8
	.text

	.text
# maps_ensure: the mappings' table loaded if it is not (before pool.S's
# workers read it at once: two loading it together would tear it).
	.globl maps_ensure
maps_ensure:
	cmpq $0, maps_valid(%rip)
	jne 1f
	call maps_load
1:	ret

# chunk_immutable(chunk rdi, 2 MiB aligned): eax 1 when the whole chunk
# lies inside one mapping the program has readable and not writable (the
# mmapped model, a DSO's text and constants), else 0. Such a chunk goes to
# a card as one pool page filled once (region.S ro_need): nothing in the
# program can change it, so it needs no shadow, no refresh and no
# write-back. A chunk at a mapping's edge (something else, maybe
# writable, in its other part) or across two mappings is not one: the
# 64 KiB unit path takes it, as before. rcx, rdx, rsi, r8 clobbered.
	.text
	.globl chunk_immutable
chunk_immutable:
	cmpq $0, maps_valid(%rip)
	jne 1f
	pushq %rdi
	call maps_load
	popq %rdi
1:	leaq maps_tab(%rip), %rcx
	movq maps_n(%rip), %r8
	leaq CHUNK(%rdi), %rsi			# the chunk's end
2:	testq %r8, %r8
	jz 9f
	cmpq 0(%rcx), %rdi
	jb 3f
	cmpq 8(%rcx), %rdi
	jae 3f
	cmpq 8(%rcx), %rsi			# the mapping holding the chunk's start: the end inside it too
	ja 9f
	movq 16(%rcx), %rax
	andl $MAPF_R | MAPF_W, %eax
	cmpl $MAPF_R, %eax
	jne 9f
	movl $1, %eax
	ret
3:	addq $MAPT_BYTES, %rcx
	decq %r8
	jmp 2b
9:	xorl %eax, %eax
	ret

# plt_name(stub rdi): the symbol a PLT stub jumps to (the stub's GOT slot,
# found in a RELA section of its object's file, the symbol of that
# relocation in the linked .dynsym, its name in that table's strings), in
# rax; 0 when it is not a stub or nothing matches. For blob.S: a call to
# memcpy, memmove or memset through the PLT becomes an inline copy on the
# card (2026-10-14: ggml_graph_compute_thread's memcpy calls were ~950
# card round trips every 5 s).
	.globl plt_name
plt_name:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %rbx
	movq %rdi, %rcx				# the GOT slot from the stub (as plt_resolve reads it)
	cmpl $0xfa1e0ff3, (%rcx)
	jne 1f
	addq $4, %rcx
	cmpb $0xf2, (%rcx)
	jne 1f
	incq %rcx
1:	cmpw $0x25ff, (%rcx)
	jne 8f
	movslq 2(%rcx), %rdx
	leaq 6(%rcx,%rdx), %r12			# the slot's address
	movq %rbx, %rdi
	call obj_at
	testq %rax, %rax
	jz 8f
	movq OBJ_MAP(%rax), %r13		# the file
	testq %r13, %r13
	jz 8f
	subq OBJ_BASE(%rax), %r12		# the slot as an r_offset
	movq 0x28(%r13), %r14			# e_shoff
	addq %r13, %r14				# the section headers
	movzwl 0x3c(%r13), %r15d		# e_shnum
2:	testl %r15d, %r15d
	jz 8f
	decl %r15d
	movl %r15d, %eax
	shll $6, %eax				# 64 bytes a header
	leaq (%r14,%rax), %rbx			# this header
	cmpl $4, 4(%rbx)			# SHT_RELA
	jne 2b
	movq 0x18(%rbx), %rcx
	addq %r13, %rcx				# its entries
	movq 0x20(%rbx), %rdx			# its bytes
3:	cmpq $24, %rdx
	jb 2b
	cmpq (%rcx), %r12
	je 4f
	addq $24, %rcx
	subq $24, %rdx
	jmp 3b
4:	movq 8(%rcx), %rax
	shrq $32, %rax				# the symbol's index
	movl 0x28(%rbx), %edx			# sh_link: the symbol table
	shll $6, %edx
	leaq (%r14,%rdx), %rdx			# its header
	imulq $24, %rax, %rax
	addq 0x18(%rdx), %rax
	addq %r13, %rax				# the symbol
	movl (%rax), %eax			# st_name
	movl 0x28(%rdx), %edx			# its sh_link: the strings
	shll $6, %edx
	movq 0x18(%r14,%rdx), %rdx
	addq %r13, %rdx
	addq %rdx, %rax				# the name
	jmp 9f
8:	xorl %eax, %eax
9:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
