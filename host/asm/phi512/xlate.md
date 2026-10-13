# xlate.S and xlate.inc: the recipes

`xl_insn(blob, in)` writes one vector instruction of the program (as
[`decode.S`](decode.md) decoded it, its rip-relative operand already
re-based by [`blob.S`](blob.md)) as the card's MVEX through the emitter
([`mvex.S`](mvex.md)). The recipe is chosen by mnemonic (`x86mnem.inc`,
the ids of `x86tab.inc`'s entries): the `xl_forms` list, a 24-byte
record per mnemonic (handler, an encoding word `map | pp << 8 | w << 16
| op << 24`, a flags word), filled into `xl_tab` at `xl_init`. The
instruction's operands are read from the decoded block: reg, rm or the
memory operand, vvvv, the mask, zeroing, broadcast, the vector length
(`EV_LL`: VEX L or EVEX L'L; EVEX.b on a register form means 512), W.

## The rules every recipe follows

- A 512-bit operation on the lanes the mask selects is one MVEX
  instruction (the one-to-one forms).
- A 128- or 256-bit form is the same operation under a lane mask
  (`vl_lanes`: 4, 8 or 16 dword lanes, 2, 4 or 8 qword ones), the lanes
  above the length zeroed after (`upper_lanes`), as EVEX and VEX require.
- Zeroing masking zeroes the unselected lanes after (`commit`, the port
  of `rewrite.rs`'s).
- A memory operand that is not an aligned move is staged through the
  unaligned pair into a temporary (`src2`), since the card needs every
  memory operand aligned to its size (ISA reference 327364-001, 2.1.1);
  an embedded broadcast is the card's own `{1to16}` (SSS 001) on the
  operand.

## The recipes

| recipe | mnemonics | how |
| --- | --- | --- |
| `xl_nds` | vaddps/pd, vsubps/pd, vmulps/pd, the twelve FMA forms (ps, the three fmadd pd), vpaddd, vpsubd, vpandd/nd/ord/xord and the q forms, vpmulld, vpmin/max sd/ud, vpsllvd/srlvd/sravd, vpermd; the VEX names vpand/n/or/xor, vxorps/andps/orps/andnps, vxorpd/andpd | d{k} = op(vvvv, r/m) one to one; the mask from the length and {k}; commit |
| `xl_shift_imm` | vpslld /6, vpsrld /2, vpsrad /4 | the card's NDD form (66.0F 72 /n ib, the destination in vvvv) |
| `xl_cmp_k` | vpcmpeqd (76), vpcmpgtd (66), vpcmpd (0F3A 1F ib), vpcmpud (1E ib), vcmpps/pd (C2 ib) | one to one into the mask register; the integer predicates 3 (false) and 7 (true) and any above 7 are refused |
| `xl_mov_aligned` | vmovaps/apd/dqa32/dqa64 (and VEX vmovdqa) | 512: the card's aligned move under the mask (28/29), {z} after; narrower: a load reads its block with a block broadcast, a store is the pack pair under the lanes; register to register the same |
| `xl_mov_unaligned` | vmovups/upd/dqu32/dqu64 (and VEX vmovdqu) | the unaligned pair; a program mask applied by lane through a temporary (a qword mask spread) |
| `xl_broadcast` | vbroadcastss/sd, vpbroadcastd/q | from memory the card's own (18/19); from a vector register vpshufd 0 then vpermf32x4 0; from a general register through the transfer slot |
| `xl_ternlog` | vpternlogd/q (register forms) | 0xff a constant, 0x00 a zero, a table independent of d one two-input function (`bool2`), else d = (d and f1) or (not d and f0) |
| `xl_extract` | vextract{f,i}{32x4,64x2,128} and {64x4,32x8} | vpermf32x4 moving the block or half to the bottom (the destination is the r/m operand), the lanes above zeroed; to memory the pack pair |
| `xl_permilps` | vpermilps imm, vpshufd | the card's vpshufd with the same immediate |
| `xl_shufps` | vshufps | two vpshufd under 0x3333 and 0xcccc into a temporary |
| `xl_movss` | vmovss/sd | register form: lane 0 from s2, lanes 1 to 3 from s1; load: a broadcast under lane 0; store: the pack pair under lane 0 |
| `xl_scalar` | vaddss/subss/mulss, the sd forms, vfmadd132/213/231ss | the packed operation under lane 0 (lanes 0 and 1 for sd), lanes 1 to 3 from s1; a memory operand as a broadcast source; {z} under a mask refused |
| `xl_nothing`, `xl_zeroall` | vzeroupper, vzeroall | nothing (the handler zeroes the upper halves at the return); zmm0 to zmm15 zeroed |

A mnemonic without a recipe refuses the function ("no recipe for this
instruction"); the refusal names the instruction's offset.

## Measured (2026-10-13, four cards)

`tools/avx512-seamless-test.c`'s three kernels from automatic
translation, bit-identical at 65536, 1M and 16M elements, in the time of
the hand-written blobs of `seeds.S` (16M: polynomial 71.6 ms against
72.0, dot product 182.0 against 177.3, integers 57.7 against 57.3):
[`docs/results/2026-10-13-translator-seamless.md`](../../../docs/results/2026-10-13-translator-seamless.md).
