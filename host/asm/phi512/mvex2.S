# mvex2.S: the exact-footprint memory moves, included by mvex.S at its
# end (one assembly unit). The card's unaligned pairs (vloadunpackld/hd,
# vpackstoreld/hd) need the element's alignment and touch the whole of
# both cache lines, so a narrow operand (an xmm, a ymm, a float16 or a
# byte source) at the end of a mapping, or at an address that is not
# 4-aligned (ggml's quantized blocks), cannot go through them. Here:
# em_unaligned sizes the move (EM_NBYTES from a caller that knows, else
# the lanes of the last mask immediate or of the length, times the
# element) and sends 64 bytes to em_unaligned_any, fewer to em_bounce;
# em_bounce moves exactly those bytes through the scratch slot S_XFER
# with scalar moves (qwords, then a dword, a word, a byte: any
# alignment) and does the vector move, with its conversion, on the
# aligned slot (a masked store merges: the bytes in, the masked slot
# store, the bytes out); em_unaligned_any (a full-width move of unknown
# alignment) tests the address at run time: 64-aligned takes the plain
# aligned move, 4-aligned the pair (the operand then spans two lines,
# both its own), else the bounce; a narrow operand never takes the pair.
# See mvex2.md.

	.text

# em_unaligned(em rdi, d esi, in rdx, k ecx, w r8d, store r9d, float
# [rsp+8], sss [rsp+16]).
	.set UN_FRAME, 16
	.globl em_unaligned
em_unaligned:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $UN_FRAME, %rsp
	movq %rdi, %rbx
	movl %esi, %r12d			# d
	movq %rdx, %r13				# in
	movl %ecx, %r14d			# k
	movl %r8d, %r15d			# w
	movl %r9d, (%rsp)			# store
	movl EM_NBYTES(%rbx), %eax
	movl $0, EM_NBYTES(%rbx)
	testl %eax, %eax
	jnz 3f
	# the lanes: the mask immediate's when a mask was set, else the length's (4 << ll dwords, 2 << ll qwords)
	testl %r14d, %r14d
	jz 11f
	movl EM_KVAL(%rbx), %eax
	testl %eax, %eax
	jz 11f
	popcntl %eax, %eax
	jmp 1f
11:	movzbl IN_L(%r13), %ecx
	andl $3, %ecx
	movl $4, %eax
	testl %r15d, %r15d
	jz 12f
	movl $2, %eax
12:	shll %cl, %eax
1:	# the element: by the conversion
	movl 72(%rsp), %ecx			# sss
	movl $4, %edx
	testl %r15d, %r15d
	jz 2f
	movl $8, %edx
2:	cmpl $3, %ecx
	jne 21f
	movl $2, %edx				# float16
	jmp 24f
21:	cmpl $4, %ecx
	je 22f
	cmpl $5, %ecx
	jne 23f
22:	movl $1, %edx				# a byte
	jmp 24f
23:	cmpl $6, %ecx
	je 25f
	cmpl $7, %ecx
	jne 24f
25:	movl $2, %edx				# a word
24:	imull %edx, %eax
3:	movl %eax, 4(%rsp)			# the bytes
	cmpl $64, %eax
	jb 5f
	movq %rbx, %rdi
	movl %r12d, %esi
	movq %r13, %rdx
	movl %r14d, %ecx
	movl $2, %r8d
	movl (%rsp), %r9d
	call em_unaligned_any
	jmp 9f
5:	movq 72(%rsp), %rax			# sss
	pushq %rax
	movq 72(%rsp), %rax			# float (the frame moved by 8)
	pushq %rax
	movl 20(%rsp), %eax			# the bytes (moved by 16)
	pushq %rax
	movq %rbx, %rdi
	movl %r12d, %esi
	movq %r13, %rdx
	movl %r14d, %ecx
	movl %r15d, %r8d
	movl 24(%rsp), %r9d			# store (moved by 24)
	call em_bounce
	addq $24, %rsp
9:	addq $UN_FRAME, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# em_bounce(em rdi, d esi, in rdx, k ecx, w r8d, store r9d, nbytes
# [rsp+8], float [rsp+16], sss [rsp+24]). r15 holds the frame (the MVEX
# block at 0, the fields below) so the helpers can be called freely.
	.set BO_K, MV_BYTES
	.set BO_W, MV_BYTES + 4
	.set BO_STORE, MV_BYTES + 8
	.set BO_FLOAT, MV_BYTES + 12
	.set BO_SSS, MV_BYTES + 16
	.set BO_N, MV_BYTES + 20
	.set BO_OFF, MV_BYTES + 24
	.set BO_DIR, MV_BYTES + 28		# 0: memory to the slot; 1: the slot to memory
	.set BO_STEP, MV_BYTES + 32
	.set BO_PACK, MV_BYTES + 36		# the store packs (EM_PACK)
	.set BO_FRAME, MV_BYTES + 48
	.globl em_bounce
