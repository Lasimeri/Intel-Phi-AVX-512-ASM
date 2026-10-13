# xlfn.S: a seed's function translated at its first fault

The hook of stage 3 into the stage-2 handler: `seed_prepare(seed, rip)`
is called by `phi512_sigill` once `seed_of` has found the seed whose
function holds the fault. Under `PHI512_HANDBLOBS=1` it does nothing
(the hand-written blobs of [`seeds.S`](seeds.md) are entered where they
start, as before). Otherwise, on the seed's first use, `translate`
indexes the function (`fn_scan` over its bytes in this process, the
object being the mapping that holds it, no PLT known), builds the blob
(`blob_build`) in a 64 MiB bump arena (`alloc`: the index, the code at
64 bytes per original byte plus 64 KiB, 256 constants, 1024 constant
fixups, the map, 4096 branch fixups), records it in the seed
(`SD_ABLOB`, `SD_ABLOB_LEN`, `SD_MAP`, `SD_INDEX`, `SD_NINSN`), and
loads it on every card (`card_load_seed`, which prefers the automatic
blob to the hand one). Then `seed_entry` gives the blob offset of the
instruction at rip (a binary search of the index, then the map); the
handler passes it to `card_fexec_post`, which puts it in the request's
`entry`.

A refusal (the scan failed, the arena is full, the blob builder refused
an instruction) is said once ("phi512: NAME: translation refused at
+OFFSET: REASON"), `SD_REFUSED` is set, and the fault is treated as
outside any seed (the program dies as it would have). Verbose: "phi512:
NAME: translated: N instructions, B bytes of blob, C constants".

Measured 2026-10-13: the seamless test's three kernels, bit-identical at
every size, the first call of each including its translation and the
four loads (65536 integers: 1.81 ms against 0.82 with the hand blob;
at 1M and 16M the two are equal within the noise):
[`docs/results/2026-10-13-translator-seamless.md`](../../../docs/results/2026-10-13-translator-seamless.md).
