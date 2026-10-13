# card.S: the cards the preload library drives: each card's window, the
# slot this process uses on it, requests posted and waited for, chunks of
# the program's memory made resident (staged into the window, K_RESIDENT),
# function instances run (K_FEXEC) and their outputs fetched (K_PUSH).
# One slot per card, one process; every request waits in turn except the
# instances of one call, which run on all the cards at once. See card.md.

	.include "common.inc"
	.include "proto.inc"
	.include "defs.inc"

	.set TB_BASE, 0
	.set TB_ENTRY, 8
	.set TB_CAP, 16
	.set TB_LIVE, 24

	.bss
	.balign 64
	.globl cards, ncards
cards:	.skip MAX_CARDS * CD_BYTES
ncards:	.skip 8
	.balign 64
res_entries:	.skip MAX_CARDS * RES_TAB_CAP * RES_ENTRY
	.globl stat_resident, stat_resident_ns, stat_push_ns
stat_resident:	.skip 8			# chunks made resident
stat_resident_ns:	.skip 8
stat_push_ns:	.skip 8
	.globl fexec_threads
fexec_threads:	.skip 8			# PHI512_THREADS: card threads an instance may split over (114)

	.section .rodata
s_env_cards:	.asciz "PHI512_CARDS"
s_env_card:	.asciz "PHI512_CARD"
s_env_slot:	.asciz "PHI512_SLOT"
s_env_threads:	.asciz "PHI512_THREADS"
s_open1:	.asciz "phi512: card "
s_open2:	.asciz ": no window (is the card up?)"
s_open3:	.asciz ": no worker polling"
s_load:	.asciz ": K_LOAD refused, status "

s_flush:	.asciz ": K_FLUSH refused (an older worker?)"

	.text

# cards_init: the cards from PHI512_CARDS (a comma list), else PHI512_CARD,
# else every card with a window; each opened, its worker waited for, the
# slot opened, the seeds loaded. eax the number of cards.
	.globl cards_init
cards_init:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	movq $0, ncards(%rip)
	leaq s_env_threads(%rip), %rdi
	movl $114, %esi
	call env_u64
	movq %rax, fexec_threads(%rip)
	leaq s_env_cards(%rip), %rdi
	call env_get
	testq %rax, %rax
	jz 2f
	movq %rax, %rbx
1:	xorl %edi, %edi				# the number at rbx, rbx past it
11:	movzbl (%rbx), %eax
	subl $'0', %eax
	cmpl $9, %eax
	ja 12f
	imulq $10, %rdi, %rdi
	addq %rax, %rdi
	incq %rbx
	jmp 11b
12:	call card_add
	cmpb $',', (%rbx)
	jne 5f
	incq %rbx
	jmp 1b
2:	leaq s_env_card(%rip), %rdi
	call env_get
	testq %rax, %rax
	jz 3f
	movq %rax, %rsi
	call parse_u64
	movq %rax, %rdi
	call card_add
	jmp 5f
3:	xorl %r12d, %r12d
4:	cmpl $MAX_CARDS, %r12d
	jae 5f
	movq %r12, %rdi
	call hostmem_exists
	testl %eax, %eax
	jz 41f
	movq %r12, %rdi
	call card_add
41:	incl %r12d
	jmp 4b
5:	movq ncards(%rip), %rax
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# card_add(index rdi): the card opened and prepared; skipped with a line
# when its window or worker is missing.
card_add:
	pushq %rbx
	pushq %r12
	pushq %r13
	movq %rdi, %r12				# the index
	movq ncards(%rip), %rax
	cmpq $MAX_CARDS, %rax
	jae 9f
	imulq $CD_BYTES, %rax, %rax
	leaq cards(%rip), %rbx
	addq %rax, %rbx				# the record
	movq %r12, CD_INDEX(%rbx)
	movq %r12, %rdi
	movq $OFF_RESIDENT + RESIDENT_BYTES, %rsi
	call window_open
	testq %rax, %rax
	jz .Lca_nowindow
	movq %rax, CD_BASE(%rbx)
	movq %rax, %rdi
	movq $2000000000, %rsi
	call wait_ready
	testl %eax, %eax
	jz .Lca_noworker
	leaq s_env_slot(%rip), %rdi
	xorl %esi, %esi
	call env_u64
	cmpq $NSLOTS, %rax
	jb 1f
	xorl %eax, %eax