em_bounce:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $BO_FRAME, %rsp
	movq %rsp, %r15
	movq %rdi, %rbx
	movl %esi, %r12d			# d
	movq %rdx, %r13				# in
	movl %ecx, BO_K(%r15)
	movl %r8d, BO_W(%r15)
	movl %r9d, BO_STORE(%r15)
	movl EM_PACK(%rbx), %eax
	movl %eax, BO_PACK(%r15)
	movl $0, EM_PACK(%rbx)
	movl 128(%rsp), %eax
	movl %eax, BO_N(%r15)
	movl 136(%rsp), %eax
	movl %eax, BO_FLOAT(%r15)
	movl 144(%rsp), %eax
	movl %eax, BO_SSS(%r15)
	movq %rbx, %rdi
	call em_rax
	movq %rbx, %rdi
	call em_rcx
	movq %rbx, %rdi
	movq %r13, %rsi
	call em_addr_regs
	movq %rbx, %rdi
	movl $1, %esi
	movq %r13, %rdx
	call em_lea				# lea rcx, [m]
	cmpl $0, BO_STORE(%r15)
	je .Lbo_load
	cmpl $0, BO_K(%r15)
	je 1f
	movl $0, BO_DIR(%r15)			# a masked store merges: the bytes in first
	call .Lbo_copy
1:	movl $0x29, %r9d
	call .Lbo_vector			# the (masked) vector into the slot
	movl $1, BO_DIR(%r15)
	call .Lbo_copy				# the slot to memory
	jmp 9f
.Lbo_load:
	movl $0, BO_DIR(%r15)
	call .Lbo_copy				# memory to the slot
	movl $0x28, %r9d
	call .Lbo_vector			# the vector from the slot
9:	addq $BO_FRAME, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
# .Lbo_copy: BO_N bytes between [rcx] and the slot in the direction
# BO_DIR, as qwords, then a dword, a word, a byte.
.Lbo_copy:
	movl $0, BO_OFF(%r15)
2:	movl BO_N(%r15), %eax
	subl BO_OFF(%r15), %eax
	jle 8f
	cmpl $8, %eax
	jae .Lbo_q
	cmpl $4, %eax
	jae .Lbo_d
	cmpl $2, %eax
	jae .Lbo_w
	movl $1, BO_STEP(%r15)
	cmpl $0, BO_DIR(%r15)
	jne 11f
	movl $0xb6, %eax			# movzx eax, byte [rcx + off]
	call .Lbo_rcx_0f
	movl $0x88, %eax			# mov [fs:slot + off], al
	call .Lbo_fs
	jmp 7f
11:	movl $0xb6, %eax			# movzx eax, byte [fs:slot + off]
	call .Lbo_fs_0f
	movl $0x88, %eax			# mov [rcx + off], al
	call .Lbo_rcx
	jmp 7f
.Lbo_w:	movl $2, BO_STEP(%r15)
	cmpl $0, BO_DIR(%r15)
	jne 12f
	movl $0xb7, %eax			# movzx eax, word [rcx + off]
	call .Lbo_rcx_0f
	movl $0x66, %eax
	call .Lbo_byte
	movl $0x89, %eax			# mov [fs:slot + off], ax
	call .Lbo_fs
	jmp 7f
12:	movl $0xb7, %eax			# movzx eax, word [fs:slot + off]
	call .Lbo_fs_0f
	movl $0x66, %eax
	call .Lbo_byte
	movl $0x89, %eax			# mov [rcx + off], ax
	call .Lbo_rcx
	jmp 7f
.Lbo_d:	movl $4, BO_STEP(%r15)
	cmpl $0, BO_DIR(%r15)
	jne 13f
	movl $0x8b, %eax			# mov eax, [rcx + off]
	call .Lbo_rcx
	xorl %edx, %edx
	movl $1, %r8d
	call .Lbo_gpr				# mov [fs:slot + off], eax
	jmp 7f
13:	xorl %edx, %edx
	xorl %r8d, %r8d
	call .Lbo_gpr				# mov eax, [fs:slot + off]
	movl $0x89, %eax			# mov [rcx + off], eax
	call .Lbo_rcx
	jmp 7f
