# xlfn.S: a seed's function translated at its first fault (stage 3,
# the automatic blobs in place of seeds.S's hand-written ones): the
# function indexed (fnscan.S) and built into a blob (blob.S) in a bump
# arena, the blob loaded on every card under the seed's id, and the
# fault's address mapped to the blob's entry through the rip map. The
# hand blobs stay under PHI512_HANDBLOBS=1 (the A/B of the two). See
# xlfn.md.

	.include "common.inc"
	.include "proto.inc"
	.include "defs.inc"
	.include "x86dec.inc"
	.include "fnscan.inc"
	.include "xlate.inc"

	.set ARENA_BYTES, 64 * 1024 * 1024
	.set CONST_CAP, 256
	.set FIX_CAP, 1024
	.set BRFIX_CAP, 4096

	.bss
	.balign 64
	.globl handblobs
handblobs:	.skip 8				# PHI512_HANDBLOBS: 1 keeps the hand-written blobs
xl_arena:	.skip 16			# struct gbuf
xl_used:	.skip 8
fnrec:		.skip FN_BYTES
obdesc:		.skip OB_BYTES
blob:		.skip BL_BYTES

	.section .rodata
s_t1:	.asciz "phi512: "
s_t2:	.asciz ": translated: "
s_t3:	.asciz " instructions, "
s_t4:	.asciz " bytes of blob, "
s_t5:	.asciz " constants"
s_r1:	.asciz "phi512: "
s_r2:	.asciz ": translation refused at +"
s_r3:	.asciz ": "
s_scan:	.asciz "the function did not scan (a decode failure, a branch into an instruction, a far form)"
s_arena: .asciz "the translation arena is full"
s_entry: .asciz "the fault's address is not an instruction of the index"

	.text
# alloc(bytes rdi): rax = 64-aligned room in the arena, 0 when full.
alloc:
	pushq %rbx
	movq %rdi, %rbx
	cmpq $0, xl_arena(%rip)
	jne 1f
	leaq xl_arena(%rip), %rdi
	movq $ARENA_BYTES, %rsi
	call gbuf_need
	testq %rax, %rax
	jz 9f
	movq $0, xl_used(%rip)
1:	movq xl_used(%rip), %rax
	addq $63, %rax
	andq $-64, %rax
	leaq (%rax,%rbx), %rcx
	cmpq $ARENA_BYTES, %rcx
	ja 9f
	movq %rcx, xl_used(%rip)
	addq xl_arena(%rip), %rax
	popq %rbx
	ret
9:	xorl %eax, %eax
	popq %rbx
	ret

# seed_prepare(seed rdi, rip rsi): the seed ready for a call at rip:
# under the hand blobs, 0 (the hand blobs are entered where they
# start); else the automatic blob built on first use and loaded on
# every card, and rax = the blob offset of rip's instruction; -1 when
# the translation was refused or rip is not an instruction (a line
# says which).
	.globl seed_prepare
seed_prepare:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %rbx
	movq %rsi, %r12
	cmpq $0, handblobs(%rip)
	jne .Lhand
	cmpq $0, SD_REFUSED(%rbx)
	jne .Lno
	cmpq $0, SD_ABLOB(%rbx)
	jne .Lentry
	call translate
	testl %eax, %eax
	jnz .Lno
	# the blob on every card
	xorl %r13d, %r13d
1:	cmpq ncards(%rip), %r13
	jae .Lentry
	movq %r13, %rdi
	imulq $CD_BYTES, %rdi, %rdi
	leaq cards(%rip), %rax
	addq %rax, %rdi
	movq %rbx, %rsi
	leaq seeds(%rip), %rax
	subq %rax, %rsi
	xorl %edx, %edx
	movq %rsi, %rax
	movl $SD_BYTES, %ecx
	divq %rcx
	movq %rax, %rsi
	call card_load_seed
	incq %r13
	jmp 1b
.Lentry:
	movq %rbx, %rdi
	movq %r12, %rsi
	call seed_entry
	jmp .Lout