1:	movq %rax, CD_SLOT(%rbx)
	movq CD_BASE(%rbx), %rcx
	movq %rax, %rdx
	shlq $12, %rdx
	leaq OFF_SLOTS(%rcx,%rdx), %rdx
	movq %rdx, CD_SLOTP(%rbx)
	movq %rax, %rdx
	shlq $20, %rdx
	addq $OFF_SLOTDATA, %rdx
	addq %rcx, %rdx
	movq %rdx, CD_DATAP(%rbx)
	movq $0, CD_SEQ(%rbx)
	movq $0, CD_STAGE(%rbx)
	# the slot opened: its u16 to 0, the stale reply number to 0
	movq CD_SLOT(%rbx), %rdx
	movw $0, OFF_SLOTSEQ(%rcx,%rdx,2)
	movq CD_SLOTP(%rbx), %rdx
	movq $0, SLOT_REPLY + SR_SEQ(%rdx)
	FENCE
	movl $1000000, %edi
	call sleep_ns
	# the session's start: the card's residency of the previous program
	# dropped (K_FLUSH), then this program's table
	movq %rbx, %rdi
	call card_clear_request
	movq %rbx, %rdi
	movl $K_FLUSH, %esi
	call card_post
	movq %rbx, %rdi
	call card_wait
	testl %eax, %eax
	jnz .Lca_flush
	# the residency table
	movq ncards(%rip), %rax
	imulq $RES_TAB_CAP * RES_ENTRY, %rax, %rax
	leaq res_entries(%rip), %rcx
	addq %rax, %rcx
	movq %rcx, CD_TAB + TB_BASE(%rbx)
	movq $RES_ENTRY, CD_TAB + TB_ENTRY(%rbx)
	movq $RES_TAB_CAP, CD_TAB + TB_CAP(%rbx)
	movq $0, CD_TAB + TB_LIVE(%rbx)
	leaq CD_TAB(%rbx), %rdi
	call tab_clear
	# the seeds' blobs, each under its index plus one
	xorl %r13d, %r13d
2:	cmpq nseeds(%rip), %r13
	jae 3f
	movq %rbx, %rdi
	movq %r13, %rsi
	call card_load_seed
	testl %eax, %eax
	jnz .Lca_load
	incq %r13
	jmp 2b
3:	incq ncards(%rip)
9:	popq %r13
	popq %r12
	popq %rbx
	ret
.Lca_nowindow:
	leaq s_open2(%rip), %r13
	jmp .Lca_say
.Lca_noworker:
	leaq s_open3(%rip), %r13
	jmp .Lca_say
.Lca_flush:
	leaq s_flush(%rip), %r13
	jmp .Lca_say
.Lca_load:
	call l_begin
	leaq s_open1(%rip), %rsi
	call w_str
	movq %r12, %rdi
	call w_dec
	leaq s_load(%rip), %rsi
	call w_str
	movq CD_SLOTP(%rbx), %rcx
	movl SLOT_REPLY + SR_STATUS(%rcx), %edi
	call w_sdec
	movl $2, %edi
	call l_end
	jmp 9b
.Lca_say:
	call l_begin
	leaq s_open1(%rip), %rsi
	call w_str
	movq %r12, %rdi
	call w_dec
	movq %r13, %rsi
	call w_str
	movl $2, %edi
	call l_end
	jmp 9b

