# sched.S: the slot processes of protocol v3

Protocol v3 ([`vpu_fexec.h`](vpu_fexec.md)) gives a host thread a slot of
the card's window and a process on the card that serves it, so twelve
host threads can have twelve function instances running on twelve
groups of cores at once, instead of one request at a time through the
`REQ` line. This file is the card side of that: the fork, the
dispatcher's poll, the hand-off and the reply. It is stage 1 of the
wrapper's restart (the plan of 2026-10-13); the function engine that a
slot will run ([`fexec.S`]) comes at stage 2, so today a slot answers
`K_PING` and refuses every other kind with `E_KERNEL`.

## Processes and cores

`worker.S` parses `-S slots`, `-C cores` and `-T threads a core`
(defaults 0, 4, 1). With `-S 0` nothing here runs and the worker is what
it was. Otherwise, after the clock calibration and the DMA channel's
open and before its own pool exists (a fork copies no threads),
`slots_start`:

1. maps one page of `SH_BYTES` shared and anonymous (`defs.inc`, `SH_*`):
   the card's free bytes and the slot count at its head, then a block of
   256 bytes per slot with the job line the dispatcher writes, the done
   line the slot writes and the slot's counters on a third line, so no
   line has two writers;
2. clamps the slots so their cores stay below core 56, which is the
   dispatcher's (CPU 0 is core 56's last hardware thread,
   [`vpu_worker.md`](vpu_worker.md));
3. forks once per slot; the child sets `slot_index`, `core_base =
   slot x cores` and `core_count = cores`, and goes to `sched_main`;
4. sets this process's `core_base` and `core_count` to the cores after
   the slots', where `pool_start` lays the wide pool for the legacy kinds
   (`main_loop` caps it at four threads a core of those).

`pool_start` and `create_thread` place thread `t` on core `core_base +
(t mod core_count)` in every process; `pool_thread` pins as before
(`pool_slot`). The window, the control area and the block device are
inherited mappings and descriptors; the DMA channel stays the
dispatcher's (a slot's pulls, when they come, go through it by the job
line).

## A request

| step | who | what |
| --- | --- | --- |
| post | host thread | the request block at `OFF_SLOTS + slot x 4096` (seq, kind, flags, ...), a fence, then its u16 at `OFF_SLOTSEQ + 2 slot` |
| see | dispatcher, `slots_poll` | one 64-byte load of the SLOTSEQ line (uncached: one PCIe read), compared with `slotseq_seen`; a moved slot gets its first request line read (one more load) |
| hand off | dispatcher | kind and flags into the slot's job line, a fence, the sequence number; `FUTEX_WAKE` when the slot had parked |
| run | slot process, `sched_main` | `sched_wait` returns the number; the kind runs (`K_PING`: nothing) |
| reply | slot process | the reply built aside (`reply_buf`): status, exit, timings, the card's free bytes, `threads_ran`, then seq; stored into the slot as two 64-byte lines, the second first, the line with seq last; the host spins on seq |
| count | slot process | its counters, then `SH_DONE_SEQ` |

`sched_wait` spins `SPIN_ROUNDS` looks with `delay` between them, and
after `spin_ns` without a job parks in a futex on the job word
(`SH_PARKED` set first, the word re-read after, so a wake is never
lost). The dispatcher never sleeps while slots exist: the host's posts
are seen only by its loop (`main_loop` skips its `nanosleep` then).

`slots_stats` runs every 64 idle polls: the dispatcher's own counters plus
every slot's, as one line at `OFF_STATS` (phitop's `vpu` line reads it,
[`vpu_proto.md`](vpu_proto.md)), the most recent `last_seq` among them
naming the last kind; and every 2048 calls `MemFree` of `/proc/meminfo`
into the shared page, which every reply carries as `free_bytes` (the
host's residency budget at stage 2).

## K_RESIDENT, the pool and the write-back (2026-10-13, later)

The dispatcher reads a `K_RESIDENT`'s request line (the kind rides in
the u16's top five bits), assigns a pool page and submits the DMA fill
straight into its frame ([`resident.md`](resident.md)); the page index
and the copy's sequence number ride in the job line (`SH_RES_IDX`,
`SH_PULL_SEQ`) and the slot waits for the copy (`res_wait`) and
replies with the index. Before a `K_FEXEC` the slot moves every resident
page it has not placed yet to the program's address (`res_map_all`),
and after the run `wb_ranges` copies the request's declared ranges
(`SL_WB_N` of `{addr, len}` in `SD_WB_TAB`, 64-byte aligned) into
`SD_WB`. A u16 of 0 is a host opening the slot (its sequence numbers
start again): recorded, no job. `K_PUSH` copies bytes of the program's
memory from this slot's view into `SD_WB`; `K_FLUSH` calls
`res_flush` ([`resident.md`](resident.md)).

## What it costs

The floor of a request is this file's work: a host store, one line read
per poll on the card, one line read of the request, a shared-memory
store and a wake at most, two posted 64-byte stores back, and the host's
poll. The gate of stage 1 is `phi-vpu-ping -n 10000 --slots 12`
([`../../host/asm/phi-vpu/ping.md`](../../host/asm/phi-vpu/ping.md)):
median at most 8 us, p99 at most 20 us. The numbers measured are in
`docs/results/` (the protocol v3 floor record).

## Limits

- At most `NSLOTS` (32) slots and 56 slot cores; `-S 12 -C 4` leaves
  cores 48 to 56 to the wide pool.
- A slot process's main thread sits on hardware thread 3 of its first
  core; with `-T 2` the pool's second thread on that core shares it.
- Kinds other than `K_PING` are refused until `fexec.S` lands.

## The control thread's CPU, the whole request, K_PUSH by the engine (2026-10-13, later)

A slot's main thread never shares a CPU with a spinning thread: with one
slot leaving cores free it takes the first free core's hardware thread 0
(`-S 1 -C 55`: CPU 221; the pollers of the block devices live on core
55's threads 1 and 2 only), else core 56's thread 1 when the slot leaves
only core 56, else its first core's thread 1. Two spinners on one CPU are
time-sliced by the card's kernel at milliseconds: a 114-slice dispatch
cost 3.5 ms flat before (the main thread sat on pool thread 57's CPU);
and a control thread beside the dispatcher's PCIe polling (core 56) ran
everything 5 to 12x slower. The dispatcher and the slot both copy the
whole request block (six lines, `SL_REQ_BYTES`), since the split and the
fill fields sit in its fifth and sixth lines; the SLOTSEQ word is
`kind << 11 | seq & 0x7ff` (K_PUSH is 16). `K_PUSH` is served by the
dispatcher's engine (`res_push`) with the slot waiting for the copy
(`land_wait`); the slot's reply carries the copy's number in `exit_aux`
and the wait's result in `exit_rip` when it refuses.
