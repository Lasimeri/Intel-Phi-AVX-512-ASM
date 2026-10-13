# blob.S: a function's blob for the card, built from its index
# (fnscan.S) over the decoder and the recipes (xlate.S): the scalar
# instructions copied as they are, a rip-relative operand re-based
# through a general register loaded with the program's address (saved
# in and restored from the card's scratch), the vector instructions
# through their recipes, the relative branches inside the function
# re-laid out as rel32 to the blob's own offsets, a branch out of the
# function and a direct call to the original address through the
# scratch's transfer slot, an indirect call or jump and a return as
# they are, the constants the recipes asked for appended 64-aligned
# and their displacements fixed up, and the rip map (the blob offset of
# every instruction, for entering at a fault's address). See blob.md.
#
#   blob_build(rdi = the blob block (BL_* with its areas set), rsi = the
#   function record (FN_*), rdx = the function's bytes as the host has
#   them (at FN_ADDR), rcx = the object (OB_*)) -> rax = 0, or the
#   refusal (a string; BL_REFUSED and BL_REFUSED_OFF say where).

	.include "proto.inc"
	.include "x86dec.inc"
	.include "fnscan.inc"
	.include "xlate.inc"

	.section .rodata
s_decode:	.asciz "the instruction did not decode in the blob pass"
s_badkind:	.asciz "an instruction kind the blob cannot carry (a trap or a far form)"
s_room:		.asciz "the blob's room ran out"
s_loop:		.asciz "a loop or jrcxz instruction (rel8 only) is not re-laid out yet"
s_noscratch:	.asciz "no general register free for a rip-relative operand"
s_sse:		.asciz "a legacy SSE instruction (the card has none) is not translated yet"
s_x87:		.asciz "an x87 instruction"
s_badmap:	.asciz "a branch target without a map entry"

	.text
# Register use: rbx the blob, r12 the function record, r13 the bytes,
# r14 the index entry, r15 the index count; the decoded block and a few
# words on the stack.
	.set F_IN, 0				# the decoded block
	.set F_I, IN_BYTES			# the entry's number
	.set F_OB, IN_BYTES + 8			# the object
	.set F_SCR, IN_BYTES + 16		# the scratch register of a re-based operand (-1 none); +8 a slot number
	.set F_BYTES, IN_BYTES + 32

	.globl blob_build
blob_build:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $F_BYTES, %rsp
	movq %rdi, %rbx
	movq %rsi, %r12
	movq %rdx, %r13
	movq %rcx, F_OB(%rsp)
	movq %r12, BL_FN(%rbx)
	movq $0, BL_REFUSED(%rbx)
	movl $0, BL_NCONST(%rbx)
	movl $0, BL_NFIX(%rbx)
	movl $0, BL_NBRFIX(%rbx)
	movq BL_CODE(%rbx), %rax
	movq %rax, BL_OUT(%rbx)
	movl FN_NINSN(%r12), %r15d
	movl %r15d, BL_NMAP(%rbx)
	movq FN_INSNS(%r12), %r14
	movq $0, F_I(%rsp)
# Pass one: every instruction emitted, its blob offset recorded in the
# map, branches inside the function as rel32 with a fixup.
.Lnext:
	movq F_I(%rsp), %rax
	cmpq %r15, %rax
	jae .Lfixups
	movq BL_MAP(%rbx), %rcx
	movq BL_OUT(%rbx), %rdx
	subq BL_CODE(%rbx), %rdx
	movl %edx, (%rcx,%rax,4)
	movl IX_OFF(%r14), %eax
	leaq (%r13,%rax), %rdi
	movzbl IX_LEN(%r14), %esi
	leaq F_IN(%rsp), %rdx
	movq FN_ADDR(%r12), %rcx
	addq %rax, %rcx
	call x86_decode
	testl %eax, %eax
	jz .Lref_decode
	movl $-1, F_SCR(%rsp)
	movzbl IX_KIND(%r14), %eax
	cmpl $K_COPY, %eax
	je .Lcopy
	cmpl $K_EVEX, %eax
	je .Lvector
	cmpl $K_VEX, %eax
	je .Lvector
	cmpl $K_BR_IN, %eax
	je .Lbr_in
	cmpl $K_BR_OUT, %eax
	je .Lbr_out
	cmpl $K_CALL, %eax
	je .Lcall
	cmpl $K_PLT, %eax
	je .Lcall
	cmpl $K_ICALL, %eax
	je .Licall
	cmpl $K_IJMP, %eax
	je .Licall
	cmpl $K_RET, %eax
	je .Lret
	cmpl $K_TRAP, %eax
	je .Ltrap
	jmp .Lref_badkind
