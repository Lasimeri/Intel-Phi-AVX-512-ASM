# 2026-10-13: the seamless test faster, the scheduling on the card, the first llama.cpp fault

The day after [the preload first ran the seamless test](2026-10-13-preload-seamless-first.md)
(correct, slow): what made it faster, what the card's scheduler was doing,
and the first run of the real target. GPU rack, four cards, host booted
with `iomem=relaxed` (07:07), workers `-S 1 -C 55 -T 2 -R 128 -s 1000`,
`PHI512_VERBOSE=1 LD_PRELOAD=libphi512-asm.so ./st N` from
`/mnt/raid5/phi/bench/restart-2026-10-13/`, phitop sampled on card 0 while
each size looped (`withtop.sh`).

## The seamless test now

| elements | poly | dot (one slice) | ints | before (morning) | gate |
| --- | --- | --- | --- | --- | --- |
| 65536 | 2.42 ms | 0.94 ms | 1.21 ms | 17.8 / 0.35 / 0.71 | 1 ms |
| 1048576 | 7.83 ms | 13.5 ms | 7.17 ms | 35.3 / 10.6 / 29.3 | 3 ms |
| 16777216 | 65.8 ms | 175 ms | 56.5 ms | 314 / 137 / 235 | 25 ms |

Every lane bit-identical at every size, four cards, 110 slices a card;
10 of 10 at 65536. The phases of a call (verbose line, 65536 poly):
resident 0.94 ms (8 fills of 64 KiB units, two rounds over four cards),
run 1.28 ms of which the cards' own run 33 us, push 0.19 ms. The gate's
times are not met: what remains is the latency of each request, about
0.3 to 1.2 ms, not the cards' work.

## What changed

| change | effect |
| --- | --- |
| residency by 64 KiB units with a coverage bitmap a chunk; a chunk the call only writes gets a page without a fill; residents posted on all four cards at once | 65536: 12 whole chunks (16.8 ms) became 8 fills of 768 KiB (0.9 ms) |
| `K_PUSH` by the card's DMA engine into window staging slots, 2 MiB pieces, four cards at once | 64 MiB of outputs in 18 to 20 ms (3.2 GB/s) instead of 131 to 211 ms through the slot's posted stores |
| the slot's control thread on a core of its own | a 114-slice dispatch 3.5 ms to 40 us; see below |
| a single-slice instance on a pool thread, not the control thread | dot at 1M on the card 53 ms back to 4.6 ms |
| the request copied whole on the card (six lines) | the split fields (fifth line) had been read from stale memory past a 64-byte buffer |
| the need queue 64 to 1024 a card, overflow fails loudly | 16M dot needs 65 chunks on one card; the 65th was dropped and the card faulted on it |
| the worker reserves `[0x550000000000, 0x7ff000000000)` before its own mappings | a program's arrays at `0x7f...` landed on the slot's own thread stacks (segfault at 1M) |
| the SLOTSEQ word `kind << 11 \| seq & 0x7ff` | `K_PUSH` = 16 did not fit four bits: the dispatcher saw kind 0 |

## The card's scheduler

The worker's dispatch trace (`-t 1`) read "last thread sees it 1.0 to
1.9 ms, last end to seen 2.8 ms" for a 114-slice dispatch whose slices
took 20 to 80 us. The slot's main thread was pinned to CPU 4 (core 0,
hardware thread 3), the same CPU as pool thread 57; two spinning threads
on one CPU are time-sliced by the card's kernel at its tick. Moved to a
core of its own: 38 to 48 us a dispatch. Then on core 56 beside the
dispatcher's PCIe polling it ran 5 to 12x slower (dot at 1M: 4.5 to 53
ms; the resident test's round trip 19 to 119 us): the control thread now
takes core 55's hardware thread 0 (CPU 221), the pool cores 0 to 54,
core 56 stays the dispatcher's. CPU numbering on the card: core c's
hardware thread h is CPU 4c + h + 1 (c < 56); core 56's are 225, 226,
227 and 0. With the trace on, its log line is written inside the run's
timing: measure without `-t`.

## The real target, first contact

`llama.phi/build-avx512f` (`-mavx512f -mno-avx512vl -mno-avx512bw
-mno-avx512dq -mno-avx512cd`, 13774 zmm instructions in
`libggml-cpu.so`, 211 functions of which 102 of the matmul family and 8
named bf16) with the BF16 Qwen3.8 Flash-Next shards
(`/mnt/raid0/Qwen3.8-Flash-Next-GGUF/BF16/`, 8 files; the rack has 251 GB
of RAM, the model streams from raid0):

- bare on the EPYC 7742: SIGILL at once (no AVX-512 on the host).
- under the preload (`PHI512_CARDS=0,1,2,3 LD_PRELOAD=libphi512-asm.so
  llama-simple -m shard1 -n 4 -ngl 0 The`): "4 card(s), the handler
  installed; seeds: 3", then "SIGILL at ... is not inside a seeded
  function" at `libggml-cpu.so` offset `0x1f63b`, inside
  `ggml_backend_cpu_reg_get_device`: an EVEX instruction gcc put into
  backend-registration glue (a struct store), before any kernel. The
  translator of stage 3 must cover glue as the plan's function regions do.
- the software reference (the AVX2 twin `build-phi512-cpu`, 128 threads,
  greedy): load 37.6 s, prompt 460 ms a token, decode 562.75 ms a token
  (1.78 tokens/s), text "The Intel Xeon Phi coprocessor runs a program by
  first loading it onto the coprocessor and then executing it there. The
  coprocessor is a PCI-Express device that contains its own memory and a
  Linux" (`baseline-twin-bf16.out`). The wrapper's run has to produce
  that text and beat that rate, when stage 3 lets it run.

## Next

Stage 3: the decoder and translator in assembly, driven by the faults the
real program takes (lazy, per function); the footprint planner that gives
each function its operand ranges and split registers (the seeds' table,
produced instead of written). Latency: the K_FEXEC round trip (1.2 ms for
33 us of card work) is register-block DMA plus placements (each
`mremap` a TLB shootdown over 110 CPUs) plus the reply; placements
coalesced already, the rest to measure apart.
