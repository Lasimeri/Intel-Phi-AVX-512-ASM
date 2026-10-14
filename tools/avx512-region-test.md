# avx512-region-test.c

A program whose AVX-512 code is broken into regions by calls, as any
compiled function is: the first kernel vectorises a stack array, calls
a plain function in the middle (which reads what the card wrote,
prints, and changes the array), continues with AVX-512 on the changed
array and returns a value; the second kernel calls through a function
pointer and branches out of its hot path. `main` and the references are
compiled without AVX-512 (`target("no-avx512f")`), so only the two
kernels fault; each result is compared with its reference.

```
gcc -O2 -mprefer-vector-width=512 -mavx512f -mno-avx512vl -mno-avx512bw -mno-avx512dq -mno-avx512cd \
    -o avx512-region-test tools/avx512-region-test.c
PHI512_CARDS=0,1,2,3 PHI512_VERBOSE=1 LD_PRELOAD=libphi512-asm.so stdbuf -oL ./avx512-region-test
```

`-O2` and the preferred vector width are what make gcc emit zmm code
(at `-O1` nothing is vectorised; without the width gcc prefers ymm, which
the host runs itself). The verdicts print as the program goes
(`stdbuf -oL`: when a later region kills the process, buffered stdout
would be lost with it).

The exercise for [`../host/asm/phi512/region.md`](../host/asm/phi512/region.md):
on 2026-10-13 the first kernel's first region came back right ("middle
sees sum 115") and its last region failed the stack canary compare; by
the night both kernels pass whole ("PASS: every region came back
right", 4 regions, 1 fault, 20 ms), after the REX fix of the
scratch-register moves (commit 365d4b3).

`kernel3` (2026-10-14): an EVEX load and compare (zmm16, k1), a VEX ymm
load, `vperm2i128` (VEX, no recipe: the host runs it, blob.S's lazy
path), then EVEX again: the card exits at it (`X_HOST`), the host runs
it and faults into a second region at the next EVEX instruction; zmm16
and k1 must survive the host's turn and the host's ymm3 must reach the
card. PASS on card 0 (6 regions, one host exit).

`kernel4` (2026-10-14): a vectorized function passes a 160-byte struct
by value; gcc's `sub $0xa0,%rsp` and the zmm stores of the stack
arguments fall inside the region, below the frame's rsp minus 128. PASS
with the alternate signal stack and the lowered floor; with the floor's
slack set to 0 it fails (2.65e8 for 2258) and the floor warning fires
twice.

## kernel5 and kernel6 (2026-10-14)

- kernel5: 384 MiB of a read-only file mapping (`avx512-region-test.ro`,
  written in the current directory when missing) read twice: every 2 MiB
  chunk wholly inside it goes to the card as one pool page, evicted from
  a 16-page ring once the pool is full; the second read re-faults the
  evicted chunks. Bit-exact against the scalar reference at `-R 128`
  (a 256 MiB pool).
- kernel6: AVX-512 functions calling each other directly and through a
  pointer, one with a plain function called in its middle (an exit from
  inside a callee the card entered). With in-card calls kernel6's work
  is 6 region posts (kernel6 3, dot6 1, scale6 2) against 38 with
  `PHI512_INCALL=0` (19, 17, 2), same results.
