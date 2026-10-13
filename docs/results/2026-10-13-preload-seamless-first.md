# 2026-10-13: the assembly preload runs the seamless test on four cards

Stage 2's third increment: `host/asm/phi512/` (the SIGILL handler, the
cards, residency and write-back from the host side, hand-translated
blobs for `tools/avx512-seamless-test.c`'s three kernels) and the card
worker's split of an instance over the slot's pool
([`card/vpu/fexec.md`](../../card/vpu/fexec.md)). Measured on the GPU
rack, 2026-10-13 07:40, workers `-S 1 -C 57 -T 2 -R 128 -s 1000` on
cards 0 to 3 (one slot process a card, 114 pool threads, a 256 MiB pool,
the pool spinning a second after a job), the test compiled on the rack
with gcc `-O2 -mavx512f -mno-avx512vl -mno-avx512bw -mno-avx512dq
-mno-avx512cd` (the kernels `noinline`), run as `PHI512_VERBOSE=1
LD_PRELOAD=libphi512-asm.so ./st N` from
`/mnt/raid5/phi/bench/restart-2026-10-13/`.

## Correct

| elements | poly (31 fmadd a vector) | dot (fmadd + reduce) | ints (compare, mask, mullo) |
| --- | --- | --- | --- |
| 65536 | 17.8 ms, every lane bit-identical | 0.35 ms, bit-identical | 0.71 ms, every lane identical |
| 1048576 | 35.3 ms, bit-identical | 10.6 ms, bit-identical | 29.3 ms, identical |
| 16777216 | 314 ms, bit-identical | 137 ms, bit-identical | 235 ms, identical |

poly and ints split over four cards (four stripes, 114 slices each);
dot is one instance on card 0 (a reduction). 10 of 10 runs at 65536
PASS.

## Not fast: where the time goes

| elements | chunks made resident | residency | outputs fetched | the cards' compute a request (phitop) |
| --- | --- | --- | --- | --- |
| 65536 | 12 | 16.8 ms | 1.2 ms | 0.04 ms |
| 1048576 | 32 | 44.7 ms | 19.9 ms | 0.32 ms |
| 16777216 | 212 | 238 ms | 286 ms | 0.62 ms |

phitop on card 0 while the 16M run looped (`withtop.sh`): VPU busy 16%,
228 threads 0.9% busy, the dispatcher's thread and one pool thread the
only ones visible. The stage-2 gate (65536 in 1 ms, 1M in 3 ms, 16M in
25 ms on four cards) is not met: a 2 MiB chunk costs 0.65 to 0.9 ms
(the link's floor, staging copy then DMA), chunks are filled whole and
one card at a time, outputs come back in 64 KiB round trips.

Next, in order of payoff: chunks only written by the call not filled
at all; partial fills (a 64 KiB coverage bitmap a chunk); residents
posted on all four cards at once; outputs pushed by the card's DMA
engine in whole pieces; and, now that the host boots with
`iomem=relaxed`, host writes straight into the pool pages through a
write-combined BAR0 mapping (`/sys/bus/pci/devices/*/resource0_wc`,
root-owned today).

## Bugs on the way (each cost a run of the whole chain)

- `res_flush` zeroed the shared residency table whole, frames included
  (`RT_PHYS`, read once at `res_init`): every later fill was a DMA to
  physical address 0, the pages stayed zero, every result was computed
  on zeros with no fault. The flush keeps the frames; a pull without a
  frame is refused.
- The staging copy clipped to the mapping holding the chunk's start,
  which is unmapped when an array begins mid-chunk: nothing staged.
  Then a plain copy of every readable mapping raised SIGBUS on a file
  mapping past its file's end (5 of 6 runs): the copy goes through
  `pread` of `/proc/self/mem`.
- `now_ns` clobbers rcx, rdx, rsi, rdi (its contract): called after the
  copy's operands were loaded, K_PUSH copied from garbage and the slot
  process died.
- The ints blob's constants at an offset of 2 mod 4 in the arena: `#GP`
  (fault address 0) on the first broadcast load; blobs are 64-aligned.
- KNC's `cdab`/`badc` swizzles named by result order: the reduce's last
  two steps swapped gave the sum one bit off.
- The worker's `-S 1 -C 57` was clamped to 0 slots (the wide pool kept
  a core); it now keeps core 56 beside the slot, where its threads sleep.
- A pool that parks on a futex after `spin_ns` costs 5 ms to wake: a
  session runs with `-s 1000`.
