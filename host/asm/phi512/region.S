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
	.set WU_ADDR, 0				# the unit's address
	.set WU_SHADOW, 8			# its shadow (64 KiB)
	.set WU_LO, 16				# the lowest address lines are written back from (the stack unit: below the frame's rsp is the handler's own)
	.set WU_PAGES, 24			# u16: the mapped 4 KiB pages
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
s_kinds: .asciz "ret\0call\0atomic\0syscall\0fault\0refused\0loop\0deferfull\0limit\0jump"

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
	# the stack: the unit of rsp - 128 (the red zone) and the one of rsp + 8 KiB
	movq UC_GREGS + 8 * G_RSP(%r12), %rdi
	subq $128, %rdi
	movq %rdi, %rsi
	call wu_ensure
	testl %eax, %eax
	jnz .Lrg_step
	movq UC_GREGS + 8 * G_RSP(%r12), %rdi
	addq $8192, %rdi
	xorl %esi, %esi
	call wu_ensure
	testl %eax, %eax
	jnz .Lrg_step
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
	xorl %esi, %esi
	call wu_ensure
	testl %eax, %eax
	jnz .Lrg_step
	call resident_rounds
	testl %eax, %eax
	jnz .Lrg_step
	call wu_verify
	leaq region_file(%rip), %rdi
	movq CD_DATAP(%rbx), %rsi
	addq $SD_REGS_OUT, %rsi
	movl $REGS_BYTES, %edx
	call mem_copy
	movq 40(%rsp), %r14			# the fault's rip on the card
	call seed_index
	movq %rax, %rcx
	shlq $7, %rcx				# MAX_CARDS * 8 = 128 bytes a seed
	leaq cblob_tab(%rip), %rdx
	subq (%rdx,%rcx), %r14			# the blob offset of the faulting instruction
	jmp .Lrg_post
.Lrg_exit:
	cmpl $X_RET, %eax
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
	cmpq $9, %rdi
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
	movq WU_LO(%rax), %rcx
	testq %rcx, %rcx
	jz 72f
	cmpq %rcx, %r13
	jae 72f
	# the floor drops: [new, old) must come whole from the host at the next region
	cmpq $0, WU_FHI(%rax)
	je 73f
	cmpq WU_FLO(%rax), %r13
	jae 74f
73:	movq %r13, WU_FLO(%rax)
74:	cmpq WU_FHI(%rax), %rcx
	jbe 72f
	movq %rcx, WU_FHI(%rax)
72:	movq %r13, WU_LO(%rax)
71:	xorl %eax, %eax
	jmp 9f
8:	movl $1, %eax
9:	popq %r14
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
	leaq wu_tab(%rip), %rbx
	movq wu_n(%rip), %r12
1:	testq %r12, %r12
	jz 9f
	leaq stage_buf(%rip), %rdi
	movq WU_ADDR(%rbx), %rsi
	movl $UNIT, %edx
	call copy_mapped
	movzwl copy_mapped_pages(%rip), %eax
	movw %ax, WU_PAGES(%rbx)		# the pages as mapped now (the program may have unmapped some)
	xorl %r13d, %r13d			# page
2:	cmpl $16, %r13d
	jae 8f
	btw %r13w, WU_PAGES(%rbx)
	jnc 7f
	xorl %r14d, %r14d			# the line's offset in the page
3:	cmpl $4096, %r14d
	jae 7f
	movq %r13, %r15
	shlq $12, %r15
	addq %r14, %r15				# the offset in the unit
	movq WU_ADDR(%rbx), %rax
	addq %r15, %rax
	cmpq WU_LO(%rbx), %rax
	jb 6f					# below the floor: the handler's own stack
	leaq stage_buf(%rip), %rsi
	addq %r15, %rsi
	movq WU_SHADOW(%rbx), %rdi
	addq %r15, %rdi
	cmpq WU_FLO(%rbx), %rax
	jb 41f
	cmpq WU_FHI(%rbx), %rax
	jb 5f					# in the forced range: whole, compared or not
41:	xorl %ecx, %ecx
4:	movq (%rsi,%rcx), %rax
	cmpq (%rdi,%rcx), %rax
	jne 5f
	addq $8, %rcx
	cmpq $64, %rcx
	jb 4b
	jmp 6f
5:	# changed: the shadow line, then the list
	xorl %ecx, %ecx
51:	movq (%rsi,%rcx), %rax
	movq %rax, (%rdi,%rcx)
	addq $8, %rcx
	cmpq $64, %rcx
	jb 51b
	movq WU_ADDR(%rbx), %rdi
	addq %r15, %rdi
	call refresh_add
	testl %eax, %eax
	jnz .Lrf_full
6:	addl $64, %r14d
	jmp 3b
7:	incl %r13d
	jmp 2b
8:	movq $0, WU_FLO(%rbx)
	movq $0, WU_FHI(%rbx)
	addq $WU_BYTES, %rbx
	decq %r12
	jmp 1b
9:	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	ret
.Lrf_full:
	# the list is full: this unit by a DMA refill (the rest of its lines
	# into the shadow whole), with the card's filled bit cleared
	incq stat_refresh_full(%rip)
	movq WU_SHADOW(%rbx), %rdi
	leaq stage_buf(%rip), %rsi
	movl $UNIT, %edx
	call mem_copy
	leaq cards + CD_TAB(%rip), %rdi
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
	btw %r14w, WU_PAGES(%rbx)
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
41:	# changed: the whole line copied to memory and the shadow
	leaq (%r9,%r10), %r11
	movq WU_ADDR(%rbx), %rdi
	addq %r11, %rdi
	xorl %ecx, %ecx
42:	movq (%r13,%r11), %rax
	movq %rax, (%rdi,%rcx)
	movq %rax, (%rdx,%r11)
	addq $8, %r11
	addq $8, %rcx
	cmpl $64, %ecx
	jb 42b
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
