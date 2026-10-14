# place.S: which card owns a byte of the model

The four-card pool (2026-10-14, the user: pool the four Phis' memory,
each card holding different weights, no copies across cards). A chunk of
the mmapped model belongs to one card; a region that faults on a chunk
another card owns moves there (region.S, in progress).

| Function | Contract |
|---|---|
| `place_load` | `PHI512_PLACE` read once: lines `card offset bytes path` (decimal; `#` comments; blank lines skipped; an empty range is no line), at most 4096; says `phi512: placement FILE: N line(s)`. Unset or unreadable: no placement, every chunk unowned. |
| `chunk_owner(address)` | eax the card (an index into `PHI512_CARDS`' list) whose line holds the address's file offset, -1 when none does or there is no placement. rax, rcx, rdx, rsi, rdi, r8 to r11 clobbered. |
| `own_lookup(address)` | the owned address range holding it (`own_tab`: lo, hi, card), -2 when none. |
| `own_examine(address)` | the mapping holding the address, the first time it is met (`ex_tab`, found through the cached maps table first, so a mapping examined before costs no read): its line of `/proc/self/maps` (start, end, file offset, path) and every placement line of that path made an owned range (the overlap of the line's file range with the mapping's). eax 1 when examined now. |

The model is mapped after the preload starts, so ownership is resolved
lazily, per mapping. The placement file is written from the GGUF
headers (a layer's tensors to one card, contiguous layers per card):
llama.phi's shards hold layers in lexical name order (shard 4: layers 1
and 10 to 19), so a split by file offset would scatter layers across the
cards.