.Lbo_q:	movl $8, BO_STEP(%r15)
	cmpl $0, BO_DIR(%r15)
	jne 14f
	movl $0x48, %eax
	call .Lbo_byte
	movl $0x8b, %eax			# mov rax, [rcx + off]
	call .Lbo_rcx
	movl $1, %edx
	movl $1, %r8d
	call .Lbo_gpr				# mov [fs:slot + off], rax
	jmp 7f
14:	movl $1, %edx
	xorl %r8d, %r8d
	call .Lbo_gpr				# mov rax, [fs:slot + off]
	movl $0x48, %eax
	call .Lbo_byte
	movl $0x89, %eax			# mov [rcx + off], rax
	call .Lbo_rcx
7:	movl BO_STEP(%r15), %eax
	addl %eax, BO_OFF(%r15)
	jmp 2b
8:	ret
# .Lbo_byte(eax): one byte.
.Lbo_byte:
	movq %rbx, %rdi
	call em_byte
	ret
# .Lbo_rcx(eax = the opcode): opcode, ModRM 41 (eax, [rcx + disp8]), the offset.
.Lbo_rcx:
	call .Lbo_byte
	movl $0x41, %eax
	call .Lbo_byte
	movl BO_OFF(%r15), %eax
	call .Lbo_byte
	ret
# .Lbo_rcx_0f(eax = b6 or b7): 0F, then as .Lbo_rcx.
.Lbo_rcx_0f:
	pushq %rax
	movl $0x0f, %eax
	call .Lbo_byte
	popq %rax
	jmp .Lbo_rcx
# .Lbo_fs(eax = 88 or 89): 64, opcode, 04 25, the slot's disp32.
.Lbo_fs:
	pushq %rax
	movl $0x64, %eax
	call .Lbo_byte
	popq %rax
	call .Lbo_byte
	jmp .Lbo_fs_tail
# .Lbo_fs_0f(eax = b6 or b7): 64 0F opcode 04 25 disp32.
.Lbo_fs_0f:
	pushq %rax
	movl $0x64, %eax
	call .Lbo_byte
	movl $0x0f, %eax
	call .Lbo_byte
	popq %rax
	call .Lbo_byte
.Lbo_fs_tail:
	movl $0x04, %eax
	call .Lbo_byte
	movl $0x25, %eax
	call .Lbo_byte
	movl EM_SCRATCH(%rbx), %eax
	addl $S_XFER, %eax
	addl BO_OFF(%r15), %eax
	movq %rbx, %rdi
	call em_dword
	ret
# .Lbo_gpr(edx = wide, r8d = store): em_gpr_scratch(0, wide, S_XFER + off, store).
.Lbo_gpr:
	movq %rbx, %rdi
	xorl %esi, %esi
	movl $S_XFER, %ecx
	addl BO_OFF(%r15), %ecx
	call em_gpr_scratch
	ret
# .Lbo_vector(r9d = 0x28 a load, 0x29 a store): vmovaps/vmovapd (float,
# pp = W) or vmovdqa32/64 (66; 6F, 7F) d{k}, [fs:S_XFER] with the
# conversion, through the frame's block.
.Lbo_vector:
	movq %r15, %rdi
	movl $1, %esi
	movl BO_W(%r15), %ecx
	movl %ecx, %edx				# pp = W for the float forms
	movl %r9d, %r8d
	cmpl $0, BO_FLOAT(%r15)
	jne 1f
	movl $1, %edx				# 66: the integer forms
	movl $0x6f, %r8d
	cmpl $0x28, %r9d
	je 1f
	movl $0x7f, %r8d
	cmpl $0, BO_PACK(%r15)
	je 1f
	# a packed store (vpackstoreld, 0F38 D0, W0): the masked dword lanes
	# land together at the slot's start, where .Lbo_copy takes BO_N bytes
	# from (an extract's element: vpextrq $1 stored the slot's old bytes
	# back, lanes 2 and 3 being at +8; common_speculative_init then read
	# a stale vector end and walked an empty vector, 2026-10-14 rs21)
	movl $2, %esi
	movl $1, %edx
	xorl %ecx, %ecx
	movl $0xd0, %r8d
1:	movl %r12d, %r9d
	call mv_set
	movq %r15, %rdi
	movl $RM_FS, %esi
	movl $S_XFER, %edx
	call mv_rm
	movl BO_K(%r15), %eax
	movb %al, MV_K(%r15)
	movl BO_SSS(%r15), %eax
	movb %al, MV_SSS(%r15)
	movq %rbx, %rdi
	movq %r15, %rsi
	call em_mvex
	ret

