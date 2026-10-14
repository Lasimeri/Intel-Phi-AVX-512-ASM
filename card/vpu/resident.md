# resident.S: the program's memory on the card

Protocol v3's `K_RESIDENT` ([`vpu_fexec.md`](vpu_fexec.md)), the second
increment of stage 2 of the restart (2026-10-13): chunks of 2 MiB of the
host program's memory live on the card at the program's own addresses,
so a function run by a slot ([`fexec.md`](fexec.md)) finds its operands
where the program had them, and the bytes cross the link once.

## The pool

`worker.S -R pages` has the dispatcher map `pages` huge pages shared
(`MAP_SHARED | MAP_ANONYMOUS | MAP_HUGETLB | MAP_POPULATE`) before it forks
the slot processes ([`sched.md`](sched.md)), so every process sees the
same pages; `res_init` reads each page's frame from `/proc/self/pagemap`
(the first entry of its 512: a huge page is one frame run; root sees
frames) into a table shared the same way: per page the program address
(0: free), the frame, the state (free, filling, resident), the class, the
DMA sequence number of its fill. 2048 pages at most (4 GiB). The huge
pages come out of the card's reservation (`PHI_VPU_HUGEPAGES`), beside
the worker's buffers and the seamless path's pool (`-e`).

## K_RESIDENT

The host writes the chunk's bytes into one of the 16 staging chunks of
the window's `RESIDENT` area and posts `fn_id` = the program address
(chunk aligned), `entry` = the staging index, `threads` = the class (0
immutable, 1 writable; informational so far). The dispatcher, in
`slots_poll`, reads the request line, `res_assign`s a pool page (the
address's own when it already has one, else a free one), and `res_pull`
submits the copy to the DMA engine straight into the page's frame
(`cdma_submit_phys`, three descriptors of at most 16383 lines each); the
page index and the last piece's sequence number go with the job. The
slot that asked waits on the engine's status word (`res_wait`, 2 s at
most), marks the page resident, and replies with the index in
`exit_aux`. The link's 3.2 GB/s makes a chunk about 0.65 ms; the
dispatcher waits for nothing.

## Before a run

`res_map_all`, in the slot process before every `K_FEXEC`: every pool
page resident in the table that this process has not placed yet is
moved to its program address with `mremap(MREMAP_MAYMOVE | MREMAP_FIXED)`
(a shared mapping's page: this process's view alone moves, the other
processes keep theirs and move it themselves when they need it). A
bitmap per process remembers the pages placed. A move that does not
land at the address (something of the process's own there) ends the
request with `E_ALLOC`.

## After a run

`sched.S wb_ranges`: the request's `wb_n` ranges (`SD_WB_TAB`, each
64-byte aligned and sized) are copied from the program's addresses into
the slot's `SD_WB`, one after another, in lines through the window; the
host applies them where it wants. The reply's `wb_n` and `wb_ns` say how
many and how long. A diff against what the chunk held (so the host
applies only what changed, and concurrent host writes to the same page
survive) is the next refinement; today the host declares what to send
back.

## Not yet

- Eviction (a full pool refuses with `E_ALLOC`), re-filling a page the
  host changed, the immutable class mapped read-only, private writable
  pages per slot with a per-request refresh of small ranges (the plan's
  class W), the demand mail for an undeclared access.
