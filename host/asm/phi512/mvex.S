# mvex.S: the emitter the translator's recipes write the card's code
# with: the MVEX prefix and its operand forms, the VEX-encoded mask
# instructions, the saves and restores of rax, rcx, a mask register and
# the flags through the card's per-thread scratch area (fs-relative;
# never the program's stack, which the threads of a split loop share),
# temporaries kept in the scratch's vector slots, 64-byte constants in
# the blob's pool, and the vector helpers every recipe composes (moves,
# zeroing by lane mask, shuffles, the unaligned pairs, broadcasts). A
# port of `Em` in host/crates/avx512-xlate/src/rewrite.rs, sequence for
# sequence, so the card-checked forms stay what they were. See mvex.md.
#
# Every emitter takes the emitter block in rdi (EM_*). Bytes go to
# EM_OUT; past EM_LIM the block is marked EU_FULL and nothing more is
# written (the blob builder refuses the function). Encodings are from
# the ISA reference 327364-001 (the opcode lines in the comments). The
# helpers keep their arguments in callee-saved registers and build the
# MVEX argument block (MV_*) on their own stack.

	.include "x86dec.inc"
	.include "xlate.inc"

	.text

# em_init(em rdi, out rsi, lim rdx, blob rcx, scratch r8d, in r9,
# reserved [rsp+8]): the block for one instruction. The reserved word
# names the vector registers the instruction uses (bits 0 to 31; no
# temporary takes them) and the mask registers (bits 32 to 39); the
# scratch mask is the lowest of k1 to k7 the instruction does not name.
	.globl em_init
em_init:
	movq %rsi, EM_OUT(%rdi)
	movq %rdx, EM_LIM(%rdi)
	movq %rcx, EM_BLOB(%rdi)
	movl %r8d, EM_SCRATCH(%rdi)
	movl $0, EM_USED(%rdi)
	movq 8(%rsp), %rax
	movl %eax, EM_RESERVED(%rdi)
	movq %r9, EM_IN(%rdi)
	movq IN_ENTRYP(%r9), %rax
	movq %rax, EM_ENT(%rdi)
	movb $0, EM_NTEMP(%rdi)
	movb $0, EM_NTAIL(%rdi)
	movl $-1, EM_FLAGS_OUT(%rdi)
	movq 8(%rsp), %rax
	shrq $32, %rax
	movl $1, %ecx
1:	btl %ecx, %eax
	jnc 2f
	incl %ecx
	cmpl $8, %ecx
	jb 1b
	movl $7, %ecx
2:	movb %cl, EM_KSCR(%rdi)
	ret

# em_byte(em rdi, al): one byte out. Keeps every register but rdx.
	.globl em_byte
em_byte:
	movq EM_OUT(%rdi), %rdx
	cmpq EM_LIM(%rdi), %rdx
	jae 1f
	movb %al, (%rdx)
	incq EM_OUT(%rdi)
	ret
1:	orl $EU_FULL, EM_USED(%rdi)
	ret
# em_dword(em rdi, eax): four bytes out. Keeps every register but rdx.
	.globl em_dword
em_dword:
	movq EM_OUT(%rdi), %rdx
	addq $4, %rdx
	cmpq EM_LIM(%rdi), %rdx
	ja 1f
	movl %eax, -4(%rdx)
	movq %rdx, EM_OUT(%rdi)
	ret
1:	orl $EU_FULL, EM_USED(%rdi)
	ret
# em_bytes(em rdi, rsi bytes, edx count).
	.globl em_bytes
em_bytes:
	pushq %rbx
	pushq %r12
	movq %rsi, %rbx
	movl %edx, %r12d
1:	testl %r12d, %r12d
	jz 2f
	movzbl (%rbx), %eax
	call em_byte
	incq %rbx
	decl %r12d
	jmp 1b
2:	popq %r12
	popq %rbx
	ret

# mv_set(mv rdi, map esi, pp edx, w ecx, op r8d, reg r9d): the block's
# fixed fields; the rest zero, the immediate none, the r/m register 0.
	.globl mv_set
mv_set:
	movb %sil, MV_MAP(%rdi)
	movb %dl, MV_PP(%rdi)
	movb %cl, MV_W(%rdi)
	movb %r8b, MV_OP(%rdi)
	movb %r9b, MV_REG(%rdi)
	movb $0, MV_VVVV(%rdi)
	movb $RM_REG, MV_RMKIND(%rdi)
	movb $0, MV_RM(%rdi)
	movb $0, MV_K(%rdi)
	movb $0, MV_SSS(%rdi)
	movw $-1, MV_IMM(%rdi)
	movl $0, MV_OFF(%rdi)
	movq $0, MV_MEMP(%rdi)
	movq $0, MV_DISP(%rdi)
	ret
