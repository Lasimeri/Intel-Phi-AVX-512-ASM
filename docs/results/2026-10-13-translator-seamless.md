# 2026-10-13: the seamless test from automatic translation

Stage 3's gate for the seamless test: the three kernels of
`tools/avx512-seamless-test.c` translated from the binary itself, by
the assembly translator, and run on four cards bit-identically. The
hand-written blobs of `host/asm/phi512/seeds.S` (stage 2) are no longer
on the path; they stay under `PHI512_HANDBLOBS=1` for comparison.

What runs at a fault now (`host/asm/phi512/`): `seed_of` finds the
function; `seed_prepare` (`xlfn.S`) indexes it (`fnscan.S` over
`decode.S`), builds the blob (`blob.S`: scalar instructions copied,
rip-relative operands re-based, branches re-laid out, the vector
instructions through the recipes of `xlate.S` and the emitter `mvex.S`,
constants appended, the rip map), loads it on every card, and gives the
handler the blob offset of the faulting instruction; the rest is stage
2's: stripes, residency, `K_FEXEC`, pushes.

GPU rack, four cards, workers `-S 1 -C 55 -T 2 -R 128 -s 1000`,
`PHI512_CARDS=0,1,2,3 PHI512_VERBOSE=1 LD_PRELOAD=libphi512-asm.so
stdbuf -oL ./st N` from `/mnt/raid5/phi/bench/restart-2026-10-13/`,
commit of this record.

## Result

| elements | kernel | automatic | hand blob | verdict |
| --- | --- | --- | --- | --- |
| 65536 | polynomial | 3.22 ms | 3.05 ms | bit-identical |
| 65536 | dot product | 1.23 ms | 0.91 ms | bit-identical (-28.6031036) |
| 65536 | integers | 1.81 ms | 0.82 ms | identical |
| 1048576 | polynomial | 8.35 ms | 7.94 ms | bit-identical |
| 1048576 | dot product | 14.1 ms | 13.6 ms | bit-identical (100.054245) |
| 1048576 | integers | 7.39 ms | 7.53 ms | identical |
| 16777216 | polynomial | 71.6 ms | 72.0 ms | bit-identical |
| 16777216 | dot product | 182.0 ms | 177.3 ms | bit-identical (1436.80762) |
| 16777216 | integers | 57.7 ms | 57.3 ms | identical |

PASS at every size. The first call of each kernel includes its
translation and the four loads (the 65536 integer call: 1.81 against
0.82 ms); at 1M and 16M the two blobs are equal within the run-to-run
noise, which says the inner loops' extra instructions (a memory operand
staged through a temporary: a save, the unaligned pair, the operation,
a restore, where the hand blob has one aligned operand) do not show
behind the request latency at these sizes. The blobs: polynomial 128
bytes for 23 instructions, dot product 896 for 19 (the VL reduce: a
256-bit extract, 256- and 128-bit adds, a 128-bit extract, a permute, a
shuffle, a scalar move and add, each a masked sequence), integers 320
for 22 with one constant (the all-ones of `vpternlogd 0xff`).

## What the first runs found

- A form record of the recipe table was 20 bytes and the table walk
  stepped by 24: the dispatch table was filled from garbage (a refusal
  under gdb, a crash without).
- `em_byte` clobbers rdx: the SIB's index and base were read into
  registers before an emit, so every indexed operand got a garbage
  index (6 or 2 for rax). The polynomial and dot product "ran" on the
  cards with wrong addresses and the verdict lines, lost because the
  process died at the third kernel with stdout still buffered, would
  have said so. The verdicts are the test; a run that returns is not.
- `vextractf64x4` and `vextractf128` write the r/m operand and read the
  reg field: the register form had them swapped (the dot product's
  reduce gave 6.02 for -28.60).
- `ld -shared` without `-z defs` leaves an undefined symbol to run time
  (`card_load_seed` was file-local): the library links with `-z defs`.

## Next

The narrow and forms corpora (`tools/avx512-narrow-test.c`, 66 forms;
`tools/avx512-f-forms-test.c`, 42) through the same path, which need
exits at calls (each check is a function with calls around its block);
then llama-simple: the twin's binaries with the AVX-512 `libggml-cpu.so`
swapped in, the functions it faults in translated lazily.
