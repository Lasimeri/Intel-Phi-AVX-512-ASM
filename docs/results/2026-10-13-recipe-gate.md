# 2026-10-13: the stage-3 recipe gate on card 0

The three programs the plan names as the translator's gate, built exactly
as their notes document, run under the preload on card 0 with a fresh
worker before each run (`PHI_VPU_ARGS="-S 1 -C 55 -T 2 -R 128 -s 1000"
scripts/phi-vpu.sh -c 0 start 57`), the host library built at 20:51 from
the tree of this record's commit. Logs on the rack:
`/mnt/raid5/phi/bench/restart-2026-10-13/{fforms-doc,narrow-doc,region-doc}.{out,err}`.

```
gcc -O1 -mavx512f -mno-avx512vl -mno-avx512bw -mno-avx512dq -mno-avx512cd -o fforms-doc tools/avx512-f-forms-test.c
gcc -O1 -mavx512f -mavx512vl -mavx512dq -mavx512bw -mf16c -o narrow-doc tools/avx512-narrow-test.c -lm
gcc -O2 -mprefer-vector-width=512 -mavx512f -mno-avx512vl -mno-avx512bw -mno-avx512dq -mno-avx512cd -o region-doc tools/avx512-region-test.c
PHI512_CARDS=0 PHI512_VERBOSE=1 LD_PRELOAD=$HOME/.cache/intel-phi-avx512/host/target/release/libphi512-asm.so stdbuf -oL ./PROGRAM
```

| program | checks | verdict line | regions | residency faults | wall | blob |
| --- | --- | --- | --- | --- | --- | --- |
| `avx512-f-forms-test` (F only) | 42 ok | `PASS: every form matched` | 41 | 1 | 35 ms | `main` 54,912 bytes, 80 branch fixups |
| `avx512-narrow-test` (VL, BW, DQ, F16C) | 66 ok | `PASS: every form matched` | 97 | 2 | 68 ms | `main` 97,536 bytes, 24 constants, 71 branch fixups |
| `avx512-region-test` (two kernels: a call in the middle, an indirect call, a branch out) | 2 ok | `PASS: every region came back right` | 4 | 1 | 20 ms | 3,968 and 1,280 bytes |

The wall time is the whole process (`date` around it): the handler's
install, the translation, the load to the card, the regions, the exit. A
residency fault is an `X_FAULT` exit answered by making the unit
resident; the narrow suite's second is its own page-end check (a 16-byte
load at the end of a page with the next page `PROT_NONE`).

What the gate took on this day, in order: the REX bit of the
scratch-register moves in `blob.S` and `mvex.S` (r8 to r15 moved rax: the
silently wrong regions, commit 365d4b3); the recipe batches of
`xlate2.S` and `xlate2.inc` (the forms both suites refused: 35 and 55
mnemonics in the morning); the exact-footprint memory moves of
[`mvex2.S`](../../host/asm/phi512/mvex2.md) (a narrow or misaligned
operand never takes the card's two-line pair; a move is sized by its
mask); the unit's readable-page bitmap taken from `copy_mapped` at every
region (the host had died writing a line back into a page the program
had protected). Not yet: the two form suites on cards 1 to 3 (regions run
on card 0 only), the probes gated, the `X_REFUSED` resume.