.Lhand:
	xorl %eax, %eax
	jmp .Lout
.Lno:
	movq $-1, %rax
.Lout:
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# translate (rbx the seed): the index, the blob, the fields; eax 0 or 1
# (refused: SD_REFUSED set and the reason said).
translate:
	pushq %r12
	pushq %r13
	# the index: SD_LEN entries at most
	movq SD_LEN(%rbx), %rdi
	shlq $4, %rdi
	call alloc
	testq %rax, %rax
	jz .Lt_arena
	movq %rax, SD_INDEX(%rbx)
	# the object: the mapping that holds the function; no PLT known (every direct call goes to its address)
	movq SD_ADDR(%rbx), %rdi
	call mapped_range
	leaq obdesc(%rip), %rcx
	movq %rax, OB_LO(%rcx)
	movq %rdx, OB_HI(%rcx)
	movq $0, OB_PLT_LO(%rcx)
	movq $0, OB_PLT_HI(%rcx)
	movq SD_ADDR(%rbx), %rdi
	movq SD_LEN(%rbx), %rsi
	movq %rdi, %rdx
	leaq fnrec(%rip), %rcx
	leaq obdesc(%rip), %r8
	movq SD_INDEX(%rbx), %r9
	call fn_scan
	testl %eax, %eax
	jnz .Lt_scan
	leaq fnrec(%rip), %rax
	movl FN_NINSN(%rax), %eax
	movq %rax, SD_NINSN(%rbx)
	# the blob's areas
	leaq blob(%rip), %r12
	movq SD_LEN(%rbx), %rdi
	shlq $6, %rdi
	addq $65536, %rdi
	movq %rdi, %r13
	call alloc
	testq %rax, %rax
	jz .Lt_arena
	movq %rax, BL_CODE(%r12)
	addq %r13, %rax
	movq %rax, BL_CODE_LIM(%r12)
	movq $CONST_CAP * 64, %rdi
	call alloc
	testq %rax, %rax
	jz .Lt_arena
	movq %rax, BL_CONSTS(%r12)
	movl $CONST_CAP, BL_CONST_CAP(%r12)
	movq $FIX_CAP * FX_BYTES, %rdi
	call alloc
	testq %rax, %rax
	jz .Lt_arena
	movq %rax, BL_FIX(%r12)
	movl $FIX_CAP, BL_FIX_CAP(%r12)
	movq SD_NINSN(%rbx), %rdi
	shlq $2, %rdi
	call alloc
	testq %rax, %rax
	jz .Lt_arena
	movq %rax, BL_MAP(%r12)
	movq %rax, SD_MAP(%rbx)
	movq $BRFIX_CAP * FX_BYTES, %rdi
	call alloc
	testq %rax, %rax
	jz .Lt_arena
	movq %rax, BL_BRFIX(%r12)
	movl $BRFIX_CAP, BL_BRFIX_CAP(%r12)
	movl $FX_SCRATCH_TPOFF, BL_SCRATCH(%r12)
	movq %r12, %rdi
	leaq fnrec(%rip), %rsi
	movq SD_ADDR(%rbx), %rdx
	leaq obdesc(%rip), %rcx
	call blob_build
	testq %rax, %rax
	jnz .Lt_refused
	movq BL_CODE(%r12), %rax
	movq %rax, SD_ABLOB(%rbx)
	movq BL_OUT(%r12), %rcx
	subq %rax, %rcx
	movq %rcx, SD_ABLOB_LEN(%rbx)
	cmpq $0, verbose(%rip)
	je 8f
	call l_begin
	leaq s_t1(%rip), %rsi
	call w_str
	movq SD_NAME(%rbx), %rsi
	call w_str
	leaq s_t2(%rip), %rsi
	call w_str
	movq SD_NINSN(%rbx), %rdi
	call w_dec
	leaq s_t3(%rip), %rsi
	call w_str
	movq SD_ABLOB_LEN(%rbx), %rdi
	call w_dec
	leaq s_t4(%rip), %rsi
	call w_str
	movl BL_NCONST(%r12), %edi
	call w_dec
	leaq s_t5(%rip), %rsi
	call w_str
	movl $2, %edi
	call l_end
