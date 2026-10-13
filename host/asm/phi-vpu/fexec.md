# fexec.S: phi-vpu-fexec, the first function through a slot

The test of [`../../../card/vpu/fexec.md`](../../../card/vpu/fexec.md):
a blob of three instructions, `vaddps zmm0{k0}, zmm1, zmm2` in the card's
MVEX encoding (`62 f1 70 08 58 c2`, the EVEX form's P1 bit 2 cleared and
the MVEX P2 byte, `docs/research/avx512-on-knc.md`), `lea rax, [rdi +
rsi]`, `ret`, loaded into one slot's arena with `K_LOAD` and run `-n`
times with `K_FEXEC`. Each run's register file in: zmm1 all 1.0, zmm2 all
2.0, k0 0xffff, rdi 5, rsi 7, rflags 0x202; the file out must show rax 12
and zmm0 3.0 in lanes 0 and 15, and the reply `X_RET`. Each run is timed
from the doorbell store to the reply's sequence number; the samples go
into one-microsecond bins.

```
phi-vpu-fexec [--card N] [--slot S] [-n COUNT]
```

The doorbell's u16 carries the kind in its top four bits and the
sequence number in the low twelve (`post_and_wait`): the dispatcher
reads the kind from it and pulls the register block by DMA for `K_FEXEC`
before the hand-off. Output: the blob's card address, then one line
`fexec: N runs on slot S of card C: min, median, p99, max, wrong results`,
then `PASS` or `FAIL` (exit status 0 or 1). Built by [`build.md`](build.md).
