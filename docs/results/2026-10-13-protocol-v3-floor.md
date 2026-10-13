# 2026-10-13: protocol v3, the floor of a request on four cards

Stage 1 of the wrapper's restart (the plan of 2026-10-13: the
instruction-region intercept rewritten in place, assembly throughout):
the slots of [`card/vpu/vpu_fexec.h`](../../card/vpu/vpu_fexec.md) and
the slot processes of [`card/vpu/sched.S`](../../card/vpu/sched.md),
measured with [`host/asm/phi-vpu/ping.S`](../../host/asm/phi-vpu/ping.md)
on the GPU rack (EPYC 7742, four Xeon Phi 3120 at PCIe Gen2 x8, cards
booted by the stack's `phi-up.sh`, host-memory windows of 2 GiB).

## The gate

A request with nothing to do, from the host thread's store of its slot's
u16 in the SLOTSEQ line to the reply's sequence number in the slot: median
at most 8 us and p99 at most 20 us with 12 slots at once. Before this
work a request through the `REQ` line cost 15 us of pool dispatch plus
the 2.36 us doorbell, one at a time.

## Measured

Worker `phi-vpu-worker -v -S 12 -C 4 57` (12 slot processes of 4 cores,
one thread a core; the wide pool for the legacy kinds on the 9 cores
left), `phi-vpu-ping --card N -n 10000 --slots 12 --timeout 1000`:

| run | slots | per slot | median | p99 | min | max | timeouts |
| --- | --- | --- | --- | --- | --- | --- | --- |
| card 0 alone | 1 | 2000 | 4 us | 6 us | 3.5 us | 245.6 us | 0 |
| card 0 alone | 12 | 10000 | 7 us | 12 us | 3.4 us | 169.9 us | 0 |
| cards 0, 1, 2, 3 at once (four ping processes on the host) | 12 each | 10000 | 7 us on every card | 13 to 15 us | 3.0 us | 1325 us (one sample) | 0 |

The four-card run is 480,000 requests answered by four cards driven
from the host at the same time; every card's median is 7 us.

The legacy matrix service on the same worker (`phi-vpu --card 0
matmul-check --repeat 3`): every type ok. With `-S 12 -C 4` it runs on
the 9-core wide pool: 27.3 to 32.0 GFLOP/s at n 8 and 64 (fused). With
`-S 0` (the worker as it was, 114 threads) 139.7 to 144.3 GFLOP/s: byte
for byte today's behaviour, which the backend keeps using until the
wrapper replaces it.

## What the floor is made of

| step | cost |
| --- | --- |
| the host's stores (request block, fence, u16) | under 0.1 us |
| the dispatcher's poll: one 64-byte uncached load of the SLOTSEQ line, plus one of the legacy `REQ` line | about 1.5 us an iteration |
| the hand-off: one store into the slot's job line of the shared page; a futex wake only if the slot had parked (never, under load) | under 0.5 us |
| the slot: one 64-byte load of its request line, the reply built, two 64-byte vector stores (the line with seq last) | about 2 us |
| the host sees seq (a `pause` poll of its own cached line, invalidated by the PCIe write) | about 1 us |

Two designs were measured on the way and replaced:

- the dispatcher reading each posted slot's request line itself and
  copying kind and flags into the job line: 12 slots median 19 us,
  p99 47 us, the later slots (5 to 11) at 26 to 28 us because the
  dispatcher visits slots in order. Now the slot reads its own line, on
  its own core, in parallel with the others.
- the reply as 16 scalar uncached stores (a diagnostic when slot 0 died):
  1 slot median 5 us against 4 us with the two vector stores.

## Bugs found on the way (and their symptoms, for the next time)

- `segfault at 0 ip 0` on the slot's CPU: a `je 1f` whose target label
  had been deleted with a stray line jumped into `sched_wait`'s loop,
  which ended in `popq %rbx; ret` on a stack it never pushed.
- `general protection fault ip:414204` (`phi_copy64`) at the worker's
  start: `slotseq_seen` declared without `.balign 64`; `phi_copy64` moves
  whole aligned lines.
- The card's kernel log names both (`dmesg` on the card), with the CPU.
- `rsync` to the rack needs `-s` (protected args): the rack's fish login
  shell turns `Intel\ Phi\ AVX-512` into a literal directory name.

## Also learned

- A forked process on the card runs vector instructions in its main
  thread with no setup (the slot's `phi_copy64`).
- The dispatcher never sleeps while slots exist (its `nanosleep` branch
  is skipped), so CPU 0 of a card with slots is always polling; the
  readiness word is re-asserted every 64 polls, which `wait_ready`'s 2 s
  covers.
- Starting the co-processor turns swap off on `/dev/phiblk1` on every
  card (the window is the same host-memory region): the user wants 2 GB
  of swap on every card beside the window, which needs a larger
  host-memory region with the swap on its upper half (open, the stack's
  side).
