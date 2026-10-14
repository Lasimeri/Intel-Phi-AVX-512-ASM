# proto.inc: the host/card contract as numbers, mirroring vpu_proto.h,
# vpu_exec.h and vpu_matmul.h (the readable contract, which
# tools/vpu-layout-check.c checks against these values and the Rust
# side's). Every offset is in the shared window: the host's
# /dev/shm/phi-hostmem[-N], the card's /dev/phihost (mapped, uncached) and
# /dev/phiblk1 (the same bytes through the DMA engine). See proto.md.

# Control words, each on its own 64-byte line.
	.set OFF_READY, 0
	.set OFF_SCRATCH, 8
	.set OFF_REQ, 64
	.set OFF_NONCE, 128		# the card alone writes it: the nonce of its DMA channel's open (cdma.md)
	.set OFF_REPLY, 256
	.set OFF_STATS, 320		# struct vpu_stats: the worker's running counters, rewritten after every reply (phitop reads them)
	.set OFF_DATA, 1048576
	.set MAGIC_LO, 0x52454144
	.set MAGIC_HI, 0x5650555F
	.set VPU_BLOCK, 4096
	.set VPU_CHUNK, 128

# Request kinds.
	.set K_POLY30, 1
	.set K_EXEC, 2
	.set K_UPLOAD, 3
	.set K_MATMUL, 4
	.set K_FREE, 5
	.set K_MATMUL_ID, 6
	.set K_FFN, 7
	.set K_MATMUL_MORE, 8

# Status values.
	.set E_OK, 0
	.set E_ALLOC, -1
	.set E_PULL, -2
	.set E_PUSH, -3
	.set E_REQUEST, -4
	.set E_KERNEL, -5

# struct vpu_request (56 bytes) and struct vpu_reply (48 bytes).
	.set RQ_SEQ, 0
	.set RQ_KERNEL, 8
	.set RQ_THREADS, 12
	.set RQ_N, 16
	.set RQ_IN_OFF, 24
	.set RQ_OUT_OFF, 32
	.set RQ_AUX_OFF, 40
	.set RQ_AUX_LEN, 48
	.set RQ_BYTES, 56
	.set RP_SEQ, 0
	.set RP_COMPUTE_NS, 8
	.set RP_TOTAL_NS, 16
	.set RP_PULL_NS, 24
	.set RP_PUSH_NS, 32
	.set RP_STATUS, 40
	.set RP_THREADS, 44
	.set RP_BYTES, 48
# struct vpu_stats (64 bytes, one line at OFF_STATS).
	.set ST_REQUESTS, 0
	.set ST_ERRORS, 8
	.set ST_BUSY_NS, 16
	.set ST_COMPUTE_NS, 24
	.set ST_PULL_NS, 32
	.set ST_PUSH_NS, 40
	.set ST_LAST_KERNEL, 48
	.set ST_LAST_THREADS, 52
	.set ST_LAST_SEQ, 56
	.set ST_BYTES, 64

# The seamless path (vpu_exec.h): the mailbox, the descriptor, the slots.
	.set OFF_MAIL, 4096
	.set OFF_EXEC, 8192
	.set EXEC_CHUNK, 2097152
	.set EXEC_THUNK_MAX, 262144
	.set EXEC_SCRATCH, 512
# The per-thread scratch area of the translated code (fs-relative, in
# the slot process threads' TLS block after the exec context):
# host/asm/phi512/xlate.inc S_* lays it out.
	.set FX_SCRATCH_TPOFF, 1536
	.set FX_SCRATCH_BYTES, 512
# The exit of a translated blob: `jmp *%fs:FX_EXIT_TPOFF` (the stub's
# address, put in every thread's TLS block at TLS_EXEC + 24 by fexec_init)
# with the exit's kind, the address the host resumes at and an aux (the
# callee, the target) in the scratch area's slots.
	.set FX_EXIT_TPOFF, 1048
	.set FX_S_KIND, 436
	.set FX_S_SITE, 440
	.set FX_S_XFER, 448
