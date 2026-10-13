# fnscan-check.c: the function scan over a library on disk

```
as --64 -I host/asm/phi512 -o host/asm/out/p512_decode.o host/asm/phi512/decode.S
as --64 -I host/asm/phi512 -o host/asm/out/p512_fnscan.o host/asm/phi512/fnscan.S
gcc -O2 -o fnscan-check tools/fnscan-check.c host/asm/out/p512_fnscan.o host/asm/out/p512_decode.o
fnscan-check libggml-cpu.so [--function NAME] [--evex]
```

Maps the ELF file, takes every `FUNC` symbol of `.symtab` with a size
(one of the aliases at an address), runs `fn_scan`
([`../host/asm/phi512/fnscan.md`](../host/asm/phi512/fnscan.md)) on its
bytes at their file offset with the file's virtual address, and prints
one census line per function: name, address, size, instructions, and
the counts by kind (EVEX, VEX, direct calls inside the object and into
the PLT, indirect calls and jumps, branches inside and out, returns,
locked, traps, `fs`, unknown, rip-relative, labels, flags). The last
line is the total. `--evex` keeps the functions with EVEX instructions;
`--function NAME` prints one function's index (address, offset, length,
kind, flags) to read against `objdump -d`.

The cross-check (2026-10-13): the totals against the iced-x86 dump of
the same file (`avx512-xlate --dump`) summed within `nm -S`'s bounds by
awk: every count equal (255741 instructions, 17243 EVEX, 54248 VEX,
5722 calls, 87 indirect calls, 37 indirect jumps, 770 returns, 18041
branches). `make fnscan-check` runs the census on the translator binary
itself and fails on any decode failure or bad branch target.