.Ladvance:
	incq F_I(%rsp)
	addq $IX_BYTES, %r14
	jmp .Lnext

# A copied instruction: an x87 one and a legacy SSE one are refused for
# now; a rip-relative operand is re-based.
.Lcopy:
	leaq F_IN(%rsp), %rdx
	cmpb $0, IN_ENC(%rdx)
	jne 1f
	cmpb $0, IN_MAP(%rdx)
	je 2f
	movq IN_ENTRYP(%rdx), %rcx
	testq %rcx, %rcx
	jz 1f
	movzbl EN_NOPS(%rcx), %esi
	xorl %eax, %eax
11:	cmpl %esi, %eax
	jae 1f
	movzbl EN_OPS(%rcx,%rax), %edi
	incl %eax
	cmpl $19, %edi
	je .Lref_sse
	cmpl $20, %edi
	je .Lref_sse
	cmpl $46, %edi
	jb 11b
	cmpl $49, %edi
	ja 11b
	jmp .Lref_sse
2:	movzbl IN_OP(%rdx), %eax
	cmpl $0xd8, %eax
	jb 1f
	cmpl $0xdf, %eax
	jbe .Lref_x87
1:	testb $H_RIPREL, IN_HAS(%rdx)
	jnz .Lcopy_rip
	movl IX_OFF(%r14), %eax
	leaq (%r13,%rax), %rsi
	movzbl IX_LEN(%r14), %edx
	call .Lput
	jmp .Ladvance

# A rip-relative operand on a copied instruction. The scratch register
# r (one the instruction does not name; r8 and up first, since nothing
# uses those implicitly; below 8 only under a two-byte VEX, which has
# no B bit) is saved to [fs:S_RIPB] and loaded with the operand's
# address (movabs); then the instruction's bytes: the prefixes, a REX
# with B for r above 7 (the instruction's own REX with the bit set, or
# a new 41 when it had none), the opcode bytes, the ModRM with mod 00
# and rm = r (no displacement: it went into the address), the
# immediate if any; last r is restored, unless the instruction left
# (an indirect call or jump, where r is dead).
.Lcopy_rip:
	call .Lscratch_gpr
	testl %eax, %eax
	js .Lref_noscratch
	movl %eax, F_SCR(%rsp)
	call .Lrip_prologue
	leaq F_IN(%rsp), %rdx
	movl IX_OFF(%r14), %eax
	leaq (%r13,%rax), %rsi			# the instruction's bytes
	movzbl IN_OP_OFF(%rdx), %ecx		# the opcode's offset
	cmpb $0, IN_ENC(%rdx)
	jne .Lrip_vex
	# legacy: the prefixes without the REX, then the REX with B
	movl %ecx, %edx
	cmpb $0, F_IN + IN_REX(%rsp)
	je 1f
	decl %edx				# the REX is the last prefix byte
1:	pushq %rsi
	pushq %rcx
	call .Lput
	popq %rcx
	popq %rsi
	movzbl F_IN + IN_REX(%rsp), %eax
	movl F_SCR(%rsp), %edx
	shrl $3, %edx
	andl $1, %edx				# B
	testl %eax, %eax
	jnz 2f
	testl %edx, %edx
	jz 3f
	movl $0x40, %eax
2:	orl %edx, %eax
	pushq %rsi
	pushq %rcx
	call .Lbyte
	popq %rcx
	popq %rsi
3:	# the opcode bytes: from the opcode's offset to the ModRM's
	leaq F_IN(%rsp), %rdx
	addq %rcx, %rsi
	movzbl IN_MODRM_OFF(%rdx), %edx
	subl %ecx, %edx
	call .Lput
	jmp .Lrip_modrm