# mv_rm(mv rdi, kind esi, value rdx): the r/m: a register number, the
# decoded instruction (RM_MEM: its memory operand), a scratch offset
# (RM_FS) or a constant's index (RM_CONST).
	.globl mv_rm
mv_rm:
	movb %sil, MV_RMKIND(%rdi)
	cmpl $RM_REG, %esi
	jne 1f
	movb %dl, MV_RM(%rdi)
	ret
1:	cmpl $RM_MEM, %esi
	jne 2f
	movq %rdx, MV_MEMP(%rdi)
	ret
2:	movl %edx, MV_OFF(%rdi)
	ret

# em_mvex(em rdi, mv rsi): one MVEX.512 instruction from the argument
# block: P0 = R X B R' 0 0 m m (the extension bits inverted), P1 = W
# vvvv 0 pp, P2 = E SSS V' aaa; then the opcode, the ModRM, a SIB and a
# disp32 for a memory operand, the immediate. The r/m forms: a register;
# the decoded instruction's memory operand (base, index, scale, disp,
# plus MV_DISP; a base of rsp or r12 takes a SIB, no base takes the
# no-base SIB with disp32); an fs-relative scratch slot (64 prefix, SIB
# 0x25, the absolute disp32); a constant of the blob's pool (rip-relative,
# a fixup recorded).
	.globl em_mvex
em_mvex:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rsi, %rbx
	movl $1, %r12d				# X inverted (1 = no index)
	movl $1, %r13d				# B inverted
	movzbl MV_RMKIND(%rbx), %eax
	cmpl $RM_REG, %eax
	jne 1f
	movzbl MV_RM(%rbx), %ecx
	movl %ecx, %edx
	shrl $4, %edx
	andl $1, %edx
	xorl $1, %edx
	movl %edx, %r12d
	movl %ecx, %edx
	shrl $3, %edx
	andl $1, %edx
	xorl $1, %edx
	movl %edx, %r13d
	jmp 3f
1:	cmpl $RM_MEM, %eax
	jne 2f
	movq MV_MEMP(%rbx), %r14
	movzbl IN_INDEX(%r14), %ecx
	cmpl $0xff, %ecx
	je 11f
	movl %ecx, %edx
	shrl $3, %edx
	andl $1, %edx
	xorl $1, %edx
	movl %edx, %r12d
11:	movzbl IN_BASE(%r14), %ecx
	cmpl $0xff, %ecx
	je 3f
	movl %ecx, %edx
	shrl $3, %edx
	andl $1, %edx
	xorl $1, %edx
	movl %edx, %r13d
	jmp 3f
2:	cmpl $RM_FS, %eax
	jne 3f
	movl $0x64, %eax
	call em_byte
3:	movl $0x62, %eax
	call em_byte
	# P0
	movzbl MV_REG(%rbx), %ecx
	movl %ecx, %eax
	shrl $3, %eax
	andl $1, %eax
	xorl $1, %eax
	shll $7, %eax
	movl %r12d, %edx
	shll $6, %edx
	orl %edx, %eax
	movl %r13d, %edx
	shll $5, %edx
	orl %edx, %eax
	movl %ecx, %edx
	shrl $4, %edx
	andl $1, %edx
	xorl $1, %edx
	shll $4, %edx
	orl %edx, %eax
	movzbl MV_MAP(%rbx), %edx
	orl %edx, %eax
	call em_byte
	# P1
	movzbl MV_W(%rbx), %eax
	shll $7, %eax
	movzbl MV_VVVV(%rbx), %edx
	notl %edx
	andl $0xf, %edx
	shll $3, %edx
	orl %edx, %eax
	movzbl MV_PP(%rbx), %edx
	orl %edx, %eax
	call em_byte
	# P2
	movzbl MV_SSS(%rbx), %eax
	shll $4, %eax
	movzbl MV_VVVV(%rbx), %edx
	shrl $4, %edx
	andl $1, %edx
	xorl $1, %edx
	shll $3, %edx
	orl %edx, %eax
	movzbl MV_K(%rbx), %edx
	andl $7, %edx
	orl %edx, %eax
	call em_byte
	movzbl MV_OP(%rbx), %eax
	call em_byte
	# ModRM and what follows
	movzbl MV_REG(%rbx), %r15d
	andl $7, %r15d
	shll $3, %r15d
	movzbl MV_RMKIND(%rbx), %eax
	cmpl $RM_REG, %eax
	jne 4f
	movzbl MV_RM(%rbx), %eax
	andl $7, %eax
	orl %r15d, %eax
	orl $0xc0, %eax
	call em_byte
	jmp .Lmv_imm
4:	cmpl $RM_FS, %eax
	jne 5f
	movl %r15d, %eax
	orl $0x04, %eax
	call em_byte
	movl $0x25, %eax
	call em_byte
	movl MV_OFF(%rbx), %eax
	addl EM_SCRATCH(%rdi), %eax
	call em_dword
	jmp .Lmv_imm
