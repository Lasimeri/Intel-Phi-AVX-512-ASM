# decode-check.c: the assembly decoder against iced-x86

```
as --64 -I host/asm/phi512 -o host/asm/out/p512_decode.o host/asm/phi512/decode.S
gcc -O2 -o decode-check tools/decode-check.c host/asm/out/p512_decode.o
decode-check FILE [SECTION] > asm.dump
avx512-xlate --dump FILE > iced.dump
diff iced.dump asm.dump
```

Walks an ELF file's `.text` (or the named section) through `x86_decode`
([`../host/asm/phi512/decode.md`](../host/asm/phi512/decode.md)) and
prints one line per instruction in the format of `avx512-xlate --dump`,
which is iced-x86's decoding of the same bytes: address, length, flow
control, encoding, the code's name, the memory operand (base, index,
scale, displacement), the last immediate or a branch's target, the mask
register, zeroing, broadcast. The two dumps are meant to be identical;
a decode failure prints `FAIL` and moves one byte on.

The vocabulary follows iced where the two differ only in words: iced
files `syscall` under `Call`, `hlt` under `Next` and `ud2` under
`Exception` (the decoder's flow class for all three is `FL_TRAP`); a 67
prefix names the 32-bit registers; the sign of an immediate follows the
entry's operand kind (`imm8sex32` is signed, `imm32` is not).

`make decode-check` runs it on the translator binary itself, so the
check needs no llama.cpp build. The ten-binary result of 2026-10-13
(2.34 million instructions, 0 differing) is in
[`../docs/results/2026-10-13-decoder.md`](../docs/results/2026-10-13-decoder.md).