.Lrip_vex:
	# VEX/EVEX: the bytes up to the ModRM copied, then the B bit of the
	# payload cleared (inverted) for r above 7: three-byte VEX byte 1 (at
	# the opcode's offset minus 2), EVEX P0 (minus 3)
	movzbl IN_MODRM_OFF(%rdx), %edx
	pushq %rsi
	pushq %rcx
	call .Lput
	popq %rcx
	popq %rsi
	movl F_SCR(%rsp), %eax
	cmpl $8, %eax
	jb .Lrip_modrm
	leaq F_IN(%rsp), %rdx
	movq BL_OUT(%rbx), %rax
	movzbl IN_MODRM_OFF(%rdx), %r8d
	subq %r8, %rax				# the copied instruction's start in the blob
	addq %rcx, %rax				# its opcode
	cmpb $2, IN_ENC(%rdx)
	je 4f
	andb $0xdf, -2(%rax)
	jmp .Lrip_modrm
4:	andb $0xdf, -3(%rax)
.Lrip_modrm:
	leaq F_IN(%rsp), %rdx
	movzbl IN_MODRM(%rdx), %eax
	andl $0x38, %eax
	movl F_SCR(%rsp), %ecx
	andl $7, %ecx
	orl %ecx, %eax
	call .Lbyte
	# the immediate, if any: after the displacement
	leaq F_IN(%rsp), %rdx
	movzbl IN_DISP_OFF(%rdx), %eax
	addl $4, %eax
	movl IX_OFF(%r14), %ecx
	leaq (%r13,%rcx), %rsi
	addq %rax, %rsi
	movzbl IX_LEN(%r14), %edx
	subl %eax, %edx
	call .Lput
	movzbl IX_KIND(%r14), %eax
	cmpl $K_ICALL, %eax
	je .Ladvance
	cmpl $K_IJMP, %eax
	je .Ladvance
	call .Lrip_epilogue
	jmp .Ladvance
# .Lrip_prologue: mov [fs:S_RIPB], r; movabs r, the operand's address
# (F_SCR the register, F_IN the instruction).
.Lrip_prologue:
	movl F_SCR + 8(%rsp), %esi
	movl $1, %edx
	movl $S_RIPB, %ecx
	movl $1, %r8d
	call .Lgpr_scratch
	popq %r10				# .Lrip_movabs reads the frame through rsp as a direct call sees it
	call .Lrip_movabs
	pushq %r10
	ret
# .Lrip_epilogue: mov r, [fs:S_RIPB].
.Lrip_epilogue:
	movl F_SCR + 8(%rsp), %esi
	movl $1, %edx
	movl $S_RIPB, %ecx
	xorl %r8d, %r8d
	call .Lgpr_scratch
	ret

# A vector instruction: a rip-relative memory operand is re-based the
# same way (the decoded block's base becomes r, its displacement 0)
# around the recipe.
.Lvector:
	leaq F_IN(%rsp), %rdx
	testb $H_RIPREL, IN_HAS(%rdx)
	jz 1f
	movb $1, scr_vector(%rip)		# the recipe re-encodes: any register serves as the base (the emitter takes rax and rcx)
	call .Lscratch_gpr
	movb $0, scr_vector(%rip)
	testl %eax, %eax
	js .Lref_noscratch
	movl %eax, F_SCR(%rsp)
	call .Lrip_prologue
	leaq F_IN(%rsp), %rdx
	movl F_SCR(%rsp), %eax
	movb %al, IN_BASE(%rdx)
	movq $0, IN_DISP(%rdx)
	andb $~H_RIPREL, IN_HAS(%rdx)
1:	movq %rbx, %rdi
	leaq F_IN(%rsp), %rsi
	call xl_insn
	testq %rax, %rax
	jnz .Lrefuse
	cmpl $0, F_SCR(%rsp)
	jl .Ladvance
	call .Lrip_epilogue
	jmp .Ladvance

# A relative branch inside the function: jcc rel32 (0F 80+cc) or jmp
# rel32 (E9) with a branch fixup to the target's offset; a loop or
# jrcxz (rel8 only) is refused for now.
.Lbr_in:
	leaq F_IN(%rsp), %rdx
	cmpb $FL_LOOP, IN_FLOW(%rdx)
	je .Lref_loop
	movzbl IN_OP(%rdx), %eax
	cmpb $FL_JCC, IN_FLOW(%rdx)
	jne 1f
	cmpb $1, IN_MAP(%rdx)
	je 2f
	andl $0x0f, %eax
	orl $0x80, %eax
2:	pushq %rax
	movl $0x0f, %eax
	call .Lbyte
	popq %rax
	call .Lbyte
	jmp 3f
