# decode.S: an x86-64 instruction decoder for the translator (stage 3 of
# the restart): legacy prefixes and REX, the one-byte, 0F, 0F38 and 0F3A
# maps, the two- and three-byte VEX prefixes and EVEX, ModRM, SIB,
# displacements, immediates, EVEX's disp8*N, the flow class of branches
# and traps, and which instruction it is (an entry of x86tab.inc, the
# tables tools/gen-x86-tables.c generated from iced-x86's own, with the
# operand kinds the translator needs). No libc, no stack use beyond the
# callee-saved registers. See decode.md.
#
#   x86_decode(rdi = bytes, rsi = bytes available, rdx = out (IN_BYTES,
#   8-aligned), rcx = the instruction's address) -> rax = length, 0 if
#   the bytes are not an instruction or run out (IN_LEN is 0 then too).
#
# The address matters for relative branches (IN_TARGET) and IN_NEXT.

	.include "x86dec.inc"

	.text
	.globl x86_decode
# Register use: rbx out, r12 start, r13 end, r14 address, r15 cursor,
# rbp the length-table entry (4 bytes in ebp), r8 the prefix bits,
# r9 the REX byte (legacy) or the X_* bits (VEX/EVEX), r10 the ModRM.
	.macro NEXTB r
	cmpq %r13, %r15
	jae .Lfail
	movzbl (%r15), \r
	incq %r15
	.endm

x86_decode:
	pushq %rbx
	pushq %rbp
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %r12
	movq %rdi, %r15
	leaq (%rdi,%rsi), %r13
	movq %rdx, %rbx
	movq %rcx, %r14
	xorl %eax, %eax
	.irp o,0,8,16,24,32,40,48,56,64,72,80,88
	movq %rax, \o(%rbx)
	.endr
	movb $0xff, IN_BASE(%rbx)
	movb $0xff, IN_INDEX(%rbx)
	movl $0xffffffff, IN_ENTRY(%rbx)
	movb $1, IN_N(%rbx)
	xorl %r8d, %r8d				# prefix bits
	xorl %r9d, %r9d				# REX
	xorl %r10d, %r10d
# The legacy prefixes, in any order; a REX counts only right before the opcode.
.Lpfx:
	NEXTB %ecx
	cmpl $0x66, %ecx
	je .Lp66
	cmpl $0x67, %ecx
	je .Lp67
	cmpl $0xf0, %ecx
	je .Lplock
	cmpl $0xf2, %ecx
	je .Lpf2
	cmpl $0xf3, %ecx
	je .Lpf3
	cmpl $0x64, %ecx
	je .Lpfs
	cmpl $0x65, %ecx
	je .Lpgs
	cmpl $0x26, %ecx
	je .Lpseg
	cmpl $0x2e, %ecx
	je .Lpseg
	cmpl $0x36, %ecx
	je .Lpseg
	cmpl $0x3e, %ecx
	je .Lpseg
	movl %ecx, %eax
	andl $0xf0, %eax
	cmpl $0x40, %eax
	jne .Lopcode
	movl %ecx, %r9d				# a REX; the next byte must be the opcode
	jmp .Lpfx
.Lp66:	orl $P_66, %r8d
	xorl %r9d, %r9d
	jmp .Lpfx
.Lp67:	orl $P_67, %r8d
	xorl %r9d, %r9d
	jmp .Lpfx
.Lplock: orl $P_LOCK, %r8d
	xorl %r9d, %r9d
	jmp .Lpfx
.Lpf2:	orl $P_F2, %r8d
	xorl %r9d, %r9d
	jmp .Lpfx
.Lpf3:	orl $P_F3, %r8d
	xorl %r9d, %r9d
	jmp .Lpfx
.Lpfs:	orl $P_FS, %r8d
	xorl %r9d, %r9d
	jmp .Lpfx
.Lpgs:	orl $P_GS, %r8d
	xorl %r9d, %r9d
	jmp .Lpfx
.Lpseg:	orl $P_SEG, %r8d
	xorl %r9d, %r9d
	jmp .Lpfx

# The opcode byte in ecx: an escape, a VEX or EVEX prefix, or a one-byte opcode.
.Lopcode:
	movb %r8b, IN_PFX(%rbx)
	movb %r9b, IN_REX(%rbx)
	leaq -1(%r15), %rax
	subq %r12, %rax
	movb %al, IN_OP_OFF(%rbx)
	cmpl $0x0f, %ecx
	je .Lmap0f
	cmpl $0xc5, %ecx
	je .Lvex2
	cmpl $0xc4, %ecx
	je .Lvex3
	cmpl $0x62, %ecx
	je .Levex
	movb $0, IN_MAP(%rbx)
	jmp .Llegacy