# In-card calls (2026-10-14): a translated call site puts the host return
# address in FX_S_RETA and calls *FX_S_INCALL (fexec.S fx_incall: the
# callee's blob when the card has it, else back to the site's X_CALL
# exit); a translated ret jumps to *FX_S_INRET (fx_inret: back into the
# calling blob when the shadow stack's top is that return, else X_RET).
# FX_S_RSH is the thread's shadow stack top, FX_S_RSHB its base (4 KiB
# aligned, 255 frames of {host return, blob return}), FX_S_T0/T1 temps.
# They lie past the 512-byte scratch (its transfer slot FX_S_XFER takes
# up to its end: the host's mvex2.S copies operands to FX_S_XFER + 32),
# in the TLS block's free 2048..4095 (a first placement at 456..511 had
# a block load overwrite FX_S_INCALL: #GP at the next call).
	.set FX_INCALL_SKIP, 20			# a hit returns past the site's X_CALL exit (blob.S .Lseq_kind 12 + .Lseq_jmp 8 bytes)
	.set FX_S_RETA, 512
	.set FX_S_INCALL, 520
	.set FX_S_INRET, 528
	.set FX_S_RSH, 536
	.set FX_S_RSHB, 544
	.set FX_S_T0, 552
	.set FX_S_T1, 560
	.if FX_SCRATCH_TPOFF + FX_S_T1 + 8 > 4096		# (TLS_BYTES: the card's defs.inc, which the host does not include)
	.error "the in-card call slots run past the TLS block"
	.endif
# K_FEXEC flags (SL_FLAGS).
	.set FXF_IDSTACK, 1			# the file's rsp is the program's stack at identity: no run stack, no return stub
	.set FXF_CARDWB, 2			# after a run that did not fault: the card's own diff of its writable units as the write-back (resident.S wb_card_diff)
	.set FXF_DIFFONLY, 4			# nothing run: only the card's own diff (a region that faulted moves to another card; the lines it wrote here go back first)
	.set EXEC_MAX_RANGES, 64
	.set EXEC_MAX_PAGES, 64
	.set EXEC_MAX_THREADS, 64
	.set EXEC_DESC_PAGES, 2
	.set OFF_EXEC_FETCH, 32 * 1048576
	.set OFF_EXEC_CODE, OFF_EXEC_FETCH + 2 * EXEC_CHUNK
	.set OFF_EXEC_WB, OFF_EXEC_CODE + EXEC_CHUNK
	.set REGS_BYTES, 2256
	.set REGS_ZMM, 0
	.set REGS_K, 2048
	.set REGS_GPR, 2112
	.set REGS_RFLAGS, 2240
	.set REGS_RIP, 2248
	.set EXEC_BYTES, 256 + 2256 + 512 + 1536
# struct vpu_exec: the phase (in), the reply (out), the register file, the
# code page addresses, the ranges.
	.set EX_REGION_ID, 0
	.set EX_MODE, 8
	.set EX_FLAGS, 12
	.set EX_CODE_ADDR, 16
	.set EX_THUNK_ADDR, 24
	.set EX_THUNK_LEN, 32
	.set EX_REGION_LO, 40
	.set EX_REGION_HI, 48
	.set EX_ENTRY, 56
	.set EX_CODE_PAGES, 64
	.set EX_NRANGES, 68
	.set EX_THREADS, 72
	.set EX_IND_REG, 76
	.set EX_BOUND_REG, 80
	.set EX_STEP, 88
	.set EX_IND_START, 96
	.set EX_IND_END, 104
	.set EX_LOOP_EXIT, 112
	.set EX_RESERVED, 120
	.set EX_EXIT_RIP, 152
	.set EX_FAULT_ADDR, 160
	.set EX_EXIT_KIND, 168
	.set EX_EXIT_THREAD, 172
	.set EX_CHUNKS, 176
	.set EX_DIRTY, 180
	.set EX_FAULTS, 184
	.set EX_THREADS_RAN, 188
	.set EX_FETCH_NS, 192
	.set EX_WB_NS, 200
	.set EX_RUN_NS, 208
	.set EX_REGS, 256
	.set EX_CODE_PAGE, 2512
	.set EX_RANGES, 3024
	.set RANGE_ADDR, 0
	.set RANGE_LEN, 8
	.set RANGE_FLAGS, 16
	.set RANGE_BYTES, 24
	.set RANGE_WRITE, 1
	.set RANGE_DENSE, 2
	.set MODE_DEMAND, 0
	.set MODE_RANGES, 1
	.set EXEC_FINAL, 1
	.set EXEC_FIRST, 2
	.set EXIT_LEFT, 0
	.set EXIT_FAULT, 1
	.set EXIT_ILLEGAL, 2
	.set EXIT_COLLISION, 3
	.set EXIT_LIMIT, 4
	.set EXIT_SPLIT, 5
