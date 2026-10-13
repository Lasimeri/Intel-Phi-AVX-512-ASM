# fexec.S: a slot process runs a function

The engine behind `K_LOAD` and `K_FEXEC` of protocol v3
([`vpu_fexec.md`](vpu_fexec.md)), the first increment of stage 2 of the
restart (2026-10-13). It replaces, for the slots, what [`exec.S`](exec.md)
does for the legacy `K_EXEC`: enter the program's code with a full
register file, come back with it. What it does not do yet: map the
program's memory (residency, the next increment) or split a loop over
the slot's cores (every run is on the slot's main thread).

## K_LOAD

The host stages a position-independent blob (a translated function:
exit stubs, rip map and relocations are the host's business at this
stage) in its slot's 512 KiB part of `LOADAREA` and posts `fn_id` and the
byte count in `entry`. `fexec_load` copies the bytes in 64-byte lines
through the window's mapping into this process's arena (16 MiB,
read-write-execute, a bump allocator; an id loaded again gets new bytes)
and answers with the blob's address in `exit_aux`. `E_ALLOC` when the
arena or the 256-entry table is full, `E_REQUEST` for an empty or
oversized blob.

## K_FEXEC

1. `sched.S` had the dispatcher pull the slot's register block
   (`SD_REGS_IN`, 2368 bytes) with the DMA engine into the slot's 64 KiB
   of the landing area before the hand-off; the slot waited on the
   engine's status word (`land_wait`).
2. `fexec_run` copies the file into its context (`fx_ctx`: the
   `vpu_regs` layout of `vpu_exec.h`, then this process's saved stack
   pointer, the exit, the kind, the raw flags), sets `rip` to the blob's
   address plus `entry`, and `rsp` to this process's run stack (1 MiB)
   with the return stub's address on top.
3. `fx_enter`: the callee-saved registers pushed, the stack pointer kept
   in the context, the vector unit loaded (32 zmm, 8 k), the flags, the
   fifteen integer registers, `rsp`, and a `ret` into the blob with `rax`
   loaded last.
4. The blob's `ret` lands in `fx_ret_stub`: `rax` and the flags kept
   through the fs scratch words, the integers stored, `rip` the stub's
   own address, kind `CTX_KIND_STUB`, this process's stack restored, the
   vector unit stored, back to `fexec_run` (`X_RET`). A fault in the blob
   goes to `fx_on_fault` or `fx_on_ill` on the alternate stack:
   `fx_leave` copies the frame's registers into the context and points
   the frame at `fx_exit_stub`, which stores the vector unit after the
   kernel's return (patch 0030 keeps it) and comes back the same way
   (`X_FAULT` with the address in `exit_aux`, or `X_REFUSED` with the
   instruction's `rip`).
5. The file as left goes to the slot's `SD_REGS_OUT` through the window
   (36 lines); the reply carries `exit_kind`, `exit_rip`, `exit_aux`,
   `run_ns`, `threads_ran` 1.

Outside a run the handlers put the signal back to its default action,
so a bug in this file ends the slot process the normal way (the card's
`dmesg` names the address, as it did for sched.S's first bugs).

## Measured

`host/asm/phi-vpu/fexec.S` ([`../../host/asm/phi-vpu/fexec.md`](../../host/asm/phi-vpu/fexec.md))
runs a three-instruction blob (an MVEX `vaddps`, a `lea`, `ret`) and
checks the file; the numbers are in the stage 2 record under
`docs/results/`.
