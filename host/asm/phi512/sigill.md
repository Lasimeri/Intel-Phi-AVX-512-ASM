# sigill.S: the SIGILL handler, one call on the cards

The host refuses the program's first AVX-512 instruction with SIGILL;
the handler takes the whole function from there as one call on the
cards and resumes the program at the function's return.

## The steps of `phi512_sigill(sig, info, uc)`

1. `seed_of`: the faulting rip inside a function the library has a seed
   for ([`seeds.md`](seeds.md): the function resolved by name on first
   use, `elf_find`), else the program dies as it would have (the
   handler resets SIGILL to default and returns; the fault repeats).
2. `file_from_frame`: the register file for the card (`vpu_fexec.h`'s
   `vpu_regs`): the integers and flags from `uc_mcontext.gregs` (glibc's
   `REG_*` order, `UC_GREGS` = 40), xmm0..15 from the FXSAVE area at
   `uc_mcontext.fpregs` (`FX_XMM0` = 160), their ymm halves from the
   XSAVE area at the offset CPUID gave (`ymm_off`); zmm16..31, the upper
   256 bits and the masks zero (the host has none).
3. The stripes: one per card when the seed's loop splits (`SD_STEP` not
   0), else one; the elements between the counter register's value and
   the bound register's value divided among them, each stripe rounded
   up to a step (an empty stripe is skipped).
4. Per stripe: `stripe_resident` (every chunk of every operand the
   stripe touches made resident on its card, `card_resident`), then
   `card_fexec_post` (the file with the stripe's counter and bound, the
   split fields, `PHI512_THREADS`).
5. Every card waited for (`card_wait`); a status or an exit other than
   `X_RET` is a failure line ("card N refused an instance of F: status,
   exit kind, step rc, exit rip, fault address") and the program dies.
6. `stripe_push`: the written operands' stripe ranges fetched back
   (`card_push`).
7. The frame as the function's `ret` leaves it: rax and xmm0 from the
   first stripe's file out (the function's return values), the upper
   halves of every ymm zero (the function's `vzeroupper`, XSTATE_BV's
   YMM bit set), rip the return address on the stack, rsp past it.

Verbose: a line per call, "phi512: F: N elements in S stripe(s) on C
card(s), K chunk(s) made resident, T us".

## Measured (2026-10-13, `tools/avx512-seamless-test.c` through the library)

Four cards, workers `-S 1 -C 57 -T 2 -R 128 -s 1000` (114 slices per
stripe): every size bit-identical to the scalar references
(`docs/results/2026-10-13-preload-seamless-first.md`). The time is the
residency's: 65536 elements, poly 17.8 ms of which 12 chunks 16.8 ms;
the card's own compute per request 0.04 to 0.6 ms.

## Limits today

The handler runs on the faulting thread's stack (no altstack yet), one
call at a time (no lock: a single-threaded program). The frame's
register file is 2256 bytes; the handler's own frame 64 bytes plus the
file in `.bss` (`file_in`), so a program with several threads faulting
at once would race on it: stage 4's per-thread slots.
