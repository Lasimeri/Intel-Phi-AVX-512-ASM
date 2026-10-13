# 2026-10-13: the first function through a slot (K_LOAD, K_FEXEC)

Stage 2's first increment of the wrapper's restart: a slot process runs a
function with a full register file in and out
([`card/vpu/fexec.md`](../../card/vpu/fexec.md)), the dispatcher pulling
the register block with the card's DMA engine before the hand-off
([`card/vpu/sched.md`](../../card/vpu/sched.md)), measured with
[`host/asm/phi-vpu/fexec.S`](../../host/asm/phi-vpu/fexec.md) on the GPU
rack, card 0, worker `-v -S 12 -C 4 57`.

## What ran

A blob of three instructions loaded by `K_LOAD` into slot 3's arena:
`vaddps zmm0{k0}, zmm1, zmm2` in the card's MVEX encoding, `lea rax,
[rdi + rsi]`, `ret`. Each `K_FEXEC` sends the register file (zmm1 all
1.0, zmm2 all 2.0, k0 0xffff, rdi 5, rsi 7, rflags 0x202), the card enters
the blob on the slot's run stack with the return stub as the return
address, and the file comes back with rax 12, zmm0 3.0 in every lane and
the reply `X_RET`.

## Measured

| runs | min | median | p99 | max | wrong results | exit |
| --- | --- | --- | --- | --- | --- | --- |
| 2000 on slot 3 of card 0 | 13.1 us | 14 us | 24 us | 449.0 us | 0 | X_RET every time |
| 500 on slot 5 of card 1 | 14.4 us | 15 us | 27 us | 102.1 us | 0 | X_RET |
| 500 on slot 5 of card 2 | 14.5 us | 15 us | 24 us | 79.1 us | 0 | X_RET |
| 500 on slot 5 of card 3 | 14.4 us | 15 us | 25 us | 77.5 us | 0 | X_RET |

For comparison, `K_PING` on the same worker: 7 us median. The difference
is the function's own transfers: the DMA pull of the 2368-byte register
block (about 3 us, the engine at 3.2 GB/s plus its fixed cost), the
slot's copy of it into the context, the 36-line vector write of the file
back into the window, and the run itself (under a microsecond).

## What this settles

- A forked slot process enters arbitrary code with the whole vector
  register file loaded and captures it on return and on a fault (the
  signal handlers and the exit stub follow `exec.S`'s design; kernel
  patch 0030 keeps the vector unit across the handler).
- The DMA engine's landing page, now mapped shared (`cdma.S`), is read by
  the slot processes forked after it was mapped; the slot waits on the
  engine's status word itself (`land_wait`), so the dispatcher never
  waits for a copy.
- The doorbell's u16 carries the kind in its top four bits, so the
  dispatcher knows a `K_FEXEC` needs the pull without reading the
  request line.

## Bugs on the way

- The host test treated `post_and_wait`'s positive return (the round
  trip in ns) as a failure: "K_LOAD failed, status 0" with status 0.
- A build script written by the Write tool is not executable; rsync
  carries the mode, so `chmod +x` on the desktop copy first.

## Next

Residency (`K_RESIDENT`: the program's memory at its own addresses on
the card, class I through shared huge-page segments, class W private
with the per-request refresh), then the preload library with the SIGILL
handler and hand-seeded blobs for the seamless test's three kernels, the
gate of stage 2.