1:	movl $0xe9, %eax
	call .Lbyte
3:	movl BL_NBRFIX(%rbx), %eax
	cmpl BL_BRFIX_CAP(%rbx), %eax
	jae .Lref_room
	incl BL_NBRFIX(%rbx)
	imulq $FX_BYTES, %rax, %rax
	addq BL_BRFIX(%rbx), %rax
	movq BL_OUT(%rbx), %rcx
	subq BL_CODE(%rbx), %rcx
	movl %ecx, FX_AT(%rax)
	addl $4, %ecx
	movl %ecx, FX_END(%rax)
	movq IX_TGT(%r14), %rcx
	subq FN_ADDR(%r12), %rcx
	movl %ecx, FX_WHAT(%rax)
	xorl %eax, %eax
	call .Ldword
	jmp .Ladvance

# The exits. A blob leaves the card through the exit stub (`jmp
# *%fs:FX_EXIT_TPOFF`) with the exit's kind in [fs:S_KIND], the address
# the host resumes at in [fs:S_SITE] and an aux in [fs:S_XFER]; the host
# continues the program natively from there (a call executed, a branch
# target, a return address, a syscall). .Lseq_slot (rax the value, ecx
# the slot) writes a 64-bit value to a scratch slot through rax (saved
# in S_RAX around it); .Lseq_kind writes the kind; .Lseq_jmp the jump.

# A relative branch out of the function: X_JUMP to the target; a
# conditional one skips the sequence when not taken (the inverse
# condition over it).
.Lbr_out:
	leaq F_IN(%rsp), %rdx
	cmpb $FL_LOOP, IN_FLOW(%rdx)
	je .Lref_loop
	cmpb $FL_JCC, IN_FLOW(%rdx)
	jne 1f
	movzbl IN_OP(%rdx), %eax
	andl $0x0f, %eax
	xorl $1, %eax
	orl $0x70, %eax
	call .Lbyte
	movl $.Lseq_slot_len + .Lseq_kind_len + .Lseq_jmp_len, %eax
	call .Lbyte
1:	movq IX_TGT(%r14), %rax
	movl $S_SITE, %ecx
	call .Lseq_slot
	movl $X_JUMP, %eax
	call .Lseq_kind
	call .Lseq_jmp
	jmp .Ladvance

# A direct call (inside the object or into the PLT): X_CALL at the call
# site, the callee as the aux.
.Lcall:
	movq IX_TGT(%r14), %rax
	movl $S_XFER, %ecx
	call .Lseq_slot
	call .Lsite_slot
	movl $X_CALL, %eax
	call .Lseq_kind
	call .Lseq_jmp
	jmp .Ladvance

# An indirect call (X_CALL at the site, the callee as the aux) or jump
# (X_JUMP to the target): the target from the register (mov [fs:slot],
# r) or loaded from the memory operand through a scratch register (r
# saved in S_GPR; a rip-relative operand through movabs r, address; mov
# r, [r]; else mov r, [the operand] with the instruction's own ModRM, SIB
# and displacement).
.Licall:
	leaq F_IN(%rsp), %rdx
	movl $S_SITE, %r8d			# the slot the target goes to: S_SITE for a jump, S_XFER for a call
	cmpb $K_IJMP, IX_KIND(%r14)
	je 1f
	movl $S_XFER, %r8d
1:	movl %r8d, F_SCR + 8(%rsp)		# (F_SCR's neighbour word: the slot)
	cmpb $3, IN_MOD(%rdx)
	jne 2f
	# call *reg / jmp *reg
	movzbl IN_RM(%rdx), %esi
	movl $1, %edx
	movl F_SCR + 8(%rsp), %ecx
	movl $1, %r8d
	call .Lgpr_scratch
	jmp 5f
2:	call .Lscratch_gpr
	testl %eax, %eax
	js .Lref_noscratch
	movl %eax, F_SCR(%rsp)
	movl %eax, %esi
	movl $1, %edx
	movl $S_GPR, %ecx
	movl $1, %r8d
	call .Lgpr_scratch
	leaq F_IN(%rsp), %rdx
	testb $H_RIPREL, IN_HAS(%rdx)
	jz 3f
	call .Lrip_movabs			# movabs r, the operand's address
	# mov r, [r]: REX.W (R and B for r above 7) 8B, ModRM mod 00 reg r rm r
	movl F_SCR(%rsp), %eax
	movl $0x48, %ecx
	cmpl $8, %eax
	jb 21f
	orl $5, %ecx
