# region.S: a region of a translated function run on card 0 from the
# fault's instruction to its next exit, the host continuing natively
# from there (stage 3's exits, for the functions seeds.S has no plan
# for: every function found at a fault). The card runs the blob on the
# program's own stack at identity (FXF_IDSTACK); whatever memory the
# region touches that is not resident faults on the card (X_FAULT), is
# made resident as a 64 KiB unit of class W with a shadow copy kept
# here, and the region is posted again from the fault's instruction. At
# the exit (X_RET, X_CALL, X_JUMP, X_SYSCALL) every unit is pulled back
# and diffed against its shadow, the changed lines written into the
# program's memory, the frame set from the card's file (rip where the
# blob said the host resumes, rsp as the blob left it), and the file
# kept as the shadow of what the host cannot hold (zmm16 to zmm31, the
# upper halves, the masks) for the next region. Before a region every
# unit is compared with the program's memory and refilled where the
# host wrote. See region.md.

	.include "common.inc"
	.include "proto.inc"
	.include "defs.inc"
	.include "xlate.inc"

	.set WU_MAX, 1024
	.set STACK_SLACK, 262144		# how far below rsp - 128 a region may write its stack (on the alternate stack): 256 KiB since in-card calls (2026-10-14) put the callees' frames there
	.set WU_ADDR, 0				# the unit's address
	.set WU_SHADOW, 8			# its shadow (64 KiB)
	.set WU_LO, 16				# the lowest address lines are written back from (the stack unit: below the frame's rsp is the handler's own)
	.set WU_PAGES, 24			# u16: the readable 4 KiB pages (filled, refreshed, verified)
	.set WU_WPAGES, 26			# u16: the writable ones (written back)
	.set WU_FLO, 32				# a range to refresh whole at the next region (the floor was lowered: the
	.set WU_FHI, 40				# card may have written below the old floor, which the shadow never saw)
	.set WU_BYTES, 48
	.set FAULTS_MAX, 4096
	.set SEEDS_MAX, 3 + SEEDS_DYN_MAX

	.bss
	.balign 4096
region_file:	.skip 4096
shadow_file:	.skip 4096
stage_buf:	.skip 65536
	.globl fexec_flags, cblob_tab, shadow_valid
shadow_valid:	.skip 8
fexec_flags:	.skip 8				# OR'd into K_FEXEC's flags by card_fexec_post
cblob_tab:	.skip SEEDS_MAX * MAX_CARDS * 8	# the blob's card address per seed and card (card_load_seed)
wu_tab:		.skip WU_MAX * WU_BYTES
wu_n:		.skip 8
wu_arena:	.skip 16
wu_used:	.skip 8
	.globl stat_regions, stat_faults, stat_wb_lines, stat_region_ns
stat_regions:	.skip 8
stat_faults:	.skip 8
stat_wb_lines:	.skip 8
stat_region_ns:	.skip 8
stat_refresh_full:	.skip 8
	.globl refresh_n, refresh_bytes
refresh_n:	.skip 8				# the refresh list of the next K_FEXEC: ranges, bytes (card_fexec_post consumes them)
refresh_bytes:	.skip 8
region_floor:	.skip 8			# this region's stack floor (region_run: rsp - 128, minus STACK_SLACK on the alternate stack)
rf_save_n:	.skip 8				# wu_refresh: the list at the current unit's start (ranges, bytes, the last range's length)
rf_save_bytes:	.skip 8
rf_save_last:	.skip 8

	.section .rodata
s_rg1:	.asciz "phi512: "
s_rg2:	.asciz " +"
s_rg3:	.asciz ": region exit "
s_rg4:	.asciz " to "
s_rg5:	.asciz ", "
s_rg6:	.asciz " fault(s), "
s_rg7:	.asciz " unit(s), "
s_rg8:	.asciz " line(s) back, "
s_rg9:	.asciz " us"
s_rg10:	.asciz ": region posted at blob offset "
s_rg11:	.asciz " of "
s_rg12:	.asciz ", seed "
s_rg13:	.asciz "phi512: region fault: exit rip "
s_rg14:	.asciz " address "
s_rg15:	.asciz " signal|code "
s_rg16:	.asciz " blob at "
s_rg18:	.asciz "phi512:   wb "
s_rg20:	.asciz "phi512:   regs in:  "
s_rg21:	.asciz "phi512:   regs out: "
s_rg19:	.asciz ": "
s_rg17:	.asciz "phi512: registers at the fault (rax rcx rdx rbx rsp rbp rsi rdi r8 to r15): "
s_rgv1:	.asciz "phi512: unit "
s_rgv2:	.asciz " after fill: "
s_rgv3:	.asciz " line(s) differ from the shadow, first at +"
s_rgv4:	.asciz ", floor +"
s_rgv5:	.asciz "phi512:   card:   "
s_rgv7:	.asciz "phi512: last fill: staging slot "
s_rgv8:	.asciz " offset "
s_rgv9:	.asciz " bytes "
s_rgv10:	.asciz ": staged vs shadow "
s_rgv11:	.asciz " word(s) differ; staged word at the floor "
s_rgv12:	.asciz "; before the post, staged vs memory differed in words: "
s_rgv6:	.asciz "phi512:   shadow: "
s_rgfl:	.asciz "phi512: a region left rsp below its stack floor (its stack writes there are lost): rsp "
s_rgfl2:	.asciz ", floor "
s_kinds: .asciz "ret\0call\0atomic\0syscall\0fault\0refused\0loop\0deferfull\0limit\0jump\0host"

	.text
# region_run(uc rdi, seed rsi, entry rdx): eax 0 when the host can go
# on from the frame; else a failure code for the handler's line (1000 +
# the exit kind, 2000 + a step).
	.globl region_run
region_run:
	pushq %rbx
	pushq %rbp
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $48, %rsp				# 0 faults, 8 t0, 16 the exit kind, 24 units before, 32 lines
	movq %rdi, %r12
	movq %rsi, %r13
	movq %rdx, %r14
	leaq cards(%rip), %rbx			# card 0
	movq $0, 0(%rsp)
	call now_ns
	movq %rax, 8(%rsp)
	movq wu_n(%rip), %rax
	movq %rax, 24(%rsp)
	# the file: the frame, then the shadow's part
	leaq region_file(%rip), %rdi
	movq %r12, %rsi
	call file_from_frame
	leaq region_file(%rip), %rdi
	call shadow_merge
	call needs_reset
	incq hw_region(%rip)
	xorl %edi, %edi
	call heap_walk				# (probe) native code since the last region
	# the stack's floor: rsp - 128 (the red zone), and STACK_SLACK further
	# down when the handler runs on its alternate stack (on_alt): the
	# program's stack below rsp is then quiet, and a region that moves rsp
	# down (a call's stack arguments: n_batch and n_ubatch came to
	# llama_init_from_model as 0, 2026-10-14) writes there; clamped to the
	# start of the stack's mapping
	movq UC_GREGS + 8 * G_RSP(%r12), %rax
	subq $128, %rax
	cmpq $0, on_alt(%rip)
	je 1f
	subq $STACK_SLACK, %rax
	pushq %rax
	pushq %rax
	movq UC_GREGS + 8 * G_RSP(%r12), %rdi
	call mapped_range
	movq %rax, %rcx
	popq %rax
	popq %rax
	cmpq %rcx, %rax
	jae 1f
	movq %rcx, %rax
1:	movq %rax, region_floor(%rip)
	movq %rax, %rdi
	xorl %esi, %esi
	call wu_ensure
	testl %eax, %eax
	jnz .Lrg_step
	# the units of rsp - 128, rsp and rsp + 8 KiB resident, then every
	# resident unit of the stack floored (wu_stack_floors: the floor, or
	# the end of a unit wholly below)
	movq UC_GREGS + 8 * G_RSP(%r12), %rdi
	subq $128, %rdi
	xorl %esi, %esi
	call wu_ensure
	testl %eax, %eax
	jnz .Lrg_step
	movq UC_GREGS + 8 * G_RSP(%r12), %rdi
	xorl %esi, %esi
	call wu_ensure
	testl %eax, %eax
	jnz .Lrg_step
	movq UC_GREGS + 8 * G_RSP(%r12), %rdi
	addq $8192, %rdi
	xorl %esi, %esi
	call wu_ensure
	testl %eax, %eax
	jnz .Lrg_step
	movq UC_GREGS + 8 * G_RSP(%r12), %rdi
	movq region_floor(%rip), %rsi
	call wu_stack_floors
	call wu_refresh
	call resident_rounds
	testl %eax, %eax
	jnz .Lrg_step
	call wu_verify