# card_load_seed(card rdi, seed index rsi): the seed's blob into the
# slot's part of LOADAREA, K_LOAD under fn_id = index + 1; eax 0 or the
# status.
card_load_seed:
	pushq %rbx
	pushq %r12
	movq %rdi, %rbx
	movq %rsi, %r12
	imulq $SD_BYTES, %r12, %rax
	leaq seeds(%rip), %rcx
	addq %rax, %rcx				# the seed
	movq CD_SLOT(%rbx), %rdi
	imulq $FX_LOAD_PER_SLOT_H, %rdi, %rdi
	addq $OFF_LOADAREA, %rdi
	addq CD_BASE(%rbx), %rdi
	movq SD_BLOB(%rcx), %rsi
	movq SD_BLOB_LEN(%rcx), %rdx
	pushq %rcx
	call mem_copy
	popq %rcx
	movq %rbx, %rdi
	call card_clear_request			# clobbers rcx: the seed again
	imulq $SD_BYTES, %r12, %rcx
	leaq seeds(%rip), %rax
	addq %rax, %rcx
	movq CD_SLOTP(%rbx), %rdi
	leaq 1(%r12), %rax
	movq %rax, SL_FN_ID(%rdi)
	movq SD_BLOB_LEN(%rcx), %rax
	movq %rax, SL_ENTRY(%rdi)
	movq %rbx, %rdi
	movl $K_LOAD, %esi
	call card_post
	movq %rbx, %rdi
	call card_wait
	testl %eax, %eax
	jnz 8f
	cmpq $0, verbose(%rip)
	je 8f
	pushq %rax
	call l_begin
	leaq s_blob1(%rip), %rsi
	call w_str
	movq CD_INDEX(%rbx), %rdi
	call w_dec
	leaq s_blob2(%rip), %rsi
	call w_str
	imulq $SD_BYTES, %r12, %rax
	leaq seeds(%rip), %rcx
	movq SD_NAME(%rcx,%rax), %rsi
	call w_str
	leaq s_blob3(%rip), %rsi
	call w_str
	movq CD_SLOTP(%rbx), %rcx
	movq SLOT_REPLY + SR_EXIT_AUX(%rcx), %rdi
	call w_hexn
	movl $2, %edi
	call l_end
	popq %rax
8:	popq %r12
	popq %rbx
	ret
	.set FX_LOAD_PER_SLOT_H, 512 * 1024

# card_clear_request(card rdi): the slot's request block zeroed but for seq.
	.globl card_clear_request
card_clear_request:
	movq CD_SLOTP(%rdi), %rdi
	addq $8, %rdi
	movl $(SL_REQ_BYTES - 8) / 8, %ecx
	xorl %eax, %eax
	rep stosq
	ret

# card_post(card rdi, kind esi): the next sequence number into the
# request, the kind, a fence, the u16 (kind in its top four bits).
	.globl card_post
card_post:
	movq CD_SLOTP(%rdi), %rcx
	incq CD_SEQ(%rdi)
	movq CD_SEQ(%rdi), %rax
	movq %rax, SL_SEQ(%rcx)
	movl %esi, SL_KIND(%rcx)
	FENCE
	andl $0xfff, %eax
	shll $12, %esi
	orl %esi, %eax
	movq CD_BASE(%rdi), %rcx
	movq CD_SLOT(%rdi), %rdx
	movw %ax, OFF_SLOTSEQ(%rcx,%rdx,2)
	FENCE
	ret

# card_wait(card rdi): until the reply's sequence number is the request's;
# eax the reply's status (0 or negative), or 1 after REQ_TIMEOUT_NS.
	.globl card_wait
card_wait:
	pushq %rbx
	pushq %r12
	pushq %r13
	movq %rdi, %rbx
	movq CD_SLOTP(%rbx), %r12
	call now_ns
	movq %rax, %r13
1:	movq CD_SEQ(%rbx), %rax
	cmpq SLOT_REPLY + SR_SEQ(%r12), %rax
	je 2f
	pause
	call now_ns
	subq %r13, %rax
	movabsq $REQ_TIMEOUT_NS, %rcx
	cmpq %rcx, %rax
	jb 1b
	movl $1, %eax
	jmp 3f
2:	movl SLOT_REPLY + SR_STATUS(%r12), %eax
3:	popq %r13
	popq %r12
	popq %rbx
	ret

# card_resident(card rdi, chunk address rsi, class edx): the chunk on the
# card: already in the table, or staged (a 2 MiB copy into the next
# staging slot), K_RESIDENT, waited for, entered. eax 0, or the status.
	.globl card_resident