# struct vpu_mail (48 bytes) and the write-back slot's page table.
	.set MAIL_SEQ, 0
	.set MAIL_ADDR, 8
	.set MAIL_LEN, 16
	.set MAIL_KIND, 24
	.set MAIL_SLOT, 28
	.set MAIL_ACK, 32
	.set MAIL_STATUS, 40
	.set MAIL_FETCH, 0
	.set MAIL_WRITEBACK, 1
	.set WB_ADDR, 0
	.set WB_LINES, 8
	.set WB_PAGE_BYTES, 16
	.set WB_TABLE, 65536
	.set WB_MAX_PAGES, (EXEC_CHUNK - WB_TABLE) / 4096

# The matrix service (vpu_matmul.h): the descriptors and their fields.
	.set OFF_MATMUL, 13312
	.set OFF_FFN, 13440
	.set OFF_MORE, 13632
	.set MM_F32, 0
	.set MM_F16, 1
	.set MM_Q4_K, 2
	.set MM_Q5_K, 3
	.set MM_Q6_K, 4
	.set MM_Q8_0, 5
	.set MM_IQ4_XS, 6
	.set MM_BF16, 7
	.set MM_TYPES, 8
	.set MM_PROBE, 99
	.set MM_SWIGLU, 98
	.set MM_A_ID, 0
	.set MM_A_OFF, 8
	.set MM_BYTES, 16
	.set MM_A_TYPE, 24
	.set MM_B_TYPE, 28
	.set MM_M, 32
	.set MM_N, 40
	.set MM_K, 48
	.set MM_NB_A, 56
	.set MM_NB_B, 64
	.set MM_B_OFF, 72
	.set MM_D_OFF, 80
	.set MM_CHUNK, 88
	.set MM_N_USED, 96
	.set MM_N_TOKENS, 104
	.set MM_B_ROWS, 112
	.set MM_IDS_BYTES, 120
	.set MM_DESC_BYTES, 128
	.set FF_GATE_ID, 0
	.set FF_UP_ID, 8
	.set FF_DOWN_ID, 16
	.set FF_GATE_TYPE, 24
	.set FF_UP_TYPE, 28
	.set FF_DOWN_TYPE, 32
	.set FF_B_TYPE, 36
	.set FF_ROWS, 40
	.set FF_K, 48
	.set FF_M_OUT, 56
	.set FF_N, 64
	.set FF_NB_GATE, 72
	.set FF_NB_UP, 80
	.set FF_NB_DOWN, 88
	.set FF_NB_B, 96
	.set FF_B_OFF, 104
	.set FF_D_OFF, 112
	.set FF_CHUNK, 120
	.set FF_H_TYPE, 128
	.set FF_DESC_BYTES, 192
	.set MORE_MAX, 3
	.set MORE_COUNT, 0
	.set MORE_MAT, 8
	.set MORE_MAT_BYTES, 40
	.set MM2_A_ID, 0
	.set MM2_A_TYPE, 8
	.set MM2_M, 16
	.set MM2_NB_A, 24
	.set MM2_D_OFF, 32
	.set MORE_DESC_BYTES, 128

# Protocol v3 (vpu_fexec.h): the slots. A host thread owns a slot: it
# writes the slot's request block, then its sequence number into the
# SLOTSEQ line (one u16 per slot), which the dispatcher reads whole with
# one 64-byte load per poll. The slot's reply, mail and progress words
# live in the same 4 KiB block; the slot's bulk data (register blocks,
# refresh bytes, write-back, the deferred list, the demand landing area)
# in its 1 MiB of SLOTDATA. Nothing of v3 lies above 128 MiB (the
# backend's areas). vpu_fexec.md has the picture.
	.set OFF_SLOTSEQ, 448
	.set NSLOTS, 32
	.set OFF_SLOTS, 65536
	.set SLOT_BYTES, 4096
	.set OFF_SLOTDATA, 48 * 1048576
	.set SLOTDATA_BYTES, 1048576
	.set OFF_LOADAREA, 80 * 1048576
	.set LOADAREA_BYTES, 16 * 1048576
	.set OFF_RESIDENT, 96 * 1048576
	.set RESIDENT_BYTES, 32 * 1048576
