# defs.inc: the preload library's constants

| group | what |
| --- | --- |
| syscalls, signals | `rt_sigaction`, `rt_sigreturn`, `sigaltstack`, `pread64`; `SIGILL` 4; `SA_SIGINFO`, `SA_ONSTACK`, `SA_RESTORER`; the 32-byte kernel `sigaction` |
| the signal frame | `UC_GREGS` 40 (glibc's `REG_*` order: `G_R8` 0 .. `G_RIP` 16, `G_EFL` 17), `UC_FPREGS` 224, `FX_XMM0` 160 in the FXSAVE area, `XSAVE_HEADER` 512 (XSTATE_BV, YMM bit 2) |
| register numbers | `R_RAX` 0 .. `R_R11` 11: ModRM order, the order of `vpu_regs.gpr` and the seeds' operand registers |
| limits | `MAX_CARDS` 16, `CHUNK` 2 MiB, `STAGING_SLOTS` 16, `RES_TAB_CAP` 4096 entries a card (`RES_ENTRY` 32: key, state, `RE_PAGE`, `RE_CLASS`), `REQ_TIMEOUT_NS` 5 s |
| a card (`CD_*`, 128 bytes) | window base, slot, the slot's block and SLOTDATA, next sequence number, next staging slot, the residency table's header (`CD_TAB`, the common table module's 32-byte header), the card's index |
| a seed (`SD_*`, 128 bytes) | name, blob, length, entry, `SD_IND`, `SD_BOUND`, `SD_STEP`, `SD_RET_XMM0`, four operands (`OP_REG`, `OP_STRIDE`, `OP_KIND`, `OP_LEN`), the resolved address and length |

The card-side layout (`REGS_*`, `SL_*`, `SR_*`, `SD_*`, `OFF_*`, the
kinds) comes from [`../../../card/vpu/proto.inc`](../../../card/vpu/proto.md),
included beside this file, and is checked against `vpu_fexec.h` by
`tools/vpu-layout-check.c`.

2026-10-13, later: `RE_FILLED` (the 64 KiB coverage bitmap), `UNIT`,
`NEED_MAX` 1024 and the need entry (`NQ_*`), `PUSH_MAX` and the push
entry (`PQ_*`), the card's pending request (`CD_PEND_*`, `CD_POSTED`).