21:	pushq %rax
	movl %ecx, %eax
	call .Lbyte
	movl $0x8b, %eax
	call .Lbyte
	popq %rax
	andl $7, %eax
	movl %eax, %ecx
	shll $3, %ecx
	orl %ecx, %eax
	call .Lbyte
	jmp 4f
3:	# mov r, [the operand]: a REX with W, R for r, and the instruction's X and B; 8B; the ModRM with reg = r; the SIB and displacement copied
	movl $0x48, %eax
	movl F_SCR(%rsp), %ecx
	shrl $3, %ecx
	andl $1, %ecx
	shll $2, %ecx
	orl %ecx, %eax
	movzbl IN_REX(%rdx), %ecx
	andl $3, %ecx
	orl %ecx, %eax
	call .Lbyte
	movl $0x8b, %eax
	call .Lbyte
	leaq F_IN(%rsp), %rdx
	movzbl IN_MODRM(%rdx), %eax
	andl $0xc7, %eax
	movl F_SCR(%rsp), %ecx
	andl $7, %ecx
	shll $3, %ecx
	orl %ecx, %eax
	call .Lbyte
	leaq F_IN(%rsp), %rdx
	movzbl IN_MODRM_OFF(%rdx), %ecx
	incl %ecx				# after the ModRM
	movl IX_OFF(%r14), %eax
	leaq (%r13,%rax), %rsi
	addq %rcx, %rsi
	movzbl IX_LEN(%r14), %edx
	subl %ecx, %edx				# the SIB and displacement (no immediate on these)
	call .Lput
4:	movl F_SCR(%rsp), %esi
	movl $1, %edx
	movl F_SCR + 8(%rsp), %ecx
	movl $1, %r8d
	call .Lgpr_scratch			# mov [fs:slot], r
	movl F_SCR(%rsp), %esi
	movl $1, %edx
	movl $S_GPR, %ecx
	xorl %r8d, %r8d
	call .Lgpr_scratch			# r restored
5:	cmpb $K_IJMP, IX_KIND(%r14)
	je 6f
	call .Lsite_slot
	movl $X_CALL, %eax
	call .Lseq_kind
	call .Lseq_jmp
	jmp .Ladvance
6:	movl $X_JUMP, %eax
	call .Lseq_kind
	call .Lseq_jmp
	jmp .Ladvance

# A return: the return address popped into S_SITE, X_JUMP.
.Lret:
	movl $0x64, %eax
	call .Lbyte
	movl $0x8f, %eax
	call .Lbyte
	movl $0x04, %eax
	call .Lbyte
	movl $0x25, %eax
	call .Lbyte
	movl $S_SITE, %eax
	addl BL_SCRATCH(%rbx), %eax
	call .Ldword
	movl $X_RET, %eax
	call .Lseq_kind
	call .Lseq_jmp
	jmp .Ladvance

# A trap: a syscall is X_SYSCALL at the site (the host executes it);
# the others are refused.
.Ltrap:
	leaq F_IN(%rsp), %rdx
	cmpb $1, IN_MAP(%rdx)
	jne .Lref_badkind
	cmpb $0x05, IN_OP(%rdx)
	jne .Lref_badkind
	call .Lsite_slot
	movl $X_SYSCALL, %eax
	call .Lseq_kind
	call .Lseq_jmp
	jmp .Ladvance

# .Lsite_slot: the instruction's original address into S_SITE.
.Lsite_slot:
	movl IX_OFF(%r14), %eax
	addq FN_ADDR(%r12), %rax
	movl $S_SITE, %ecx
	jmp .Lseq_slot
# .Lseq_slot (rax the value, ecx the slot): mov [fs:S_RAX], rax; movabs
# rax, value; mov [fs:slot], rax; mov rax, [fs:S_RAX]. 37 bytes.
.Lseq_slot:
	pushq %rax
	pushq %rcx
	xorl %esi, %esi
	movl $1, %edx
	movl $S_RAX, %ecx
	movl $1, %r8d
	call .Lgpr_scratch
	movl $0x48, %eax
	call .Lbyte
	movl $0xb8, %eax
	call .Lbyte
	movq 8(%rsp), %rax
	call .Lqword
	xorl %esi, %esi
	movl $1, %edx
	movl (%rsp), %ecx
	movl $1, %r8d
	call .Lgpr_scratch
	xorl %esi, %esi
	movl $1, %edx
	movl $S_RAX, %ecx
	xorl %r8d, %r8d
	call .Lgpr_scratch
	popq %rcx
	popq %rax
	ret
	.set .Lseq_slot_len, 9 + 10 + 9 + 9