8:	xorl %eax, %eax
	jmp .Lt_out
.Lt_arena:
	leaq s_arena(%rip), %rax
	movq $-1, %rdx
	jmp .Lt_say
.Lt_scan:
	leaq s_scan(%rip), %rax
	leaq fnrec(%rip), %rcx
	movl FN_FAIL_OFF(%rcx), %edx
	jmp .Lt_say
.Lt_refused:
	movl BL_REFUSED_OFF(%r12), %edx
.Lt_say:
	# rax the reason, edx the offset
	movq $1, SD_REFUSED(%rbx)
	pushq %rax
	pushq %rdx
	call l_begin
	leaq s_r1(%rip), %rsi
	call w_str
	movq SD_NAME(%rbx), %rsi
	call w_str
	leaq s_r2(%rip), %rsi
	call w_str
	movq (%rsp), %rdi
	call w_dec
	leaq s_r3(%rip), %rsi
	call w_str
	movq 8(%rsp), %rsi
	call w_str
	movl $2, %edi
	call l_end
	addq $16, %rsp
	movl $1, %eax
.Lt_out:
	popq %r13
	popq %r12
	ret

# seed_entry(seed rdi, rip rsi): the blob offset of the instruction at
# rip (a binary search of the index for rip - SD_ADDR, then the map);
# -1 when rip is not an instruction's start.
	.globl seed_entry
seed_entry:
	pushq %rbx
	movq %rdi, %rbx
	movq %rsi, %rdi
	subq SD_ADDR(%rbx), %rdi		# the offset in the function
	movq SD_INDEX(%rbx), %r8
	movq SD_NINSN(%rbx), %r9
	xorl %ecx, %ecx
	movl %r9d, %edx
1:	cmpl %edx, %ecx
	jae 8f
	leal (%rcx,%rdx), %esi
	shrl $1, %esi
	movl %esi, %r10d
	shll $4, %r10d
	leaq (%r8,%r10), %rax
	cmpl IX_OFF(%rax), %edi
	je 7f
	jb 2f
	leal 1(%rsi), %ecx
	jmp 1b
2:	movl %esi, %edx
	jmp 1b
7:	movq SD_MAP(%rbx), %rcx
	movl (%rcx,%rsi,4), %eax		# the entry's blob offset
	popq %rbx
	ret
8:	call l_begin
	leaq s_r1(%rip), %rsi
	call w_str
	movq SD_NAME(%rbx), %rsi
	call w_str
	leaq s_r3(%rip), %rsi
	call w_str
	leaq s_entry(%rip), %rsi
	call w_str
	movl $2, %edi
	call l_end
	movq $-1, %rax
	popq %rbx
	ret
	.section .note.GNU-stack,"",@progbits

	.text
# seed_dyn_add(addr rdi): a dynamic seed for the executable's function
# that holds addr (elf_func_at): the record after the last (the table
# has SEEDS_DYN_MAX of them after the static ones), its name, address
# and length set, no plan (the region path runs it); rax the seed, 0
# when no function holds addr or the table is full.
	.globl seed_dyn_add
seed_dyn_add:
	pushq %rbx
	call elf_func_at
	testq %rax, %rax
	jz 9f
	movq nseeds(%rip), %rbx
	cmpq $3 + SEEDS_DYN_MAX, %rbx
	jae 9f
	imulq $SD_BYTES, %rbx, %rbx
	leaq seeds(%rip), %rsi
	addq %rsi, %rbx
	movq %rcx, SD_NAME(%rbx)
	movq %rax, SD_ADDR(%rbx)
	movq %rdx, SD_LEN(%rbx)
	movl $OPK_NONE, SD_OPS + OP_KIND(%rbx)
	movq %rbx, %rax
	incq nseeds(%rip)
	popq %rbx
	ret
9:	xorl %eax, %eax
	popq %rbx
	ret
