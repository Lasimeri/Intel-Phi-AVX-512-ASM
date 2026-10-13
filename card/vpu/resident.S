# resident.S: the program's memory on the card, chunk by chunk (protocol
# v3's K_RESIDENT, vpu_fexec.h). The dispatcher maps a pool of huge pages
# shared with the slot processes it forks afterwards and learns each
# page's frame from pagemap; a K_RESIDENT names a 2 MiB chunk the host
# staged in the window's RESIDENT area and the program address it lives
# at, the dispatcher gives it a pool page and has the DMA engine copy it
# straight into that page's frame (cdma_submit_phys), the slot that asked
# waits for the copy and marks the chunk resident; before a run every
# slot process moves the pool pages it has not yet (mremap, the mapping
# shared by all of them) to the program's addresses, so a function finds
# its memory where the program had it. See resident.md.

	.include "defs.inc"
	.include "proto.inc"

	.set RES_MAX, 2048			# 4 GiB of chunks at most
# The table, one entry per pool page, in a page shared by every process:
# the program address (0: free), the frame, the state (RS_*), the class,
# the DMA sequence number of its fill.
	.set RT_ADDR, 0
	.set RT_PHYS, 8
	.set RT_STATE, 16
	.set RT_CLASS, 20
	.set RT_SEQ, 24
	.set RT_BYTES, 32
	.set RS_FREE, 0
	.set RS_FILLING, 1
	.set RS_RESIDENT, 2
	.set EP_PIECE, 16383 * 64		# one descriptor's length (cdma.S, CD_LEN_MAX)
	.set SYS_mremap, 25
	.set MREMAP_MAYMOVE, 1
	.set MREMAP_FIXED, 2
	.set MAP_HUGETLB, 0x40000
	.set MAP_POPULATE, 0x8000

	.bss
	.balign 64
	.globl res_n
res_n:	.skip 8				# pool pages (0: no pool)
res_pool:	.skip 8			# the pool's base in this process
res_table:	.skip 8			# the shared table
res_mapped:	.skip RES_MAX / 8		# this process: which pool pages sit at their program address
pagemap_fd:	.skip 8
pm_buf:	.skip 64

	.section .rodata
s_res_pagemap:	.asciz "/proc/self/pagemap"
s_res_pool1:	.asciz "resident: pool of "
s_res_pool2:	.asciz " huge page(s), "
s_res_pool3:	.asciz " MiB, frames read"
s_res_nopool:	.asciz "resident: no pool: the huge pages or pagemap were refused (-R 0)"

	.text

# res_init(edi pages): the pool and its table, before the fork. On any
# failure the pool is 0 and a line says so.
	.globl res_init
res_init:
	pushq %rbx
	pushq %r12
	pushq %r13
	movl %edi, %ebx
	testl %ebx, %ebx
	jz 9f
	cmpl $RES_MAX, %ebx
	jbe 1f
	movl $RES_MAX, %ebx
1:	xorl %edi, %edi
	movq %rbx, %rsi
	shlq $21, %rsi
	movl $PROT_READ | PROT_WRITE, %edx
	movl $MAP_SHARED | MAP_ANONYMOUS | MAP_HUGETLB | MAP_POPULATE, %r10d
	movq $-1, %r8
	xorl %r9d, %r9d
	SYS SYS_mmap
	cmpq $MAP_FAILED_MAX, %rax
	ja .Lri_fail
	movq %rax, res_pool(%rip)
	xorl %edi, %edi
	movl $RES_MAX * RT_BYTES, %esi
	movl $PROT_READ | PROT_WRITE, %edx
	movl $MAP_SHARED | MAP_ANONYMOUS, %r10d
	movq $-1, %r8
	xorl %r9d, %r9d
	SYS SYS_mmap
	cmpq $MAP_FAILED_MAX, %rax
	ja .Lri_fail
	movq %rax, res_table(%rip)
	# each page's frame: the first pagemap entry of its 512 (a huge page
	# is one frame run)
	leaq s_res_pagemap(%rip), %rdi
	movl $O_RDONLY, %esi
	xorl %edx, %edx
	SYS SYS_open
	testq %rax, %rax
	js .Lri_fail
	movq %rax, pagemap_fd(%rip)
	xorl %r12d, %r12d
