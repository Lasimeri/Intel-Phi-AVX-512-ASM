# xlate.inc: the layouts of the translator (mvex.S, xlate.S, blob.S):
# the card's per-thread scratch area the sequences use through fs, the
# emitter's state, the MVEX argument block, a blob under construction.
# See xlate.md.

# The scratch area (SCRATCH_BYTES at the fs offset the card gives): six
# vector slots, rax, rcx, a mask, a general register, the flags, the x87
# control word and a copy with truncation set, the base register of a
# re-based rip-relative operand, a transfer slot. The layout of
# host/crates/avx512-xlate/src/rewrite.rs (S_*) plus S_RIPB.
	.set SCRATCH_BYTES, 512
	.set S_ZMM0, 0
	.set S_ZMM1, 64
	.set S_ZMM2, 128
	.set S_ZMM3, 192
	.set S_ZMM4, 256
	.set S_ZMM5, 320
	.set S_RAX, 384
	.set S_RCX, 392
	.set S_K, 400
	.set S_GPR, 408
	.set S_FLAGS, 416
	.set S_CW, 424
	.set S_CW2, 428
	.set S_RIPB, 432
	.set S_KIND, 436			# an exit's kind (FX_S_KIND of proto.inc)
	.set S_SITE, 440			# where the host resumes (FX_S_SITE)
	.set S_XFER, 448			# (FX_S_XFER)
	# in-card calls: past the 512-byte scratch (the transfer slot S_XFER
	# runs to its end: mvex2.S XFER_HI = S_XFER + 32 takes up to 32 bytes
	# more), in the TLS block's free 2048..4095 (card proto.inc FX_S_RETA)
	.set S_RETA, 512			# an in-card call: the host return address
	.set S_INCALL, 520			# the card's fx_incall
	.set S_INRET, 528			# the card's fx_inret
	.set S_NTEMPS, 6
# The emitter (struct em), one per translated instruction, on the
# caller's stack. The output pointer and limit belong to the blob; the
# rest is this instruction's bookkeeping: which scratch registers were
# saved (restored in reverse at em_finish), the temporaries taken, the
# general registers to load last (gpr_result), the flags-out slot.
	.set EM_OUT, 0				# u64: where the next byte goes
	.set EM_LIM, 8				# u64: the end of the room
	.set EM_BLOB, 16			# u64: the blob under construction (BL_*), for constants and fixups
	.set EM_SCRATCH, 24			# i32: the scratch area's fs offset
	.set EM_USED, 28			# u32: EU_* bits
	.set EM_RESERVED, 32			# u32: the vector registers the instruction names (no temporary takes them)
	.set EM_KSCR, 36			# u8: the scratch mask register
	.set EM_NTEMP, 37			# u8
	.set EM_NTAIL, 38			# u8
	.set EM_FLAGS_OUT, 40			# i32: the scratch offset holding the flags the instruction defines, -1 none
	.set EM_TEMPS, 44			# 6 x u8: the temporaries' registers (slot = index)
	.set EM_TAIL, 52			# 4 x {reg u8, wide u8, pad u16, off i32}
	.set EM_IN, 84				# u64: the decoded instruction (IN_*)
	.set EM_ENT, 92				# u64: its entry (EN_*)
	.set EM_NBYTES, 100			# u32: the bytes the next unaligned move touches (0: from the mask or the length, and the conversion)
	.set EM_KVAL, 104			# u32: the last mask immediate (em_mask_imm), 0 none: the lanes an unaligned move covers
	.set EM_PACK, 108			# u32: 1 = the next bounced store packs its lanes to the slot's start (vpackstoreld: an extract's element, xl_pextr); em_bounce clears it
	.set EM_BYTES, 112
	.set EU_RAX, 1
	.set EU_RCX, 2
	.set EU_K, 4
	.set EU_FLAGS, 8
	.set EU_FULL, 0x80000000		# the room ran out (every emit is a no-op after)
# The MVEX argument block (struct mv), filled by a recipe, read by em_mvex.
	.set MV_MAP, 0				# u8: 1 0F, 2 0F38, 3 0F3A
	.set MV_PP, 1				# u8
	.set MV_W, 2				# u8
	.set MV_OP, 3				# u8
	.set MV_REG, 4				# u8: ModRM.reg (zmm or k, 5 bits)
	.set MV_VVVV, 5				# u8: the first source (0 when unused)
	.set MV_RMKIND, 6			# u8: RM_*
	.set MV_RM, 7				# u8: the r/m register (RM_REG)
	.set MV_K, 8				# u8: the write mask (0 none)
	.set MV_SSS, 9				# u8
	.set MV_IMM, 10				# i16: the immediate, -1 none
	.set MV_OFF, 12				# i32: RM_FS: the scratch offset; RM_CONST: the constant's index
	.set MV_MEMP, 16			# u64: RM_MEM: the decoded instruction whose memory operand is used (base, index, scale, disp)
	.set MV_DISP, 24			# i64: RM_MEM: added to the operand's displacement
	.set MV_BYTES, 32
	.set RM_REG, 0
	.set RM_MEM, 1
	.set RM_FS, 2
	.set RM_CONST, 3
# A blob under construction (struct bl): the code area, the constants
# (64-byte each, deduplicated), the fixups (a rip-relative disp32 in the
# code that must reach a constant), the rip map (original offset to
# blob offset per instruction), the labels (blob offset per index
# entry), and the branch fixups (a rel32 in the code that must reach an
# index entry's label).
	.set BL_CODE, 0				# u64: the code's start
	.set BL_CODE_LIM, 8			# u64
	.set BL_OUT, 16				# u64: where the next byte goes
	.set BL_CONSTS, 24			# u64: 64-byte constants
	.set BL_NCONST, 32			# u32
	.set BL_CONST_CAP, 36			# u32
	.set BL_FIX, 40				# u64: fixups, FX_BYTES each
	.set BL_NFIX, 48			# u32
	.set BL_FIX_CAP, 52			# u32
	.set BL_MAP, 56				# u64: u32 blob offset per index entry (the rip map)
	.set BL_NMAP, 64			# u32
	.set BL_BRFIX, 72			# u64: branch fixups, FX_BYTES each
	.set BL_NBRFIX, 80			# u32
	.set BL_BRFIX_CAP, 84			# u32
	.set BL_FN, 88				# u64: the function record (FN_*)
	.set BL_REFUSED, 96			# u64: the refusal's reason (a string), 0 none
	.set BL_REFUSED_OFF, 104		# u32: the instruction's offset in the function
	.set BL_SCRATCH, 108			# i32: the scratch area's fs offset
	.set BL_BYTES, 128
	.set LAZY_MAX, 256			# blob.S's lazy sites recorded per function (blob_lazy: u32 offset, u32 kind, u64 reason)
	.set FX_AT, 0				# u32: the disp32's offset in the code
	.set FX_END, 4				# u32: the instruction's end (the rip the disp is relative to)
	.set FX_WHAT, 8				# u32: a constant's index, or an index entry
	.set FX_BYTES, 16
