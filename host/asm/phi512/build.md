# build.sh: libphi512-asm.so

Assembles the common modules (`host/asm/common`: text, env, lock, mem,
table, window, fp) and `main.S`, `sigill.S`, `card.S`, `elf.S`,
`seeds.S` with GNU `as`, and links them with `ld -shared -z now -z relro
-z noexecstack -Bsymbolic` into `host/asm/out/libphi512-asm.so`, copied
to `host/target/release/libphi512-asm.so` (the path `scripts/phi512.sh`
preloads with `PHI512_V3=1`). The library exports nothing and imports
nothing: its constructor runs from `.init_array`, every system call is
direct.

Run on the rack (`host/asm/phi512/build.sh`); 93 KB. Position
independence: every data reference is RIP-relative or through a
register (a `file_in + REGS_GPR(,%rax,8)` form is an absolute
relocation the linker refuses for a shared object).

## decode.S (2026-10-13)

The decoder of stage 3 ([`decode.md`](decode.md)) is assembled into the
library as `p512_decode.o`; its tables (`x86tab.inc`) are included by
it. `make decode-check` assembles it alone against `tools/decode-check.c`.
