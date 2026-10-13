# 2026-10-13: the program's memory resident on the card (K_RESIDENT)

Stage 2's second increment of the wrapper's restart: chunks of the host
program's memory live on the card at the program's own addresses
([`card/vpu/resident.md`](../../card/vpu/resident.md)), a function run
by a slot reads and writes them there, and the host gets back the ranges
it declared ([`card/vpu/sched.md`](../../card/vpu/sched.md), `wb_ranges`).
Measured with [`host/asm/phi-vpu/resident.S`](../../host/asm/phi-vpu/resident.md)
on the GPU rack, worker `-v -S 12 -C 4 -R 64 57` (a pool of 64 huge
pages, 128 MiB).

## What ran

Two chunks of 2 MiB staged in the window's RESIDENT area and made
resident at `0x7e0000000000` (float `i` at dword `i`) and the next chunk
(zeros); a blob of five instructions (`vmovaps zmm0, [rdi]`, `vaddps
zmm0, zmm0, zmm0`, `vmovaps [rsi], zmm0`, `mov rax, [rdi + 4096]`, `ret`)
loaded with `K_LOAD`; `K_FEXEC` runs with `rdi` and `rsi` the two
addresses and one write-back range of 64 bytes at `rsi`. Checked every
run: the register file out (zmm0 = twice the pattern, rax = the
pattern's quadword at 4096), the write-back line in `SD_WB`, the reply
(`X_RET`, `wb_n` 1, status 0).

## Measured

| step | card 0 |
| --- | --- |
| `K_RESIDENT`, 2 MiB, pattern chunk | 774.7 us, 922.5 us (two runs) |
| `K_RESIDENT`, 2 MiB, zero chunk | 590.6 us, 591.6 us |
| `K_FEXEC` with one write-back line, 2000 runs | min 15.4 us, median 17 us, p99 26 us, max 400.9 us, 0 wrong |
| `K_FEXEC` without memory (phi-vpu-fexec, same worker), 2000 runs | median 15 us, p99 24 us |

A chunk crosses at about 2.3 to 3.5 GB/s: the DMA engine's three
descriptors straight into the pool page's frame (`cdma_submit_phys`),
no copy on the card. The first chunk after a worker start is slower (the
host's own page cache of the staging area and the pool page's first
touch). The write-back of one line costs about 2 us over a plain run.

With the worker's second `-v` (a log line per job on the host-backed
disk) the same runs read 23 us median and 54 us p99: measure with one
`-v`.

## What this settles

- A shared huge-page pool mapped before the fork is one physical set
  for every slot process: the DMA engine fills a page once and each
  process `mremap`s it to the program's address when it first needs it
  (this process's view alone moves).
- `/proc/self/pagemap` gives the frames from a root process on the card
  (the first entry of each huge page), as `cdma.S` already relied on.
- The card's `vaddps` did not flush denormals: with the test's first
  pattern (integers `i` as float bit patterns) 0xf + 0xf came back 0x1e,
  the exact denormal sum. The research memo's "DAZ/FTZ always" is not
  what this add did; to be checked against the MXCSR the worker runs
  with before anything relies on either.

## Bugs on the way

- `cdma_submit_phys` appended after cdma.S's `.rodata` strings landed in
  read-only data (nm type `R`): the dispatcher faulted at the symbol's own
  address (`segfault at 41c095 ip 41c095 error 15`). `.text` before it.
- The dispatcher seeds `slotseq_seen` from the live line, so a host
  program that starts its sequence numbers at 1 again writes the u16 the
  previous program left and is never seen. The drivers now open a slot
  by writing u16 0 and clearing the stale reply number; the dispatcher
  takes a change to 0 as no job.
- The common `w_hex` wants the digit count in `cl`; without it the digit
  loop ran off the stack (`w_hexn` instead).
- `movq $imm, mem` and `cmpq $imm, reg` take a sign-extended 32-bit
  immediate: program addresses and nanosecond counts need `movabsq`.

## Next

The preload library's side (stage 2's third increment): the SIGILL
handler, the residency table and placement on the host, and hand-seeded
blobs for the seamless test's three kernels, which is the gate of
stage 2 (`tools/avx512-seamless-test.c` bit-exact at 65536, 1M and 16M
through the slots).