.Lmap0f:
	NEXTB %ecx
	movb $1, IN_MAP(%rbx)
	cmpl $0x38, %ecx
	je .Lmap0f38
	cmpl $0x3a, %ecx
	je .Lmap0f3a
	jmp .Llegacy
.Lmap0f38:
	NEXTB %ecx
	movb $2, IN_MAP(%rbx)
	jmp .Llegacy
.Lmap0f3a:
	NEXTB %ecx
	movb $3, IN_MAP(%rbx)
.Llegacy:
	movb %cl, IN_OP(%rbx)
	movl %r9d, %eax
	shrl $3, %eax
	andl $1, %eax
	movb %al, IN_W(%rbx)			# REX.W
	movzbl IN_MAP(%rbx), %eax		# the map index into the length table
	jmp .Llen

# VEX, two bytes: C5, then R vvvv L pp (R and vvvv inverted); map 0F, W 0.
.Lvex2:
	testl %r9d, %r9d			# a REX before VEX is invalid
	jnz .Lfail
	NEXTB %edx
	movb $1, IN_ENC(%rbx)
	movb $1, IN_MAP(%rbx)
	movl %edx, %eax
	notl %eax
	shrl $7, %eax
	andl $1, %eax
	shll $2, %eax				# X_R
	movl %eax, %r9d
	movl %edx, %eax
	notl %eax
	shrl $3, %eax
	andl $0xf, %eax
	movb %al, IN_VVVV(%rbx)
	movl %edx, %eax
	shrl $2, %eax
	andl $1, %eax
	movb %al, IN_L(%rbx)
	andl $3, %edx
	movb %dl, IN_PP(%rbx)
	jmp .Lvopcode
# VEX, three bytes: C4, then R X B mmmmm (inverted bits), then W vvvv L pp.
.Lvex3:
	testl %r9d, %r9d
	jnz .Lfail
	NEXTB %edx
	movb $1, IN_ENC(%rbx)
	movl %edx, %eax
	andl $0x1f, %eax			# the map
	cmpl $1, %eax
	jb .Lfail
	cmpl $3, %eax
	ja .Lfail
	movb %al, IN_MAP(%rbx)
	movl %edx, %eax
	notl %eax
	shrl $5, %eax
	andl $7, %eax				# R X B as bits 2 1 0
	movl %eax, %r9d
	NEXTB %edx
	movl %edx, %eax
	shrl $7, %eax
	movb %al, IN_W(%rbx)
	shll $3, %eax
	orl %eax, %r9d				# X_W
	movl %edx, %eax
	notl %eax
	shrl $3, %eax
	andl $0xf, %eax
	movb %al, IN_VVVV(%rbx)
	movl %edx, %eax
	shrl $2, %eax
	andl $1, %eax
	movb %al, IN_L(%rbx)
	andl $3, %edx
	movb %dl, IN_PP(%rbx)
	jmp .Lvopcode
# EVEX: 62, P0 = R X B R' 0 0 m m, P1 = W vvvv 1 pp, P2 = z L'L b V' aaa.
.Levex:
	testl %r9d, %r9d
	jnz .Lfail
	NEXTB %edx
	movb $2, IN_ENC(%rbx)
	movl %edx, %eax
	andl $7, %eax
	cmpl $1, %eax
	jb .Lfail
	cmpl $3, %eax
	ja .Lfail
	movb %al, IN_MAP(%rbx)
	movl %edx, %eax
	notl %eax
	shrl $5, %eax
	andl $7, %eax				# R X B
	movl %eax, %r9d
	movl %edx, %eax
	notl %eax
	shrl $4, %eax
	andl $1, %eax
	shll $4, %eax				# X_RP
	orl %eax, %r9d
	NEXTB %edx
	testl $4, %edx				# P1 bit 2 must be 1
	jz .Lfail
	movl %edx, %eax
	shrl $7, %eax
	movb %al, IN_W(%rbx)
	shll $3, %eax
	orl %eax, %r9d
	movl %edx, %eax
	notl %eax
	shrl $3, %eax
	andl $0xf, %eax
	movb %al, IN_VVVV(%rbx)
	andl $3, %edx
	movb %dl, IN_PP(%rbx)
	NEXTB %edx
	movl %edx, %eax
	shrl $7, %eax
	movb %al, IN_Z(%rbx)
	movl %edx, %eax
	shrl $5, %eax
	andl $3, %eax
	movb %al, IN_L(%rbx)
	movl %edx, %eax
	shrl $4, %eax
	andl $1, %eax
	movb %al, IN_B(%rbx)
	movl %edx, %eax
	notl %eax
	shrl $3, %eax
	andl $1, %eax
	shll $5, %eax				# X_VP
	orl %eax, %r9d
	andl $7, %edx
	movb %dl, IN_AAA(%rbx)
