# vpu_fexec.h: protocol v3, the slots

The contract between a host thread and a slot process on the card
([`sched.md`](sched.md)), beside the legacy contract of
[`vpu_proto.h`](vpu_proto.md) (kinds 1 to 8 on the `REQ` and `REPLY`
lines, which stay as they were). Its assembly mirrors are
[`proto.inc`](proto.md) on the card and the preload's `state.inc` (stage
2); `tools/vpu-layout-check.c` compares every offset of the three.

## The window

| offset | name | what |
| --- | --- | --- |
| 448 | `VPU_OFF_SLOTSEQ` | one line: `uint16_t seq[32]`, slot s's doorbell at `448 + 2 s`; the dispatcher reads the line whole |
| 65536 | `VPU_OFF_SLOTS` | 32 blocks of 4 KiB, `struct vpu_slot_req` at 0, the reply at 2048, the demand mail at 3072, the progress word at 3136 |
| 48 MiB | `VPU_OFF_SLOTDATA` | 32 x 1 MiB, a slot's bulk data: register blocks in and out (0, 4096), the refresh table and bytes (8192, 16384), the write-back table and lines (272 KiB, 288 KiB), the deferred call list (528 KiB, 2048 x 128 bytes), the demand landing area (784 KiB to the end) |
| 80 MiB | `VPU_OFF_LOADAREA` | 16 MiB: blobs staged by the host for `K_LOAD` |
| 96 MiB | `VPU_OFF_RESIDENT` | 32 MiB: 16 chunks of 2 MiB in flight for `K_RESIDENT` |

Nothing of v3 lies above 128 MiB, where the backend's areas A, B and D
begin (`host/asm/ggml-phi/defs.inc`), so the backend and the slots share
a window.

## Kinds and exits

| kind | number | what (the stage that serves it) |
| --- | --- | --- |
| `VPU_K_PING` | 9 | nothing: the floor of a request (1) |
| `VPU_K_LOAD`, `VPU_K_UNLOAD` | 10, 11 | a translated function's blob into or out of the code arena (2) |
| `VPU_K_RESIDENT` | 12 | chunks of the program's memory pulled by DMA and mapped at their own addresses (2) |
| `VPU_K_FEXEC`, `VPU_K_RESUME` | 13, 14 | a function instance run, or continued after an exit (2) |
| `VPU_K_FLUSH` | 15 | the slot's private mappings dropped (2) |

A reply's `exit_kind` says how the instance left: `VPU_X_RET` (0) through
`VPU_X_LIMIT` (8): a return, a PLT or indirect call (the callee in
`exit_aux`), a locked instruction, a system call, a fault (the address in
`exit_aux`), an instruction the card cannot run, a split loop's head
reached (the loop in `exit_aux`), a full deferred list, a limit.

## The structures

`struct vpu_slot_req` (336 bytes, at the slot's start): `seq`, `kind`,
`flags`, `fn_id`, `entry` (an offset into the blob), `threads`,
`nstripes` and 16 `{lo, hi}` stripes, the split loop's `ind_reg`,
`bound_reg`, `step` and `loop_exit`, `refresh_n`, `defer_cap`,
`resident_hint`. The host writes every field, a fence, then the u16.

`struct vpu_slot_reply` (88 bytes, at 2048): `seq`, `status`
(`VPU_OK` or a `VPU_E_*`), `exit_kind`, `exit_rip`, `exit_aux`, `run_ns`,
`fetch_ns`, `wb_ns`, `total_ns`, `wb_n`, `defer_n`, `threads_ran`,
`free_bytes` (the card's `MemFree` when the reply was written: the host's
residency budget). The card stores the second line, a fence, then the
first line with `seq` in it; the host polls `seq`.

`struct vpu_slot_mail` (40 bytes, at 3072): the demand mail of stage 2,
the card asking (`addr`, `len`, `seq`) and the host answering (`ack`,
`status`), as the legacy `vpu_mail` did for the exec engine.

The progress word at 3136 is `defer_n`, card-written while an instance
runs, for the progressive deferred lists of stage 5.