2:	cmpl %ebx, %r12d
	jae 3f
	movq res_pool(%rip), %r10
	movq %r12, %rax
	shlq $21, %rax
	addq %rax, %r10
	shrq $12, %r10
	shlq $3, %r10				# the entry's offset
	movq pagemap_fd(%rip), %rdi
	leaq pm_buf(%rip), %rsi
	movl $8, %edx
	SYS SYS_pread64
	cmpq $8, %rax
	jne .Lri_fail
	movq pm_buf(%rip), %rax
	btq $63, %rax
	jnc .Lri_fail
	movabsq $(1 << 55) - 1, %rdx
	andq %rdx, %rax
	jz .Lri_fail
	shlq $12, %rax
	movq res_table(%rip), %rcx
	movq %r12, %rdx
	shlq $5, %rdx
	movq %rax, RT_PHYS(%rcx,%rdx)
	incl %r12d
	jmp 2b
3:	movq %rbx, res_n(%rip)
	call l_begin
	leaq s_res_pool1(%rip), %rsi
	call w_str
	movl %ebx, %edi
	call w_dec
	leaq s_res_pool2(%rip), %rsi
	call w_str
	movl %ebx, %edi
	shll $1, %edi
	call w_dec
	leaq s_res_pool3(%rip), %rsi
	call w_str
	movl $1, %edi
	call l_end
9:	popq %r13
	popq %r12
	popq %rbx
	ret
.Lri_fail:
	movq $0, res_n(%rip)
	leaq s_res_nopool(%rip), %rsi
	call say
	jmp 9b

# res_assign(rdi program address, esi class): the pool page for that
# address (its own when it already has one, else a free one): eax the
# index, or -1 when the pool is full or absent. The dispatcher's.
	.globl res_assign
res_assign:
	movq res_table(%rip), %rcx
	xorl %edx, %edx
	movl $-1, %r8d				# a free one seen
1:	cmpq res_n(%rip), %rdx
	jae 3f
	movq %rdx, %rax
	shlq $5, %rax
	cmpq RT_ADDR(%rcx,%rax), %rdi
	je 4f
	cmpq $0, RT_ADDR(%rcx,%rax)
	jne 2f
	cmpl $-1, %r8d
	jne 2f
	movl %edx, %r8d
2:	incq %rdx
	jmp 1b
3:	cmpl $-1, %r8d
	je 5f
	movl %r8d, %edx
	movq %rdx, %rax
	shlq $5, %rax
	movq %rdi, RT_ADDR(%rcx,%rax)
4:	movl %esi, RT_CLASS(%rcx,%rax)
	movl $RS_FILLING, RT_STATE(%rcx,%rax)
	movl %edx, %eax
	ret
5:	movl $-1, %eax
	ret

# res_pull(edi index, esi staging index): the chunk staged at
# OFF_RESIDENT + staging x 2 MiB copied by the DMA engine into the pool
# page's frame, in pieces of one descriptor; rax the last piece's
# sequence number (kept in the entry), or 0 when a submit was refused.
# The dispatcher's.
	.globl res_pull
res_pull:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	movl %edi, %ebx
	pushq %rcx				# len
	movq %rsi, %r12
	shlq $21, %r12
	addq $OFF_RESIDENT, %r12		# the source offset
	addq %rdx, %r12				# ... of the range
	movq res_table(%rip), %rax
	movq %rbx, %rcx
	shlq $5, %rcx
	movq RT_PHYS(%rax,%rcx), %r13		# the destination frame
	testq %r13, %r13
	jnz 0f
	xorl %eax, %eax				# no frame: never a DMA to physical 0
	addq $8, %rsp
	jmp 9f
0:	addq %rdx, %r13				# ... at the range
	xorl %r14d, %r14d			# done
1:	cmpq (%rsp), %r14
	jae 3f
	movq (%rsp), %rdx
	subq %r14, %rdx
	cmpq $EP_PIECE, %rdx
	jbe 2f
	movq $EP_PIECE, %rdx
2:	leaq (%r12,%r14), %rdi
	leaq (%r13,%r14), %rsi
	pushq %rdx
	call cdma_submit_phys
	popq %rdx
	testq %rax, %rax
	jz 8f
	addq %rdx, %r14
	jmp 1b