.Lvopcode:
	movb %r9b, IN_REX(%rbx)
	movq %r15, %rax
	subq %r12, %rax
	movb %al, IN_OP_OFF(%rbx)		# the opcode byte proper, after the payload
	NEXTB %ecx
	movb %cl, IN_OP(%rbx)
	movzbl IN_MAP(%rbx), %eax
	addl $3, %eax				# VEX/EVEX maps are 4 to 6 of the length table

# The length-table entry: eax = map index, ecx = opcode.
.Llen:
	shll $8, %eax
	addl %ecx, %eax
	leaq x86_len_tab(%rip), %rdx
	movl (%rdx,%rax,4), %ebp
	testl $LT_INVALID, %ebp
	jnz .Lfail
	testl $LT_MODRM, %ebp
	jz .Lnomodrm
	leaq (%r15), %rax
	subq %r12, %rax
	movb %al, IN_MODRM_OFF(%rbx)
	NEXTB %r10d
	movb %r10b, IN_MODRM(%rbx)
	orb $H_MODRM, IN_HAS(%rbx)
	movl %r10d, %eax
	shrl $6, %eax
	movb %al, IN_MOD(%rbx)
	testl $LT_GROUP, %ebp
	jz .Lmodrm_regs
	movl %ebp, %eax
	shrl $8, %eax
	andl $0xff, %eax			# the subtable
	shll $3, %eax
	movl %r10d, %edx
	shrl $3, %edx
	andl $7, %edx
	addl %edx, %eax
	leaq x86_grp_tab(%rip), %rdx
	movl (%rdx,%rax,4), %ebp
	testl $LT_INVALID, %ebp
	jnz .Lfail
.Lmodrm_regs:
	# reg with R (and R'), rm with B (and X in an EVEX register form)
	# a REX byte and the VEX/EVEX bits keep W R X B in the same positions
	movl %r10d, %eax
	shrl $3, %eax
	andl $7, %eax
	testl $X_R, %r9d
	jz 2f
	orl $8, %eax
2:	testl $X_RP, %r9d			# EVEX only (a REX byte has the bit clear)
	jz 3f
	orl $16, %eax
3:	movb %al, IN_REG(%rbx)
	movl %r10d, %eax
	andl $7, %eax
	testl $X_B, %r9d
	jz 5f
	orl $8, %eax
5:	cmpb $3, IN_MOD(%rbx)
	jne 6f
	cmpb $2, IN_ENC(%rbx)
	jne 6f
	testl $X_X, %r9d
	jz 6f
	orl $16, %eax
6:	movb %al, IN_RM(%rbx)
	cmpb $3, IN_MOD(%rbx)
	je .Lopsize
	# a memory operand
	orb $H_MEM, IN_HAS(%rbx)
	movl %r10d, %eax
	andl $7, %eax
	cmpl $4, %eax
	je .Lsib
	cmpl $5, %eax
	jne 7f
	cmpb $0, IN_MOD(%rbx)
	jne 7f
	orb $H_RIPREL, IN_HAS(%rbx)		# [rip + disp32]
	jmp .Ldisp32
7:	testl $X_B, %r9d
	jz 8f
	orl $8, %eax
8:	movb %al, IN_BASE(%rbx)
	jmp .Ldispmod
.Lsib:
	orb $H_SIB, IN_HAS(%rbx)
	NEXTB %edx
	movl %edx, %eax
	shrl $6, %eax
	movb %al, IN_SCALE(%rbx)
	movl %edx, %eax
	shrl $3, %eax
	andl $7, %eax
	testl $X_X, %r9d
	jz 1f
	orl $8, %eax
1:	cmpl $4, %eax				# index 4 without X: no index
	je 2f
	movb %al, IN_INDEX(%rbx)
