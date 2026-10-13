# fnscan.S: a function's instructions indexed for the translator: every
# instruction decoded (decode.S) and classified (copied, translated,
# a branch inside or outside the function, a direct call inside the
# object or into the PLT, an indirect call or jump, a return, a trap),
# the branch targets marked, the counts a census or a refusal needs.
# See fnscan.md.
#
#   fn_scan(rdi = the function's bytes, rsi = its size, rdx = its
#   address, rcx = the record out (FN_BYTES), r8 = the object (OB_*),
#   r9 = the index area (at least size * IX_BYTES bytes)) -> rax = 0,
#   or the FNF_* flags that stop a translation (the record is filled as
#   far as it went).
#
# The bytes need not be at the address: a file mapped elsewhere scans
# the same way (tools/fnscan-check.c); branch targets and callees are
# computed against the address.

	.include "x86dec.inc"
	.include "fnscan.inc"

	.text
	.globl fn_scan
# Register use: rbx the record, r12 the bytes, r13 the size, r14 the
# address, r15 the object; rbp the index entry being written; the
# decoded block on the stack.
fn_scan:
	pushq %rbx
	pushq %rbp
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $IN_BYTES + 16, %rsp
	movq %rcx, %rbx
	movq %rdi, %r12
	movq %rsi, %r13
	movq %rdx, %r14
	movq %r8, %r15
	# the record zeroed, then the fixed fields
	xorl %eax, %eax
	.irp o,0,8,16,24,32,40,48,56,64,72,80,88,96,104,112,120
	movq %rax, \o(%rbx)
	.endr
	movq %r14, FN_ADDR(%rbx)
	movq %r13, FN_SIZE(%rbx)
	movq %r9, FN_INSNS(%rbx)
	movq %r9, %rbp
	movq %r9, 8(%rsp)			# the index area's end: start + size * IX_BYTES
	movq %r13, %rax
	shlq $4, %rax
	addq %rax, 8(%rsp)
	xorl %r9d, %r9d				# the offset
	movq %r9, (%rsp)
# The linear decode.
.Lnext:
	movq (%rsp), %r9
	cmpq %r13, %r9
	jae .Llabels
	leaq (%r12,%r9), %rdi
	movq %r13, %rsi
	subq %r9, %rsi
	leaq 16(%rsp), %rdx
	leaq (%r14,%r9), %rcx
	call x86_decode
	movq (%rsp), %r9			# x86_decode uses r9
	testl %eax, %eax
	jz .Lfailed
	# the entry
	leaq IX_BYTES(%rbp), %rcx
	cmpq 8(%rsp), %rcx
	ja .Lfull
	movl %r9d, IX_OFF(%rbp)
	movb %al, IX_LEN(%rbp)
	movq $0, IX_TGT(%rbp)
	movw $0, IX_KIND(%rbp)
	leaq 16(%rsp), %rdx			# the decoded block
	incl FN_NINSN(%rbx)
	# flags: rip-relative, lock, fs/gs, no entry
	testb $H_RIPREL, IN_HAS(%rdx)
	jz 1f
	orb $IXF_RIP, IX_FLAGS(%rbp)
	incl FN_NRIP(%rbx)
1:	testb $P_LOCK, IN_PFX(%rdx)
	jz 2f
	orb $IXF_LOCK, IX_FLAGS(%rbp)
	incl FN_NLOCK(%rbx)
	orl $FNF_LOCK, FN_FLAGS(%rbx)
2:	testb $P_FS | P_GS, IN_PFX(%rdx)
	jz 3f
	orb $IXF_FS, IX_FLAGS(%rbp)
	incl FN_NFS(%rbx)
3:	testb $H_ENTRY, IN_HAS(%rdx)
	jnz 4f
	orb $IXF_UNK, IX_FLAGS(%rbp)
	incl FN_NUNK(%rbx)
	orl $FNF_UNK, FN_FLAGS(%rbx)
4:	# the kind, by flow class first
	movzbl IN_FLOW(%rdx), %eax
	cmpl $FL_NEXT, %eax
	je .Lplain
	cmpl $FL_JCC, %eax
	je .Lbranch_cond
	cmpl $FL_LOOP, %eax
	je .Lbranch_cond
	cmpl $FL_JMP, %eax
	je .Lbranch
	cmpl $FL_CALL, %eax
	je .Lcall
	cmpl $FL_RET, %eax
	je .Lret
	cmpl $FL_JMPI, %eax
	je .Lijmp
	cmpl $FL_CALLI, %eax
	je .Licall
	cmpl $FL_TRAP, %eax
	je .Ltrap
	# FL_FAR
	movb $K_FAR, IX_KIND(%rbp)
	orl $FNF_FAR, FN_FLAGS(%rbx)
	jmp .Ladvance