3:	movq res_table(%rip), %rcx
	movq %rbx, %rdx
	shlq $5, %rdx
	movq %rax, RT_SEQ(%rcx,%rdx)
8:	addq $8, %rsp				# len
9:	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# res_mark(edi index): the entry resident without a fill (a page the
# program only writes: K_RESIDENT with a fill of 0 bytes). The
# dispatcher's.
	.globl res_mark
res_mark:
	movq res_table(%rip), %rcx
	movl %edi, %edx
	shlq $5, %rdx
	movl $RS_RESIDENT, RT_STATE(%rcx,%rdx)
	movq $0, RT_SEQ(%rcx,%rdx)
	ret

# res_wait(edi index): until the entry's fill has landed (the engine's
# status word, which every process can read in the shared DMA page);
# the entry marked resident. eax 1, or 0 after 2 s. A slot's.
	.globl res_wait
res_wait:
	pushq %rbx
	pushq %r12
	movl %edi, %ebx
	movq res_table(%rip), %rcx
	movq %rbx, %rdx
	shlq $5, %rdx
	movq RT_SEQ(%rcx,%rdx), %r12
	call now_ns
	movq %rax, %rdx
	pushq %rdx
1:	movq cdma_page(%rip), %rcx
	movq 4096(%rcx), %rax			# CD_STATUS
	cmpq %r12, %rax
	jae 2f
	movl $WAIT_DELAY, %eax
	DELAY_EAX
	call now_ns
	subq (%rsp), %rax
	cmpq $2000000000, %rax
	jb 1b
	addq $8, %rsp
	xorl %eax, %eax
	jmp 3f
2:	addq $8, %rsp
	movq res_table(%rip), %rcx
	movq %rbx, %rdx
	shlq $5, %rdx
	movl $RS_RESIDENT, RT_STATE(%rcx,%rdx)
	movl $1, %eax
3:	popq %r12
	popq %rbx
	ret

# res_map_all: every resident pool page this process has not moved yet
# goes to its program address (mremap of the shared mapping's page:
# this process's view alone moves). eax the pages moved, or -1 when a
# move failed (the address was taken in this process).
	.globl res_map_all
res_map_all:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	movq $0, res_map_failed(%rip)
	xorl %ebx, %ebx				# index
	xorl %r13d, %r13d			# moved
1:	cmpq res_n(%rip), %rbx
	jae 8f
	movq res_table(%rip), %rcx
	movq %rbx, %rdx
	shlq $5, %rdx
	cmpl $RS_RESIDENT, RT_STATE(%rcx,%rdx)
	jne 7f
	leaq res_mapped(%rip), %rax
	btq %rbx, (%rax)
	jc 7f
	movq RT_ADDR(%rcx,%rdx), %r12		# the program address
	movq %r12, %rdi
	call resv_free
	testl %eax, %eax
	jz 11f					# taken on this card: refused (the rest still placed)
	# the run: pages rbx .. rbx + n - 1 resident, unplaced, at addresses
	# r12 + k x 2 MiB (one mremap, one TLB shootdown for the run)
	movl $1, %r14d
2:	leaq 1(%rbx), %rax
	addq %r14, %rax
	decq %rax				# the next index
	cmpq res_n(%rip), %rax
	jae 3f
	movq res_table(%rip), %rcx
	movq %rax, %rdx
	shlq $5, %rdx
	cmpl $RS_RESIDENT, RT_STATE(%rcx,%rdx)
	jne 3f
	leaq res_mapped(%rip), %rsi
	btq %rax, (%rsi)
	jc 3f
	movq %r14, %rsi
	shlq $21, %rsi
	addq %r12, %rsi
	cmpq RT_ADDR(%rcx,%rdx), %rsi
	jne 3f
	incl %r14d
	jmp 2b
3:	movq res_pool(%rip), %rdi
	movq %rbx, %rax
	shlq $21, %rax
	addq %rax, %rdi
	movq %r14, %rsi
	shlq $21, %rsi
	movq %rsi, %rdx
	movl $MREMAP_MAYMOVE | MREMAP_FIXED, %r10d
	movq %r12, %r8
	SYS SYS_mremap
	cmpq %r12, %rax
	jne 11f
