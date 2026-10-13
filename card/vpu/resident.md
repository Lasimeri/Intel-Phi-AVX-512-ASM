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