.Lplain:
	cmpb $2, IN_ENC(%rdx)
	jne 5f
	movb $K_EVEX, IX_KIND(%rbp)
	incl FN_NEVEX(%rbx)
	orl $FNF_EVEX, FN_FLAGS(%rbx)
	jmp .Ladvance
5:	cmpb $1, IN_ENC(%rdx)
	jne .Ladvance
	movb $K_VEX, IX_KIND(%rbp)
	incl FN_NVEX(%rbx)
	orl $FNF_VEX, FN_FLAGS(%rbx)
	jmp .Ladvance
.Lbranch_cond:
	orb $IXF_COND, IX_FLAGS(%rbp)
.Lbranch:
	movq IN_TARGET(%rdx), %rax
	movq %rax, IX_TGT(%rbp)
	subq %r14, %rax
	cmpq %r13, %rax
	jae 6f
	movb $K_BR_IN, IX_KIND(%rbp)
	incl FN_NBRIN(%rbx)
	jmp .Ladvance
6:	movb $K_BR_OUT, IX_KIND(%rbp)
	incl FN_NBROUT(%rbx)
	jmp .Ladvance
.Lcall:
	movq IN_TARGET(%rdx), %rax
	movq %rax, IX_TGT(%rbp)
	cmpq OB_PLT_LO(%r15), %rax
	jb 7f
	cmpq OB_PLT_HI(%r15), %rax
	jae 7f
	movb $K_PLT, IX_KIND(%rbp)
	incl FN_NPLT(%rbx)
	jmp .Ladvance
7:	movb $K_CALL, IX_KIND(%rbp)
	incl FN_NCALL(%rbx)
	jmp .Ladvance
.Lret:
	movb $K_RET, IX_KIND(%rbp)
	incl FN_NRET(%rbx)
	jmp .Ladvance
.Lijmp:
	movb $K_IJMP, IX_KIND(%rbp)
	incl FN_NIJMP(%rbx)
	jmp .Ladvance
.Licall:
	movb $K_ICALL, IX_KIND(%rbp)
	incl FN_NICALL(%rbx)
	jmp .Ladvance
.Ltrap:
	movb $K_TRAP, IX_KIND(%rbp)
	incl FN_NTRAP(%rbx)
	orl $FNF_TRAP, FN_FLAGS(%rbx)
.Ladvance:
	movzbl IX_LEN(%rbp), %eax
	addq %rax, (%rsp)
	addq $IX_BYTES, %rbp
	jmp .Lnext
.Lfailed:
	movl %r9d, FN_FAIL_OFF(%rbx)
	orl $FNF_FAILED, FN_FLAGS(%rbx)
	jmp .Llabels
.Lfull:
	orl $FNF_FULL, FN_FLAGS(%rbx)
# The labels: every internal branch's target must be an instruction's
# offset; found by a binary search over the index (offsets ascend).
.Llabels:
	movq FN_INSNS(%rbx), %r12		# the index
	movl FN_NINSN(%rbx), %r13d		# its count
	xorl %r9d, %r9d
1:	cmpl %r13d, %r9d
	jae .Ldone
	movq %r9, %rax
	shlq $4, %rax
	leaq (%r12,%rax), %rbp
	cmpb $K_BR_IN, IX_KIND(%rbp)
	jne 5f
	movq IX_TGT(%rbp), %rdi
	subq %r14, %rdi				# the target offset
	call .Lfind
	testq %rax, %rax
	jz 4f
	testb $IXF_LABEL, IX_FLAGS(%rax)
	jnz 5f
	orb $IXF_LABEL, IX_FLAGS(%rax)
	incl FN_NLABEL(%rbx)
	jmp 5f
4:	orl $FNF_BADTARGET, FN_FLAGS(%rbx)
5:	incl %r9d
	jmp 1b
.Ldone:
	movl FN_FLAGS(%rbx), %eax
	andl $FNF_FAILED | FNF_BADTARGET | FNF_FAR | FNF_FULL, %eax
	addq $IN_BYTES + 16, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbp
	popq %rbx
	ret

# .Lfind: the index entry whose offset is edi, in rax (0 none). r12 the
# index, r13d the count. Uses rcx, rdx, rsi, r8.
.Lfind:
	xorl %ecx, %ecx				# lo
	movl %r13d, %edx			# hi
1:	cmpl %edx, %ecx
	jae 9f
	leal (%rcx,%rdx), %esi
	shrl $1, %esi				# mid
	movl %esi, %r8d
	shll $4, %r8d
	leaq (%r12,%r8), %rax
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