card_resident:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	movq %rdi, %rbx
	movq %rsi, %r12
	movl %edx, %r13d
	leaq CD_TAB(%rbx), %rdi
	movq %r12, %rsi
	call tab_find
	testq %rax, %rax
	jnz 8f
	call now_ns
	movq %rax, %r14
	# the staging slot, round robin
	movq CD_STAGE(%rbx), %rax
	movq %rax, %rcx
	incq %rcx
	andq $STAGING_SLOTS - 1, %rcx
	movq %rcx, CD_STAGE(%rbx)
	pushq %rax
	shlq $21, %rax
	addq $OFF_RESIDENT, %rax
	addq CD_BASE(%rbx), %rax
	movq %rax, %rdi
	# the parts of the chunk the program has mapped readable (an array
	# may start or end inside the 2 MiB, with nothing beside it)
	movq %r12, %rsi
	movl $CHUNK, %edx
	call copy_mapped
	popq %rax
	pushq %rax
	movq %rbx, %rdi
	call card_clear_request
	popq %rax
	movq CD_SLOTP(%rbx), %rcx
	movq %r12, SL_FN_ID(%rcx)
	movq %rax, SL_ENTRY(%rcx)
	movl %r13d, SL_THREADS(%rcx)
	movq %rbx, %rdi
	movl $K_RESIDENT, %esi
	call card_post
	movq %rbx, %rdi
	call card_wait
	testl %eax, %eax
	jnz 9f
	leaq CD_TAB(%rbx), %rdi
	movq %r12, %rsi
	call tab_insert
	testq %rax, %rax
	jz 9f
	movq CD_SLOTP(%rbx), %rcx
	movq SLOT_REPLY + SR_EXIT_AUX(%rcx), %rdx
	movq %rdx, RE_PAGE(%rax)
	movl %r13d, RE_CLASS(%rax)
	incq stat_resident(%rip)
	call now_ns
	subq %r14, %rax
	addq %rax, stat_resident_ns(%rip)
8:	xorl %eax, %eax
9:	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# card_fexec_post(card rdi, seed rsi, file rdx (REGS_BYTES), lo rcx, hi r8):
# the file into the slot's SD_REGS_IN with the induction and bound
# registers set, the request (fn_id = seed index + 1, entry the seed's),
# posted. The caller waits (card_wait) when every instance is posted.
	.globl card_fexec_post
card_fexec_post:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %rbx
	movq %rsi, %r12
	movq %rcx, %r14
	movq %r8, %r15
	movq CD_DATAP(%rbx), %rdi
	addq $SD_REGS_IN, %rdi
	movq %rdx, %rsi
	movl $REGS_BYTES, %edx
	call mem_copy
	movq CD_DATAP(%rbx), %rdi
	addq $SD_REGS_IN, %rdi
	movl SD_IND(%r12), %eax
	movq %r14, REGS_GPR(%rdi,%rax,8)
	movl SD_BOUND(%r12), %eax
	movq %r15, REGS_GPR(%rdi,%rax,8)
	movq %rbx, %rdi
	call card_clear_request
	movq CD_SLOTP(%rbx), %rcx
	movq %r12, %rax
	leaq seeds(%rip), %rdx
	subq %rdx, %rax
	xorl %edx, %edx
	movl $SD_BYTES, %r8d
	divq %r8
	incq %rax
	movq %rax, SL_FN_ID(%rcx)
	movq $0, SL_ENTRY(%rcx)			# the hand-translated blobs start at the fault point
	movq fexec_threads(%rip), %rax
	movl %eax, SL_THREADS(%rcx)
	movl SD_IND(%r12), %eax
	movl %eax, SL_IND_REG(%rcx)
	movl SD_BOUND(%r12), %eax
	movl %eax, SL_BOUND_REG(%rcx)
	movl SD_STEP(%r12), %eax
	movq %rax, SL_STEP(%rcx)
	movq %rbx, %rdi
	movl $K_FEXEC, %esi
	call card_post
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# card_push(card rdi, address rsi, bytes rdx): the program's bytes from
# the card's memory into the program's, in pieces of SD_WB_BYTES (K_PUSH,
# then a copy out of the slot's SD_WB). eax 0, or the status.
	.globl card_push
card_push:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %rbx
	movq %rsi, %r12
	movq %rdx, %r13
	call now_ns
	movq %rax, %r15
1:	testq %r13, %r13
	jz 8f
	movq %r13, %r14
	cmpq $SD_WB_BYTES, %r14
	jbe 2f
	movq $SD_WB_BYTES, %r14
2:	movq %rbx, %rdi
	call card_clear_request
	movq CD_SLOTP(%rbx), %rcx
	movq %r12, SL_FN_ID(%rcx)
	movq %r14, SL_ENTRY(%rcx)
	movq %rbx, %rdi
	movl $K_PUSH, %esi
	call card_post
	movq %rbx, %rdi
	call card_wait
	testl %eax, %eax
	jnz 9f
	movq %r12, %rdi
	movq CD_DATAP(%rbx), %rsi
	addq $SD_WB, %rsi
	movq %r14, %rdx
	call mem_copy
	addq %r14, %r12
	subq %r14, %r13
	jmp 1b
8:	call now_ns
	subq %r15, %rax
	addq %rax, stat_push_ns(%rip)
	xorl %eax, %eax
9:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