5:	cmpl $RM_CONST, %eax
	jne 6f
	movl %r15d, %eax
	orl $0x05, %eax
	call em_byte
	movq EM_BLOB(%rdi), %rcx
	movq EM_OUT(%rdi), %r14
	subq BL_CODE(%rcx), %r14		# the disp32's offset in the code
	xorl %eax, %eax
	call em_dword
	movq EM_BLOB(%rdi), %rcx
	movl BL_NFIX(%rcx), %eax
	cmpl BL_FIX_CAP(%rcx), %eax
	jae .Lmv_full
	incl BL_NFIX(%rcx)
	imulq $FX_BYTES, %rax, %rax
	addq BL_FIX(%rcx), %rax
	movl %r14d, FX_AT(%rax)
	movl MV_OFF(%rbx), %edx
	movl %edx, FX_WHAT(%rax)
	movq EM_OUT(%rdi), %rdx
	subq BL_CODE(%rcx), %rdx
	cmpw $0, MV_IMM(%rbx)
	jl 51f
	incl %edx				# the immediate is still to come
51:	movl %edx, FX_END(%rax)
	jmp .Lmv_imm
6:	movq MV_MEMP(%rbx), %r14
	movzbl IN_BASE(%r14), %ecx
	movzbl IN_INDEX(%r14), %edx
	cmpl $0xff, %ecx
	je 62f
	cmpl $0xff, %edx
	jne 63f
	movl %ecx, %eax
	andl $7, %eax
	cmpl $4, %eax
	je 61f
	orl %r15d, %eax				# [base + disp32]: mod 10
	orl $0x80, %eax
	call em_byte
	jmp .Lmv_disp
61:	movl %r15d, %eax			# rsp or r12: a SIB with no index
	orl $0x84, %eax
	call em_byte
	movl $0x24, %eax
	call em_byte
	jmp .Lmv_disp
62:	cmpl $0xff, %edx
	jne 64f
	movl %r15d, %eax			# [disp32] through a SIB
	orl $0x04, %eax
	call em_byte
	movl $0x25, %eax
	call em_byte
	jmp .Lmv_disp
63:	movl %r15d, %eax			# base and index: mod 10 with a SIB
	orl $0x84, %eax
	call em_byte				# (em_byte clobbers rdx: the fields are read again)
	movzbl IN_SCALE(%r14), %eax
	shll $6, %eax
	movzbl IN_INDEX(%r14), %edx
	andl $7, %edx
	shll $3, %edx
	orl %edx, %eax
	movzbl IN_BASE(%r14), %ecx
	andl $7, %ecx
	orl %ecx, %eax
	call em_byte
	jmp .Lmv_disp
64:	movl %r15d, %eax			# index without a base: SIB base 101, disp32
	orl $0x04, %eax
	call em_byte
	movzbl IN_SCALE(%r14), %eax
	shll $6, %eax
	movzbl IN_INDEX(%r14), %edx
	andl $7, %edx
	shll $3, %edx
	orl %edx, %eax
	orl $5, %eax
	call em_byte
.Lmv_disp:
	movq IN_DISP(%r14), %rax
	addq MV_DISP(%rbx), %rax
	call em_dword
.Lmv_imm:
	movswl MV_IMM(%rbx), %eax
	testl %eax, %eax
	js 9f
	call em_byte
9:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
.Lmv_full:
	orl $EU_FULL, EM_USED(%rdi)
	jmp 9b

# em_vexk(em rdi, op esi, reg edx, rm ecx): a VEX-encoded mask
# instruction with two mask (or one general) register operands:
# VEX.128.0F.W0 op /r (kand 41, knot 44, kor 45, kxor 47, kmov 90 92 93,
# kortest 98).
	.globl em_vexk
em_vexk:
	pushq %rbx
	pushq %r12
	pushq %r13
	movl %esi, %ebx
	movl %edx, %r12d
	movl %ecx, %r13d
	cmpl $8, %r12d
	jae 1f
	cmpl $8, %r13d
	jae 1f
	movl $0xc5, %eax
	call em_byte
	movl $0xf8, %eax
	call em_byte
	jmp 2f
1:	movl $0xc4, %eax
	call em_byte
	movl %r12d, %eax
	shrl $3, %eax
	andl $1, %eax
	xorl $1, %eax
	shll $7, %eax
	orl $0x40, %eax
	movl %r13d, %edx
	shrl $3, %edx
	andl $1, %edx
	xorl $1, %edx
	shll $5, %edx
	orl %edx, %eax
	orl $1, %eax
	call em_byte
	movl $0x78, %eax
	call em_byte