2:	movl %edx, %eax
	andl $7, %eax
	cmpl $5, %eax
	jne 3f
	cmpb $0, IN_MOD(%rbx)
	jne 3f
	jmp .Ldisp32				# base 5 with mod 0: [disp32 + index*scale]
3:	testl $X_B, %r9d
	jz 4f
	orl $8, %eax
4:	movb %al, IN_BASE(%rbx)
.Ldispmod:
	cmpb $1, IN_MOD(%rbx)
	je .Ldisp8
	cmpb $2, IN_MOD(%rbx)
	je .Ldisp32
	jmp .Lopsize
.Ldisp8:
	movq %r15, %rax
	subq %r12, %rax
	movb %al, IN_DISP_OFF(%rbx)
	movb $1, IN_DISP_SZ(%rbx)
	orb $H_DISP, IN_HAS(%rbx)
	NEXTB %eax
	movsbq %al, %rax
	movq %rax, IN_DISP(%rbx)
	jmp .Lopsize
.Ldisp32:
	movq %r15, %rax
	subq %r12, %rax
	movb %al, IN_DISP_OFF(%rbx)
	movb $4, IN_DISP_SZ(%rbx)
	orb $H_DISP, IN_HAS(%rbx)
	leaq 4(%r15), %rax
	cmpq %r13, %rax
	ja .Lfail
	movslq (%r15), %rax
	movq %rax, IN_DISP(%rbx)
	addq $4, %r15
	jmp .Lopsize
.Lnomodrm:
	testl $LT_GROUP, %ebp			# a group needs a ModRM; the table never says otherwise
	jnz .Lfail

# The legacy operand size: REX.W, else a forced 64, else 66 gives 16,
# else the default (64 for the D64 opcodes, 32 otherwise). For VEX/EVEX
# the same bytes with W in place of REX.W (used by the entry match only
# for legacy entries, and by the immediate size for every map).
.Lopsize:
	movl $8, %eax
	cmpb $0, IN_W(%rbx)
	jne 1f
	testl $LT_F64, %ebp
	jnz 1f
	movl $2, %eax
	testl $P_66, %r8d
	jnz 1f
	movl $8, %eax
	testl $LT_D64, %ebp
	jnz 1f
	movl $4, %eax
1:	movb %al, IN_OPSIZE(%rbx)
	movl %eax, %r10d			# kept for the entry match (the ModRM is in the block now)
	# the immediate bytes at that size
	movl %ebp, %edx
	shrl $8, %edx				# LT_IMM
	cmpl $4, %eax
	je 2f
	cmpl $2, %eax
	jne 3f
	shrl $4, %edx
	jmp 2f
3:	movl %ebp, %edx
	shrl $16, %edx				# LT_IMM64
2:	andl $15, %edx
	movl %ebp, %ecx
	shrl $16, %ecx
	testl $LI_MOFFS, %ecx
	jz 4f
	movl $8, %edx
	testl $P_67, %r8d
	jz 4f
	movl $4, %edx
4:	testl %edx, %edx
	jz .Lflow
	movq %r15, %rax
	subq %r12, %rax
	movb %al, IN_IMM_OFF(%rbx)
	movb %dl, IN_IMM_SZ(%rbx)
	orb $H_IMM, IN_HAS(%rbx)
	leaq (%r15,%rdx), %rax
	cmpq %r13, %rax
	ja .Lfail
	cmpl $1, %edx
	je .Limm1
	cmpl $2, %edx
	je .Limm2
	cmpl $4, %edx
	je .Limm4
	cmpl $8, %edx
	je .Limm8
	# 3: imm16 then imm8 (ENTER)
	movzwl (%r15), %eax
	movq %rax, IN_IMM(%rbx)
	movzbl 2(%r15), %eax
	movb %al, IN_IMM2(%rbx)
	addq $3, %r15
	jmp .Lflow
.Limm1:	movzbl (%r15), %eax
	movq %rax, IN_IMM(%rbx)
	incq %r15
	jmp .Lflow
.Limm2:	movzwl (%r15), %eax
	movq %rax, IN_IMM(%rbx)
	addq $2, %r15
	jmp .Lflow
.Limm4:	movl (%r15), %eax
	movq %rax, IN_IMM(%rbx)
	addq $4, %r15
	jmp .Lflow
.Limm8:	movq (%r15), %rax
	movq %rax, IN_IMM(%rbx)
	addq $8, %r15