.Lrg_post:
	cmpq $0, verbose(%rip)
	je 0f
	call l_begin
	leaq s_rg1(%rip), %rsi
	call w_str
	movq SD_NAME(%r13), %rsi
	call w_str
	leaq s_rg10(%rip), %rsi
	call w_str
	movq %r14, %rdi
	call w_dec
	leaq s_rg11(%rip), %rsi
	call w_str
	movq SD_ABLOB_LEN(%r13), %rdi
	call w_dec
	leaq s_rg12(%rip), %rsi
	call w_str
	call seed_index
	movq %rax, %rdi
	call w_dec
	movl $2, %edi
	call l_end
	# (probe) the general registers posted, after the rip
	call l_begin
	leaq s_rg20(%rip), %rsi
	call w_str
	leaq region_file(%rip), %rdi
	movq REGS_RIP(%rdi), %rdi
	call w_hexn
	leaq s_rg5(%rip), %rsi
	call w_str
	xorl %r15d, %r15d
81:	leaq region_file(%rip), %rdi
	movq REGS_GPR(%rdi,%r15,8), %rdi
	call w_hexn
	leaq s_rg5(%rip), %rsi
	call w_str
	incq %r15
	cmpq $16, %r15
	jb 81b
	movl $2, %edi
	call l_end
0:	movq $FXF_IDSTACK, fexec_flags(%rip)
	movq %rbx, %rdi
	movq %r13, %rsi
	leaq region_file(%rip), %rdx
	xorl %ecx, %ecx
	xorl %r8d, %r8d
	movq %r14, %r9
	call card_fexec_post
	movq $0, fexec_flags(%rip)
	movq %rbx, %rdi
	call card_wait
	testl %eax, %eax
	jnz .Lrg_status
	movq CD_SLOTP(%rbx), %rcx
	movl SLOT_REPLY + SR_EXIT_KIND(%rcx), %eax
	movq %rax, 16(%rsp)
	movq SLOT_REPLY + SR_EXIT_RIP(%rcx), %rax	# kept before any other request reuses the reply
	movq %rax, 40(%rsp)
	movq SLOT_REPLY + SR_EXIT_AUX(%rcx), %r15
	movl SLOT_REPLY + SR_SIGINFO(%rcx), %eax
	movq %rax, 24(%rsp)			# (the units-before word is free now)
	cmpl $X_FAULT, 16(%rsp)
	jne .Lrg_exit
	# a fault: the unit made resident, the file as left, posted again from the fault's instruction
	cmpq $0, verbose(%rip)
	je 41f
	pushq %rcx
	call l_begin
	leaq s_rg13(%rip), %rsi
	call w_str
	movq (%rsp), %rcx
	movq SLOT_REPLY + SR_EXIT_RIP(%rcx), %rdi
	call w_hexn
	leaq s_rg14(%rip), %rsi
	call w_str
	movq (%rsp), %rcx
	movq SLOT_REPLY + SR_EXIT_AUX(%rcx), %rdi
	call w_hexn
	leaq s_rg15(%rip), %rsi
	call w_str
	movq 24 + 8(%rsp), %rdi			# the signal and code
	call w_hexn
	leaq s_rg16(%rip), %rsi
	call w_str
	call seed_index
	shlq $7, %rax
	leaq cblob_tab(%rip), %rdx
	movq (%rdx,%rax), %rdi
	call w_hexn
	movl $2, %edi
	call l_end
	popq %rcx
41:	incq 0(%rsp)
	cmpq $FAULTS_MAX, 0(%rsp)
	jae .Lrg_step
	cmpq $0x10000, %r15			# a fault with no address: a general-protection fault, not a missing page
	jb .Lrg_gp
	incq stat_faults(%rip)
	pushq %rcx
	call needs_reset
	popq %rcx
	movq %r15, %rdi				# the fault address
	call ro_need				# in an immutable chunk: the chunk as one pool page, no unit
	testl %eax, %eax
	jnz 42f
	movq %r15, %rdi
	xorl %esi, %esi
	call wu_ensure
	testl %eax, %eax
	jnz .Lrg_step
42:
	movq UC_GREGS + 8 * G_RSP(%r12), %rdi
	movq region_floor(%rip), %rsi
	call wu_stack_floors			# a stack unit the fault brought in floored before any write-back
	call resident_rounds
	testl %eax, %eax
	jnz .Lrg_step
	call wu_verify
	leaq region_file(%rip), %rdi
	movq CD_DATAP(%rbx), %rsi
	addq $SD_REGS_OUT, %rsi
	movl $REGS_BYTES, %edx
	call mem_copy
	movq 40(%rsp), %rdi			# the fault's rip on the card
	call blob_at				# the region's blob, or a callee's an in-card call entered
	testq %rax, %rax
	jz .Lrg_step
	movq %rax, %r13				# the region goes on in that blob
	movq %rdx, %r14				# the blob offset of the faulting instruction
	jmp .Lrg_post
.Lrg_exit:
	movl 16(%rsp), %eax			# the exit kind (eax held the reply's signal word: before 2026-10-14 every exit without a signal was taken as a resume, X_REFUSED too)
	cmpl $X_HOST, %eax
	jne 3f
	# an instruction the host runs (blob.S's lazy path); a region posted at
	# it means the host could not run it either: the loop guard
	movq 40(%rsp), %rcx
	cmpq UC_GREGS + 8 * G_RIP(%r12), %rcx
	jne 1f
	addl $1000, %eax
	jmp .Lrg_out
3:	cmpl $X_RET, %eax
	je 1f
	cmpl $X_CALL, %eax
	je 1f
	cmpl $X_JUMP, %eax
	je 1f
	cmpl $X_SYSCALL, %eax
	je 1f
	addl $1000, %eax
	jmp .Lrg_out
1:	call wu_writeback
	movq %rax, 32(%rsp)
	movl $1, %edi
	call heap_walk				# (probe) this region's write-back
	# a region that left rsp below its floor: what it wrote down there
	# did not come back (said every time: a lost write)
	movq CD_DATAP(%rbx), %rax
	movq SD_REGS_OUT + REGS_GPR + 32(%rax), %rax
	subq $128, %rax
	cmpq region_floor(%rip), %rax
	jae 51f
	pushq %rax
	pushq %rax
	call l_begin
	leaq s_rgfl(%rip), %rsi
	call w_str
	movq (%rsp), %rdi
	addq $128, %rdi
	call w_hexn
	leaq s_rgfl2(%rip), %rsi
	call w_str
	movq region_floor(%rip), %rdi
	call w_hexn
	movl $2, %edi
	call l_end
	popq %rax
	popq %rax
51:
	cmpq $0, verbose(%rip)
	je 82f
	# (probe) the general registers as the card left them
	call l_begin
	leaq s_rg21(%rip), %rsi
	call w_str
	movq CD_DATAP(%rbx), %rdi
	movq SD_REGS_OUT + REGS_RIP(%rdi), %rdi
	call w_hexn
	leaq s_rg5(%rip), %rsi
	call w_str
	xorl %r15d, %r15d
83:	movq CD_DATAP(%rbx), %rdi
	movq SD_REGS_OUT + REGS_GPR(%rdi,%r15,8), %rdi
	call w_hexn
	leaq s_rg5(%rip), %rsi
	call w_str
	incq %r15
	cmpq $16, %r15
	jb 83b
	movl $2, %edi
	call l_end
82:
	# the frame from the file, the file kept as the shadow
	movq %r12, %rdi
	movq CD_DATAP(%rbx), %rsi
	addq $SD_REGS_OUT, %rsi
	call frame_from_file_full
	leaq shadow_file(%rip), %rdi
	movq CD_DATAP(%rbx), %rsi
	addq $SD_REGS_OUT, %rsi
	movl $REGS_BYTES, %edx
	call mem_copy
	movq $1, shadow_valid(%rip)
	incq stat_regions(%rip)
	call now_ns
	subq 8(%rsp), %rax
	addq %rax, stat_region_ns(%rip)
	movq %rax, %r15
	movq SD_NAME(%r13), %rdi		# the progress line (heartbeat, at most every 5 s)
	call heartbeat
	cmpq $0, verbose(%rip)
	je 2f
	call l_begin
	leaq s_rg1(%rip), %rsi
	call w_str
	movq SD_NAME(%r13), %rsi
	call w_str
	leaq s_rg2(%rip), %rsi
	call w_str
	movq UC_GREGS + 8 * G_RIP(%r12), %rdi	# (the frame's rip is the resume address now; the entry's offset was r14 at the start: say the resume)
	call w_hexn
	leaq s_rg3(%rip), %rsi
	call w_str
	movq 16(%rsp), %rdi
	call kind_name
	movq %rax, %rsi
	call w_str
	leaq s_rg4(%rip), %rsi
	call w_str
	movq UC_GREGS + 8 * G_RIP(%r12), %rdi
	call w_hexn
	leaq s_rg5(%rip), %rsi
	call w_str
	movq 0(%rsp), %rdi
	call w_dec
	leaq s_rg6(%rip), %rsi
	call w_str
	movq wu_n(%rip), %rdi
	call w_dec
	leaq s_rg7(%rip), %rsi
	call w_str
	movq 32(%rsp), %rdi
	call w_dec
	leaq s_rg8(%rip), %rsi
	call w_str
	movq %r15, %rdi
	call w_us
	movl $2, %edi
	call l_end
