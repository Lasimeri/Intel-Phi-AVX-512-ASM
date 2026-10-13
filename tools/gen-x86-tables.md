# gen-x86-tables.c: the decoder's tables from iced-x86's listing

```
tcc -run tools/gen-x86-tables.c tools/x86-opcodes.txt host/asm/phi512/x86tab.inc host/asm/phi512/x86tab.h
```

The listing `tools/x86-opcodes.txt` is written by `avx512-xlate
--gen-opcodes tools/x86-opcodes.txt` from iced-x86 1.21's `OpCodeInfo`
(`Code::values()`, the crate's `op_code_info` feature): one line per
instruction code that is a 64-bit-mode legacy, VEX or EVEX instruction
needing no decoder option, tab-separated: encoding, opcode table,
mandatory prefix, opcode (hex), opcode bytes, ModRM.reg group, ModRM.rm
group, W, L, tuple type, flags, operand size, address size, the operand
kinds, the mnemonic, the code, the opcode string, the instruction
string. The listing is checked in as the source of record: it survives
the Rust crates' retirement (stage 7 of the restart), and a regenerated
listing from a newer iced is a reviewable diff.

What the tool derives from a line:

- a ModRM byte follows when any operand is encoded in it, when the code
  has a group, or when the opcode has two bytes with the second at or
  above C0 (`0F AE E8` lfence, `D9 C0+i` fld st(i)): that second byte is
  a ModRM with `mod` 3, so the entry gets the group from its `reg` bits
  and a fixed `rm` unless the operand is `sti_opcode`;
- the immediate bytes from the operand kinds (`imm8`, `imm16`,
  `imm32`, `imm64`, the branch displacements, `mem_offs`, the `/is4`
  byte once), per operand size from the `o16`, `o32`, `o64` variants;
- the flow class from the mnemonic (`Jmp`, `Call`, `Ret*`, the
  conditional jumps, `Loop*` and `Jrcxz`, `Syscall`, `Int*`, `Hlt`,
  `Ud*`, the far forms);
- the disp8 scales from the tuple type (`N64b8`: 64, or 8 with
  broadcast);
- the `+r` opcodes (`B8+r`, `50+r`, `90+r`, `0F C8+r`) expanded to
  eight entries;
- a group subtable when the codes of one opcode differ by ModRM.reg in
  their immediate bytes, flow or branch flag (`F7`: `/0 /1 test imm`
  against `/2 not`; `FF`: `/2 call`, `/4 jmp`; `C7`: `/7 xbegin`).

The operand-size defaults (`D`, `F` in the listing's flags) and the
address size are kept per entry (byte 15), not per opcode: a union per
opcode made `rdrand r32` decode as the 64-bit form, because `senduipi`
(`F3 0F C7 /6`) forces 64 for the same opcode and group.

Entries are sorted by key then specificity, so the decoder's first match
is the right one. The layouts are in
[`../host/asm/phi512/x86dec.md`](../host/asm/phi512/x86dec.md), the
output in [`../host/asm/phi512/x86tab.md`](../host/asm/phi512/x86tab.md).