# .Lseq_kind (eax the kind): mov dword [fs:S_KIND], kind (64 C7 04 25 disp32 imm32). 12 bytes.
.Lseq_kind:
	pushq %rax
	movl $0x64, %eax
	call .Lbyte
	movl $0xc7, %eax
	call .Lbyte
	movl $0x04, %eax
	call .Lbyte
	movl $0x25, %eax
	call .Lbyte
	movl $S_KIND, %eax
	addl BL_SCRATCH(%rbx), %eax
	call .Ldword
	popq %rax
	call .Ldword
	ret
	.set .Lseq_kind_len, 12
# .Lseq_jmp: jmp *%fs:FX_EXIT_TPOFF (64 FF 24 25 disp32). 8 bytes.
.Lseq_jmp:
	movl $0x64, %eax
	call .Lbyte
	movl $0xff, %eax
	call .Lbyte
	movl $0x24, %eax
	call .Lbyte
	movl $0x25, %eax
	call .Lbyte
	movl $FX_EXIT_TPOFF, %eax
	call .Ldword
	ret
	.set .Lseq_jmp_len, 8
# .Lrip_movabs: movabs r, the operand's address (F_SCR the register).
.Lrip_movabs:
	movl F_SCR + 8(%rsp), %ecx
	movl $0x48, %eax
	cmpl $8, %ecx
	jb 1f
	orl $1, %eax
1:	call .Lbyte
	movl F_SCR + 8(%rsp), %eax
	andl $7, %eax
	addl $0xb8, %eax
	call .Lbyte
	leaq F_IN + 8(%rsp), %rdx
	movq IN_NEXT(%rdx), %rax
	addq IN_DISP(%rdx), %rax
	call .Lqword
	ret

# Pass two: the branch fixups through the map, then the constants
# appended 64-aligned and their fixups.
.Lfixups:
	xorl %r14d, %r14d
1:	cmpl BL_NBRFIX(%rbx), %r14d
	jae .Lconsts
	movl %r14d, %eax
	imulq $FX_BYTES, %rax, %rax
	addq BL_BRFIX(%rbx), %rax
	movl FX_WHAT(%rax), %edi
	pushq %rax
	call .Lfind
	popq %rcx
	testq %rax, %rax
	jz .Lref_badmap
	movq FN_INSNS(%r12), %rdx
	subq %rdx, %rax
	shrq $4, %rax
	movq BL_MAP(%rbx), %rdx
	movl (%rdx,%rax,4), %eax
	subl FX_END(%rcx), %eax
	movl FX_AT(%rcx), %edx
	movq BL_CODE(%rbx), %rsi
	movl %eax, (%rsi,%rdx)
	incl %r14d
	jmp 1b
.Lconsts:
	movq BL_OUT(%rbx), %rax
	subq BL_CODE(%rbx), %rax
	addq $63, %rax
	andq $-64, %rax
	movq %rax, %r14				# the constants' offset
	movl BL_NCONST(%rbx), %ecx
	shll $6, %ecx
	addq %rax, %rcx
	addq BL_CODE(%rbx), %rcx
	cmpq BL_CODE_LIM(%rbx), %rcx
	ja .Lref_room
2:	movq BL_OUT(%rbx), %rdx
	subq BL_CODE(%rbx), %rdx
	cmpq %r14, %rdx
	jae 3f
	movl $0xcc, %eax
	call .Lbyte
	jmp 2b
3:	xorl %ecx, %ecx
	movl %ecx, F_I(%rsp)
4:	movl F_I(%rsp), %ecx
	cmpl BL_NCONST(%rbx), %ecx
	jae 5f
	movq BL_CONSTS(%rbx), %rsi
	shll $6, %ecx
	addq %rcx, %rsi
	movl $64, %edx
	call .Lput
	incl F_I(%rsp)
	jmp 4b
