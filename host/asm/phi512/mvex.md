# mvex.S: the emitter

The recipes of [`xlate.S`](xlate.md) write the card's code through
this file: a port of `Em` in `host/crates/avx512-xlate/src/rewrite.rs`,
sequence for sequence, so the forms checked on the card by
`tools/avx512-narrow-test.c` stay what they were.

## What it provides

| group | functions |
| --- | --- |
| bytes | `em_byte`, `em_dword`, `em_bytes` into the emitter's output (`EM_OUT`); past `EM_LIM` the block is marked `EU_FULL` and the blob is refused at the end |
| the prefix | `em_mvex(em, mv)`: one MVEX.512 instruction from an argument block (`MV_*` of [`xlate.inc`](xlate.md): map, pp, W, opcode, reg, vvvv, the r/m form, mask, SSS, immediate); the r/m forms are a register, the decoded instruction's memory operand (base, index, scale, displacement plus an offset; rsp or r12 as the base take a SIB; no base takes the no-base SIB with disp32), an fs-relative scratch slot (64 prefix, SIB 0x25, absolute disp32) and a constant of the blob's pool (rip-relative with a fixup) |
| masks | `em_vexk` (VEX.128.0F.W0 op /r), `em_kand`, `em_knot`, `em_kor`, `em_kmov_kk`, `em_kmov_k_r`, `em_kmov_r_k` |
| the scratch | `em_gpr_scratch` (mov to or from `[fs:scratch + off]`), `em_rax`, `em_rcx`, `em_k`, `em_flags` (lahf; seto al), `em_mov_eax`, `em_mask_imm` (the scratch mask set to a lane mask), `em_gpr_result` (a register loaded last), `em_temp` (a free vector register kept in a scratch slot) |
| constants | `em_const` (64 bytes, deduplicated in the blob's pool), `em_const_dw`, `em_const_qw` |
| vectors | `em_vmov` (vmovaps/apd), `em_zero` (vpxord/q), `em_zero_lanes`, `em_op3` (a three-operand form from a preset block), `em_op2i` (a two-operand form with an immediate), `em_unaligned` (a move of unknown alignment sized by its bytes: [`mvex2.S`](mvex2.md) chooses the aligned move, the pair or the scalar bounce; `em_unaligned_pair` is the vloadunpackld/hd or vpackstoreld/hd pair, each masked, the high half at +64), `em_broadcast` (vbroadcastss/sd; a memory operand through the aligned transfer slot, [`mvex2.md`](mvex2.md)), `em_load_block` (vbroadcasti32x4/64x4: a 16- or 32-byte block, a memory one through the same slot), `em_qmask_to_dmask` (a qword mask spread to dword lanes) |
| the end | `em_finish`: everything restored in the reverse order of the saves (the temporaries, the flags, the scratch mask, rcx, rax, then the registers the sequence produces, last the flags the instruction defines) |

The scratch area is the one `rewrite.rs` laid out (`S_*`: six vector
slots, rax, rcx, a mask, a general register, the flags, the x87 control
word, a transfer slot) plus `S_RIPB` for the base register of a re-based
rip-relative operand; its fs offset on the card is `FX_SCRATCH_TPOFF`
(`card/vpu/proto.inc`, 1536: after the exec context in the slot
threads' TLS block).

## Traps met (2026-10-13)

`em_byte` and `em_dword` clobber rdx: a field read into rdx before an
emit must be read again after it (the SIB's index was a garbage
register for every indexed operand until this was). A form record is 24
bytes: the two shorts after the quad and two longs are padded.

## kmov with r8..r15 (2026-10-14)

The card raises #UD on `kmovw` between a mask register and r8..r15 (the
VEX.R/VEX.B extension of the general register): measured on card 0,
`kmovw %k0,%eax` and `%k1,%eax` run, `%k0,%r9d` and `%k1,%r9d` do not.
llama-server died on it (`kmovw %k0,%r9d` in
`ggml_compute_forward_add_non_quantized`, its first compute). `em_vexk`
now routes those through eax: `mov eax, rN` (41 8B C0+n) then `kmov k,
eax`, or `kmov eax, k` then `mov rN, eax` (41 89 C0+n), rax saved by
the recipe (`em_rax`). Checked on the card: k0/k1 to r9d and r15d and
back to a mask, the sums right. Multi-byte NOPs (0F 1F) run on the card
as they are (measured the same day).