2:	xorl %eax, %eax
	jmp .Lrg_out
.Lrg_gp:
	cmpq $0, verbose(%rip)
	je 1f
	# the general registers the card had at the fault, from the file out
	call l_begin
	leaq s_rg17(%rip), %rsi
	call w_str
	xorl %r15d, %r15d
2:	movq CD_DATAP(%rbx), %rdi
	movq SD_REGS_OUT + REGS_GPR(%rdi,%r15,8), %rdi
	call w_hexn
	leaq s_rg5(%rip), %rsi
	call w_str
	incq %r15
	cmpq $16, %r15
	jb 2b
	movl $2, %edi
	call l_end
1:	movl $1000 + X_FAULT, %eax
	jmp .Lrg_out
.Lrg_status:
	addl $2000, %eax
	jmp .Lrg_out
.Lrg_step:
	movl $2001, %eax
.Lrg_out:
	addq $48, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbp
	popq %rbx
	ret

# needs_reset: the need queues empty (need_n, need_i, the overflow flag).
needs_reset:
	pushq %rdi
	leaq need_n(%rip), %rdi
	movl $MAX_CARDS * 2, %ecx
	xorl %eax, %eax
	rep stosq
	movq $0, need_overflow(%rip)
	popq %rdi
	ret

# kind_name(kind rdi): the exit kind's name.
kind_name:
	leaq s_kinds(%rip), %rax
	cmpq $10, %rdi
	ja 9f
1:	testq %rdi, %rdi
	jz 9f
2:	cmpb $0, (%rax)
	leaq 1(%rax), %rax
	jne 2b
	decq %rdi
	jmp 1b
9:	ret

# seed_index: rax = the seed's number (r13 the seed).
	.globl seed_index
seed_index:
	movq %r13, %rax
	leaq seeds(%rip), %rcx
	subq %rcx, %rax
	xorl %edx, %edx
	movl $SD_BYTES, %ecx
	divq %rcx
	ret

# wu_find(addr rdi): the unit's entry in rax, 0 when none.
wu_find:
	andq $-UNIT, %rdi
	leaq wu_tab(%rip), %rax
	movq wu_n(%rip), %rcx
1:	testq %rcx, %rcx
	jz 9f
	cmpq WU_ADDR(%rax), %rdi
	je 8f
	addq $WU_BYTES, %rax
	decq %rcx
	jmp 1b
9:	xorl %eax, %eax
8:	ret

# wu_ensure(addr rdi, lo rsi): the 64 KiB unit holding addr resident on
# card 0 with a shadow here: a new entry (its mapped pages found, the
# shadow filled from the program's memory, the need queued; a page the
# program has not mapped stays out of the write-back); lo, when not 0,
# becomes the unit's write-back floor. eax 0, or 1 (the table or the
# arena is full).
wu_ensure:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	cmpq $0x10000, %rdi
	jb 8f					# no unit at the bottom of the address space
	movq %rdi, %r12
	andq $-UNIT, %r12
	movq %rsi, %r13
	movq %r12, %rdi
	call wu_find
	testq %rax, %rax
	jnz 7f
	movq wu_n(%rip), %rax
	cmpq $WU_MAX, %rax
	jae 8f
	cmpq $0, wu_arena(%rip)
	jne 1f
	leaq wu_arena(%rip), %rdi
	movq $WU_MAX * UNIT, %rsi
	call gbuf_need
	testq %rax, %rax
	jz 8f
	movq $0, wu_used(%rip)
1:	movq wu_n(%rip), %rax
	imulq $WU_BYTES, %rax, %rbx
	leaq wu_tab(%rip), %rax
	addq %rax, %rbx				# the entry
	incq wu_n(%rip)
	movq %r12, WU_ADDR(%rbx)
	movq wu_used(%rip), %rax
	addq wu_arena(%rip), %rax
	movq %rax, WU_SHADOW(%rbx)
	addq $UNIT, wu_used(%rip)
	movq $0, WU_LO(%rbx)
	# the mapped pages
	xorl %r14d, %r14d
	xorl %ecx, %ecx
	movw %cx, WU_PAGES(%rbx)
2:	cmpl $16, %r14d
	jae 3f
	movq %r14, %rdi
	shlq $12, %rdi
	addq %r12, %rdi
	call mapped_range
	testq %rax, %rax
	jz 21f
	btsw %r14w, WU_PAGES(%rbx)
21:	incl %r14d
	jmp 2b
3:	movq WU_SHADOW(%rbx), %rdi
	movq %r12, %rsi
	movl $UNIT, %edx
	call copy_mapped
	movzwl copy_mapped_pages(%rip), %eax
	movw %ax, WU_PAGES(%rbx)		# the readable pages only (a PROT_NONE page is in the maps but not writable)
	movzwl copy_mapped_wpages(%rip), %eax
	movw %ax, WU_WPAGES(%rbx)
	# the need on card 0: the chunk and the unit's bit, class 1 (written back)
	xorl %edi, %edi
	movq %r12, %rsi
	andq $-CHUNK, %rsi
	movq %r12, %rdx
	subq %rsi, %rdx
	shrq $16, %rdx
	movl %edx, %ecx
	movl $1, %edx
	shll %cl, %edx
	movl $1, %ecx
	call need_add
	movq %rbx, %rax
7:	testq %r13, %r13
	jz 71f
	movq %rax, %rdi
	movq %r13, %rsi
	call wu_set_floor
71:	xorl %eax, %eax
	jmp 9f
8:	movl $1, %eax
9:	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# wu_set_floor(entry rdi, lo rsi): the unit's write-back floor set to lo
# (an absolute address: a floor below the unit's base leaves it whole, one
# at its end leaves nothing); when it drops below the old floor, [lo, old)
# is refreshed whole at the next wu_refresh (the card may have written
# there, which the shadow never saw). A floor of 0 (a new unit, filled
# whole) is replaced without a forced range.
wu_set_floor:
	movq WU_LO(%rdi), %rcx
	testq %rcx, %rcx
	jz 2f
	cmpq %rcx, %rsi
	jae 2f
	cmpq $0, WU_FHI(%rdi)
	je 1f
	cmpq WU_FLO(%rdi), %rsi
	jae 3f
1:	movq %rsi, WU_FLO(%rdi)
3:	cmpq WU_FHI(%rdi), %rcx
	jbe 2f
	movq %rcx, WU_FHI(%rdi)
2:	movq %rsi, WU_LO(%rdi)
	ret

# wu_stack_floors(rsp rdi, floor rsi): every resident unit of the mapping
# holding rsp (the thread's stack) floored at min(floor, the unit's end):
# a unit the region may use gets the floor (rsp - 128, lower on the
# alternate stack: region_run), a unit wholly below gets its end (the SIGILL handler runs
# there, on the program's stack: a write-back into it would overwrite
# the handler's frames). Every unit, whichever path made it resident: a
# floor kept from an earlier region was the bug of 2026-10-14 (the unit
# of rsp kept a higher floor when rsp - 128 fell into the unit below,
# and the lines the region wrote between came back as nothing).
wu_stack_floors:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rsi, %r12				# the floor (rdi, rsp, finds the mapping)
	call mapped_range
	testq %rax, %rax
	jz 9f
	movq %rax, %r13				# the mapping's start
	movq %rdx, %r14				# its end
	leaq wu_tab(%rip), %rbx
	movq wu_n(%rip), %r15
1:	testq %r15, %r15
	jz 9f
	movq WU_ADDR(%rbx), %rax
	cmpq %r14, %rax
	jae 8f
	leaq UNIT(%rax), %rsi			# the unit's end
	cmpq %r13, %rsi
	jbe 8f
	movq %r12, %rcx
	cmpq %rsi, %rcx
	jae 2f
	movq %rcx, %rsi
2:	movq %rbx, %rdi
	call wu_set_floor
8:	addq $WU_BYTES, %rbx
	decq %r15
	jmp 1b
9:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# wu_refresh: every unit compared with the program's memory, line by
# line over its mapped pages above its floor; a line the host wrote
# since goes into the refresh list of the next K_FEXEC (refresh_add: a
# range of lines and their bytes in card 0's slot data; the card's own
# core copies them in before the run, coherently with its caches, which
# a DMA fill is not against a line it holds dirty) and into the shadow.
# When the list is full the unit falls back to a DMA refill (noted).
wu_refresh:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	# phase 0 (here): what the workers share made ready first: the
	# /proc/self/mem descriptor (copy_mapped of nothing opens it), the
	# mappings' table, the pool (16 workers a card, made once)
	leaq stage_buf(%rip), %rdi
	xorl %esi, %esi
	xorl %edx, %edx
	call copy_mapped
	call maps_ensure
	movl ncards(%rip), %edi
	call pool_start
	# phase 1 (card 0's workers and this thread): every unit read and
	# compared, its changed lines into its shadow and its bitmap
	xorl %edi, %edi
	leaq wu_refresh_unit(%rip), %rsi
	movq wu_n(%rip), %rdx
	call pool_run
	# phase 2 (here): the changed lines into the refresh list, unit by unit
	leaq wu_tab(%rip), %rbx
	leaq wu_chg(%rip), %r13
	movq wu_n(%rip), %r12
1:	testq %r12, %r12
	jz 9f
	# the list's state at the unit's start: an overflow inside the unit
	# takes back what the unit added (see .Lrf_full)
	movq refresh_n(%rip), %rax
	movq %rax, rf_save_n(%rip)
	movq refresh_bytes(%rip), %rax
	movq %rax, rf_save_bytes(%rip)
	movq $0, rf_save_last(%rip)
	movq refresh_n(%rip), %rax
	testq %rax, %rax
	jz 10f
	shlq $4, %rax
	movq cards + CD_DATAP(%rip), %rcx
	movq SD_REFRESH_TAB - 16 + 8(%rcx,%rax), %rax
	movq %rax, rf_save_last(%rip)
10:	xorl %r14d, %r14d			# the line (0 to 1023)
2:	cmpl $1024, %r14d
	jae 8f
	btq %r14, (%r13)
	jnc 6f
	movq %r14, %r15
	shlq $6, %r15				# its offset
	movq WU_ADDR(%rbx), %rdi
	addq %r15, %rdi
	movq WU_SHADOW(%rbx), %rsi
	addq %r15, %rsi				# the shadow holds the new bytes (phase 1)
	call refresh_add
	testl %eax, %eax
	jnz .Lrf_full
6:	incl %r14d
	jmp 2b
8:	movq $0, WU_FLO(%rbx)
	movq $0, WU_FHI(%rbx)
	addq $WU_BYTES, %rbx
	addq $128, %r13
	decq %r12
	jmp 1b
9:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
.Lrf_full:
	# the list is full: this unit by a DMA refill, with the card's filled
	# bit cleared (its shadow is new already, and card_resident_post sets
	# it from the staged bytes again)
	incq stat_refresh_full(%rip)
	# the lines this unit already put in the list taken back: the refill
	# below is a second read of the program's memory, and the card would
	# apply the list's older lines over it while the shadow takes the
	# newer ones, so the write-back would put the older bytes back (the
	# log worker's region reverted the main thread's malloc metadata:
	# "corrupted double-linked list", 2026-10-14)
	movq rf_save_n(%rip), %rax
	movq %rax, refresh_n(%rip)
	movq rf_save_bytes(%rip), %rax
	movq %rax, refresh_bytes(%rip)
	movq refresh_n(%rip), %rax
	testq %rax, %rax
	jz 11f
	shlq $4, %rax
	movq cards + CD_DATAP(%rip), %rcx
	movq rf_save_last(%rip), %rdx
	movq %rdx, SD_REFRESH_TAB - 16 + 8(%rcx,%rax)
11:	leaq cards + CD_TAB(%rip), %rdi
	movq WU_ADDR(%rbx), %rsi
	andq $-CHUNK, %rsi
	call tab_find
	testq %rax, %rax
	jz 1f
	movq WU_ADDR(%rbx), %rcx
	andq $CHUNK - 1, %rcx
	shrq $16, %rcx
	btrl %ecx, RE_FILLED(%rax)
1:	xorl %edi, %edi
	movq WU_ADDR(%rbx), %rsi
	andq $-CHUNK, %rsi
	movq WU_ADDR(%rbx), %rdx
	subq %rsi, %rdx
	shrq $16, %rdx
	movl %edx, %ecx
	movl $1, %edx
	shll %cl, %edx
	movl $1, %ecx
	call need_add
	jmp 8b

# wu_refresh_unit(unit rdi, a 64 KiB buffer rsi): one unit of the refresh
# (pool.S's workers run these at once, a unit each, so nothing here is
# shared but read): the program's 64 KiB read into the buffer
# (copy_mapped, its page bitmaps returned in edx), then, over the
# readable pages above the floor, a line that differs from the shadow
# (or lies in the forced range) copied into the shadow and marked in the
# unit's bitmap (wu_chg) for the list.
wu_refresh_unit:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %rax
	imulq $WU_BYTES, %rax, %rbx
	leaq wu_tab(%rip), %rcx
	addq %rcx, %rbx				# the entry
	movq %rdi, %r13
	shlq $7, %r13
	leaq wu_chg(%rip), %rcx
	addq %rcx, %r13				# its bitmap (128 bytes)
	movq %rsi, %r12				# the buffer
	xorl %eax, %eax
	movl $16, %ecx
1:	movq %rax, -8(%r13,%rcx,8)
	loop 1b
	movq %r12, %rdi
	movq WU_ADDR(%rbx), %rsi
	movl $UNIT, %edx
	call copy_mapped
	movw %dx, WU_PAGES(%rbx)		# the pages as mapped now
	shrl $16, %edx
	movw %dx, WU_WPAGES(%rbx)
	xorl %r14d, %r14d			# the line (0 to 1023)
2:	cmpl $1024, %r14d
	jae 9f
	movl %r14d, %eax
	shrl $6, %eax				# its page
	btw %ax, WU_PAGES(%rbx)
	jnc 7f
	movq %r14, %r15
	shlq $6, %r15				# its offset
	movq WU_ADDR(%rbx), %rax
	addq %r15, %rax
	cmpq WU_LO(%rbx), %rax
	jb 7f					# below the floor: the handler's own stack
	leaq (%r12,%r15), %rsi
	movq WU_SHADOW(%rbx), %rdi
	addq %r15, %rdi
	cmpq WU_FLO(%rbx), %rax
	jb 3f
	cmpq WU_FHI(%rbx), %rax
	jb 5f					# in the forced range: whole, compared or not
3:	xorl %ecx, %ecx
4:	movq (%rsi,%rcx), %rax
	cmpq (%rdi,%rcx), %rax
	jne 5f
	addq $8, %rcx
	cmpq $64, %rcx
	jb 4b
	jmp 7f
5:	xorl %ecx, %ecx
6:	movq (%rsi,%rcx), %rax
	movq %rax, (%rdi,%rcx)
	addq $8, %rcx
	cmpq $64, %rcx
	jb 6b
	btsq %r14, (%r13)
7:	incl %r14d
	jmp 2b
9:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
	.bss
	.balign 64
wu_chg:	.skip WU_MAX * 128			# per unit, a bit per line the refresh found changed
	.text

# refresh_add(addr rdi, bytes rsi): the line into the refresh list of
# card 0's slot data: coalesced with the last range when contiguous;
# the 64 bytes appended. eax 0, or 1 when the table (512 ranges) or
# the bytes (SD_REFRESH to SD_WB_TAB) are full.
refresh_add:
	movq cards + CD_DATAP(%rip), %rdx
	movq refresh_n(%rip), %rax
	testq %rax, %rax
	jz 1f
	movq %rax, %rcx
	shlq $4, %rcx
	leaq SD_REFRESH_TAB - 16(%rdx,%rcx), %rcx	# the last range
	movq 0(%rcx), %r8
	addq 8(%rcx), %r8
	cmpq %r8, %rdi
	jne 1f
	addq $64, 8(%rcx)
	jmp 2f
1:	cmpq $512, %rax
	jae 9f
	movq %rax, %rcx
	shlq $4, %rcx
	leaq SD_REFRESH_TAB(%rdx,%rcx), %rcx
	movq %rdi, 0(%rcx)
	movq $64, 8(%rcx)
	incq refresh_n(%rip)
2:	movq refresh_bytes(%rip), %rcx
	cmpq $SD_WB_TAB - SD_REFRESH, %rcx
	jae 9f
	leaq SD_REFRESH(%rdx,%rcx), %rdi
	xorl %ecx, %ecx
3:	movq (%rsi,%rcx), %rax
	movq %rax, (%rdi,%rcx)
	addq $8, %rcx
	cmpq $64, %rcx
	jb 3b
	addq $64, refresh_bytes(%rip)
	xorl %eax, %eax
	ret
9:	movl $1, %eax
	ret

# wu_diff_pages(entry rdi, a rsi, b rdx, floor ecx): 1 when a and b
# differ in any mapped page of the unit (above the floor when ecx is 1:
# WU_LO), else 0.
wu_diff_pages:
	pushq %rbx
	movq %rdi, %rbx
	xorl %r8d, %r8d				# page
