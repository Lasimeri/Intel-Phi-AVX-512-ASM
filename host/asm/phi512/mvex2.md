# mvex2.S: the exact-footprint memory moves

Included by [`mvex.S`](mvex.md) at its end (one assembly unit). The
card's unaligned pairs (`vloadunpackld`/`hd`, `vpackstoreld`/`hd`) need
the element's alignment and touch the whole of both cache lines, so an
operand that is not a full 64-byte line cannot go through them: a
narrow operand (an xmm or a ymm, a float16 or a byte source) at the end
of a mapping has the pair's second half reading the next line, and an
operand at an address that is not 4-aligned (ggml's quantized blocks
load 32-byte vectors at 2-byte offsets) faults. Found by the narrow
suite's page-end check (`tools/avx512-narrow-test.c`: a 16-byte load at
`page + 4096 - 16` with the next page `PROT_NONE`): the card faulted on
the line above the page, the host could not make it resident, and the
program died.

| function | what it emits |
| --- | --- |
| `em_unaligned(em, d, in, k, w, store, float, sss)` | the dispatcher: the move's bytes from `EM_NBYTES` (a caller that knows: `xl_movlh` 8, the half-lane sources of `xl_widen_dq`, `xl_cvtps2pd` and `xl_widen_bw`), else the lanes of the last mask immediate (`EM_KVAL`, recorded by `em_mask_imm`: a one-lane `vmovss` store is 4 bytes, not 64) or of the length (4 << ll dwords, 2 << ll qwords), times the element by the conversion (4 or 8; float16 2; the byte conversions 1; the word ones 2); 64 bytes go to `em_unaligned_any`, fewer to `em_bounce`; `EM_NBYTES` is cleared after use |
| `em_bounce(em, d, in, k, w, store, nbytes, float, sss)` | rax and rcx saved, `lea rcx, [m]` with the program's address registers reloaded; a load copies exactly nbytes from `[rcx]` to `[fs:S_XFER]` with scalar moves (qwords, then a dword, a word, a byte: any alignment, nothing beyond the operand touched) and does `vmovaps`/`vmovapd` (float) or `vmovdqa32`/`64` `d{k}, [fs:S_XFER]` with the conversion; a store does the vector store into the slot and copies out; a masked store merges: the bytes in first, the masked slot store, the bytes out; with `EM_PACK` set (an extract's element to memory, `xl_pextr`; `xl_movq`'s store, lane 0, too) the slot store is `vpackstoreld` (0F38 D0), so the masked lanes land together at the slot's start whatever their lane (before 2026-10-14 `vpextrq $1` stored the slot's old bytes); em_bounce clears the flag |
| `em_unaligned_any(em, d, in, k, ll, store)` | a full-width move of unknown alignment, decided at run time: rax, rcx and the flags saved, `lea rcx, [m]`, `test cl, 63`, `jz` to the plain aligned `vmovaps d{k}, [m]` (or the store); for a 512-bit operand `test cl, 3`, `jz` to the pair (`em_unaligned_pair`: the operand spans its two lines, both its own); else the bounce of 16 << ll bytes; the branches are rel32 and patched in place; a narrow operand (ll below 2) never takes the pair |
| `em_unaligned_pair`, `em_unaligned_any_pairs` | the former emitters under their old names: the pair (each half masked, the high half at +64), and the pair-or-qword-bounce dispatcher |

The transfer slot `S_XFER` is 64 bytes of the thread's scratch area,
64-aligned, so the vector move on it is a plain aligned move; the
conversion (`sss`) and the mask apply on that move, as they did on the
pair.

## Measured (2026-10-13, card 0, a fresh worker per run, library built 20:51)

| suite | before | after |
| --- | --- | --- |
| `tools/avx512-narrow-test.c` (66 checks, `-O1` as its note documents) | 35 ok, then SIGSEGV at the page-end check | 66 ok, PASS, 97 regions, 72 to 84 ms wall, two runs |
| `tools/avx512-f-forms-test.c` (42 checks) | 42 ok | 42 ok, three runs |
| `tools/avx512-region-test.c` | PASS | PASS, 4 regions |

Two bugs the path exposed on the way: sizing a move by the vector length
made a one-lane `vmovss` store write 16 bytes over its neighbours (the
suite's expected arrays), hence `EM_KVAL`; and after the suite's
`munmap` the host died in `wu_writeback`, writing a line into the
unmapped page, because a unit's page bitmap was computed once at
residency: [`region.S`](region.md) now takes `copy_mapped_pages` from
every [`copy_mapped`](elf.md).

## Broadcasts and block loads through the slot (2026-10-14)

The card wants a broadcast's memory operand (`vbroadcastss`/`sd`,
`em_broadcast`) aligned to its element and a block load
(`vbroadcasti32x4`/`64x4`, `em_load_block`) aligned to its 16 or 32
bytes; x86 wants neither. `em_copy_to_xfer` copies the operand's 4, 8,
16 or 32 bytes by scalar moves into the transfer slot's upper half
(`XFER_HI`, `S_XFER` + 32: `xl_divs` keeps the first 16 bytes across
its memory broadcast) and both read the aligned slot. A VEX `vmovq` from
a 4-aligned address (a broadcast under lane 0) in
`llama_memory_hybrid_idx`'s constructor raised #GP on the card at the
first context of `llama-server`. The narrow suite checks the five
cases; with the change stashed it stops with #GP at the first.
