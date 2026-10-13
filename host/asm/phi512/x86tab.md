# x86tab.inc and x86tab.h: the decoder's tables (generated)

Both files are written by `tools/gen-x86-tables.c`
([`../../../tools/gen-x86-tables.md`](../../../tools/gen-x86-tables.md))
from the listing `tools/x86-opcodes.txt` and are not edited by hand:

```
tcc -run tools/gen-x86-tables.c tools/x86-opcodes.txt host/asm/phi512/x86tab.inc host/asm/phi512/x86tab.h
```

`x86tab.inc` is included at the end of [`decode.S`](decode.md) and
holds, in `.rodata`:

| symbol | what |
| --- | --- |
| `x86_len_tab` | 8 maps x 256 opcodes x 4 bytes: ModRM presence, immediate bytes by operand size, flow class, group flag ([`x86dec.inc`](x86dec.md)'s `LT_*`) |
| `x86_grp_tab` | the group subtables, 8 entries of 4 bytes each, indexed by ModRM.reg |
| `x86_idx` | u16 per (encoding 0 to 2, map 0 to 3, prefix 0 to 3, opcode): the first entry of the key, `0xffff` none |
| `x86_ent`, `x86_nent` | the entries, 24 bytes each (`EN_*`), the entries of one key consecutive, the last flagged `EF_LAST`, the more specific first (a fixed r/m, then a group, then a form, then a size, then W and L) |
| `x86_code_off`, `x86_code_str` | the code names (iced-x86's `Code` names, for diagnostics: "EVEX_Vpaddq_zmm_k1z_zmm_zmmm512b64") |
| `x86_mnem_off`, `x86_mnem_str` | the mnemonics |

`x86tab.h` gives C tools the same: the operand-kind enum (`OK_*`, iced's
numbering and names), the `LT_*`, `FL_*`, `EF_*` and `EX_*` constants,
`struct x86_ent`, and the extern declarations.

Counts on 2026-10-13: 4079 codes (iced-x86 1.21's 64-bit legacy, VEX
and EVEX codes needing no decoder option; the AVX512-FP16 maps left
out), 4177 entries (the `+r` opcodes expanded to eight), 1535
mnemonics, 16 group subtables.