5:	movl $0, F_I(%rsp)
6:	movl F_I(%rsp), %ecx
	cmpl BL_NFIX(%rbx), %ecx
	jae 7f
	imulq $FX_BYTES, %rcx, %rax
	addq BL_FIX(%rbx), %rax
	movl FX_WHAT(%rax), %ecx
	shll $6, %ecx
	addq %r14, %rcx
	subl FX_END(%rax), %ecx
	movl FX_AT(%rax), %edx
	movq BL_CODE(%rbx), %rsi
	movl %ecx, (%rsi,%rdx)
	incl F_I(%rsp)
	jmp 6b
7:	movq %r15, F_I(%rsp)
	xorl %eax, %eax
	jmp .Lout

.Lref_decode:	leaq s_decode(%rip), %rax
	jmp .Lrefuse
.Lref_badkind:	leaq s_badkind(%rip), %rax
	jmp .Lrefuse
.Lref_room:	leaq s_room(%rip), %rax
	jmp .Lrefuse
.Lref_loop:	leaq s_loop(%rip), %rax
	jmp .Lrefuse
.Lref_noscratch: leaq s_noscratch(%rip), %rax
	jmp .Lrefuse
.Lref_sse:	leaq s_sse(%rip), %rax
	jmp .Lrefuse
.Lref_x87:	leaq s_x87(%rip), %rax
	jmp .Lrefuse
.Lref_badmap:	leaq s_badmap(%rip), %rax
.Lrefuse:
	movq %rax, BL_REFUSED(%rbx)
	movl $0xffffffff, BL_REFUSED_OFF(%rbx)
	movq F_I(%rsp), %rcx
	cmpq %r15, %rcx
	jae .Lout
	movl IX_OFF(%r14), %ecx
	movl %ecx, BL_REFUSED_OFF(%rbx)
.Lout:
	addq $F_BYTES, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# .Lbyte (al), .Ldword (eax), .Lqword (rax), .Lput (rsi bytes, edx
# count): into the blob's code; past the limit nothing is written and
# the room refusal comes at the end. They clobber rdx (and .Lput rax).
.Lbyte:
	movq BL_OUT(%rbx), %rdx
	cmpq BL_CODE_LIM(%rbx), %rdx
	jae 1f
	movb %al, (%rdx)
	incq BL_OUT(%rbx)
1:	ret
.Ldword:
	movq BL_OUT(%rbx), %rdx
	addq $4, %rdx
	cmpq BL_CODE_LIM(%rbx), %rdx
	ja 1f
	movl %eax, -4(%rdx)
	movq %rdx, BL_OUT(%rbx)
1:	ret
.Lqword:
	movq BL_OUT(%rbx), %rdx
	addq $8, %rdx
	cmpq BL_CODE_LIM(%rbx), %rdx
	ja 1f
	movq %rax, -8(%rdx)
	movq %rdx, BL_OUT(%rbx)
1:	ret
.Lput:
	pushq %rsi
	pushq %rcx
	movl %edx, %ecx
1:	testl %ecx, %ecx
	jz 2f
	movzbl (%rsi), %eax
	call .Lbyte
	incq %rsi
	decl %ecx
	jmp 1b
2:	popq %rcx
	popq %rsi
	ret
# .Lgpr_scratch(r esi, wide edx, off ecx, store r8d): mov [fs:scratch +
# off], r or mov r, [fs:scratch + off], as mvex.S's em_gpr_scratch.
.Lgpr_scratch:
	pushq %rsi
	pushq %rdx
	pushq %rcx
	pushq %r8
	movl $0x64, %eax
	call .Lbyte
	movl 16(%rsp), %eax
	shll $3, %eax
	movl 24(%rsp), %edx
	shrl $3, %edx
	andl $1, %edx
	orl %edx, %eax
	testl %eax, %eax
	jz 1f
	orl $0x40, %eax
	call .Lbyte
1:	movl $0x8b, %eax
	cmpl $0, (%rsp)
	je 2f
	movl $0x89, %eax
2:	call .Lbyte
	movl 24(%rsp), %eax
	andl $7, %eax
	shll $3, %eax
	orl $0x04, %eax
	call .Lbyte
	movl $0x25, %eax
	call .Lbyte
	movl 8(%rsp), %eax
	addl BL_SCRATCH(%rbx), %eax
	call .Ldword
	popq %r8
	popq %rcx
	popq %rdx
	popq %rsi
	ret