2:	movl %ebx, %eax
	call em_byte
	movl %r12d, %eax
	andl $7, %eax
	shll $3, %eax
	movl %r13d, %edx
	andl $7, %edx
	orl %edx, %eax
	orl $0xc0, %eax
	call em_byte
	popq %r13
	popq %r12
	popq %rbx
	ret
# em_kand(em, k1 esi, k2 edx) and the others: the two-operand mask forms.
	.globl em_kand, em_knot, em_kor, em_kmov_kk, em_kmov_k_r, em_kmov_r_k
em_kand:
	movl %edx, %ecx
	movl %esi, %edx
	movl $0x41, %esi
	jmp em_vexk
em_knot:
	movl %edx, %ecx
	movl %esi, %edx
	movl $0x44, %esi
	jmp em_vexk
em_kor:
	movl %edx, %ecx
	movl %esi, %edx
	movl $0x45, %esi
	jmp em_vexk
em_kmov_kk:
	movl %edx, %ecx
	movl %esi, %edx
	movl $0x90, %esi
	jmp em_vexk
# em_kmov_k_r(em, k esi, r edx): kmovw k, r32 (92).
em_kmov_k_r:
	movl %edx, %ecx
	movl %esi, %edx
	movl $0x92, %esi
	jmp em_vexk
# em_kmov_r_k(em, r esi, k edx): kmovw r32, k (93).
em_kmov_r_k:
	movl %edx, %ecx
	movl %esi, %edx
	movl $0x93, %esi
	jmp em_vexk

# em_gpr_scratch(em rdi, r esi, wide edx, off ecx, store r8d): mov
# [fs:scratch + off], r (89 /r) or mov r, [fs:scratch + off] (8B /r).
	.globl em_gpr_scratch
em_gpr_scratch:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	movl %esi, %ebx
	movl %edx, %r12d
	movl %ecx, %r13d
	movl %r8d, %r14d
	movl $0x64, %eax
	call em_byte
	movl %r12d, %eax
	shll $3, %eax
	movl %ebx, %edx
	shrl $3, %edx
	andl $1, %edx
	orl %edx, %eax
	testl %eax, %eax
	jz 1f
	orl $0x40, %eax
	call em_byte
1:	movl $0x8b, %eax
	testl %r14d, %r14d
	jz 2f
	movl $0x89, %eax
2:	call em_byte
	movl %ebx, %eax
	andl $7, %eax
	shll $3, %eax
	orl $0x04, %eax
	call em_byte
	movl $0x25, %eax
	call em_byte
	movl %r13d, %eax
	addl EM_SCRATCH(%rdi), %eax
	call em_dword
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# em_rax, em_rcx: the register saved on first use.
	.globl em_rax, em_rcx
em_rax:
	testl $EU_RAX, EM_USED(%rdi)
	jnz 1f
	orl $EU_RAX, EM_USED(%rdi)
	xorl %esi, %esi
	movl $1, %edx
	movl $S_RAX, %ecx
	movl $1, %r8d
	jmp em_gpr_scratch
1:	ret
em_rcx:
	testl $EU_RCX, EM_USED(%rdi)
	jnz 1f
	orl $EU_RCX, EM_USED(%rdi)
	movl $1, %esi
	movl $1, %edx
	movl $S_RCX, %ecx
	movl $1, %r8d
	jmp em_gpr_scratch
1:	ret
# em_k: the scratch mask register (saved on first use, through eax), in eax.
	.globl em_k
em_k:
	testl $EU_K, EM_USED(%rdi)
	jnz 1f
	orl $EU_K, EM_USED(%rdi)
	call em_rax
	xorl %esi, %esi
	movzbl EM_KSCR(%rdi), %edx
	call em_kmov_r_k
	xorl %esi, %esi
	movl $1, %edx
	movl $S_K, %ecx
	movl $1, %r8d
	call em_gpr_scratch
1:	movzbl EM_KSCR(%rdi), %eax
	ret
# em_flags: the flags saved (lahf; seto al; rax saved first).
	.globl em_flags
em_flags:
	testl $EU_FLAGS, EM_USED(%rdi)
	jnz 1f
	orl $EU_FLAGS, EM_USED(%rdi)
	call em_rax
	leaq .Lb_lahf_seto(%rip), %rsi
	movl $4, %edx
	call em_bytes
	xorl %esi, %esi
	movl $1, %edx
	movl $S_FLAGS, %ecx
	movl $1, %r8d
	call em_gpr_scratch
1:	ret
.Lb_lahf_seto: .byte 0x9f, 0x0f, 0x90, 0xc0
# em_mov_eax(em rdi, imm esi): mov eax, imm32 (rax saved first).
	.globl em_mov_eax
em_mov_eax:
	pushq %rbx
	movl %esi, %ebx
	call em_rax
	movl $0xb8, %eax
	call em_byte
	movl %ebx, %eax
	call em_dword
	popq %rbx
	ret