1:	cmpl $16, %r8d
	jae 8f
	btw %r8w, WU_PAGES(%rbx)
	jnc 7f
	movq %r8, %r9
	shlq $12, %r9				# the page's offset
	xorl %r10d, %r10d
2:	cmpl $4096, %r10d
	jae 7f
	leaq (%r9,%r10), %r11
	testl %ecx, %ecx
	jz 3f
	movq WU_ADDR(%rbx), %rax
	addq %r11, %rax
	cmpq WU_LO(%rbx), %rax
	jb 4f
3:	movq (%rsi,%r11), %rax
	cmpq (%rdx,%r11), %rax
	jne 9f
4:	addl $8, %r10d
	jmp 2b
7:	incl %r8d
	jmp 1b
8:	xorl %eax, %eax
	popq %rbx
	ret
9:	movl $1, %eax
	popq %rbx
	ret

# wu_writeback: every unit pulled back from card 0 (K_PUSH into a
# staging slot) and diffed against its shadow line by line over the
# mapped pages above the floor; a changed line goes into the program's
# memory and the shadow. rax the lines written.
wu_writeback:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	leaq wu_tab(%rip), %rbx
	movq wu_n(%rip), %r12
	xorl %r15d, %r15d			# lines
1:	testq %r12, %r12
	jz 9f
	leaq cards(%rip), %rdi
	movq WU_ADDR(%rbx), %rsi
	movl $UNIT, %edx
	call card_push_post
	leaq cards(%rip), %rdi
	call card_wait
	movq $0, cards + CD_POSTED(%rip)
	testl %eax, %eax
	jnz 8f
	movq cards + CD_PEND_UNITS(%rip), %r13	# the staging slot
	shlq $21, %r13
	addq $OFF_RESIDENT, %r13
	addq cards + CD_BASE(%rip), %r13	# the staged bytes (the window)
	xorl %r14d, %r14d			# page
2:	cmpl $16, %r14d
	jae 7f
	btw %r14w, WU_WPAGES(%rbx)		# a line in a page the program cannot write is never written back
	jnc 6f
	movq %r14, %r9
	shlq $12, %r9
	xorl %r10d, %r10d
3:	cmpl $4096, %r10d
	jae 6f
	leaq (%r9,%r10), %r11			# the line's offset
	movq WU_ADDR(%rbx), %rax
	addq %r11, %rax
	cmpq WU_LO(%rbx), %rax
	jb 5f
	# the line: staged vs shadow, 8 words
	movq WU_SHADOW(%rbx), %rdx
	xorl %ecx, %ecx
4:	movq (%r13,%r11), %rax
	cmpq (%rdx,%r11), %rax
	jne 41f
	addq $8, %r11
	incl %ecx
	cmpl $8, %ecx
	jb 4b
	jmp 5f
41:	# changed: the bytes the card changed, alone, to the program and the
	# shadow, through /proc/self/mem (wb_line_apply): a page another thread
	# unmapped meanwhile fails there instead of faulting the host
	# (2026-10-14: an HTTP thread's region faulted reading a line above its
	# stack); a whole line copied had also undone other threads' writes
	leaq (%r9,%r10), %r11
	movq WU_ADDR(%rbx), %rdi
	addq %r11, %rdi
	leaq (%r13,%r11), %rsi
	addq %r11, %rdx
	pushq %r9
	pushq %r10
	call wb_line_apply
	popq %r10
	popq %r9
	testl %eax, %eax
	jz 5f
	incq %r15
	cmpq $0, verbose(%rip)
	je 5f
	# (probe) the line written: its address and eight words
	pushq %r9
	pushq %r10
	call l_begin
	leaq s_rg18(%rip), %rsi
	call w_str
	movq WU_ADDR(%rbx), %rdi
	addq 8(%rsp), %rdi
	addq 0(%rsp), %rdi
	call w_hexn
	leaq s_rg19(%rip), %rsi
	call w_str
	xorl %ecx, %ecx
43:	pushq %rcx
	movq 16(%rsp), %rdi
	addq 8(%rsp), %rdi
	addq (%rsp), %rdi
	movq (%r13,%rdi), %rdi
	call w_hexn
	leaq s_rg5(%rip), %rsi
	call w_str
	popq %rcx
	addq $8, %rcx
	cmpq $64, %rcx
	jb 43b
	movl $2, %edi
	call l_end
	popq %r10
	popq %r9
5:	addl $64, %r10d
	jmp 3b
6:	incl %r14d
	jmp 2b
7:	addq $WU_BYTES, %rbx
	decq %r12
	jmp 1b
8:	# a push that failed: the lines so far
9:	addq %r15, stat_wb_lines(%rip)
	movq %r15, %rax
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# shadow_merge(file rdi): what the host cannot hold, from the last
# region's file out: zmm16 to zmm31 and the masks whole; of zmm0 to
# zmm15 the upper 256 bits when the lower 256 are what the last region
# left (the host wrote the register otherwise, and a VEX write zeroes
# the upper bits).
shadow_merge:
	cmpq $0, shadow_valid(%rip)
	je 9f
	leaq shadow_file(%rip), %rsi
	xorl %ecx, %ecx
1:	cmpl $16, %ecx
	jae 3f
	movq %rcx, %rax
	shlq $6, %rax				# the zmm's offset
	xorl %edx, %edx
2:	movq REGS_ZMM(%rdi,%rax), %r8
	cmpq REGS_ZMM(%rsi,%rax), %r8
	jne 21f
	addq $8, %rax
	incl %edx
	cmpl $4, %edx
	jb 2b
	# equal lower 256: the upper from the shadow (rax is at +32)
	xorl %edx, %edx
22:	movq REGS_ZMM(%rsi,%rax), %r8
	movq %r8, REGS_ZMM(%rdi,%rax)
	addq $8, %rax
	incl %edx
	cmpl $4, %edx
	jb 22b
21:	incl %ecx
	jmp 1b
3:	# zmm16 to zmm31 and the masks
	movl $16 * 64 / 8, %ecx
	leaq REGS_ZMM + 16 * 64(%rsi), %rdx
	leaq REGS_ZMM + 16 * 64(%rdi), %rax
4:	movq (%rdx), %r8
	movq %r8, (%rax)
	addq $8, %rdx
	addq $8, %rax
	decl %ecx
	jnz 4b
	movl $8, %ecx
	leaq REGS_K(%rsi), %rdx
	leaq REGS_K(%rdi), %rax
5:	movq (%rdx), %r8
	movq %r8, (%rax)
	addq $8, %rdx
	addq $8, %rax
	decl %ecx
	jnz 5b
9:	ret

