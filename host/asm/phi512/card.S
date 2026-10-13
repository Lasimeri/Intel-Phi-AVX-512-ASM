# card.S: the cards the preload library drives: each card's window, the
# slot this process uses on it, requests posted and waited for, the
# program's memory made resident by 64 KiB units (K_RESIDENT with a
# fill range, staged through the window), function instances run
# (K_FEXEC) and their outputs fetched (K_PUSH). One slot per card, one
# process; one request in flight per card, the four cards at once
# (sigill.S's rounds). See card.md.

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
	.globl stat_resident, stat_resident_ns, stat_push_ns, stat_resident_bytes
stat_resident:	.skip 8			# fills (K_RESIDENT with bytes)
stat_resident_ns:	.skip 8
stat_resident_bytes:	.skip 8
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
	movq $0, CD_POSTED(%rbx)
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
# status. Verbose: the blob's card address.
	.globl card_load_seed
card_load_seed:
	pushq %rbx
	pushq %r12
	pushq %r13
	movq %rdi, %rbx
	movq %rsi, %r12
	imulq $SD_BYTES, %r12, %rax
	leaq seeds(%rip), %rcx
	addq %rax, %rcx				# the seed
	movq CD_SLOT(%rbx), %rdi
	imulq $FX_LOAD_PER_SLOT_H, %rdi, %rdi
	addq $OFF_LOADAREA, %rdi
	addq CD_BASE(%rbx), %rdi
	movq SD_ABLOB(%rcx), %rsi		# the automatic blob when it exists, else the hand-written one
	movq SD_ABLOB_LEN(%rcx), %rdx
	testq %rsi, %rsi
	jnz 1f
	movq SD_BLOB(%rcx), %rsi
	movq SD_BLOB_LEN(%rcx), %rdx
1:	movq %rdx, %r13
	call mem_copy
	movq %rbx, %rdi
	call card_clear_request
	imulq $SD_BYTES, %r12, %rcx
	leaq seeds(%rip), %rax
	addq %rax, %rcx
	movq CD_SLOTP(%rbx), %rdi
	leaq 1(%r12), %rax
	movq %rax, SL_FN_ID(%rdi)
	movq %r13, SL_ENTRY(%rdi)		# the byte count
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
8:	popq %r13
	popq %r12
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
# request, the kind, a fence, the u16 (kind in its top five bits, the
# sequence number's low eleven below).
	.globl card_post
card_post:
	movq CD_SLOTP(%rdi), %rcx
	incq CD_SEQ(%rdi)
	movq CD_SEQ(%rdi), %rax
	movq %rax, SL_SEQ(%rcx)
	movl %esi, SL_KIND(%rcx)
	FENCE
	andl $0x7ff, %eax
	shll $11, %esi
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

# card_need(card rdi, chunk rsi, units edx): the units of the chunk the
# card does not hold yet, in eax; edx 1 when the chunk has no entry at
# all (a request is needed even for 0 units: the page).
	.globl card_need
card_need:
	pushq %rbx
	movl %edx, %ebx
	leaq CD_TAB(%rdi), %rdi
	call tab_find
	testq %rax, %rax
	jz 1f
	movl RE_FILLED(%rax), %ecx
	notl %ecx
	andl %ecx, %ebx
	movl %ebx, %eax
	xorl %edx, %edx
	popq %rbx
	ret
1:	movl %ebx, %eax
	movl $1, %edx
	popq %rbx
	ret

# card_resident_post(card rdi, chunk rsi, units edx, class ecx): the
# units' span staged into the next staging slot (the parts the program
# has mapped, through copy_mapped) and K_RESIDENT posted with the fill
# range (0 bytes when no unit: the page only). Kept as the card's
# pending request for card_resident_done.
	.globl card_resident_post
card_resident_post:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %rbx
	movq %rsi, %r12
	movl %edx, %r13d
	movl %ecx, %r14d
	movq %r12, CD_PEND_CHUNK(%rbx)
	movl %r13d, CD_PEND_UNITS(%rbx)
	movl %r14d, CD_PEND_CLASS(%rbx)
	# the staging slot, round robin
	movq CD_STAGE(%rbx), %r15
	movq %r15, %rcx
	incq %rcx
	andq $STAGING_SLOTS - 1, %rcx
	movq %rcx, CD_STAGE(%rbx)
	xorl %r8d, %r8d				# off
	xorl %r9d, %r9d				# len
	testl %r13d, %r13d
	jz 2f
	bsfl %r13d, %eax
	shll $16, %eax
	movl %eax, %r8d				# the lowest unit's offset
	bsrl %r13d, %ecx
	incl %ecx
	shll $16, %ecx
	subl %eax, %ecx
	movl %ecx, %r9d				# the span's bytes
	movq %r15, %rdi
	shlq $21, %rdi
	addq $OFF_RESIDENT, %rdi
	addq CD_BASE(%rbx), %rdi
	addq %r8, %rdi
	leaq (%r12,%r8), %rsi
	movq %r9, %rdx
	pushq %r8
	pushq %r9
	call copy_mapped
	popq %r9
	popq %r8
	addq %r9, stat_resident_bytes(%rip)
	incq stat_resident(%rip)
