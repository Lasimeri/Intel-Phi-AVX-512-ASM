# fnscan.inc: the layouts of fnscan.S: the object descriptor a scan is
# given, the function record it fills, the instruction index entries.
# See fnscan.md.

# The object (struct obj) the function belongs to: its address range
# (a direct call inside it is an in-object call, outside it a PLT call
# or stranger) and its PLT's.
	.set OB_LO, 0
	.set OB_HI, 8
	.set OB_PLT_LO, 16
	.set OB_PLT_HI, 24
	.set OB_BYTES, 32
# The function record (struct fn).
	.set FN_ADDR, 0				# u64: the function's address
	.set FN_SIZE, 8				# u64: its bytes
	.set FN_NAME, 16			# u64: its name (the caller's), 0 none
	.set FN_NINSN, 24			# u32: instructions indexed
	.set FN_FLAGS, 28			# u32: FNF_*
	.set FN_INSNS, 32			# u64: the index entries (IX_BYTES each)
	.set FN_NEVEX, 40			# u32 counts by kind
	.set FN_NVEX, 44
	.set FN_NCALL, 48			# direct calls inside the object
	.set FN_NPLT, 52			# direct calls into the PLT
	.set FN_NICALL, 56			# indirect calls
	.set FN_NIJMP, 60			# indirect jumps
	.set FN_NBROUT, 64			# relative branches leaving the function
	.set FN_NLOCK, 68			# locked instructions
	.set FN_NTRAP, 72			# syscall, int, hlt, ud2
	.set FN_NFS, 76				# fs- or gs-relative accesses
	.set FN_NUNK, 80			# instructions without a table entry
	.set FN_NRIP, 84			# rip-relative operands
	.set FN_FAIL_OFF, 88			# u32: where the decode failed (FNF_FAILED)
	.set FN_NLABEL, 92			# u32: instructions that are branch targets
	.set FN_NBRIN, 96			# relative branches inside the function
	.set FN_NRET, 100
	.set FN_BYTES, 128
	.set FNF_FAILED, 1			# a byte sequence that is not an instruction
	.set FNF_BADTARGET, 2			# a branch into the middle of an instruction
	.set FNF_FAR, 4				# a far form, iret, sysret
	.set FNF_EVEX, 8
	.set FNF_VEX, 16
	.set FNF_LOCK, 32
	.set FNF_TRAP, 64
	.set FNF_UNK, 128
	.set FNF_FULL, 256			# the index ran out of room
# An index entry (struct ix), one per instruction.
	.set IX_OFF, 0				# u32: offset in the function
	.set IX_LEN, 4				# u8
	.set IX_KIND, 5				# u8: K_*
	.set IX_FLAGS, 6			# u8: IXF_*
	.set IX_TGT, 8				# u64: a branch's target address, a direct call's callee
	.set IX_BYTES, 16
	.set K_COPY, 0				# copied as it is
	.set K_EVEX, 1				# translated
	.set K_VEX, 2				# translated (a masked 512-bit form)
	.set K_BR_IN, 3				# a relative branch inside the function (re-laid out)
	.set K_BR_OUT, 4			# a relative branch outside it (a tail call, a cold part): to the original address
	.set K_CALL, 5				# a direct call inside the object
	.set K_PLT, 6				# a direct call into the PLT
	.set K_ICALL, 7				# an indirect call
	.set K_IJMP, 8				# an indirect jump (a jump table, a tail call through a pointer)
	.set K_RET, 9
	.set K_TRAP, 10
	.set K_FAR, 11
	.set IXF_LABEL, 1			# a branch target
	.set IXF_RIP, 2				# a rip-relative operand
	.set IXF_LOCK, 4
	.set IXF_FS, 8
	.set IXF_UNK, 16			# no table entry
	.set IXF_COND, 32			# a conditional branch