# .Lscratch_gpr: a general register the decoded instruction (F_IN) does
# not name: r8, r9, r10, r11, r14, r15 in that order (nothing uses them
# implicitly; r12 and r13 have special ModRM encodings), or, under a
# two-byte VEX (no B bit), rax, rcx, rdx, rbx, rsi, rdi; the named ones
# are the ModRM reg field and vvvv when general, and the implicit al,
# cl, dx, eax, rax of the entry's kinds. eax the register or -1.
.Lscratch_gpr:
	leaq F_IN + 8(%rsp), %rdx
	movq IN_ENTRYP(%rdx), %rcx
	xorl %r8d, %r8d
	testb $H_MEM, IN_HAS(%rdx)
	jz 62f
	movzbl IN_BASE(%rdx), %edi
	cmpl $0xff, %edi
	je 61f
	btsl %edi, %r8d
61:	movzbl IN_INDEX(%rdx), %edi
	cmpl $0xff, %edi
	je 62f
	andl $15, %edi
	btsl %edi, %r8d
62:
	testq %rcx, %rcx
	jz 5f
	movzbl EN_NOPS(%rcx), %esi
	xorl %eax, %eax
1:	cmpl %esi, %eax
	jae 5f
	movzbl EN_OPS(%rcx,%rax), %edi
	incl %eax
	cmpl $25, %edi
	je 2f
	cmpl $27, %edi
	je 2f
	cmpl $28, %edi
	je 2f
	cmpl $31, %edi
	je 2f
	cmpl $32, %edi
	je 2f
	cmpl $36, %edi
	je 2f
	cmpl $37, %edi
	je 2f
	cmpl $35, %edi
	je 3f
	cmpl $40, %edi
	je 3f
	cmpl $73, %edi
	je 41f
	cmpl $75, %edi
	je 41f
	cmpl $77, %edi
	je 41f
	cmpl $78, %edi
	je 41f
	cmpl $74, %edi
	je 42f
	cmpl $76, %edi
	je 43f
	jmp 1b
2:	movzbl IN_REG(%rdx), %edi
	btsl %edi, %r8d
	jmp 1b
3:	movzbl IN_VVVV(%rdx), %edi
	btsl %edi, %r8d
	jmp 1b
41:	orl $1, %r8d
	jmp 1b
42:	orl $2, %r8d
	jmp 1b
43:	orl $4, %r8d
	jmp 1b
5:	# the order of preference
	leaq .Lscr_order(%rip), %rsi
	movl $6, %ecx
	cmpb $0, scr_vector(%rip)
	jne 6f
	cmpb $1, IN_ENC(%rdx)
	jne 6f
	movzbl IN_OP_OFF(%rdx), %eax
	movl IX_OFF(%r14), %edi
	leaq (%r13,%rdi), %rdi
	cmpb $0xc5, -2(%rdi,%rax)
	jne 6f
	leaq .Lscr_order_low(%rip), %rsi
6:	xorl %eax, %eax
7:	cmpl %ecx, %eax
	jae 9f
	movzbl (%rsi,%rax), %edi
	btl %edi, %r8d
	jnc 8f
	incl %eax
	jmp 7b
8:	movl %edi, %eax
	ret
9:	movl $-1, %eax
	ret
	.section .rodata
.Lscr_order: .byte 8, 9, 10, 11, 14, 15
.Lscr_order_low: .byte 0, 1, 2, 3, 6, 7
	.text
# .Lfind: the index entry whose offset is edi, in rax (0 none).
.Lfind:
	movq FN_INSNS(%r12), %r8
	movl FN_NINSN(%r12), %r9d
	xorl %ecx, %ecx
	movl %r9d, %edx
1:	cmpl %edx, %ecx
	jae 9f
	leal (%rcx,%rdx), %esi
	shrl $1, %esi
	movl %esi, %r10d
	shll $4, %r10d
	leaq (%r8,%r10), %rax
	cmpl IX_OFF(%rax), %edi
	je 8f
	jb 2f
	leal 1(%rsi), %ecx
	jmp 1b
2:	movl %esi, %edx
	jmp 1b
9:	xorl %eax, %eax
8:	ret
	.section .note.GNU-stack,"",@progbits

	.bss
scr_vector:	.skip 8			# 1 while .Lscratch_gpr serves a re-encoded vector instruction (r8 and up whatever the original's encoding)
