# resident.S: phi-vpu-resident, a function over resident memory

The test of [`../../../card/vpu/resident.md`](../../../card/vpu/resident.md):
two chunks of 2 MiB made resident at two program addresses the test
chooses (`0x7e0000000000` and the next chunk), the first filled with a
pattern (float `i` at dword `i`, so the sums are normal numbers) and the second with zeros, through
`K_RESIDENT`; then a blob of five instructions loaded with `K_LOAD` and
run `-n` times with `K_FEXEC`: `vmovaps zmm0, [rdi]` (the pattern's first
line), `vaddps zmm0, zmm0, zmm0`, `vmovaps [rsi], zmm0` (into the second
chunk), `mov rax, [rdi + 4096]`, `ret`, with `rdi` and `rsi` the two
addresses and one write-back range (`rsi`, 64 bytes). Each run's file out
must show zmm0 lane 0 = 0 and lane 15 = 30 (twice the pattern), rax the
pattern's quadword at 4096 (floats 1024.0 and 1025.0, `0x4480200044800000`), and the write-back
line in `SD_WB` the same doubled pattern; the reply `X_RET` with `wb_n`
1. The two `K_RESIDENT` and the runs are timed.

```
phi-vpu-resident [--card N] [--slot S] [-n COUNT]
```

The worker must have a pool (`PHI_VPU_ARGS="-S 12 -C 4 -R 64"`). Output:
the two chunks' pool indices and times, the blob's address, one line
with the runs' min, median, p99 and max, and `PASS` or `FAIL`. Built by
[`build.md`](build.md).

The test now posts `K_FLUSH` first (2026-10-13): the previous program's
residency is dropped, so the two chunks always get pool pages.
