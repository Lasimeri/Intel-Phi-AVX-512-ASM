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
2. The stack: the floor is rsp minus 128 (the red zone), and 16 KiB
   lower (`STACK_SLACK`) when the handler runs on its alternate stack,
   clamped to the stack mapping's start: a region may move rsp down and
   write there (a call's stack arguments: `llama-server`'s context
   parameters reached `llama_init_from_model` with `n_batch` 0 because
   the line below rsp minus 128 never came back, 2026-10-14; a region
   that ends below the floor is reported). The units of the floor, of
   rsp minus 128, of rsp and of rsp plus 8 KiB made resident
   (`wu_ensure`), then every resident unit of the mapping holding rsp
   floored (`wu_stack_floors`) at the floor, or at its end when it lies
   wholly below: below the frame's rsp
   minus the red zone the stack is the SIGILL handler's own (it has no
   alternate stack) and is never written back (`WU_LO`). A floor that
   drops marks the range between for a whole refresh (`wu_set_floor`).
   The fault path floors again (a stack unit a fault brought in). Before
   2026-10-14 only the unit of rsp minus 128 took the floor: when that
   address fell into the unit below, the unit holding rsp kept a higher
   floor from an earlier region and the lines the region wrote between
   never came back (a `std::regex` bracket matcher built on the card,
   "0 line(s) back", a null store in the host; ASLR decided the run).
3. Every resident unit compared with the program's memory
   (`wu_refresh`: the reads and compares of the units by card 0's 16
   workers and this thread at once, [`pool.md`](pool.md), each changed
   line marked in the unit's bitmap; then the marked lines into the list
   unit by unit here): one the host wrote since gets its shadow updated, its
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

## The write-back by bytes, one snapshot (2026-10-14)

A line the card changed goes back byte by byte: only the bytes where
the card's copy differs from the shadow are written into the program
and the shadow, run by run, through `/proc/self/mem` (`wb_line_apply`:
the line is read with `pread`, each run written with `pwrite`), never by
the host's own loads and stores: a page another thread unmapped during
the region fails the call instead of faulting the host (an HTTP
thread's region read a line above its stack that was gone, 2026-10-14). `llama-server` has more threads than the one in a
region (`common_log`'s worker, 130 in all at model loading); a whole
line copied back undid what another thread wrote to the same line
during the region, and glibc stopped on "corrupted double-linked list"
where vocabulary strings shared lines with malloc's free-list links.
The shadows of the units a `K_RESIDENT` fills come from the bytes
staged for the card (`wu_shadows_from_stage`, called by
`card_resident_post`), not from an earlier read: two reads differ when
another thread writes between them. A probe counts the lines where
memory no longer matches the shadow at the write-back
(`stat_wb_conflicts`; under verbose a line per conflict with the
memory, shadow and card words).

A unit whose changed lines overflow the refresh list is refilled whole
(a `K_RESIDENT` from a new read of the program's memory), and the lines
it had already put into the list are taken back (`wu_refresh` keeps the
list's count, bytes and last range's length at each unit's start):
the card applies the list after the refill, so a line kept from the
first read landed over the second while the shadow held the second,
and the write-back put the first read's bytes back. That reverted the
main thread's malloc metadata from a region of `common_log`'s worker
thread (a write-back conflict of three different values, the card's
the oldest) and glibc stopped at 11,955 regions.

## The exit kind and X_HOST (2026-10-14)

`.Lrg_exit` reloads the exit kind from its slot: the register held the
reply's signal word, so every exit without a signal had been taken as a
resume, `X_REFUSED` included. `X_HOST` (an instruction the host runs,
[`blob.md`](blob.md)'s lazy sites) resumes like `X_JUMP`; a region whose
exit is `X_HOST` at the very address it was posted at means the host
faulted on that instruction too, and the program dies instead of
looping.

## The heap walk (a probe, `PHI512_HEAPCHECK=1`)

`heap_walk` walks glibc's main arena from the `[heap]` mapping's start
by the chunks' size fields (a size of at least 32, a multiple of 16,
the next chunk within the mapping, the last ending at its end; for a
chunk the next one marks free, that its size is the next one's
`prev_size` and that an `fd` or `bk` inside the heap links back to it,
glibc's "corrupted double-linked list" condition) at every region's
start and after every write-back, and reports the first break once,
with the check that failed and the chunk's first 64 bytes: the region's number (the n-th `region exit` line of the verbose
log), whether native code before it or its own write-back broke the
heap, the chunk, its size field and the chunk before. glibc finds such
damage only when it next frees or merges the chunk. Only the main
thread's regions walk: from another thread's handler the main thread may
be inside malloc, and a list caught mid-update reads as broken (the
first report, after a region of `common_log`'s worker thread, was
that). Checked against a
program that breaks a chunk's size natively between two regions
("before region 2", the chunk and its field exactly).

## The progress line (2026-10-14)

`heartbeat`, called from region_run after each region, writes one line to standard error at most every 5 s, always on (not gated by `PHI512_VERBOSE`):

```
phi512: progress at 65 s: 6905 regions (79/s), 99.9% of the time in regions, 41 fault(s), 33483 write-back line(s); last region in ggml_backend_buffer_init
```

Seconds count from the constructor (close to llama's own log clock). The rate and the share are over the interval since the previous line; the share is host wall time inside region_run. Reason: under the preload llama-server's loader prints nothing for minutes at its default verbosity, and two runs were killed as hung on 2026-10-14 while card 0 was 87.7% busy.