2:	pushq %r8
	pushq %r9
	movq %rbx, %rdi
	call card_clear_request
	popq %r9
	popq %r8
	movq CD_SLOTP(%rbx), %rcx
	movq %r12, SL_FN_ID(%rcx)
	movq %r15, SL_ENTRY(%rcx)
	movl %r14d, SL_THREADS(%rcx)
	movq %r8, SL_FILL_OFF(%rcx)
	movq %r9, SL_FILL_LEN(%rcx)
	movq %rbx, %rdi
	movl $K_RESIDENT, %esi
	call card_post
	movq $1, CD_POSTED(%rbx)
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# card_resident_done(card rdi): the pending K_RESIDENT waited for and
# its chunk entered (the page, the units added); eax 0 or the status.
	.globl card_resident_done
card_resident_done:
	pushq %rbx
	pushq %r12
	movq %rdi, %rbx
	call now_ns
	movq %rax, %r12
	movq %rbx, %rdi
	call card_wait
	movq $0, CD_POSTED(%rbx)
	testl %eax, %eax
	jnz 9f
	leaq CD_TAB(%rbx), %rdi
	movq CD_PEND_CHUNK(%rbx), %rsi
	call tab_insert
	testq %rax, %rax
	jz 8f
	movq CD_SLOTP(%rbx), %rcx
	movq SLOT_REPLY + SR_EXIT_AUX(%rcx), %rdx
	movq %rdx, RE_PAGE(%rax)
	movl CD_PEND_CLASS(%rbx), %ecx
	movl %ecx, RE_CLASS(%rax)
	movl CD_PEND_UNITS(%rbx), %ecx
	orl %ecx, RE_FILLED(%rax)
	call now_ns
	subq %r12, %rax
	addq %rax, stat_resident_ns(%rip)
8:	xorl %eax, %eax
9:	popq %r12
	popq %rbx
	ret

# card_fexec_post(card rdi, seed rsi, file rdx (REGS_BYTES), lo rcx, hi r8):
# the file into the slot's SD_REGS_IN with the induction and bound
# registers set, the request (fn_id = seed index + 1, entry 0: a hand-
# translated blob starts at the fault point, the split, the threads),
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
	movq %r9, %r13				# the blob offset to enter at
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
	movq %r13, SL_ENTRY(%rcx)
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

# card_push_post(card rdi, address rsi, bytes rdx): K_PUSH for one piece
# of the program's memory (within one chunk, at most 2 MiB, 64-aligned):
# the engine copies it from the resident page into the window's next
# staging slot; kept as the card's pending request.
	.globl card_push_post
card_push_post:
	pushq %rbx
	movq %rdi, %rbx
	movq %rsi, CD_PEND_ADDR(%rbx)
	movq %rdx, CD_PEND_LEN(%rbx)
	call card_clear_request
	movq CD_STAGE(%rbx), %rax
	movq %rax, %rcx
	incq %rcx
	andq $STAGING_SLOTS - 1, %rcx
	movq %rcx, CD_STAGE(%rbx)
	movq %rax, CD_PEND_UNITS(%rbx)		# the staging slot, for the copy out
	movq CD_SLOTP(%rbx), %rcx
	movq %rax, SL_ENTRY(%rcx)
	movq CD_PEND_ADDR(%rbx), %rax
	movq %rax, SL_FN_ID(%rcx)
	movq CD_PEND_LEN(%rbx), %rax
	movq %rax, SL_FILL_LEN(%rcx)
	movq %rbx, %rdi
	movl $K_PUSH, %esi
	call card_post
	movq $1, CD_POSTED(%rbx)
	popq %rbx
	ret

# card_push_done(card rdi): the pending K_PUSH waited for, the piece
# copied out of SD_WB into the program's memory; eax 0 or the status.
	.globl card_push_done
card_push_done:
	pushq %rbx
	pushq %r12
	movq %rdi, %rbx
	call now_ns
	movq %rax, %r12
	movq %rbx, %rdi
	call card_wait
	movq $0, CD_POSTED(%rbx)
	testl %eax, %eax
	jnz 9f
	movq CD_PEND_ADDR(%rbx), %rdi
	movq CD_PEND_UNITS(%rbx), %rsi		# the staging slot
	shlq $21, %rsi
	addq $OFF_RESIDENT, %rsi
	addq CD_BASE(%rbx), %rsi
	movq CD_PEND_LEN(%rbx), %rdx
	call mem_copy
	call now_ns
	subq %r12, %rax
	addq %rax, stat_push_ns(%rip)
	xorl %eax, %eax
9:	popq %r12
	popq %rbx
	ret
