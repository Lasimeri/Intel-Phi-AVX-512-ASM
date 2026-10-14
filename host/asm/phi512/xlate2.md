# xlate2.S: the second file of recipes

Included by `xlate.S` at its end, so the two are one assembly unit and
the helpers (`commit`, `src2`, `vl_lanes`, the macros `LOADCTX` and
`EV_LL`, the refusal and byte strings) are in reach; its forms are in
`xlate2.inc`, included in `xlate.S`'s table before `xl_forms_end`. The
recipes are ports of `host/crates/avx512-xlate/src/rewrite.rs`,
sequence for sequence, written over a set of macros that read like the
Rust: `R_ENTER` builds the frame (the MVEX block at 0, the
instruction's reg, vvvv, rm, mask and vector length as dwords, six
slots `FR0` to `FR5`), `R_MVEX` emits one card instruction from
immediates, frame slots or callee-saved registers, `R_VMOV`, `R_ZERO`,
`R_SHIFT`, `R_VPSHUFD`, `R_VPERMD`, `R_VCMP` and the rest name the
instruction they emit, `R_SRC2` stages the second source, `R_TEMP`
takes a temporary, `R_COMMIT` writes the result under the mask, `{z}`
and the length.

Recipes (2026-10-13 evening): `xl_addsubq` (vpaddq, vpsubq), `xl_shiftq`
(vpsrlq, vpsllq, vpsraq by immediate), `xl_muludq`, `q_lt_eq` with
`xl_minmax_q` (vpmaxsq, vpminsq, vpmaxuq, vpminuq) and `xl_cmpq_pred`
(vpcmpq, vpcmpuq, vpcmpgtq), `xl_testm` (vptestnmd, vptestmq,
vptestnmq), `xl_widen` (vpmovzxbd, vpmovsxbd, vpmovzxwd, vpmovsxwd),
`xl_widen_dq`, `xl_cvt_to_int` (vcvttps2dq, vcvtps2dq), `xl_cvt_pd2ps`,
`xl_op2` (vcvtdq2ps, vcvtudq2ps, vgetexpps, vgetmantps), `xl_minmax`
(vminps, vmaxps, vminpd, vmaxpd), `xl_fma_addsub`, `xl_shuf_blocks`,
`xl_insertps`, `xl_abs_d`, `xl_byte_shift` (vpsrldq, vpslldq, vpalignr
by whole dwords), `xl_mov_u8` (vmovdqu8 and vmovdqu16 unmasked),
`xl_kmovb`, `xl_kshift`; forms over the existing recipes for
vpblendmd/q, vblendmps/pd, valignd, vinserti64x2, vinsertf64x2, kmovd,
kmovq, vptestmd.

State: assembled and counted by `tools/recipe-census.c`; the sequences
have not yet run on a card. The form suites (`tools/avx512-f-forms-test.c`,
`tools/avx512-narrow-test.c`) on card 0 are the check.