# em_mask_imm(em rdi, mask esi): the scratch mask set to mask; its number in eax.
	.globl em_mask_imm
em_mask_imm:
	pushq %rbx
	movl %esi, %ebx
	call em_k
	movl %ebx, %esi
	call em_mov_eax
	movzbl EM_KSCR(%rdi), %esi
	xorl %edx, %edx
	call em_kmov_k_r
	movzbl EM_KSCR(%rdi), %eax
	popq %rbx
	ret
# em_gpr_result(em rdi, r esi, wide edx, off ecx): mov r, [fs:off] after
# everything else is restored (a general register the sequence produces,
# rax included).
	.globl em_gpr_result
em_gpr_result:
	movzbl EM_NTAIL(%rdi), %eax
	cmpl $4, %eax
	jae 1f
	leaq EM_TAIL(%rdi,%rax,8), %rax
	movb %sil, 0(%rax)
	movb %dl, 1(%rax)
	movl %ecx, 4(%rax)
	incb EM_NTAIL(%rdi)
	ret
1:	orl $EU_FULL, EM_USED(%rdi)
	ret

# em_temp(em rdi): a temporary vector register, its value kept in the
# scratch's next slot (vmovaps [fs:slot], z); the register in eax, or
# -1 when none is free or the slots are used up.
	.globl em_temp
em_temp:
	pushq %rbx
	pushq %r12
	pushq %r13
	subq $MV_BYTES, %rsp
	movq %rdi, %r13
	movzbl EM_NTEMP(%rdi), %r12d
	cmpl $S_NTEMPS, %r12d
	jae 8f
	xorl %ebx, %ebx
1:	cmpl $32, %ebx
	jae 8f
	btl %ebx, EM_RESERVED(%rdi)
	jnc 2f
	incl %ebx
	jmp 1b
2:	btsl %ebx, EM_RESERVED(%rdi)
	movb %bl, EM_TEMPS(%rdi,%r12)
	incb EM_NTEMP(%rdi)
	movq %rsp, %rdi
	movl $1, %esi
	xorl %edx, %edx
	xorl %ecx, %ecx
	movl $0x29, %r8d
	movl %ebx, %r9d
	call mv_set
	movq %rsp, %rdi
	movl $RM_FS, %esi
	movl %r12d, %edx
	shll $6, %edx
	call mv_rm
	movq %r13, %rdi
	movq %rsp, %rsi
	call em_mvex
	movl %ebx, %eax
	jmp 9f
8:	movl $-1, %eax
9:	addq $MV_BYTES, %rsp
	popq %r13
	popq %r12
	popq %rbx
	ret

# em_const(em rdi, bytes rsi): a 64-byte constant of the blob's pool,
# deduplicated; its index in eax (-1 when the pool is full).
	.globl em_const
em_const:
	pushq %rbx
	pushq %r12
	pushq %r13
	movq %rsi, %r12
	movq EM_BLOB(%rdi), %rbx
	xorl %r13d, %r13d
1:	cmpl BL_NCONST(%rbx), %r13d
	jae 3f
	movq BL_CONSTS(%rbx), %rcx
	movl %r13d, %eax
	shll $6, %eax
	addq %rax, %rcx
	xorl %edx, %edx
2:	movq (%rcx,%rdx), %rax
	cmpq (%r12,%rdx), %rax
	jne 21f
	addl $8, %edx
	cmpl $64, %edx
	jb 2b
	movl %r13d, %eax
	jmp 9f
21:	incl %r13d
	jmp 1b
3:	cmpl BL_CONST_CAP(%rbx), %r13d
	jae 8f
	movq BL_CONSTS(%rbx), %rcx
	movl %r13d, %eax
	shll $6, %eax
	addq %rax, %rcx
	xorl %edx, %edx
4:	movq (%r12,%rdx), %rax
	movq %rax, (%rcx,%rdx)
	addl $8, %edx
	cmpl $64, %edx
	jb 4b
	incl BL_NCONST(%rbx)
	movl %r13d, %eax
	jmp 9f
8:	movl $-1, %eax
9:	popq %r13
	popq %r12
	popq %rbx
	ret
# em_const_dw(em rdi, v esi): the constant with v in every dword lane.
	.globl em_const_dw
em_const_dw:
	subq $72, %rsp
	movl %esi, %eax
	movq %rax, %rdx
	shlq $32, %rdx
	orq %rdx, %rax
	.irp o,0,8,16,24,32,40,48,56
	movq %rax, \o(%rsp)
	.endr
	movq %rsp, %rsi
	call em_const
	addq $72, %rsp
	ret
# em_const_qw(em rdi, v rsi): the constant with v in every qword lane.
	.globl em_const_qw
