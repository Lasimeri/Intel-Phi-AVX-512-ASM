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

## An instance split over the slot's pool (2026-10-13, later)

A `K_FEXEC` whose request carries a split (`ind_reg`, `bound_reg`,
`step` not 0) runs as `threads` slices (at most the slot's pool plus
this thread: 114 with `-C 57 -T 2`): the landed file is kept in
`fx_base`, each slice's context (`fx_ctx`, one per thread, 2304 bytes)
is a copy with the counter register at the slice's first element and
the bound register at its last plus one (the elements divided evenly,
rounded up to a step; a slice past the end is marked returned and
skipped), its own run stack (`FX_STACK` each, `(MAX_POOL + 1)` of them)
with the return stub on top, and `fx_slice` enters it through `fx_enter`
on its pool thread (`vpu_pool_map`; the last slice on this thread). The
exit is the first slice's that did not return normally, else `X_RET`;
the file out is the last slice's; `threads_ran` says how many ran. A
step of 0 is one slice with the file as it is (no split), run on this
thread without waking the pool (5 ms when it has parked). With
`-s 1000` the pool spins a second after a job, so a session's requests
find it awake.

A single slice (step 0) runs on pool thread 0, through `vpu_pool_map` with
two slices of which the second is empty, never on the slot's control
thread (2026-10-13: that thread's core is the control plane's).

## In-card calls (2026-10-14)

Before this, every call in a blob, direct or through a pointer, left the
card (`X_CALL`): llama.cpp's expert path calls `vec_dot` through a
pointer once a row, which made a token millions of regions. Now a call
site (host `blob.S` `.Lincall`) puts the callee's host address in
`FX_S_XFER`, its own in `FX_S_SITE` and the host return address in
`FX_S_RETA`, then `call *%fs:FX_S_INCALL`:

- `fx_incall` looks the callee up in `fn_htab` (4096 entries of {host
  function address, blob entry}, filled by `K_LOAD` from the request's
  `fill_off` = the function's host address and `fill_len` = its entry's
  blob offset, emptied by `fexec_flush` at `K_FLUSH`). A hit pushes
  {host return, blob return} on this thread's shadow stack
  (`fx_shadow`, 4 KiB a thread, 4 KiB aligned: 255 frames), writes the
  host return address over the blob's on the program's stack (so the
  stack is what a native call leaves, and any exit hands the host a
  state it can run), and jumps to the callee's blob. A miss, or 255
  frames, returns to the site, whose `X_CALL` exit follows as before.
- A translated `ret` pops into `FX_S_SITE` and jumps to `*FX_S_INRET`:
  `fx_inret` returns into the calling blob when the shadow stack's top
  is that return address, else ends the region with `X_RET` there.

Only r11 (dead at a call and at a return in the SysV convention) and the
scratch words are touched; rax and rcx go through `FX_S_T0`/`FX_S_T1`
(rax carries a variadic call's vector count, rcx an argument).
`fx_enter` empties the shadow stack at every run's start, so a region
re-posted after a fault inside a callee (the host finds the callee's
blob: `region.S blob_at`) leaves the card at the callee's `ret` and the
host goes on natively in the caller. `PHI512_INCALL=0` on the host
builds blobs without any of this.
