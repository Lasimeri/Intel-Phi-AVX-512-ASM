# main.S: libphi512-asm.so's entry

The assembly preload library of the restart's stage 2 (the plan's
`host/asm/phi512/`): `scripts/phi512.sh` preloads it with `PHI512_V3=1`
into an unmodified program compiled for AVX-512, and from then on the
program's AVX-512 functions run on the cards. The Rust `libphi512.so`
stays beside it until stage 3's translator replaces its hand-seeded
blobs ([`seeds.md`](seeds.md)).

## The constructor

`.init_array` runs `phi512_init` before the program's `main`:

1. `PHI512_DISABLE` set: nothing is installed.
2. CPUID leaf 7, EBX bit 16: a host with AVX-512 needs nothing.
3. `PHI512_VERBOSE` set: a line per step on standard error ("phi512:
   init: ..." while the cards open, then "phi512: N card(s), the
   handler installed; seeds: 3").
4. CPUID 0xD, subleaf 2, EBX: where the YMM halves lie in an XSAVE area
   (the signal frame's), kept in `ymm_off` for [`sigill.S`](sigill.md).
5. `elf_init` ([`elf.md`](elf.md)): the executable mapped, its load
   address found.
6. `cards_init` ([`card.md`](card.md)): the cards opened (`PHI512_CARDS`,
   `PHI512_CARD`, else every window present), each flushed, the seeds'
   blobs loaded. No card: a line, no handler, and the program dies at
   its first AVX-512 instruction as it would have.
7. `rt_sigaction(SIGILL)` with `SA_SIGINFO | SA_RESTORER` and the
   library's own restorer (`phi512_sig_restorer`, an `rt_sigreturn`):
   no libc call anywhere in the library.

The destructor (`.fini_array`) prints, when verbose, the calls the cards
ran and their total time, the chunks made resident and their time, and
the time the outputs took to fetch (the counters of `sigill.S` and
`card.S`).

## Environment

| variable | meaning |
| --- | --- |
| `PHI512_DISABLE` | set: the library does nothing |
| `PHI512_VERBOSE` | set: init steps, a line per call, the exit report |
| `PHI512_CARDS=0,1,2,3` | the cards to use, in order (comma list) |
| `PHI512_CARD=N` | one card |
| `PHI512_SLOT=N` | the slot to use on every card (0) |
| `PHI512_THREADS=N` | card threads an instance may split over (114) |

## What is not here yet

Translation (stage 3), the twin, the per-call decision, eviction, class
W refresh: the plan's later stages. Today a function the library has no
seed for ends the program as it would have ended without the library
(the handler resets SIGILL to its default and returns, and the fault
repeats).