# The flow class and, for a relative branch, the target.
.Lflow:
	movl %ebp, %eax
	shrl $24, %eax
	movb %al, IN_FLOW(%rbx)
	movq %r15, %rax
	subq %r12, %rax
	movb %al, IN_LEN(%rbx)
	addq %r14, %rax
	movq %rax, IN_NEXT(%rbx)
	movl %ebp, %ecx
	shrl $16, %ecx
	testl $LI_REL, %ecx
	jz .Lmatch
	movzbl IN_IMM_SZ(%rbx), %ecx
	movq IN_IMM(%rbx), %rdx
	cmpl $1, %ecx
	jne 1f
	movsbq %dl, %rdx
	jmp 3f
1:	cmpl $2, %ecx
	jne 2f
	movswq %dx, %rdx
	jmp 3f
2:	movslq %edx, %rdx
3:	addq %rdx, %rax
	movq %rax, IN_TARGET(%rbx)

# Which instruction: the entry under (encoding, map, prefix, opcode). A
# legacy instruction's prefix is tried as the mandatory one first (F3, F2
# or 66), then as none (66 then means a 16-bit operand size).
.Lmatch:
	cmpb $0, IN_ENC(%rbx)
	jne .Lmatch_v
	xorl %edx, %edx				# the first candidate
	testl $P_F3, %r8d
	jz 1f
	movl $2, %edx
	jmp 2f
1:	testl $P_F2, %r8d
	jz 3f
	movl $3, %edx
	jmp 2f
3:	testl $P_66, %r8d
	jz 2f
	movl $1, %edx
2:	movl %edx, %ecx				# ecx = the candidate pp
	call .Ltry_pp
	testl %eax, %eax
	jnz .Lmatched
	testl %ecx, %ecx
	jz .Lnoentry
	xorl %ecx, %ecx				# then with no mandatory prefix
	call .Ltry_pp
	testl %eax, %eax
	jnz .Lmatched
	jmp .Lnoentry
.Lmatch_v:
	movzbl IN_PP(%rbx), %ecx
	call .Ltry_pp
	testl %eax, %eax
	jz .Lnoentry
.Lmatched:
	# rax = the entry
	movq %rax, IN_ENTRYP(%rbx)
	leaq x86_ent(%rip), %rdx
	subq %rdx, %rax
	xorl %edx, %edx
	movl $EN_BYTES, %ecx
	divq %rcx
	movl %eax, IN_ENTRY(%rbx)
	orb $H_ENTRY, IN_HAS(%rbx)
	movq IN_ENTRYP(%rbx), %rdx
	cmpb $2, IN_ENC(%rbx)
	jne .Lvsib
	# EVEX: disp8 * N, N by broadcast
	cmpb $1, IN_DISP_SZ(%rbx)
	jne .Lvsib
	movzbl EN_N(%rdx), %eax
	cmpb $0, IN_B(%rbx)
	je 1f
	movzbl EN_NB(%rdx), %ecx
	testl %ecx, %ecx
	jz 1f
	movl %ecx, %eax
1:	testl %eax, %eax
	jnz 2f
	movl $1, %eax
2:	movb %al, IN_N(%rbx)
	movq IN_DISP(%rbx), %rcx
	imulq %rax, %rcx
	movq %rcx, IN_DISP(%rbx)
.Lvsib:
	# a VSIB index takes V' (EVEX); otherwise V' is vvvv's bit 4
	cmpb $0, IN_ENC(%rbx)
	je .Ldone
	xorl %ecx, %ecx
	movzbl EN_NOPS(%rdx), %esi
1:	cmpl %esi, %ecx
	jae 3f
	movzbl EN_OPS(%rdx,%rcx), %eax
	incl %ecx
	cmpl $OK_mem_vsib32x, %eax
	jb 1b
	cmpl $OK_mem_vsib64z, %eax
	ja 1b
	orb $H_VSIB, IN_HAS(%rbx)
	testl $X_VP, %r9d
	jz .Ldone
	orb $16, IN_INDEX(%rbx)
	jmp .Ldone
3:	testl $X_VP, %r9d
	jz .Ldone
	orb $16, IN_VVVV(%rbx)
	jmp .Ldone
.Lnoentry:
	cmpb $0, IN_ENC(%rbx)
	jne .Ldone
	# no entry: the operand size as if no mandatory prefix was consumed
.Ldone:
	movzbl IN_LEN(%rbx), %eax
	jmp .Lret
.Lfail:
	movb $0, IN_LEN(%rbx)
	xorl %eax, %eax