4:	leaq res_mapped(%rip), %rax
	btsq %rbx, (%rax)
	incl %r13d
	incq %rbx
	decl %r14d
	jnz 4b
	jmp 1b
7:	incq %rbx
	jmp 1b
11:	movq $1, res_map_failed(%rip)		# this chunk cannot be placed: the next ones still are
	incq %rbx
	jmp 1b
8:	movl %r13d, %eax
	cmpq $0, res_map_failed(%rip)
	je 10f
9:	movl $-1, %eax
10:	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# res_flush: the session's end (K_FLUSH, a host program opening a slot):
# every pool page this process placed goes back to its pool address, the
# shared table is emptied (every entry free, address 0). One slot process
# at a time uses the pool today; with several, each must see the flush
# (a generation in the table: not yet). eax the pages returned.
	.globl res_flush
res_flush:
	pushq %rbx
	pushq %r12
	pushq %r13
	xorl %ebx, %ebx
	xorl %r13d, %r13d
1:	cmpq res_n(%rip), %rbx
	jae 8f
	leaq res_mapped(%rip), %rax
	btq %rbx, (%rax)
	jnc 7f
	movq res_table(%rip), %rcx
	movq %rbx, %rdx
	shlq $5, %rdx
	movq RT_ADDR(%rcx,%rdx), %rdi		# from the program address
	movl $HUGE_BYTES, %esi
	movl $HUGE_BYTES, %edx
	movl $MREMAP_MAYMOVE | MREMAP_FIXED, %r10d
	movq res_pool(%rip), %r8
	movq %rbx, %rax
	shlq $21, %rax
	addq %rax, %r8				# back to its pool address
	SYS SYS_mremap
	movq res_table(%rip), %rcx
	movq %rbx, %rdx
	shlq $5, %rdx
	movq RT_ADDR(%rcx,%rdx), %rdi
	call resv_restore
	leaq res_mapped(%rip), %rax
	btrq %rbx, (%rax)
	incl %r13d
7:	incq %rbx
	jmp 1b
8:	# every entry free: address, state, class and sequence cleared; the
	# frame (RT_PHYS, read once at res_init) stays, it is the page's
	movq res_table(%rip), %rcx
	xorl %edx, %edx
81:	cmpq res_n(%rip), %rdx
	jae 82f
	movq %rdx, %rax
	shlq $5, %rax
	movq $0, RT_ADDR(%rcx,%rax)
	movq $0, RT_STATE(%rcx,%rax)		# state and class
	movq $0, RT_SEQ(%rcx,%rax)
	incq %rdx
	jmp 81b
82:	movl %r13d, %eax
	popq %r13
	popq %r12
	popq %rbx
	ret

# The program's address space: the worker reserves [RESV_LO, RESV_HI)
# (where a host program's mmap region lies, below its stack) as PROT_NONE
# pieces before its first own mapping, so that its windows, pools, arenas
# and every thread's stack land below it and a resident page can take a
# program address there (res_map_all moves the page over the
# reservation). A piece the kernel already holds (this process's own
# stack, the vdso) stays unreserved and its bit clear; a program address
# there, or anywhere else not free, is refused. See resident.md.
	.set RESV_LO, 0x550000000000		# a position-independent program's heap lies from 0x55..
	.set RESV_HI, 0x7ff000000000		# ... to its mmap region below the stack
	.set RESV_PIECE, 0x40000000		# 1 GiB
	.set RESV_PIECES, (RESV_HI - RESV_LO) / RESV_PIECE

	.bss
	.balign 64
resv_bits:	.skip RESV_PIECES / 8
res_map_failed:	.skip 8
	.text

# reserve_high: the reservation, once, before the worker's first mmap:
# one mapping over the whole range (nothing of the worker's lies there at
# its start: a fixed binary at 0x400000, its heap just above); every
# piece's bit set when it took, none when it did not. eax the pieces.
	.globl reserve_high
reserve_high:
	movabsq $RESV_LO, %rdi
	movabsq $RESV_HI - RESV_LO, %rsi
	movl $PROT_NONE, %edx
	movl $MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED_NOREPLACE, %r10d
	movq $-1, %r8
	xorl %r9d, %r9d
	SYS SYS_mmap
	cmpq $MAP_FAILED_MAX, %rax
	ja 9f
	leaq resv_bits(%rip), %rdi
	movl $RESV_PIECES / 8 / 8, %ecx
	movq $-1, %rax
	rep stosq
	movl $RESV_PIECES, %eax
	ret
