# decode.S: the x86-64 decoder

The first unit of stage 3 of the restart (the translator in assembly):
every instruction the translator meets goes through `x86_decode` first,
which says how long it is, what it is, and what its operands are.

```
x86_decode(rdi = bytes, rsi = bytes available, rdx = out, rcx = address)
    -> rax = length, 0 if the bytes are not an instruction or run out
```

`out` is the decoded block of [`x86dec.inc`](x86dec.md) (`IN_*`, 96
bytes). The address is the instruction's own, for the targets of
relative branches (`IN_TARGET`) and `IN_NEXT`.

## What it decodes

- Legacy prefixes in any order (66, 67, F0, F2, F3, the segment
  overrides) and REX, which counts only right before the opcode (a REX
  followed by another prefix is dropped, as the processor does).
- The one-byte map, 0F, 0F38 and 0F3A; the two- and three-byte VEX
  prefixes; EVEX (P0 `R X B R' 0 0 m m`, P1 `W vvvv 1 pp`, P2 `z L'L b
  V' aaa`); 3DNow, XOP and the AVX512-FP16 maps are refused.
- ModRM, SIB, disp8 and disp32, rip-relative addressing, the no-base
  and no-index SIB forms; the register extension bits R, X, B, R' and
  V' (V' goes to a VSIB index when the entry has one, to vvvv
  otherwise).
- Immediates by the operand size (the length table carries the bytes at
  16, 32 and 64 bits; `ENTER`'s pair; `MOV AL, moffs`); a relative
  branch's target.
- EVEX's compressed displacement: disp8 times the entry's N, the N of
  the broadcast form when `EVEX.b` is set on a memory operand.
- The flow class (`FL_*`: a conditional or unconditional relative
  branch, a call, a return, an indirect jump or call, a trap, a loop, a
  far form) from the length table.
- Which instruction it is: the entry of [`x86tab.inc`](x86tab.md) under
  (encoding, map, mandatory prefix, opcode) that matches W, L, the
  ModRM.reg group, a fixed r/m (the two-byte opcodes like `0F AE E8`),
  the register or memory form, the operand size and the address size.
  A legacy instruction's 66, F2 or F3 is tried as the mandatory prefix
  first, then as none (a 66 is then a 16-bit operand size). The entry
  gives the operand kinds and the code's name; `IN_ENTRY` is
  `0xffffffff` when nothing matches, and the length still stands.

## Measured (2026-10-13, the rack)

`tools/decode-check.c` ([`../../../tools/decode-check.md`](../../../tools/decode-check.md))
prints one line per instruction of an ELF's `.text` in the format of
`avx512-xlate --dump` (iced-x86's decoding). The two dumps are
identical, every field (length, flow, encoding, code, base, index,
scale, displacement, immediate, mask, zeroing, broadcast), on:

| file | instructions |
| --- | --- |
| `llama.phi/build-avx512f/bin/libggml-cpu.so.0.26.0` | 256896 |
| the twin `build-phi512-cpu/bin/libggml-cpu.so.0.26.0` | 227043 |
| `libllama.so.0` | 660827 |
| `libggml-base.so.0.26.0`, `libggml.so.0.26.0`, `llama-simple` | 141139, 7236, 1173 |
| `/usr/lib/libc.so.6`, `libm.so.6`, `libstdc++.so.6`, `libgomp.so.1` | 403006, 129795, 442442, 73766 |

2.34 million instructions, 0 differing lines, 0 decode failures; the
AVX-512 library in 0.125 s. Record:
[`docs/results/2026-10-13-decoder.md`](../../../docs/results/2026-10-13-decoder.md).

## Register use

rbx the block, r12 the start, r13 the end, r14 the address, r15 the
cursor, ebp the length-table entry, r8 the prefix bits, r9 the REX byte
or the VEX/EVEX extension bits (W R X B in the same positions as a REX
byte, R' and V' above), r10 the ModRM then the operand size the length
table implies. `NEXTB` reads a byte and fails past the end.