# em_unaligned_any(em rdi, d esi, in rdx, k ecx, ll r8d, store r9d): a
# full-width move of unknown alignment (the lanes mask in k, 0 none):
# rax, rcx and the flags saved, the address into rcx (lea), then at run
# time: 64-aligned takes vmovaps (the one line); 4-aligned, for a
# 512-bit operand, the pair (it spans its two lines); else the bounce of
# 16 << ll bytes. The branches are rel32, patched here.
	.set UA_K, MV_BYTES
	.set UA_LL, MV_BYTES + 4
	.set UA_STORE, MV_BYTES + 8
	.set UA_JZD, MV_BYTES + 16		# the end of the jz to the aligned move
	.set UA_JZP, MV_BYTES + 24		# the end of the jz to the pair
	.set UA_JE1, MV_BYTES + 32		# the ends of the jmps to the end (0 none)
	.set UA_JE2, MV_BYTES + 40
	.set UA_FRAME, MV_BYTES + 64
	.globl em_unaligned_any
em_unaligned_any:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $UA_FRAME, %rsp
	movq %rdi, %rbx
	movl %esi, %r12d			# d
	movq %rdx, %r13				# in
	movl %ecx, UA_K(%rsp)
	movl %r8d, UA_LL(%rsp)
	movl %r9d, UA_STORE(%rsp)
	movq $0, UA_JE2(%rsp)
	movq %rbx, %rdi
	call em_rax
	movq %rbx, %rdi
	call em_rcx
	movq %rbx, %rdi
	call em_flags
	movq %rbx, %rdi
	movq %r13, %rsi
	call em_addr_regs
	movq %rbx, %rdi
	movl $1, %esi
	movq %r13, %rdx
	call em_lea				# lea rcx, [m]
	movq %rbx, %rdi
	leaq .Lb2_testcl63(%rip), %rsi
	movl $3, %edx
	call em_bytes				# test cl, 63
	movq %rbx, %rdi
	leaq .Lb2_jz32(%rip), %rsi
	movl $6, %edx
	call em_bytes				# jz -> the aligned move
	movq EM_OUT(%rbx), %rax
	movq %rax, UA_JZD(%rsp)
	cmpl $2, UA_LL(%rsp)
	jne .Lua_bounce				# a narrow operand: never the pair
	movq %rbx, %rdi
	leaq .Lb2_testcl3(%rip), %rsi
	movl $3, %edx
	call em_bytes				# test cl, 3
	movq %rbx, %rdi
	leaq .Lb2_jz32(%rip), %rsi
	movl $6, %edx
	call em_bytes				# jz -> the pair
	movq EM_OUT(%rbx), %rax
	movq %rax, UA_JZP(%rsp)
.Lua_bounce:
	movl UA_LL(%rsp), %ecx
	movl $16, %eax
	shll %cl, %eax
	pushq $0				# sss
	pushq $0				# float
	pushq %rax				# nbytes
	movq %rbx, %rdi
	movl %r12d, %esi
	movq %r13, %rdx
	movl UA_K + 24(%rsp), %ecx
	xorl %r8d, %r8d
	movl UA_STORE + 24(%rsp), %r9d
	call em_bounce
	addq $24, %rsp
	movq %rbx, %rdi
	leaq .Lb2_jmp32(%rip), %rsi
	movl $5, %edx
	call em_bytes				# jmp -> the end
	movq EM_OUT(%rbx), %rax
	movq %rax, UA_JE1(%rsp)
	cmpl $2, UA_LL(%rsp)
	jne .Lua_direct
	# the pair (the second jz lands here)
	movq EM_OUT(%rbx), %rax
	movq UA_JZP(%rsp), %rcx
	subq %rcx, %rax
	movl %eax, -4(%rcx)
	pushq $0				# sss
	pushq $0				# float
	movq %rbx, %rdi
	movl %r12d, %esi
	movq %r13, %rdx
	movl UA_K + 16(%rsp), %ecx
	xorl %r8d, %r8d
	movl UA_STORE + 16(%rsp), %r9d
	call em_unaligned_pair
	addq $16, %rsp
	movq %rbx, %rdi
	leaq .Lb2_jmp32(%rip), %rsi
	movl $5, %edx
	call em_bytes				# jmp -> the end
	movq EM_OUT(%rbx), %rax
	movq %rax, UA_JE2(%rsp)
