# x86dec.inc: the decoder's layouts

The constants [`decode.S`](decode.md) and its callers share: the decoded
block, the length table's entries, the instruction entries of
[`x86tab.inc`](x86tab.md). `tools/gen-x86-tables.c` writes the C mirror
`x86tab.h` for [`tools/decode-check.c`](../../../tools/decode-check.md);
the two are kept in step by hand (a drift shows at once as a differing
dump).

## The decoded block (`IN_*`, 96 bytes)

| field | holds |
| --- | --- |
| `IN_LEN` | the instruction's bytes, 0 after a failure |
| `IN_ENC`, `IN_MAP`, `IN_PP`, `IN_OP` | legacy, VEX or EVEX; the opcode map; the prefix the entry matched under; the opcode byte |
| `IN_PFX`, `IN_REX`, `IN_W`, `IN_L` | the legacy prefixes seen (`P_*`); the REX byte or the VEX/EVEX extension bits (`X_*`); W; the vector length |
| `IN_MODRM`, `IN_HAS`, `IN_MOD`, `IN_REG`, `IN_RM` | the ModRM byte, what is present (`H_*`), and its fields with the extension bits applied |
| `IN_BASE`, `IN_INDEX`, `IN_SCALE` | the memory operand (`0xff` for no base or no index; `H_RIPREL` for rip-relative) |
| `IN_VVVV`, `IN_AAA`, `IN_Z`, `IN_B` | the VEX/EVEX register source (not inverted), the mask, zeroing, broadcast or rounding |
| `IN_FLOW` | `FL_*` |
| `IN_IMM_OFF`, `IN_IMM_SZ`, `IN_DISP_OFF`, `IN_DISP_SZ`, `IN_OP_OFF`, `IN_MODRM_OFF` | where the pieces lie in the instruction (the translator rewrites around them) |
| `IN_OPSIZE`, `IN_IMM2`, `IN_N` | the legacy operand size in bytes, `ENTER`'s second immediate, the disp8 scale applied |
| `IN_ENTRY`, `IN_ENTRYP` | the entry's index and pointer (`0xffffffff` and 0 when none) |
| `IN_DISP`, `IN_IMM`, `IN_TARGET`, `IN_NEXT` | the displacement (signed, scaled), the immediate (zero-extended by its size; the entry's operand kind says whether it is signed), a relative branch's target, the next instruction's address |

## The length table (`LT_*`)

Eight maps of 256 entries of 4 bytes (legacy one-byte, 0F, 0F38, 0F3A,
then the VEX/EVEX 0F, 0F38, 0F3A, one spare): flags (`LT_MODRM`,
`LT_GROUP`, `LT_D64`, `LT_INVALID`, `LT_PFX`, `LT_ESC`, `LT_F64`,
`LT_X87`), the immediate bytes at operand size 32 and 16 (`LT_IMM`, two
nibbles) and at 64 (`LT_IMM64`, with `LI_REL` for a branch displacement
and `LI_MOFFS` for a 64-bit memory offset), the flow class. A group
entry's `LT_IMM` is the index of its subtable of eight entries in
`x86_grp_tab`, one per ModRM.reg.

## An entry (`EN_*`, 24 bytes)

W (2 any), L (3 any), the ModRM.reg group (255 any), a fixed r/m (255
any), the required form (any, register, memory), the disp8 scale without
and with broadcast, flags (`EF_*`), the operand size (0 any, 2, 4, 8),
the operand count and five operand kinds in iced-x86's numbering, byte
15 with the address size (`EX_ASIZE`: 0 any, 1 32-bit, 2 64-bit) and the
operand-size defaults (`EX_D64`: 64 unless a 66 prefix; `EX_F64`: 64
whatever the prefix), then the indexes of the code's and the mnemonic's
names. `EF_LAST` marks the last entry of a key.