.Lret:
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbp
	popq %rbx
	ret

# .Ltry_pp: the entries under prefix ecx for this instruction; rax = the
# matching entry or 0. Keeps ecx and r8 (the prefixes), r10 (the operand
# size from the length table). Uses rdx, rsi, rdi.
.Ltry_pp:
	movzbl IN_ENC(%rbx), %eax
	shll $2, %eax
	movzbl IN_MAP(%rbx), %edx
	addl %edx, %eax
	shll $2, %eax
	addl %ecx, %eax
	shll $8, %eax
	movzbl IN_OP(%rbx), %edx
	addl %edx, %eax
	leaq x86_idx(%rip), %rdx
	movzwl (%rdx,%rax,2), %eax
	cmpl $0xffff, %eax
	je .Ltry_none
	imulq $EN_BYTES, %rax, %rax
	leaq x86_ent(%rip), %rdx
	addq %rdx, %rax				# rax = the first entry
	cmpb $0, IN_ENC(%rbx)
	jne .Ltry_loop
	movb %cl, IN_PP(%rbx)
	movb %r10b, IN_OPSIZE(%rbx)
.Ltry_loop:
	# W
	cmpb $0, IN_ENC(%rbx)
	je 2f
	movzbl EN_W(%rax), %edx
	cmpl $2, %edx
	je 3f
	cmpb %dl, IN_W(%rbx)
	jne .Ltry_next
3:	movzbl EN_L(%rax), %edx
	cmpl $3, %edx
	je 4f
	cmpb %dl, IN_L(%rbx)
	je 4f
	# EVEX.b on a register form: L'L is the rounding control, the length 512
	cmpb $2, IN_ENC(%rbx)
	jne .Ltry_next
	cmpb $0, IN_B(%rbx)
	je .Ltry_next
	cmpb $3, IN_MOD(%rbx)
	jne .Ltry_next
	cmpl $2, %edx
	jne .Ltry_next
	jmp 4f
2:	# legacy: the operand size this entry sees: REX.W gives 64; else a 66
	# that is not the mandatory prefix gives 16 (64 for an EX_F64 entry);
	# else the default, 64 for an EX_D64 entry, 32 otherwise
	movzbl EN_OPSIZE(%rax), %edx
	testl %edx, %edx
	jz 24f
	movzbl EN_X(%rax), %edi
	movl $8, %esi
	cmpb $0, IN_W(%rbx)
	jne 21f
	testl $EX_F64, %edi
	jnz 21f
	movl $2, %esi
	cmpl $1, %ecx
	je 22f
	testl $P_66, %r8d
	jnz 21f
22:	movl $8, %esi
	testl $EX_D64, %edi
	jnz 21f
	movl $4, %esi
21:	cmpl %esi, %edx
	jne .Ltry_next
	movb %sil, IN_OPSIZE(%rbx)
24:	# the address size
	movzbl EN_X(%rax), %edx
	andl $EX_ASIZE, %edx
	jz 4f
	movl $2, %esi
	testl $P_67, %r8d
	jz 23f
	movl $1, %esi
23:	cmpl %esi, %edx
	jne .Ltry_next
4:	# the group
	movzbl EN_GRP(%rax), %edx
	cmpl $255, %edx
	je 5f
	movzbl IN_MODRM(%rbx), %esi
	shrl $3, %esi
	andl $7, %esi
	cmpl %esi, %edx
	jne .Ltry_next
5:	movzbl EN_RMFIX(%rax), %edx
	cmpl $255, %edx
	je 6f
	cmpb $3, IN_MOD(%rbx)
	jne .Ltry_next
	movzbl IN_MODRM(%rbx), %esi
	andl $7, %esi
	cmpl %esi, %edx
	jne .Ltry_next
6:	movzbl EN_MODREQ(%rax), %edx
	testl %edx, %edx
	jz .Ltry_hit
	cmpl $1, %edx
	jne 7f
	cmpb $3, IN_MOD(%rbx)
	jne .Ltry_next
	jmp .Ltry_hit
7:	cmpb $3, IN_MOD(%rbx)
	je .Ltry_next
.Ltry_hit:
	ret
.Ltry_next:
	testb $EF_LAST, EN_FLAGS(%rax)
	jnz .Ltry_none
	addq $EN_BYTES, %rax
	jmp .Ltry_loop
.Ltry_none:
	xorl %eax, %eax
	ret

	.include "x86tab.inc"
	.section .note.GNU-stack,"",@progbits
