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
sees sum 115") and its last region failed the stack canary compare.