em_const_qw:
	subq $72, %rsp
	.irp o,0,8,16,24,32,40,48,56
	movq %rsi, \o(%rsp)
	.endr
	movq %rsp, %rsi
	call em_const
	addq $72, %rsp
	ret

# ---- the vector instructions the sequences use ----
# Each keeps its arguments in callee-saved registers and builds the
# block on its stack: after five pushes and the block, the first stack
# argument of the caller lies at 80(%rsp), the second at 88(%rsp).

# em_vmov(em rdi, d esi, rmkind edx, rm rcx, k r8d, w r9d): vmovaps
# d{k}, s (MVEX.512.0F.W0 28 /r); vmovapd for W1 (66, 28).
	.globl em_vmov
em_vmov:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES, %rsp
	movq %rdi, %r15
	movl %esi, %ebx
	movl %edx, %r12d
	movq %rcx, %r13
	movl %r8d, %r14d
	pushq %r9
	movq %rsp, %rdi
	addq $8, %rdi
	movl $1, %esi
	movl %r9d, %edx
	movl %r9d, %ecx
	movl $0x28, %r8d
	movl %ebx, %r9d
	call mv_set
	popq %r9
	movq %rsp, %rdi
	movl %r12d, %esi
	movq %r13, %rdx
	call mv_rm
	movb %r14b, MV_K(%rsp)
	movq %r15, %rdi
	movq %rsp, %rsi
	call em_mvex
	addq $MV_BYTES, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# em_zero(em rdi, d esi, k edx, w ecx): vpxord d{k}, d, d
# (MVEX.NDS.512.66.0F.W0 EF /r); vpxorq for W1.
	.globl em_zero
em_zero:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES, %rsp
	movq %rdi, %r15
	movl %esi, %ebx
	movl %edx, %r12d
	movl %ecx, %r13d
	movq %rsp, %rdi
	movl $1, %esi
	movl $1, %edx
	movl %r13d, %ecx
	movl $0xef, %r8d
	movl %ebx, %r9d
	call mv_set
	movb %bl, MV_VVVV(%rsp)
	movb %bl, MV_RM(%rsp)
	movb %r12b, MV_K(%rsp)
	movq %r15, %rdi
	movq %rsp, %rsi
	call em_mvex
	addq $MV_BYTES, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
# em_zero_lanes(em rdi, d esi, mask edx): the dword lanes of mask zeroed.
	.globl em_zero_lanes
em_zero_lanes:
	testl %edx, %edx
	jz 1f
	pushq %rbx
	movl %esi, %ebx
	movl %edx, %esi
	call em_mask_imm
	movl %ebx, %esi
	movl %eax, %edx
	xorl %ecx, %ecx
	call em_zero
	popq %rbx
1:	ret

# em_op3(em rdi, mv rsi, d edx, s1 ecx, rmkind r8d, rm r9, k [rsp+8],
# imm [rsp+16] (-1 none)): a three-operand instruction whose map, pp, W
# and opcode the caller set in the block (mv_set); fills the rest and
# emits. The common path of the NDS recipes.
	.globl em_op3
em_op3:
	pushq %rbx
	pushq %r12
	movq %rsi, %rbx
	movq %rdi, %r12
	movb %dl, MV_REG(%rbx)
	movb %cl, MV_VVVV(%rbx)
	movq %rbx, %rdi
	movl %r8d, %esi
	movq %r9, %rdx
	call mv_rm
	movq 24(%rsp), %rax
	movb %al, MV_K(%rbx)
	movq 32(%rsp), %rax
	movw %ax, MV_IMM(%rbx)
	movq %r12, %rdi
	movq %rbx, %rsi
	call em_mvex
	popq %r12
	popq %rbx
	ret

# em_op2i(em rdi, map esi, pp edx, w ecx, op r8d, d r9d, rmkind [rsp+8],
# rm [rsp+16], imm [rsp+24], k [rsp+32]): a two-operand instruction with
# an immediate (vpshufd 66.0F 70, vpermf32x4 66.0F3A 07, the shifts by
# immediate with the opcode's /n in the reg field and the destination
# in vvvv: those call em_op3 instead).
	.globl em_op2i
em_op2i:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES, %rsp
	movq %rdi, %r15
	movq %rsp, %rdi
	call mv_set
	movq %rsp, %rdi
	movq 80(%rsp), %rsi
	movq 88(%rsp), %rdx
	call mv_rm
	movq 96(%rsp), %rax
	movw %ax, MV_IMM(%rsp)
	movq 104(%rsp), %rax
	movb %al, MV_K(%rsp)
	movq %r15, %rdi
	movq %rsp, %rsi
	call em_mvex
	addq $MV_BYTES, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# em_unaligned(em rdi, d esi, in rdx, k ecx, w r8d, store r9d, float