# Inside a slot's 1 MiB of SLOTDATA.
	.set SD_REGS_IN, 0
	.set SD_REGS_OUT, 4096
	.set SD_REFRESH_TAB, 8192
	.set SD_REFRESH, 16384
	.set SD_WB_TAB, 272 * 1024
	.set SD_WB, 288 * 1024
	.set SD_DEFER, 528 * 1024
	.set SD_LAND, 784 * 1024
	.set SD_DEFER_MAX, 2048
	.set SD_DEFER_BYTES, 128
# Request kinds of the slots (the legacy kinds 1 to 8 ride the REQ line).
	.set K_PING, 9
	.set K_LOAD, 10
	.set K_UNLOAD, 11
	.set K_RESIDENT, 12
	.set K_FEXEC, 13
	.set K_RESUME, 14
	.set K_FLUSH, 15
	.set K_PUSH, 16
	.set K_LAST, 16
	.set SD_WB_BYTES, SD_DEFER - SD_WB
# How a function instance left the card.
	.set X_RET, 0
	.set X_CALL, 1
	.set X_ATOMIC, 2
	.set X_SYSCALL, 3
	.set X_FAULT, 4
	.set X_REFUSED, 5
	.set X_LOOP, 6
	.set X_DEFER_FULL, 7
	.set X_LIMIT, 8
	.set X_HOST, 10				# an instruction the host runs itself (blob.S's lazy path): the host resumes at the exit's rip
	.set X_JUMP, 9				# the host resumes at the exit's rip (a branch out of the blob, an indirect jump, a return)
# struct vpu_slot: the request at 0, the reply at SLOT_REPLY, the demand
# mail at SLOT_MAIL, the progress line at SLOT_PROGRESS.
	.set SL_SEQ, 0
	.set SL_KIND, 8
	.set SL_FLAGS, 12			# K_FEXEC: FXF_*; K_RESIDENT: the units of the chunk (a bit per 64 KiB)
	.set SL_FN_ID, 16
	.set SL_ENTRY, 24
	.set SL_THREADS, 32
	.set SL_NSTRIPES, 36
	.set SL_STRIPES, 40
	.set SL_STRIPE_BYTES, 16
	.set SL_MAX_STRIPES, 16
	.set SL_IND_REG, 296
	.set SL_BOUND_REG, 300
	.set SL_STEP, 304
	.set SL_LOOP_EXIT, 312
	.set SL_REFRESH_N, 320
	.set SL_DEFER_CAP, 324
	.set SL_WB_N, 328
	.set SL_WB_BYTES, 332
	.set SL_FILL_OFF, 336
	.set SL_FILL_LEN, 344
	.set SL_CANARY, 352			# K_FEXEC: the program's stack-protector canary, put at fs:0x28 of every thread
	.set SL_VICTIM, 360			# K_RESIDENT: a class-0 chunk to drop first (its pool page freed for this one), 0 none
	.set SL_REQ_BYTES, 368
	.set SLOT_REPLY, 2048
	.set SR_SEQ, 0
	.set SR_STATUS, 8
	.set SR_EXIT_KIND, 12
	.set SR_EXIT_RIP, 16
	.set SR_EXIT_AUX, 24
	.set SR_RUN_NS, 32
	.set SR_FETCH_NS, 40
	.set SR_WB_NS, 48
	.set SR_TOTAL_NS, 56
	.set SR_WB_N, 64
	.set SR_DEFER_N, 68
	.set SR_THREADS_RAN, 72
	.set SR_SIGINFO, 76			# a fault's signal number | si_code << 8 (X_FAULT, X_REFUSED)
	.set SR_FREE_BYTES, 80
	.set SR_BYTES, 88
	.set SLOT_MAIL, 3072
	.set SM_ADDR, 0
	.set SM_LEN, 8
	.set SM_SEQ, 16
	.set SM_ACK, 24
	.set SM_STATUS, 32
	.set SM_BYTES, 40
	.set SLOT_PROGRESS, 3136