.Lua_direct:
	# the aligned move (the first jz lands here): vmovaps d{k}, [m] or [m]{k}, d
	movq EM_OUT(%rbx), %rax
	movq UA_JZD(%rsp), %rcx
	subq %rcx, %rax
	movl %eax, -4(%rcx)
	movq %rsp, %rdi
	movl $1, %esi
	xorl %edx, %edx
	xorl %ecx, %ecx
	movl $0x28, %r8d
	cmpl $0, UA_STORE(%rsp)
	je 1f
	movl $0x29, %r8d
1:	movl %r12d, %r9d
	call mv_set
	movq %rsp, %rdi
	movl $RM_MEM, %esi
	movq %r13, %rdx
	call mv_rm
	movl UA_K(%rsp), %eax
	movb %al, MV_K(%rsp)
	movq %rbx, %rdi
	movq %rsp, %rsi
	call em_mvex
	# the end: the jmps land here
	movq EM_OUT(%rbx), %rax
	movq UA_JE1(%rsp), %rcx
	subq %rcx, %rax
	movl %eax, -4(%rcx)
	movq UA_JE2(%rsp), %rcx
	testq %rcx, %rcx
	jz 2f
	movq EM_OUT(%rbx), %rax
	subq %rcx, %rax
	movl %eax, -4(%rcx)
2:	addq $UA_FRAME, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
	.section .rodata
.Lb2_testcl63:	.byte 0xf6, 0xc1, 0x3f
.Lb2_testcl3:	.byte 0xf6, 0xc1, 0x03
.Lb2_jz32:	.byte 0x0f, 0x84, 0, 0, 0, 0
.Lb2_jmp32:	.byte 0xe9, 0, 0, 0, 0
	.text

	.text
	.set XFER_HI, S_XFER + 32		# the transfer slot's upper half: em_copy_to_xfer's (xl_divs keeps [S_XFER, +16))
# em_copy_to_xfer(em rdi, in rsi, bytes edx: 4, 8, 16 or 32): the
# decoded instruction's memory operand copied to [fs:XFER_HI] by scalar
# moves (rax and rcx saved, the program's address registers reloaded,
# lea rcx, [m]; mov rax/eax, [rcx + off]; mov [fs:XFER_HI + off]): a
# broadcast (em_broadcast) or a block load (em_load_block) then reads
# the aligned slot. The card requires their memory operand aligned to
# the element or the block; the program's need not be (vmovq at a
# 4-aligned address, llama_memory_hybrid_idx's constructor: #GP on the
# card, 2026-10-14).
	.globl em_copy_to_xfer
em_copy_to_xfer:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	subq $8, %rsp
	movq %rdi, %rbx
	movq %rsi, %r12
	movl %edx, %r13d
	movq %rbx, %rdi
	call em_rax
	movq %rbx, %rdi
	call em_rcx
	movq %rbx, %rdi
	movq %r12, %rsi
	call em_addr_regs
	movq %rbx, %rdi
	movl $1, %esi
	movq %r12, %rdx
	call em_lea				# lea rcx, [m]
	xorl %r14d, %r14d			# off
1:	cmpl %r13d, %r14d
	jae 9f
	movl %r13d, %eax
	subl %r14d, %eax
	cmpl $8, %eax
	jb 2f
	movq %rbx, %rdi
	movl $0x48, %eax
	call em_byte
	movq %rbx, %rdi
	movl $0x8b, %eax			# mov rax, [rcx + off]
	call em_byte
	movq %rbx, %rdi
	movl $0x41, %eax
	call em_byte
	movq %rbx, %rdi
	movl %r14d, %eax
	call em_byte
	movq %rbx, %rdi
	xorl %esi, %esi
	movl $1, %edx
	leal XFER_HI(%r14), %ecx
	movl $1, %r8d
	call em_gpr_scratch			# mov [fs:XFER_HI + off], rax
	addl $8, %r14d
	jmp 1b
2:	movq %rbx, %rdi
	movl $0x8b, %eax			# mov eax, [rcx + off]
	call em_byte
	movq %rbx, %rdi
	movl $0x41, %eax
	call em_byte
	movq %rbx, %rdi
	movl %r14d, %eax
	call em_byte
	movq %rbx, %rdi
	xorl %esi, %esi
	xorl %edx, %edx
	leal XFER_HI(%r14), %ecx
	movl $1, %r8d
	call em_gpr_scratch			# mov [fs:XFER_HI + off], eax
	addl $4, %r14d
	jmp 1b
9:	addq $8, %rsp
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