# [rsp+8], sss [rsp+16]): the unaligned pair over the decoded
# instruction's memory operand: a load, vloadunpackld/hd
# (MVEX.512.0F38.W0 D0/D4; W1 for qwords; D1/D5 the float forms that
# take the float16 up-conversion); a store, vpackstoreld/hd
# (MVEX.512.66.0F38 D0/D4, D1/D5), each masked, the high half at +64.
	.globl em_unaligned
em_unaligned:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES, %rsp
	movq %rdi, %r15
	movl %esi, %ebx
	movq %rdx, %r12
	movl %ecx, %r13d
	movl %r8d, %r14d
	movl $0xd0, %r8d
	cmpq $0, 80(%rsp)
	je 1f
	movl $0xd1, %r8d
1:	movq %rsp, %rdi
	movl $2, %esi
	movl %r9d, %edx
	movl %r14d, %ecx
	movl %ebx, %r9d
	call mv_set
	movq 88(%rsp), %rax
	movb %al, MV_SSS(%rsp)
	movb %r13b, MV_K(%rsp)
	movq %rsp, %rdi
	movl $RM_MEM, %esi
	movq %r12, %rdx
	call mv_rm
	movq %r15, %rdi
	movq %rsp, %rsi
	call em_mvex
	addb $4, MV_OP(%rsp)
	movq $64, MV_DISP(%rsp)
	movq %r15, %rdi
	movq %rsp, %rsi
	call em_mvex
	addq $MV_BYTES, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# em_broadcast(em rdi, d esi, rmkind edx, rm rcx, k r8d, w r9d):
# vbroadcastss d{k}, m32 (MVEX.512.66.0F38.W0 18 /r); vbroadcastsd W1 19.
	.globl em_broadcast
em_broadcast:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES, %rsp
	movq %rdi, %r15
	movl %esi, %ebx
	movl %edx, %r12d
	movq %rcx, %r13
	movl %r8d, %r14d
	movl %r9d, %ecx
	movl $0x18, %r8d
	orl %ecx, %r8d
	movq %rsp, %rdi
	movl $2, %esi
	movl $1, %edx
	movl %ebx, %r9d
	call mv_set
	movq %rsp, %rdi
	movl %r12d, %esi
	movq %r13, %rdx
	call mv_rm
	movb %r14b, MV_K(%rsp)
	movq %r15, %rdi
	movq %rsp, %rsi
	call em_mvex
	addq $MV_BYTES, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# em_load_block(em rdi, d esi, rmkind edx, rm rcx, k r8d, half r9d): a
# 16-byte block into every block (vbroadcasti32x4, MVEX.512.66.0F38.W0
# 5A /r) or a 32-byte half into both halves (vbroadcasti64x4, W1 5B).
	.globl em_load_block
em_load_block:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $MV_BYTES, %rsp
	movq %rdi, %r15
	movl %esi, %ebx
	movl %edx, %r12d
	movq %rcx, %r13
	movl %r8d, %r14d
	movl %r9d, %ecx
	movl $0x5a, %r8d
	orl %ecx, %r8d
	movq %rsp, %rdi
	movl $2, %esi
	movl $1, %edx
	movl %ebx, %r9d
	call mv_set
	movq %rsp, %rdi
	movl %r12d, %esi
	movq %r13, %rdx
	call mv_rm
	movb %r14b, MV_K(%rsp)
	movq %r15, %rdi
	movq %rsp, %rsi
	call em_mvex
	addq $MV_BYTES, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# em_qmask_to_dmask(em rdi, k esi, limit edx): the scratch mask set to
# the dword-lane form of the qword-lane mask in k (bit i to bits 2i and
# 2i + 1), under limit; its number in eax. The unaligned pairs move
# dwords, since qword elements would need 8-byte alignment that AVX-512
# does not require.
	.globl em_qmask_to_dmask
em_qmask_to_dmask:
	pushq %rbx
	pushq %r12
	movl %esi, %ebx
	movl %edx, %r12d
	call em_k
	call em_flags
	call em_rcx
	xorl %esi, %esi
	movl %ebx, %edx
	call em_kmov_r_k
	leaq .Lb_spread(%rip), %rsi
	movl $.Lb_spread_end - .Lb_spread, %edx
	call em_bytes
	movl %r12d, %eax
	call em_dword
	movzbl EM_KSCR(%rdi), %esi
	xorl %edx, %edx
	call em_kmov_k_r
	movzbl EM_KSCR(%rdi), %eax
	popq %r12
	popq %rbx
	ret