# frame_from_file_full(uc rdi, file rsi): the frame from the card's
# file: every general register (rsp as the blob left it), rip where
# the blob said the host resumes, the flags (from the raw lahf/seto
# word: SF ZF AF PF CF in bits 15 to 8, OF in bit 0), xmm0 to xmm15
# and their ymm halves from the file's zmm.
frame_from_file_full:
	pushq %rbx
	pushq %r12
	movq %rdi, %rbx
	movq %rsi, %r12
	movq REGS_GPR + 0(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_RAX(%rbx)
	movq REGS_GPR + 8(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_RCX(%rbx)
	movq REGS_GPR + 16(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_RDX(%rbx)
	movq REGS_GPR + 24(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_RBX(%rbx)
	movq REGS_GPR + 32(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_RSP(%rbx)
	movq REGS_GPR + 40(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_RBP(%rbx)
	movq REGS_GPR + 48(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_RSI(%rbx)
	movq REGS_GPR + 56(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_RDI(%rbx)
	movq REGS_GPR + 64(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_R8(%rbx)
	movq REGS_GPR + 72(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_R9(%rbx)
	movq REGS_GPR + 80(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_R10(%rbx)
	movq REGS_GPR + 88(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_R11(%rbx)
	movq REGS_GPR + 96(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_R12(%rbx)
	movq REGS_GPR + 104(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_R13(%rbx)
	movq REGS_GPR + 112(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_R14(%rbx)
	movq REGS_GPR + 120(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_R15(%rbx)
	movq REGS_RIP(%r12), %rax
	movq %rax, UC_GREGS + 8 * G_RIP(%rbx)
	# the flags
	movq REGS_RFLAGS(%r12), %rax
	movq %rax, %rcx
	shrq $8, %rcx
	andl $0xd5, %ecx
	andl $1, %eax
	shll $11, %eax
	orl %ecx, %eax
	orl $0x202, %eax
	movq %rax, UC_GREGS + 8 * G_EFL(%rbx)
	# the vector registers
	movq UC_FPREGS(%rbx), %rdi
	testq %rdi, %rdi
	jz 9f
	xorl %ecx, %ecx
1:	cmpl $16, %ecx
	jae 2f
	movq %rcx, %rax
	shlq $6, %rax
	movq REGS_ZMM(%r12,%rax), %rdx
	movq %rcx, %r8
	shlq $4, %r8
	movq %rdx, FX_XMM0(%rdi,%r8)
	movq REGS_ZMM + 8(%r12,%rax), %rdx
	movq %rdx, FX_XMM0 + 8(%rdi,%r8)
	movq ymm_off(%rip), %r9
	testq %r9, %r9
	jz 11f
	addq %rdi, %r9
	movq REGS_ZMM + 16(%r12,%rax), %rdx
	movq %rdx, (%r9,%r8)
	movq REGS_ZMM + 24(%r12,%rax), %rdx
	movq %rdx, 8(%r9,%r8)
11:	incl %ecx
	jmp 1b
2:	orq $(1 << 1) | (1 << XSTATE_YMM_BIT), XSAVE_HEADER(%rdi)
9:	popq %r12
	popq %rbx
	ret
	.section .note.GNU-stack,"",@progbits

	.text
# wu_verify (a probe, verbose only): every unit pulled back from card 0
# and diffed against its shadow over its mapped pages, no floor; a line
# per unit with the differing lines and the first one's offset.
wu_verify:
	cmpq $0, verbose(%rip)
	je 9f
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	# the last fill's staging bytes against the unit they were for
	leaq wu_tab(%rip), %rbx
	movq wu_n(%rip), %r12
70:	testq %r12, %r12
	jz 75f
	movq WU_ADDR(%rbx), %rax
	andq $CHUNK - 1, %rax
	cmpq fill_last_off(%rip), %rax
	jne 74f
	movq fill_last_slot(%rip), %r13
	shlq $21, %r13
	addq $OFF_RESIDENT, %r13
	addq cards + CD_BASE(%rip), %r13
	addq %rax, %r13				# the staged bytes of this unit
	movq WU_SHADOW(%rbx), %rdx
	movq WU_LO(%rbx), %rcx
	subq WU_ADDR(%rbx), %rcx		# from the floor (0 when none)
	jns 711f
	xorl %ecx, %ecx
711:	xorl %r15d, %r15d
	movq %rcx, %r14				# the first offset compared
71:	movq (%r13,%rcx), %rax
	cmpq (%rdx,%rcx), %rax
	je 72f
	incq %r15
72:	addq $8, %rcx
	cmpq $UNIT, %rcx
	jb 71b
	call l_begin
	leaq s_rgv7(%rip), %rsi
	call w_str
	movq fill_last_slot(%rip), %rdi
	call w_dec
	leaq s_rgv8(%rip), %rsi
	call w_str
	movq fill_last_off(%rip), %rdi
	call w_hexn
	leaq s_rgv9(%rip), %rsi
	call w_str
	movq fill_last_len(%rip), %rdi
	call w_hexn
	leaq s_rgv10(%rip), %rsi
	call w_str
	movq %r15, %rdi
	call w_dec
	leaq s_rgv11(%rip), %rsi
	call w_str
	movq (%r13,%r14), %rdi
	call w_hexn
	leaq s_rgv12(%rip), %rsi
	call w_str
	movq fill_last_prediff(%rip), %rdi
	call w_dec
	movl $2, %edi
	call l_end
74:	addq $WU_BYTES, %rbx
	decq %r12
	jmp 70b
75:	leaq wu_tab(%rip), %rbx
	movq wu_n(%rip), %r12
1:	testq %r12, %r12
	jz 8f
	leaq cards(%rip), %rdi
	movq WU_ADDR(%rbx), %rsi
	movl $UNIT, %edx
	call card_push_post
	leaq cards(%rip), %rdi
	call card_wait
	movq $0, cards + CD_POSTED(%rip)
	testl %eax, %eax
	jnz 8f
	movq cards + CD_PEND_UNITS(%rip), %r13
	shlq $21, %r13
	addq $OFF_RESIDENT, %r13
	addq cards + CD_BASE(%rip), %r13	# the staged bytes
	xorl %r15d, %r15d			# lines
	movq $-1, %r14				# the first offset
	xorl %r8d, %r8d				# page
2:	cmpl $16, %r8d
	jae 6f
	btw %r8w, WU_PAGES(%rbx)
	jnc 5f
	movq %r8, %r9
	shlq $12, %r9
	xorl %r10d, %r10d
3:	cmpl $4096, %r10d
	jae 5f
	leaq (%r9,%r10), %r11
	movq WU_ADDR(%rbx), %rax
	addq %r11, %rax
	cmpq WU_LO(%rbx), %rax
	jb 42f					# below the floor: the handler's own stack, noise
	movq WU_SHADOW(%rbx), %rdx
	xorl %ecx, %ecx
4:	movq (%r13,%r11), %rax
	cmpq (%rdx,%r11), %rax
	jne 41f
	addq $8, %r11
	incl %ecx
	cmpl $8, %ecx
	jb 4b
	jmp 42f
41:	incq %r15
	cmpq $-1, %r14
	jne 42f
	leaq (%r9,%r10), %r14
42:	addl $64, %r10d
	jmp 3b
5:	incl %r8d
	jmp 2b
6:	call l_begin
	leaq s_rgv1(%rip), %rsi
	call w_str
	movq WU_ADDR(%rbx), %rdi
	call w_hexn
	leaq s_rgv2(%rip), %rsi
	call w_str
	movq %r15, %rdi
	call w_dec
	leaq s_rgv3(%rip), %rsi
	call w_str
	movq %r14, %rdi
	call w_hexn
	leaq s_rgv4(%rip), %rsi
	call w_str
	movq WU_LO(%rbx), %rdi
	subq WU_ADDR(%rbx), %rdi
	call w_hexn
	movl $2, %edi
	call l_end
	cmpq $-1, %r14
	je 7f
	# the first differing line: staged, then shadow, 8 words each
	call l_begin
	leaq s_rgv5(%rip), %rsi
	call w_str
	xorl %ecx, %ecx
61:	pushq %rcx
	leaq (%r13,%r14), %rdi
	addq (%rsp), %rdi
	movq (%rdi), %rdi
	call w_hexn
	leaq s_rg5(%rip), %rsi
	call w_str
	popq %rcx
	addq $8, %rcx
	cmpq $64, %rcx
	jb 61b
	movl $2, %edi
	call l_end
	call l_begin
	leaq s_rgv6(%rip), %rsi
	call w_str
	xorl %ecx, %ecx
62:	pushq %rcx
	movq WU_SHADOW(%rbx), %rdi
	addq %r14, %rdi
	addq (%rsp), %rdi
	movq (%rdi), %rdi
	call w_hexn
	leaq s_rg5(%rip), %rsi
	call w_str
	popq %rcx
	addq $8, %rcx
	cmpq $64, %rcx
	jb 62b
	movl $2, %edi
	call l_end
7:	addq $WU_BYTES, %rbx
	decq %r12
	jmp 1b
8:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
9:	ret

	.text
# heap_walk(when edi: 0 at a region's start, 1 after its write-back): a
# probe (PHI512_HEAPCHECK=1). The main arena's heap is walked chunk by
# chunk from the [heap] mapping's start by the size fields (glibc's
# malloc chunk: prev_size, then size with three flag bits; the next chunk
# at chunk + size; the top chunk ends at the mapping's end), and the
# first walk that breaks (a size below 32 or not a multiple of 16, a
# chunk past the end) is reported once: the region's number (region_run
# calls so far, the n-th "region exit" line of the verbose log), before
# its start (native code since the last region broke it) or after its
# write-back (the region did), the bad chunk, its size field and the
# chunk before it. glibc itself finds such damage only when it next
# frees or merges that chunk, thousands of regions later.
heap_walk:
	cmpq $0, heapcheck(%rip)
	je 99f
	cmpq $0, hw_reported(%rip)
	jne 99f
	# the main thread's regions only: from another thread's handler the main
	# thread may be inside malloc, and a list caught mid-update reads as
	# broken (a report after common_log's worker's region, 2026-10-14)
	movl $186, %eax				# gettid
	syscall
	pushq %rax
	movl $39, %eax				# getpid
	syscall
	popq %rcx
	cmpl %eax, %ecx
	jne 99f
	pushq %rbx
	pushq %rbp
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	subq $24, %rsp				# 0 the heap's start, 8 the reason
	movl %edi, %r15d
	call heap_bounds
	testq %rax, %rax
	jz 9f
	movq %rax, 0(%rsp)
	leaq s_hw_rsize(%rip), %rcx
	movq %rcx, 8(%rsp)
	movq %rax, %rbx				# the chunk
	movq %rdx, %r12				# the heap's end
	xorl %r13d, %r13d			# chunks walked
	xorl %ebp, %ebp				# the chunk before
1:	leaq 16(%rbx), %rax
	cmpq %r12, %rax
	ja 8f
	movq 8(%rbx), %r14
	andq $-8, %r14
	cmpq $32, %r14
	jb 8f
	testq $15, %r14
	jnz 8f
	leaq (%rbx,%r14), %rax
	cmpq %r12, %rax
	ja 8f
	# a chunk the next one marks free (PREV_INUSE clear) is in a bin: its
	# size in the next one's prev_size, its fd and bk linked back to it
	leaq 16(%rax), %rcx
	cmpq %r12, %rcx
	ja 2f					# the top chunk: no next
	testq $1, 8(%rax)
	jnz 2f
	leaq s_hw_rprev(%rip), %rcx
	movq %rcx, 8(%rsp)
	cmpq %r14, (%rax)
	jne 8f
	leaq s_hw_rfd(%rip), %rcx
	movq %rcx, 8(%rsp)
	movq 16(%rbx), %rcx			# fd
	cmpq 0(%rsp), %rcx
	jb 21f
	leaq 32(%rcx), %rdx
	cmpq %r12, %rdx
	ja 21f
	cmpq %rbx, 24(%rcx)			# fd->bk
	jne 8f
21:	leaq s_hw_rbk(%rip), %rcx
	movq %rcx, 8(%rsp)
	movq 24(%rbx), %rcx			# bk
	cmpq 0(%rsp), %rcx
	jb 22f
	leaq 32(%rcx), %rdx
	cmpq %r12, %rdx
	ja 22f
	cmpq %rbx, 16(%rcx)			# bk->fd
	jne 8f
22:	leaq s_hw_rsize(%rip), %rcx
	movq %rcx, 8(%rsp)
2:	incq %r13
	movq %rbx, %rbp
	movq %rax, %rbx
	cmpq %r12, %rbx
	jb 1b
	jmp 9f
8:	movq $1, hw_reported(%rip)
	call l_begin
	leaq s_hw1(%rip), %rsi
	call w_str
	movq 8(%rsp), %rsi
	call w_str
	leaq s_hw_before(%rip), %rsi
	testl %r15d, %r15d
	jz 81f
	leaq s_hw_after(%rip), %rsi
81:	call w_str
	movq hw_region(%rip), %rdi
	call w_dec
	leaq s_hw3(%rip), %rsi
	call w_str
	movq %rbx, %rdi
	call w_hexn
	leaq s_hw4(%rip), %rsi
	call w_str
	xorl %edi, %edi
	leaq 16(%rbx), %rax
	cmpq %r12, %rax
	ja 82f
	movq 8(%rbx), %rdi
82:	call w_hexn
	leaq s_hw5(%rip), %rsi
	call w_str
	movq %rbp, %rdi
	call w_hexn
	leaq s_hw6(%rip), %rsi
	call w_str
	movq %r13, %rdi
	call w_dec
	leaq s_hw7(%rip), %rsi
	call w_str
	movq %r12, %rdi
	call w_hexn
	movl $2, %edi
	call l_end
	# the chunk's first 64 bytes
	leaq 64(%rbx), %rax
	cmpq %r12, %rax
	ja 9f
	call l_begin
	leaq s_hw8(%rip), %rsi
	call w_str
	xorl %r13d, %r13d
83:	movq (%rbx,%r13,8), %rdi
	call w_hexn
	leaq s_hw6(%rip), %rsi
	call w_str
	incl %r13d
	cmpl $8, %r13d
	jb 83b
	movl $2, %edi
	call l_end
9:	addq $24, %rsp
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbp
	popq %rbx
99:	ret
	.section .rodata
s_hw1:	.asciz "phi512: HEAP WALK BROKE ("
s_hw_rsize:	.asciz "a size field) "
s_hw_rprev:	.asciz "a free chunk's size not in the next one's prev_size) "
s_hw_rfd:	.asciz "a free chunk's fd->bk not back to it) "
s_hw_rbk:	.asciz "a free chunk's bk->fd not back to it) "
s_hw8:	.asciz "phi512:   the chunk: "
s_hw_before:	.asciz "before region "
s_hw_after:	.asciz "after the write-back of region "
s_hw3:	.asciz ": chunk "
s_hw4:	.asciz " size field "
s_hw5:	.asciz ", the chunk before "
s_hw6:	.asciz ", "
s_hw7:	.asciz " chunks walked, heap end "
	.bss
	.balign 8
hw_region:	.skip 8
hw_reported:	.skip 8
	.text

	.text

# wu_shadows_from_stage(chunk rdi, units esi, the staging slot's bytes
# rdx): every unit of the mask that the region path tracks gets its
# shadow from the bytes staged for the card (card.S's
# card_resident_post), so the card and the shadow start from one
# snapshot: a second read of the program's memory differs when another
# thread writes it between the reads, and the write-back then took the
# difference for the card's.
	.globl wu_shadows_from_stage
wu_shadows_from_stage:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	subq $8, %rsp
	movq %rdi, %r12
	movl %esi, %r13d
	movq %rdx, %r14
	xorl %ebx, %ebx
1:	cmpl $32, %ebx
	jae 9f
	btl %ebx, %r13d
	jnc 2f
	movq %rbx, %rdi
	shlq $16, %rdi
	addq %r12, %rdi
	call wu_find
	testq %rax, %rax
	jz 2f
	movq WU_SHADOW(%rax), %rdi
	movq %rbx, %rsi
	shlq $16, %rsi
	addq %r14, %rsi
	movl $UNIT, %edx
	call mem_copy
2:	incl %ebx
	jmp 1b
9:	addq $8, %rsp
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
	.section .rodata
s_wc1:	.asciz "phi512:   wb conflict at "
s_wc2:	.asciz "; word "
s_wc3:	.asciz " memory "
s_wc4:	.asciz " shadow "
s_wc5:	.asciz " card "
	.bss
	.balign 8
	.globl stat_wb_conflicts
stat_wb_conflicts:	.skip 8
	.text

	.text
	.set SYS_pwrite64, 18
# wb_line_apply(the line's address rdi, the card's line rsi, the shadow's
# line rdx): the bytes where the card differs from the shadow written into
# the program, run by run, by pwrite on /proc/self/mem, and into the
# shadow. The program's line is read first (pread): unreadable now
# (another thread unmapped it during the region) -> nothing written, eax
# 0; where it no longer matches the shadow, a write-back conflict is
# counted (and printed under verbose). eax 1 when the line was taken.
wb_line_apply:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %rbx
	movq %rsi, %r12
	movq %rdx, %r13
	call mem_wfd_get
	testl %eax, %eax
	js 8f
	movl %eax, %r15d			# the fd
	movl %r15d, %edi
	leaq wb_cur(%rip), %rsi
	movl $64, %edx
	movq %rbx, %r10
	movl $SYS_pread64, %eax
	syscall
	cmpq $64, %rax
	jne 8f
	# (probe) a conflict: the program's line no longer the shadow
	xorl %ecx, %ecx
1:	leaq wb_cur(%rip), %rax
	movq (%rax,%rcx), %rax
	cmpq (%r13,%rcx), %rax
	jne 2f
	addq $8, %rcx
	cmpl $64, %ecx
	jb 1b
	jmp 3f
2:	incq stat_wb_conflicts(%rip)
	cmpq $0, verbose(%rip)
	je 3f
	leaq wb_cur(%rip), %rdi
	movq %r13, %rsi
	movq %r12, %rdx
	movq %rbx, %rcx
	call wb_conflict_print
3:	# the runs of changed bytes
	xorl %r14d, %r14d			# the byte
4:	cmpl $64, %r14d
	jae 7f
	movzbl (%r12,%r14), %eax
	cmpb (%r13,%r14), %al
	jne 5f
	incl %r14d
	jmp 4b
5:	movl %r14d, %ecx			# the run's start
6:	movzbl (%r12,%r14), %eax
	cmpb (%r13,%r14), %al
	je 61f
	movb %al, (%r13,%r14)			# the shadow's byte
	incl %r14d
	cmpl $64, %r14d
	jb 6b
61:	pushq %rcx
	pushq %rcx
	movl %r15d, %edi
	leaq (%r12,%rcx), %rsi			# the card's bytes
	movl %r14d, %edx
	subl %ecx, %edx				# the run's length
	leaq (%rbx,%rcx), %r10			# at the program's address
	movl $SYS_pwrite64, %eax
	syscall
	popq %rcx
	popq %rcx
	jmp 4b
7:	movl $1, %eax
	jmp 9f
8:	xorl %eax, %eax
9:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# mem_wfd_get: /proc/self/mem opened read-write once (the write-back's);
# eax the fd, negative when it cannot be opened.
mem_wfd_get:
	movq mem_wfd(%rip), %rax
	testq %rax, %rax
	jnz 1f
	leaq s_procmem(%rip), %rdi
	movl $O_RDWR | O_CLOEXEC, %esi
	xorl %edx, %edx
	movl $SYS_open, %eax
	syscall
	testq %rax, %rax
	js 2f
	incq %rax				# stored + 1: 0 means not open
	movq %rax, mem_wfd(%rip)
1:	decq %rax
2:	ret

# wb_conflict_print(memory words rdi, shadow rsi, card rdx, the line's
# address rcx): a probe line for a write-back conflict: the words where
# memory is no longer the shadow, with the card's.
wb_conflict_print:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %rbx
	movq %rsi, %r12
	movq %rdx, %r13
	movq %rcx, %r15
	call l_begin
	leaq s_wc1(%rip), %rsi
	call w_str
	movq %r15, %rdi
	call w_hexn
	xorl %r14d, %r14d
1:	movq (%rbx,%r14,8), %rax
	cmpq (%r12,%r14,8), %rax
	je 2f
	leaq s_wc2(%rip), %rsi
	call w_str
	movq %r14, %rdi
	call w_dec
	leaq s_wc3(%rip), %rsi
	call w_str
	movq (%rbx,%r14,8), %rdi
	call w_hexn
	leaq s_wc4(%rip), %rsi
	call w_str
	movq (%r12,%r14,8), %rdi
	call w_hexn
	leaq s_wc5(%rip), %rsi
	call w_str
	movq (%r13,%r14,8), %rdi
	call w_hexn
2:	incl %r14d
	cmpl $8, %r14d
	jb 1b
	movl $2, %edi
	call l_end
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
	.section .rodata
s_procmem:	.asciz "/proc/self/mem"
	.bss
	.balign 64
wb_cur:		.skip 64			# the program's line as wb_line_apply read it
mem_wfd:	.skip 8				# /proc/self/mem read-write, fd + 1 (0: not open)
	.text

# heartbeat(name rdi): a progress line to standard error at most every
# 5 s, from region_run's completion, always on. Without it a load under
# the preload prints nothing for minutes (llama-server's loader is quiet
# at its default verbosity) and looks hung: two runs were killed for that
# on 2026-10-14. The line: seconds since the constructor, regions so far,
# the interval's regions per second, the share of the interval spent in
# region_run (host wall from posting to the frame back), faults, write-back
# lines, and the function of the region just finished.
	.bss
	.balign 8
	.globl hb_t0, hb_last
hb_t0:		.skip 8			# the constructor's now_ns (main.S)
hb_last:	.skip 8			# the last line's now_ns
hb_regions:	.skip 8			# stat_regions at the last line
hb_rns:		.skip 8			# stat_region_ns at the last line
	.section .rodata
s_hb1:	.asciz "phi512: progress at "
s_hb2:	.asciz " s: "
s_hb3:	.asciz " regions ("
s_hb4:	.asciz "/s), "
s_hb5:	.asciz "% of the time in regions, "
s_hb6:	.asciz " fault(s), "
s_hb7:	.asciz " write-back line(s), "
s_hb8:	.asciz " chunk fill(s) ("
s_hb9:	.asciz " read-only), "
s_hb10:	.asciz " eviction(s); last region in "
	.text
	.globl heartbeat
heartbeat:
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	movq %rdi, %r12
	call now_ns
	movq %rax, %rbx				# now
	movq %rax, %r13
	subq hb_last(%rip), %r13		# the interval, ns
	movabsq $5000000000, %rax
	cmpq %rax, %r13
	jb 9f
	movq stat_regions(%rip), %r14
	subq hb_regions(%rip), %r14		# the interval's regions
	movq stat_region_ns(%rip), %r15
	subq hb_rns(%rip), %r15			# the interval's time in region_run
	call l_begin
	leaq s_hb1(%rip), %rsi
	call w_str
	movq %rbx, %rax
	subq hb_t0(%rip), %rax
	xorl %edx, %edx
	movl $1000000000, %ecx
	divq %rcx
	movq %rax, %rdi
	call w_dec
	leaq s_hb2(%rip), %rsi
	call w_str
	movq stat_regions(%rip), %rdi
	call w_dec
	leaq s_hb3(%rip), %rsi
	call w_str
	movq %r14, %rax
	imulq $1000000000, %rax, %rax
	xorl %edx, %edx
	divq %r13
	movq %rax, %rdi
	call w_dec
	leaq s_hb4(%rip), %rsi
	call w_str
	movq %r15, %rax				# per mille, then "x.y"
	imulq $1000, %rax, %rax
	xorl %edx, %edx
	divq %r13
	xorl %edx, %edx
	movl $10, %ecx
	divq %rcx
	movq %rdx, %r15
	movq %rax, %rdi
	call w_dec
	movb $'.', %al
	call w_byte
	movq %r15, %rdi
	call w_dec
	leaq s_hb5(%rip), %rsi
	call w_str
	movq stat_faults(%rip), %rdi
	call w_dec
	leaq s_hb6(%rip), %rsi
	call w_str
	movq stat_wb_lines(%rip), %rdi
	call w_dec
	leaq s_hb7(%rip), %rsi
	call w_str
	movq stat_resident(%rip), %rdi
	call w_dec
	leaq s_hb8(%rip), %rsi
	call w_str
	movq stat_ro_faults(%rip), %rdi
	call w_dec
	leaq s_hb9(%rip), %rsi
	call w_str
	movq stat_evictions(%rip), %rdi
	call w_dec
	leaq s_hb10(%rip), %rsi
	call w_str
	testq %r12, %r12
	jz 1f
	movq %r12, %rsi
	call w_str
1:	movl $2, %edi
	call l_end
	movq %rbx, hb_last(%rip)
	movq stat_regions(%rip), %rax
	movq %rax, hb_regions(%rip)
	movq stat_region_ns(%rip), %rax
	movq %rax, hb_rns(%rip)
9:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret

# ro_need(address rdi): when the 2 MiB chunk holding the address is
# immutable in the program (elf.S chunk_immutable: inside one readable,
# not writable mapping; the mmapped model's weights), the whole chunk is
# queued for card 0 as class 0 and eax is 1: one pool page filled once by
# DMA, no shadow, no refresh, no write-back; when the card's pool is full
# the host names a victim (card.S c0_victim), so a region runs on the card
# whatever part of the model it reads (the user, 2026-10-14: the cards run
# every region, the weights they cannot hold are streamed). Else eax 0:
# the 64 KiB unit path (wu_ensure). A chunk card 0 already holds by
# writable units (classified before) stays on that path.
	.bss
	.balign 8
	.globl stat_ro_faults
stat_ro_faults:	.skip 8			# faults taken as immutable chunks
	.text
	.globl ro_need
ro_need:
	pushq %rbx
	movq %rdi, %rbx
	andq $-CHUNK, %rbx
	movq %rbx, %rdi
	call chunk_immutable
	testl %eax, %eax
	jz 9f
	leaq cards(%rip), %rdi			# card 0's table: a chunk held as units stays units
	leaq CD_TAB(%rdi), %rdi
	movq %rbx, %rsi
	call tab_find
	testq %rax, %rax
	jz 1f
	cmpl $0, RE_CLASS(%rax)
	jne 8f
1:	xorl %edi, %edi
	movq %rbx, %rsi
	movl $-1, %edx				# every unit of the chunk
	xorl %ecx, %ecx				# class 0
	call need_add
	incq stat_ro_faults(%rip)
	movl $1, %eax
	jmp 9f
8:	xorl %eax, %eax
9:	popq %rbx
	ret

# blob_at(card address rdi): the seed whose blob on card 0 holds the
# address, in rax, and the offset in rdx; rax 0 when none does. A fault
# inside a callee that an in-card call entered (card fexec.S fx_incall)
# is in the callee's blob, not the region's: the re-post enters there
# (the shadow stack starts empty again, so the callee's ret leaves the
# card for the host, which goes on natively in the caller).
	.text
blob_at:
	xorl %ecx, %ecx
1:	cmpq nseeds(%rip), %rcx
	jae 8f
	movq %rcx, %rax
	shlq $7, %rax				# MAX_CARDS * 8 bytes a seed; card 0's first
	leaq cblob_tab(%rip), %rdx
	movq (%rdx,%rax), %rdx
	testq %rdx, %rdx
	jz 2f
	movq %rdi, %rsi
	subq %rdx, %rsi
	jb 2f
	imulq $SD_BYTES, %rcx, %rax
	leaq seeds(%rip), %r8
	addq %r8, %rax
	movq SD_ABLOB_LEN(%rax), %r9
	testq %r9, %r9
	jnz 3f
	movq SD_BLOB_LEN(%rax), %r9
3:	cmpq %r9, %rsi
	jae 2f
	movq %rsi, %rdx
	ret
2:	incq %rcx
	jmp 1b
8:	xorl %eax, %eax
	ret
