# ping.S: phi-vpu-ping, the floor of a request

The first host-side driver in assembly (the Rust `phi-vpu` keeps the
other verbs until stage 7 of the restart). It measures what protocol v3
costs with nothing to do: `S` threads, each owning a slot of a card's
window ([`../../../card/vpu/vpu_fexec.md`](../../../card/vpu/vpu_fexec.md)),
post `N` `K_PING` requests one after another and time each from the
store of the slot's u16 in the SLOTSEQ line to the reply's sequence
number appearing in the slot.

```
phi-vpu-ping [--card N] [-n COUNT] [--slots S] [--timeout MS]
```

Defaults: card 0, 1000 requests, 1 slot, 1000 ms. The window is opened
with [`../common/window.md`](../common/window.md)'s `window_open` for its
first 192 KiB (the control words and the slots), `wait_ready` confirms a
worker is polling, then one thread per slot (`clone` with a 1 MiB stack,
the slot number at the stack's top). A thread's loop: the request block
(kind `K_PING`, then `seq`), a fence, the u16, then a spin on the reply's
`seq` with `pause` and a timeout. Each sample goes into the thread's
record: count, min, max, sum, timeouts and a histogram of 100,000 bins
of one microsecond, from which the median and p99 are read (a bin is a
whole microsecond, so those print as integers; min, max and mean print
with a tenth).

Output: one line per slot and one over all slots:

```
ping: 10000 x 12 slots on card 0
slot 0: 10000 done min 5.2 us median 7 us p99 15 us max 44.1 us mean 7.4 us, timeouts 0
...
all slots: 120000 done min 5.1 us median 7 us p99 16 us max 61.0 us mean 7.5 us, timeouts 0
```

The stage 1 gate: median at most 8 us and p99 at most 20 us with 12
slots (`scripts/phi-vpu.sh -c N ping -n 10000 --slots 12`); the numbers
measured are in the protocol v3 floor record under `docs/results/`.
Built by [`build.md`](build.md).