.Lb_spread:
	.byte 0x0f, 0xb6, 0xc0			# movzx eax, al
	.byte 0x89, 0xc1, 0xc1, 0xe1, 0x04, 0x09, 0xc8, 0x25, 0x0f, 0x0f, 0x00, 0x00	# mov ecx, eax; shl ecx, 4; or eax, ecx; and eax, 0x0f0f
	.byte 0x89, 0xc1, 0xc1, 0xe1, 0x02, 0x09, 0xc8, 0x25, 0x33, 0x33, 0x00, 0x00	# ... shl 2 ... and 0x3333
	.byte 0x89, 0xc1, 0xd1, 0xe1, 0x09, 0xc8, 0x25, 0x55, 0x55, 0x00, 0x00		# ... shl 1 ... and 0x5555
	.byte 0x89, 0xc1, 0xd1, 0xe1, 0x09, 0xc8, 0x25					# ... shl 1 ... and limit (the dword follows)
.Lb_spread_end:

# em_finish(em rdi): everything restored in the reverse order of the
# saves: the temporaries from their slots, the flags (add al, 127; sahf
# after the saved word is back in rax), the scratch mask, rcx, rax, then
# the general registers the sequence produces (gpr_result), and last
# the flags the instruction defines (EM_FLAGS_OUT: a test clears OF,
# the byte goes through ah, restored from the saved rax after).
	.globl em_finish
em_finish:
	pushq %rbx
	pushq %r12
	movq %rdi, %rbx
	movzbl EM_NTEMP(%rbx), %r12d
1:	testl %r12d, %r12d
	jz 2f
	decl %r12d
	movq %rbx, %rdi
	movzbl EM_TEMPS(%rbx,%r12), %esi
	movl $RM_FS, %edx
	movl %r12d, %ecx
	shll $6, %ecx
	xorl %r8d, %r8d
	xorl %r9d, %r9d
	call em_vmov
	jmp 1b
2:	testl $EU_FLAGS, EM_USED(%rbx)
	jz 3f
	movq %rbx, %rdi
	xorl %esi, %esi
	movl $1, %edx
	movl $S_FLAGS, %ecx
	xorl %r8d, %r8d
	call em_gpr_scratch
	movq %rbx, %rdi
	leaq .Lb_addal_sahf(%rip), %rsi
	movl $3, %edx
	call em_bytes
3:	testl $EU_K, EM_USED(%rbx)
	jz 4f
	movq %rbx, %rdi
	xorl %esi, %esi
	movl $1, %edx
	movl $S_K, %ecx
	xorl %r8d, %r8d
	call em_gpr_scratch
	movq %rbx, %rdi
	movzbl EM_KSCR(%rbx), %esi
	xorl %edx, %edx
	call em_kmov_k_r
4:	testl $EU_RCX, EM_USED(%rbx)
	jz 5f
	movq %rbx, %rdi
	movl $1, %esi
	movl $1, %edx
	movl $S_RCX, %ecx
	xorl %r8d, %r8d
	call em_gpr_scratch
5:	testl $EU_RAX, EM_USED(%rbx)
	jz 6f
	movq %rbx, %rdi
	xorl %esi, %esi
	movl $1, %edx
	movl $S_RAX, %ecx
	xorl %r8d, %r8d
	call em_gpr_scratch
6:	xorl %r12d, %r12d
7:	cmpb %r12b, EM_NTAIL(%rbx)
	jbe 8f
	leaq EM_TAIL(%rbx,%r12,8), %rax
	movq %rbx, %rdi
	movzbl 0(%rax), %esi
	movzbl 1(%rax), %edx
	movl 4(%rax), %ecx
	xorl %r8d, %r8d
	call em_gpr_scratch
	incl %r12d
	jmp 7b
8:	cmpl $-1, EM_FLAGS_OUT(%rbx)
	je 9f
	movq %rbx, %rdi
	leaq .Lb_test_eax(%rip), %rsi
	movl $2, %edx
	call em_bytes
	movq %rbx, %rdi
	leaq .Lb_mov_ah(%rip), %rsi
	movl $4, %edx
	call em_bytes
	movl EM_FLAGS_OUT(%rbx), %eax
	addl EM_SCRATCH(%rbx), %eax
	movq %rbx, %rdi
	call em_dword
	movq %rbx, %rdi
	movl $0x9e, %eax
	call em_byte
	movq %rbx, %rdi
	leaq .Lb_mov_ah(%rip), %rsi
	movl $4, %edx
	call em_bytes
	movl $S_RAX + 1, %eax
	addl EM_SCRATCH(%rbx), %eax
	movq %rbx, %rdi
	call em_dword
9:	movl EM_USED(%rbx), %eax
	andl $EU_FULL, %eax			# 0 when everything fitted
	popq %r12
	popq %rbx
	ret
.Lb_addal_sahf: .byte 0x04, 0x7f, 0x9e
.Lb_test_eax: .byte 0x85, 0xc0
.Lb_mov_ah: .byte 0x64, 0x8a, 0x24, 0x25
	.section .note.GNU-stack,"",@progbits
