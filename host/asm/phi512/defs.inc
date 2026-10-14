# defs.inc: the preload library's constants: the signal frame's layout
# (arch/x86/include/uapi/asm/sigcontext.h, ucontext.h), the register file
# block it builds for the card (vpu_exec.h's vpu_regs, as proto.inc has
# it), its limits, the per-card record and the seed table's entries. See
# defs.md.

	.set SYS_rt_sigaction, 13
	.set SYS_rt_sigreturn, 15
	.set SYS_sigaltstack, 131
	.set SYS_pread64, 17
	.set SYS_exit, 60
	.set SYS_gettid, 186
	.set SIGILL, 4
	.set SA_SIGINFO, 4
	.set SA_ONSTACK, 0x08000000
	.set SA_RESTORER, 0x04000000
	.set SA_HANDLER, 0
	.set SA_FLAGS, 8
	.set SA_RESTORER_OFF, 16
	.set SA_MASK, 24
	.set SA_BYTES, 32
	.set SIGSET_BYTES, 8
	.set ALTSTACK_BYTES, 1048576
	.set MAP_FIXED, 0x10
# struct ucontext: the general registers at 40 in glibc's REG_* order,
# the pointer to the FXSAVE/XSAVE area at 224.
	.set UC_GREGS, 40
	.set UC_FPREGS, 224
	.set G_R8, 0
	.set G_R9, 1
	.set G_R10, 2
	.set G_R11, 3
	.set G_R12, 4
	.set G_R13, 5
	.set G_R14, 6
	.set G_R15, 7
	.set G_RDI, 8
	.set G_RSI, 9
	.set G_RBP, 10
	.set G_RBX, 11
	.set G_RDX, 12
	.set G_RAX, 13
	.set G_RCX, 14
	.set G_RSP, 15
	.set G_RIP, 16
	.set G_EFL, 17
	.set FX_XMM0, 160			# xmm0..15 at 160, 16 bytes each, in the FXSAVE area
	.set XSAVE_HEADER, 512			# XSTATE_BV at 512 of the XSAVE area
	.set XSTATE_YMM_BIT, 2
# The ModRM register numbers, as the seed table and the card's file use
# them (vpu_regs.gpr is in this order).
	.set R_RAX, 0
	.set R_RCX, 1
	.set R_RDX, 2
	.set R_RBX, 3
	.set R_RSP, 4
	.set R_RBP, 5
	.set R_RSI, 6
	.set R_RDI, 7
	.set R_R8, 8
	.set R_R9, 9
	.set R_R10, 10
	.set R_R11, 11
# Limits.
	.set MAX_CARDS, 16
	.set CHUNK, 2097152
	.set STAGING_SLOTS, 16
	.set RES_TAB_CAP, 4096			# resident chunks remembered per card (a power of two)
	.set RES_ENTRY, 32			# key (chunk address), state, pool page, class
	.set RE_PAGE, 16
	.set RE_CLASS, 24
	.set REQ_TIMEOUT_NS, 5000000000
# A card the library drives (struct card): the window's base, the slot
# this process uses, the slot's block and SLOTDATA, the next sequence
# number, the next staging slot, the residency table's header.
	.set CD_BASE, 0
	.set CD_SLOT, 8
	.set CD_SLOTP, 16
	.set CD_DATAP, 24
	.set CD_SEQ, 32
	.set CD_STAGE, 40
	.set CD_TAB, 48				# 32 bytes: TB_BASE, TB_ENTRY, TB_CAP, TB_LIVE
	.set CD_INDEX, 80
	.set CD_BYTES, 128
# A seed (struct seed): a function the library has a blob for, resolved
# at the first fault: the name, the blob's bytes, the fault's offset into
# the function (where the blob is entered), the loop's induction and
# bound registers and step (0: not split), then up to four memory
# operands: register, element stride, kind (0 none, 1 read indexed by
# the induction, 2 written indexed by the induction, 3 read fixed bytes).
	.set SD_NAME, 0
	.set SD_BLOB, 8
	.set SD_BLOB_LEN, 16
	.set SD_ENTRY, 24
	.set SD_IND, 32
	.set SD_BOUND, 36
	.set SD_STEP, 40
	.set SD_RET_XMM0, 44			# 1: the function returns in xmm0
	.set SD_OPS, 48				# 4 x {reg u32, stride u32, kind u32, fixed_len u32}
	.set OP_BYTES, 16
	.set OP_REG, 0
	.set OP_STRIDE, 4
	.set OP_KIND, 8
	.set OP_LEN, 12
	.set OPK_NONE, 0
	.set OPK_READ, 1
	.set OPK_WRITE, 2
	.set OPK_FIXED, 3
	.set SD_ADDR, 112			# resolved: the function's address, 0 until then
	.set SD_LEN, 120
# The automatic translation (stage 3): the blob built from the function
# itself, its rip map (the blob offset per instruction), the index, the
# instruction count; SD_BLOB above stays the hand-written blob, used
# under PHI512_HANDBLOBS=1.
	.set SD_ABLOB, 128
	.set SD_ABLOB_LEN, 136
	.set SD_MAP, 144
	.set SD_INDEX, 152
	.set SD_NINSN, 160
	.set SD_REFUSED, 168			# 1: the translation was refused (not tried again)
	.set SD_NREG, 176			# regions that ended in this seed's blob
	.set SD_NREG0, 184			# SD_NREG at the last progress line (region.S heartbeat)
	.set SD_BYTES, 192
	.set SEEDS_DYN_MAX, 1024		# dynamic seeds the table has room for after the static ones
# Residency by 64 KiB units: a chunk's entry keeps which units the card
# holds (RE_FILLED, 32 bits); a need is a chunk and the units a stripe
# reads (0 for a chunk it only writes: the page without a fill).
	.set RE_FILLED, 28
	.set UNIT, 65536
	.set NEED_MAX, 1024			# needs queued per card per call (a 64 MiB array is 32 chunks)
	.set NQ_CHUNK, 0
	.set NQ_UNITS, 8
	.set NQ_CLASS, 12
	.set NQ_BYTES, 16
	.set PUSH_MAX, 8			# written ranges queued per card per call
	.set PQ_ADDR, 0
	.set PQ_LEN, 8
	.set PQ_DONE, 16
	.set PQ_BYTES, 24
# The card record's pending request (one in flight per card).
	.set CD_PEND_CHUNK, 88
	.set CD_PEND_UNITS, 96			# a push: the staging slot
	.set CD_PEND_CLASS, 100
	.set CD_PEND_ADDR, 104
	.set CD_PEND_LEN, 112
	.set CD_POSTED, 120

# The loaded-object table of elf.S (obj_at): an entry per executable or
# shared object a fault has landed in.
	.set OBJ_MAX, 64
	.set OBJ_BASE, 0			# the load base
	.set OBJ_MAP, 8				# the file mapped whole (its symbol table)
	.set OBJ_LEN, 16
	.set OBJ_LO, 24				# the span of its mappings
	.set OBJ_HI, 32
	.set OBJ_PATH, 40			# the path, NUL-terminated
	.set OBJ_PATH_CAP, 256
	.set OBJ_BYTES, 320