- The host side: the preload library's residency table and placement
  (stage 2's third increment); today `host/asm/phi-vpu/resident.S` drives
  it by hand.

## The session's end: `res_flush` (2026-10-13, later)

`K_FLUSH` (the host opening a slot for a new program) moves every pool
page this process placed back to its pool address and empties the
shared table: address, state, class and sequence of every entry
cleared, the frame (`RT_PHYS`, read once from pagemap at `res_init`)
kept. A first version zeroed the entries whole, and every later fill
was a DMA to physical address 0: the pages stayed zero and the program
computed on zeros without a fault. `res_pull` now refuses an entry
without a frame. With several slot processes each would need to see
the flush (a generation in the table): not yet, one slot a card today.

## Fill ranges, pushes by the engine, the address reservation (2026-10-13, later)

- A `K_RESIDENT` names a range of its chunk to fill (`fill_off`, `fill_len`
  at 336 and 344 of the request): `res_pull` copies only that range; a
  length of 0 is the page alone (`res_mark`: a chunk the program only
  writes), resident at once with no copy. The host keeps a 64 KiB
  coverage bitmap per chunk and asks for the units a call reads.
- `res_push` (the dispatcher's, `K_PUSH`): the bytes at a program address
  (resident here, within one chunk, 64-aligned) copied by the engine from
  the pool page's frame into a window staging slot (`cdma_submit_tohost`,
  [`cdma.md`](cdma.md)); the slot waits for the copy's number. 64 MiB come
  back in 18 to 20 ms (3.2 GB/s); the slot's own posted stores through the
  aperture did 0.5 GB/s.
- The worker reserves `[0x550000000000, 0x7ff000000000)` as one PROT_NONE
  mapping before its first own mapping (`reserve_high`, from `_start`): a
  position-independent program's heap and mmap region lie there, so a
  resident page can take the program's address without meeting the
  worker's windows, pools, arenas or thread stacks (a 1 MiB-element run
  did, before: the slot's stack vanished under a page). `resv_free` says
  whether an address may be taken (inside the reservation, or free by a
  probe mapping); `resv_restore` puts the PROT_NONE page back when a page
  returns to the pool (`res_flush`).
- `res_map_all` places a run of consecutive pool pages at consecutive
  program addresses with one `mremap`: every `mremap` or `munmap` of a
  huge page in the slot process is a TLB shootdown over its ~110 running
  threads' CPUs (about 100 us each on the card).

## Writable units by 64 KiB (2026-10-13, night)

The chunk model hid a hole: the host tracks the program's memory by
64 KiB units (a shadow, a refresh, a write-back each), but the first
fault in a 2 MiB chunk placed the whole huge page, so every later touch
to another unit of that chunk neither faulted nor was filled nor pulled
back: the program read garbage there and its writes were lost (the
options vector of `llama-server` moved on the card at every growth and
never came back: "invalid argument: -m" after 976 regions, with 7 units
resident, one per chunk).

A `K_RESIDENT` of class 1 (writable) now takes no pool page. The
dispatcher marks the job (`SH_RES_IDX` -2, no fill to wait for) and the
slot process does the rest (`res_map_units`): each unit of the request's
mask (`SL_FLAGS`, a bit per 64 KiB of the chunk) is mapped once at the
program's address as ordinary 4 KiB pages, private to the process,
read-write (`MAP_FIXED` over the reservation's piece inside it; as a hint
that must land outside it, backed out when it does not), and remembered
in `wmap_tab` (4096 units); when the fill has bytes, the unit's 64 KiB
are copied from the staged chunk by this core (`phi_copy64`: coherent
with its caches, where a DMA fill is not against a line a core holds).
A unit the host has not sent stays `PROT_NONE` and faults, so the host
sees every unit the program touches. `K_PUSH` of such a unit (the pool
has no page for it: `res_push` returns 0, the dispatcher marks -2) is the
slot's own copy into the staging slot (`res_push_unit`). `K_FLUSH`
restores the reservation over every unit (`res_unmap_units`). The pool
and its chunks stay for the immutable class.

## Eviction of read-only chunks (2026-10-14)

The cards run every region whatever the residency: a chunk of the
program that is immutable (inside one readable, not writable mapping: the
mmapped model) comes as class 0, one pool page filled by DMA, and once
the pool is full the host names a victim in the `K_RESIDENT`
(`SL_VICTIM`, request offset 360; `SL_REQ_BYTES` 368). The dispatcher
frees the victim's page first (`res_drop`: address 0, state free, the
frame kept), so `res_assign` gives it to the new chunk; the slot process,
before every run, moves every page it placed whose table entry no longer
names that address back to its pool address (`res_unplace_stale`, from
the per-process `res_at`, which `res_flush` also uses), so the old
address faults again instead of reading the page's new chunk. No
CLEVICT: a read-only chunk's lines are never dirty, and DMA writes reach
clean cached lines (the stack's `docs/results/2026-09-16-dma.md`).
`K_FLUSH`'s reply carries the pool's bytes in `exit_rip` (every reply's
`free_bytes` is the card's own, set at the reply's end).

The address reservation (`reserve_high`) has failed with EEXIST at every
start so far (the pool's log line now says so: "address reservation ...:
-17"); placement works through `resv_free`'s probe of a hole. Because of
that, `resv_restore` now puts a PROT_NONE page back only in a piece the
reservation holds: before, it mapped one at every evicted address and the
probe then found the address taken (an evicted chunk could never come
back: E_ALLOC on the second pass of the region test's kernel5).

Gate: `tools/avx512-region-test.c` kernel5 (384 MiB of a PROT_READ file
mapping, read twice, against a 256 MiB pool at `-R 128`): bit-exact.

## The card-side write-back diff (2026-10-14)

The host used to pull every writable unit back after every region (a
`K_PUSH` of 64 KiB per unit, about 0.25 ms each) to diff it against its
shadow: late in llama-server's load that was about 200 requests a region
(card 0 at 3,022 requests/s, 76% busy, 15 regions/s). Now the slot keeps
its own copy of each unit as the host sent it (`wsh_base`, a 64 KiB copy
per `wmap` index in a no-reserve mapping hinted below the program's
range; `wsh_fill` after a unit's fill, `wsh_sync` after each refresh
range), and after a `K_FEXEC` with `FXF_CARDWB` whose exit is not a
fault, `wb_card_diff` has the pool compare every unit with its copy
(`wd_slice` over up to 32 slices: a bit per changed 64-byte line in
`wd_bits`, the copy brought up to date), then lists the changed lines,
adjacent ones as one range, in the slot data's `SD_WB_TAB` and `SD_WB`;
the reply's `wb_n` is the count of ranges, -1 when they overflow (1024
ranges or 240 KiB), and the host then pulls the units as before. No diff
after a fault: the host re-posts without writing back, and moving the
baseline then would lose the lines. Measured on card 0: the narrow suite
65 to 109 ms against 150 to 230 ms pulling, identical lines written
back (306); every region of the three gates took the card's list, none
overflowed.
