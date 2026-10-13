# card.S: the cards the library drives

One slot per card, one process (`PHI512_SLOT`, 0). Requests go through
protocol v3's slot ([`../../../card/vpu/vpu_fexec.md`](../../../card/vpu/vpu_fexec.md)):
`card_post` writes the request block, a fence, then the slot's u16 in
SLOTSEQ (the kind in the top four bits); `card_wait` spins on the reply's
sequence number (5 s timeout) and returns its status.

## A session

`cards_init` opens each card's window (`window_open`, the common module;
`OFF_RESIDENT + RESIDENT_BYTES` mapped), waits for a polling worker,
opens the slot (u16 0, the stale reply number cleared), posts `K_FLUSH`
(the previous program's residency dropped: the pool is finite and
nothing evicts yet), and loads every seed's blob with `K_LOAD` under
`fn_id` = seed index + 1 (verbose: "card N: blob F at <card address>").
A card without a window or worker is skipped with a line.

## Residency (`card_resident(card, chunk, class)`)

The program's memory goes to the card in 2 MiB chunks at the program's
own addresses. A chunk not in this card's table (the common hash table,
`RES_TAB_CAP` 4096 entries a card) is staged: `copy_mapped`
([`elf.md`](elf.md)) copies the parts of the chunk the program has
mapped readable into the window's next staging slot (16 of 2 MiB,
round robin), `K_RESIDENT` names the chunk, the staging index and the
class, and the reply's `exit_aux` is the pool page, entered in the
table. 0.6 to 0.9 ms a chunk: the link's floor for 2 MiB.

## An instance (`card_fexec_post`)

The register file into the slot's `SD_REGS_IN` with the stripe's counter
and bound in the seed's registers; the request: `fn_id` = seed index +
1, `entry` 0 (a hand-translated blob starts at the fault point),
`threads` from `PHI512_THREADS` (114), the split (`ind_reg`,
`bound_reg`, `step` from the seed). The caller waits when every card's
instance is posted.

## Outputs (`card_push(card, address, bytes)`)

`K_PUSH` copies `bytes` of the program's memory from the card's view
(the slot's resident pages) into the slot's `SD_WB` (at most
`SD_WB_BYTES`, 240 KiB, a piece), and the host copies them out: a round
trip per piece, 64 KiB pieces today.

## Counters

`stat_resident`, `stat_resident_ns`, `stat_push_ns` for the exit report
([`main.md`](main.md)).
