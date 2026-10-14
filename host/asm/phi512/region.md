# region.S: a region of a function run to its next exit

The path for the functions `seeds.S` has no plan for, which is every
function found at a fault (`xlfn.S`'s dynamic seeds): the blob runs on
card 0 from the fault's instruction to its next exit, and the host
continues the program natively from there.

```
region_run(uc rdi, seed rsi, entry rdx) -> eax 0 (the frame is set),
    else a failure code for the handler's line (1000 + the exit kind,
    2000 + a card status, 2001 a step)
```

## What a region does

1. The register file from the signal frame (`file_from_frame`), then
   what the host cannot hold from the last region's file out
   (`shadow_merge`): zmm16 to zmm31 and the masks whole; of zmm0 to
   zmm15 the upper 256 bits when the lower 256 are what the last region
   left (a VEX write on the host zeroes them otherwise).
2. The stack: the 64 KiB unit of rsp minus the red zone and the unit of
   rsp plus 8 KiB made resident (`wu_ensure`); below the frame's rsp
   the stack is the handler's own and is never written back (`WU_LO`).
3. Every resident unit compared with the program's memory
   (`wu_refresh`): one the host wrote since gets its shadow updated, its
   filled bit on the card cleared and a fill queued; the residency
   rounds run.
4. `K_FEXEC` with `FXF_IDSTACK` (the file's rsp is the program's stack
   at identity; the blob's `ret` is an exit, not the card's return
   stub) at the blob offset of the instruction.
5. The exit (the reply's fields are kept before any other request
   reuses the slot's reply):
   - `X_FAULT` with an address: the unit made resident with a shadow
     filled from the program's memory, the file as the card left it,
     posted again at the fault's instruction (the card's blob address
     from `cblob_tab`, filled by `card_load_seed`). A fault with no
     address is a general-protection fault, not a missing page: a
     failure.
   - `X_RET`, `X_CALL`, `X_JUMP`, `X_SYSCALL`: every unit pulled back
     (`K_PUSH` into a staging slot) and diffed against its shadow line
     by line over its mapped pages above the floor (`wu_writeback`); a
     changed line goes into the program's memory and the shadow. Then
     the frame from the card's file (`frame_from_file_full`: every
     general register, rsp as the blob left it, rip where the blob
     said the host resumes, the flags from the raw `lahf`/`seto` word,
     xmm0 to xmm15 and their ymm halves), the file kept as the shadow.

The unit table holds up to 1024 units with 64 KiB shadows in a 64 MiB
arena; the readable and the writable pages of a unit come from
`copy_mapped` (`copy_mapped_pages`, `copy_mapped_wpages`: a bit per
4 KiB page) at residency and again at every refresh, so a page the
program unmaps or protects after a region is never compared, and a
line is written back only into a page the program can write (the host
died storing into a library's read-only page before) (the narrow suite's page-end check
protects its second page after the load; before this the host wrote the
line into it and died, 2026-10-13).

Verbose: a line per region (the exit kind, where the host resumes, the
faults, the units, the lines written back, the time) and, on a fault,
the card's exit rip, the address, the signal and code, the blob's card
address.

## State (2026-10-13 night)

`tools/avx512-region-test.c` passes whole on card 0 (both kernels, 4
regions), as do the form suites `tools/avx512-f-forms-test.c` (42
checks) and `tools/avx512-narrow-test.c` (66 checks, 97 regions): the
stage-3 recipe gate. The silently wrong regions of the day were the
scratch-register moves of `blob.S` and `mvex.S` with the register's
extension in REX.B instead of REX.R (r8 to r15 moved rax), found by
decoding a blob against the register probes.
