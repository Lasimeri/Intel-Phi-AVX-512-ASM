# avx512-libm-test.c: libm called from a region, translated as callees

A function with AVX-512 code (so it runs on the card as a region) calls
`expf` and `sinf` through the PLT for each of 4096 elements, as ggml's
gated delta net and rope cache do; `main` (no AVX-512) checks every
result bit for bit against the host's libm.

```
gcc -O2 -mavx512f -o avx512-libm-test tools/avx512-libm-test.c -lm
PHI512_TRAMP_ANY=1 PHI512_CARDS=0 LD_PRELOAD=libphi512-asm.so ./avx512-libm-test
```

`PHI512_TRAMP_ANY=1` lets the region go on on the card after a call
returns although the program is not libggml-cpu (the continuation is
limited to the compute library and libm otherwise).

2026-10-14 on card 0: before, 16,387 regions (one round trip per call:
libm has no `.symtab`, so `expf` and `sinf` could not be sized for
callee translation); with the unwind-index fallback
(`elf.S eh_func_at`) and `endbr64` dropped (`blob.S .Lcopy`), 7 regions
and 63 ms, 0 of 4096 results different from the host's libm.