9:	xorl %eax, %eax
	ret

# resv_free(rdi address, 2 MiB aligned): eax 1 when a resident page may
# take the address: inside the reservation's pieces, or free (a probe
# mapping that is unmapped again). 0 otherwise.
	.globl resv_free
resv_free:
	pushq %rbx
	movq %rdi, %rbx
	movabsq $RESV_LO, %rax
	cmpq %rax, %rbx
	jb 1f
	movabsq $RESV_HI, %rax
	cmpq %rax, %rbx
	jae 1f
	movq %rbx, %rcx
	movabsq $RESV_LO, %rax
	subq %rax, %rcx
	shrq $30, %rcx
	leaq resv_bits(%rip), %rax
	btq %rcx, (%rax)
	jnc 1f
	movl $1, %eax
	popq %rbx
	ret
1:	movq %rbx, %rdi
	movl $HUGE_BYTES, %esi
	movl $PROT_NONE, %edx
	movl $MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED_NOREPLACE, %r10d
	movq $-1, %r8
	xorl %r9d, %r9d
	SYS SYS_mmap
	cmpq $MAP_FAILED_MAX, %rax
	ja 2f
	movq %rbx, %rdi
	movl $HUGE_BYTES, %esi
	SYS SYS_munmap
	movl $1, %eax
	popq %rbx
	ret
2:	xorl %eax, %eax
	popq %rbx
	ret

# resv_restore(rdi address, 2 MiB aligned): the hole a page left when it
# went back to the pool, reserved again when it lies in the reservation.
	.globl resv_restore
resv_restore:
	movabsq $RESV_LO, %rax
	cmpq %rax, %rdi
	jb 9f
	movabsq $RESV_HI, %rax
	cmpq %rax, %rdi
	jae 9f
	movl $HUGE_BYTES, %esi
	movl $PROT_NONE, %edx
	movl $MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED, %r10d
	movq $-1, %r8
	xorl %r9d, %r9d
	SYS SYS_mmap
9:	ret

# res_push(rdi program address, esi staging index, rdx bytes): the bytes
# of the program's memory at the address (resident on this card: within
# one chunk, 64-aligned) copied by the DMA engine from the pool page's
# frame into the window's staging slot, in pieces of one descriptor; rax
# the last piece's sequence number, or 0 when the chunk is not resident
# or a submit was refused. The dispatcher's (K_PUSH).
	.globl res_push
res_push:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	movq %rdi, %rbx
	andq $-HUGE_BYTES, %rbx			# the chunk
	movq %rsi, %r12
	shlq $21, %r12
	addq $OFF_RESIDENT, %r12		# the destination offset
	movq %rdx, %r14				# bytes
	# the entry with the chunk's address, resident
	movq res_table(%rip), %rcx
	xorl %edx, %edx
1:	cmpq res_n(%rip), %rdx
	jae 8f
	movq %rdx, %rax
	shlq $5, %rax
	cmpq RT_ADDR(%rcx,%rax), %rbx
	jne 2f
	cmpl $RS_RESIDENT, RT_STATE(%rcx,%rax)
	je 3f
2:	incq %rdx
	jmp 1b
3:	movq RT_PHYS(%rcx,%rax), %r13
	testq %r13, %r13
	jz 8f
	subq %rbx, %rdi
	addq %rdi, %r13				# the frame, at the address's offset
	xorl %ebx, %ebx				# done
4:	cmpq %r14, %rbx
	jae 7f
	movq %r14, %rdx
	subq %rbx, %rdx
	cmpq $EP_PIECE, %rdx
	jbe 5f
	movq $EP_PIECE, %rdx
5:	leaq (%r12,%rbx), %rdi
	leaq (%r13,%rbx), %rsi
	pushq %rdx
	call cdma_submit_tohost
	popq %rdx
	testq %rax, %rax
	jz 8f
	addq %rdx, %rbx
	jmp 4b
7:	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
8:	xorl %eax, %eax
	jmp 7b
