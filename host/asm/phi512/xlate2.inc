# xlate2.inc: the forms of xlate2.S's recipes, included in xlate.S's
# table (FORM mnemonic, handler, XF_A, XF_B). See xlate2.md.
	.set XB_FIX, 32				# the immediate is fixed: bits 8 to 15 of XF_B
	# qword integer arithmetic in dword lanes
	FORM MN_Vpaddq, xl_addsubq, 0xfe, 0
	FORM MN_Vpsubq, xl_addsubq, 0xfa, 0
	FORM MN_Vpsrlq, xl_shiftq, 0, 0
	FORM MN_Vpsllq, xl_shiftq, 1, 0
	FORM MN_Vpsraq, xl_shiftq, 2, 0
	FORM MN_Vpmuludq, xl_muludq, 0, 0
	FORM MN_Vpmaxsq, xl_minmax_q, 3, 0
	FORM MN_Vpminsq, xl_minmax_q, 2, 0
	FORM MN_Vpmaxuq, xl_minmax_q, 1, 0
	FORM MN_Vpminuq, xl_minmax_q, 0, 0
	FORM MN_Vpcmpq, xl_cmpq_pred, 1, 0
	FORM MN_Vpcmpuq, xl_cmpq_pred, 0, 0
	FORM MN_Vpcmpgtq, xl_cmpq_vec, 3, 0
	FORM MN_Vptestmd, xl_cmp_k, (2 | (1 << 8) | (0 << 16) | (0x27 << 24)), 0
	FORM MN_Vptestnmd, xl_testm, 1, 0
	FORM MN_Vptestmq, xl_testm, 2, 0
	FORM MN_Vptestnmq, xl_testm, 3, 0
	# widening and narrowing conversions
	FORM MN_Vpmovzxbd, xl_widen, 4, 1
	FORM MN_Vpmovsxbd, xl_widen, 5, 1
	FORM MN_Vpmovzxwd, xl_widen, 6, 2
	FORM MN_Vpmovsxwd, xl_widen, 7, 2
	FORM MN_Vpmovzxdq, xl_widen_dq, 0, 0
	FORM MN_Vpmovsxdq, xl_widen_dq, 1, 0
	FORM MN_Vcvttps2dq, xl_cvt_to_int, 1, 0
	FORM MN_Vcvtps2dq, xl_cvt_to_int, 0, 0
	FORM MN_Vcvtpd2ps, xl_cvt_pd2ps, 0, 0
	# two operands, the card's own instruction, an immediate fixed or the program's
	FORM MN_Vcvtdq2ps, xl_op2, (3 | (0 << 8) | (0 << 16) | (0xcb << 24)), XB_FIX | XB_FLOAT
	FORM MN_Vcvtudq2ps, xl_op2, (3 | (0 << 8) | (0 << 16) | (0xca << 24)), XB_FIX | XB_FLOAT
	FORM MN_Vgetexpps, xl_op2, (2 | (1 << 8) | (0 << 16) | (0x42 << 24)), XB_FLOAT
	FORM MN_Vgetmantps, xl_op2, (3 | (1 << 8) | (0 << 16) | (0x26 << 24)), XB_IMM | XB_FLOAT
	# three operands with an immediate; the blends by mask
	FORM MN_Valignd, xl_nds, (3 | (1 << 8) | (0 << 16) | (0x03 << 24)), XB_IMM
	FORM MN_Vpblendmd, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x64 << 24)), 0
	FORM MN_Vpblendmq, xl_nds, (2 | (1 << 8) | (1 << 16) | (0x64 << 24)), XB_QWORD
	FORM MN_Vblendmps, xl_nds, (2 | (1 << 8) | (0 << 16) | (0x65 << 24)), XB_FLOAT
	FORM MN_Vblendmpd, xl_nds, (2 | (1 << 8) | (1 << 16) | (0x65 << 24)), XB_FLOAT | XB_QWORD
	# float min and max with AVX-512's choice of operand
	FORM MN_Vminps, xl_minmax, 0, XB_FLOAT
	FORM MN_Vmaxps, xl_minmax, 1, XB_FLOAT
	FORM MN_Vminpd, xl_minmax, 0, XB_FLOAT | XB_QWORD
	FORM MN_Vmaxpd, xl_minmax, 1, XB_FLOAT | XB_QWORD
	# fused multiply add/subtract by lane parity
	FORM MN_Vfmaddsub132ps, xl_fma_addsub, 0, XB_FLOAT
	FORM MN_Vfmaddsub213ps, xl_fma_addsub, 0, XB_FLOAT
	FORM MN_Vfmaddsub231ps, xl_fma_addsub, 0, XB_FLOAT
	FORM MN_Vfmsubadd132ps, xl_fma_addsub, 0, XB_FLOAT
	FORM MN_Vfmsubadd213ps, xl_fma_addsub, 0, XB_FLOAT
	FORM MN_Vfmsubadd231ps, xl_fma_addsub, 0, XB_FLOAT
	FORM MN_Vfmaddsub132pd, xl_fma_addsub, 0, XB_FLOAT | XB_QWORD
	FORM MN_Vfmaddsub213pd, xl_fma_addsub, 0, XB_FLOAT | XB_QWORD
	FORM MN_Vfmaddsub231pd, xl_fma_addsub, 0, XB_FLOAT | XB_QWORD
	FORM MN_Vfmsubadd132pd, xl_fma_addsub, 0, XB_FLOAT | XB_QWORD
	FORM MN_Vfmsubadd213pd, xl_fma_addsub, 0, XB_FLOAT | XB_QWORD
	FORM MN_Vfmsubadd231pd, xl_fma_addsub, 0, XB_FLOAT | XB_QWORD
	# blocks, lanes, bytes
	FORM MN_Vshuff32x4, xl_shuf_blocks, 0, 0
	FORM MN_Vshufi32x4, xl_shuf_blocks, 0, 0
	FORM MN_Vshuff64x2, xl_shuf_blocks, 0, XB_QWORD
	FORM MN_Vshufi64x2, xl_shuf_blocks, 0, XB_QWORD
	FORM MN_Vinsertps, xl_insertps, 0, 0
	FORM MN_Vpabsd, xl_abs_d, 0, 0
	FORM MN_Vpsrldq, xl_byte_shift, 0, 0
	FORM MN_Vpslldq, xl_byte_shift, 1, 0
	FORM MN_Vpalignr, xl_byte_shift, 2, 0
	FORM MN_Vmovdqu8, xl_mov_u8, 0, 0
	FORM MN_Vmovdqu16, xl_mov_u8, 0, 0
	FORM MN_Vinserti64x2, xl_insert, 0, 0
	FORM MN_Vinsertf64x2, xl_insert, 0, 0
	# mask registers
	FORM MN_Kmovb, xl_kmovb, 0, 0
	FORM MN_Kmovd, xl_kmov, 0, 0
	FORM MN_Kmovq, xl_kmov, 0, 0
	FORM MN_Kshiftlw, xl_kshift, 1, 16
	FORM MN_Kshiftrw, xl_kshift, 0, 16
	FORM MN_Kshiftlb, xl_kshift, 1, 8
	FORM MN_Kshiftrb, xl_kshift, 0, 8
	FORM MN_Kshiftld, xl_kshift, 1, 16
	FORM MN_Kshiftrd, xl_kshift, 0, 16
	FORM MN_Kshiftlq, xl_kshift, 1, 16
	FORM MN_Kshiftrq, xl_kshift, 0, 16
	# batch 2b: blends, the word forms, the byte-to-word widening, the saturating packs
	FORM MN_Vpblendd, xl_blendd, 0, 0
	FORM MN_Vpblendw, xl_blendw, 0, 0
	FORM MN_Vblendvps, xl_blendv, 0, 0
	FORM MN_Vblendvpd, xl_blendv, 1, 0
	FORM MN_Vpblendvb, xl_blendv, 2, 0
	FORM MN_Vpsrlw, xl_shiftw, 0, 0
	FORM MN_Vpsllw, xl_shiftw, 1, 0
	FORM MN_Vpsraw, xl_shiftw, 2, 0
	FORM MN_Vpaddw, xl_addw, 0, 0
	FORM MN_Vpsubw, xl_addw, 1, 0
	FORM MN_Vpmullw, xl_mullw, 0, 0
	FORM MN_Vmovlps, xl_movlh, 0, 0
	FORM MN_Vmovlpd, xl_movlh, 0, 0
	FORM MN_Vmovhps, xl_movlh, 1, 0
	FORM MN_Vmovhpd, xl_movlh, 1, 0
	FORM MN_Vpmovzxbw, xl_widen_bw, 4, 0
	FORM MN_Vpmovsxbw, xl_widen_bw, 5, 0
	FORM MN_Vpackusdw, xl_packusdw, 0, 0
	FORM MN_Vpackuswb, xl_packuswb, 0, 0
	FORM MN_Vcvtps2pd, xl_cvtps2pd, 0, 0
	FORM MN_Vminss, xl_sminmax, 0, 0
	FORM MN_Vmaxss, xl_sminmax, 1, 0
	FORM MN_Vminsd, xl_sminmax, 0, XB_QWORD
	FORM MN_Vmaxsd, xl_sminmax, 1, XB_QWORD
	FORM MN_Vmovshdup, xl_op2, (1 | (1 << 8) | (0 << 16) | (0x70 << 24)), XB_FIX | (0xf5 << 8)
	FORM MN_Vmovsldup, xl_op2, (1 | (1 << 8) | (0 << 16) | (0x70 << 24)), XB_FIX | (0xa0 << 8)
	FORM MN_Vmovddup, xl_op2, (1 | (1 << 8) | (0 << 16) | (0x70 << 24)), XB_FIX | (0x44 << 8)
	# the scalar fused multiply-adds: the card's packed opcode (the scalar one less its low bit) on lane 0
	FORM MN_Vfmsub132ss, xl_scalar, (2 | (1 << 8) | (0 << 16) | (0x9a << 24)), 0
	FORM MN_Vfmsub213ss, xl_scalar, (2 | (1 << 8) | (0 << 16) | (0xaa << 24)), 0
	FORM MN_Vfmsub231ss, xl_scalar, (2 | (1 << 8) | (0 << 16) | (0xba << 24)), 0
	FORM MN_Vfnmadd132ss, xl_scalar, (2 | (1 << 8) | (0 << 16) | (0x9c << 24)), 0
	FORM MN_Vfnmadd213ss, xl_scalar, (2 | (1 << 8) | (0 << 16) | (0xac << 24)), 0
	FORM MN_Vfnmadd231ss, xl_scalar, (2 | (1 << 8) | (0 << 16) | (0xbc << 24)), 0
	FORM MN_Vfnmsub132ss, xl_scalar, (2 | (1 << 8) | (0 << 16) | (0x9e << 24)), 0
	FORM MN_Vfnmsub213ss, xl_scalar, (2 | (1 << 8) | (0 << 16) | (0xae << 24)), 0
	FORM MN_Vfnmsub231ss, xl_scalar, (2 | (1 << 8) | (0 << 16) | (0xbe << 24)), 0
	FORM MN_Vfmadd132sd, xl_scalar, (2 | (1 << 8) | (1 << 16) | (0x98 << 24)), XB_QWORD
	FORM MN_Vfmadd213sd, xl_scalar, (2 | (1 << 8) | (1 << 16) | (0xa8 << 24)), XB_QWORD
	FORM MN_Vfmadd231sd, xl_scalar, (2 | (1 << 8) | (1 << 16) | (0xb8 << 24)), XB_QWORD
	FORM MN_Vfmsub132sd, xl_scalar, (2 | (1 << 8) | (1 << 16) | (0x9a << 24)), XB_QWORD
	FORM MN_Vfmsub213sd, xl_scalar, (2 | (1 << 8) | (1 << 16) | (0xaa << 24)), XB_QWORD
	FORM MN_Vfmsub231sd, xl_scalar, (2 | (1 << 8) | (1 << 16) | (0xba << 24)), XB_QWORD
	FORM MN_Vfnmadd132sd, xl_scalar, (2 | (1 << 8) | (1 << 16) | (0x9c << 24)), XB_QWORD
	FORM MN_Vfnmadd213sd, xl_scalar, (2 | (1 << 8) | (1 << 16) | (0xac << 24)), XB_QWORD
	FORM MN_Vfnmadd231sd, xl_scalar, (2 | (1 << 8) | (1 << 16) | (0xbc << 24)), XB_QWORD
	FORM MN_Vfnmsub132sd, xl_scalar, (2 | (1 << 8) | (1 << 16) | (0x9e << 24)), XB_QWORD
	FORM MN_Vfnmsub213sd, xl_scalar, (2 | (1 << 8) | (1 << 16) | (0xae << 24)), XB_QWORD
	FORM MN_Vfnmsub231sd, xl_scalar, (2 | (1 << 8) | (1 << 16) | (0xbe << 24)), XB_QWORD
	# batch 2c: the byte narrowing, gathers and scatters, half floats, scalef, valignq, rounding
	FORM MN_Vpmovdb, xl_narrow_db, 0, 0
	FORM MN_Vpgatherdd, xl_gather, 0, 0
	FORM MN_Vgatherdps, xl_gather, 0, 0
	FORM MN_Vpgatherdq, xl_gather, 0, 0
	FORM MN_Vgatherdpd, xl_gather, 0, 0
	FORM MN_Vpscatterdd, xl_gather, 0, 0
	FORM MN_Vscatterdps, xl_gather, 0, 0
	FORM MN_Vpscatterdq, xl_gather, 0, 0
	FORM MN_Vscatterdpd, xl_gather, 0, 0
	FORM MN_Vcvtph2ps, xl_cvt_ph2ps, 0, 0
	FORM MN_Vcvtps2ph, xl_cvt_ps2ph, 0, 0
	FORM MN_Vscalefps, xl_scalef, 0, 0
	FORM MN_Valignq, xl_valignq, 0, 0
	FORM MN_Vrndscaleps, xl_rndscale, 0, 0
	FORM MN_Vrndscalepd, xl_rndscale, 1, 0
	FORM MN_Vrndscaless, xl_rndscale, 2, 0
	FORM MN_Vrndscalesd, xl_rndscale, 3, 0
	# the permutes
	FORM MN_Vpermi2d, xl_permute, 0, 0
	FORM MN_Vpermi2ps, xl_permute, 0, 0
	FORM MN_Vpermt2d, xl_permute, 1, 0
	FORM MN_Vpermt2ps, xl_permute, 1, 0
	FORM MN_Vpermi2q, xl_permute, 2, 0
	FORM MN_Vpermi2pd, xl_permute, 2, 0
	FORM MN_Vpermt2q, xl_permute, 3, 0
	FORM MN_Vpermt2pd, xl_permute, 3, 0
	FORM MN_Vpermq, xl_permute, 4, 0
	FORM MN_Vpermpd, xl_permute, 4, 0
	FORM MN_Vpermilpd, xl_permute, 5, 0
	FORM MN_Vpermps, xl_permd2, 0, 0
	# the scalar conversions
	FORM MN_Vcvtusi2ss, xl_cvti2s, 2, 0
	FORM MN_Vcvtusi2sd, xl_cvti2s, 3, 0
	FORM MN_Vcvtss2si, xl_cvts2i, 0, 0
	FORM MN_Vcvttss2si, xl_cvts2i, 1, 0
	FORM MN_Vcvtsd2si, xl_cvts2i, 2, 0
	FORM MN_Vcvttsd2si, xl_cvts2i, 3, 0
	FORM MN_Vcvtss2usi, xl_cvts2i, 4, 0
	FORM MN_Vcvttss2usi, xl_cvts2i, 5, 0
	FORM MN_Vcvtsd2usi, xl_cvts2i, 6, 0
	FORM MN_Vcvttsd2usi, xl_cvts2i, 7, 0
	# division and square root by Newton-Raphson from the card's estimates
	FORM MN_Vdivps, xl_divsqrt, 0, XB_FLOAT
	FORM MN_Vdivpd, xl_divsqrt, 1, XB_FLOAT | XB_QWORD
	FORM MN_Vsqrtps, xl_divsqrt, 2, XB_FLOAT
	FORM MN_Vsqrtpd, xl_divsqrt, 3, XB_FLOAT | XB_QWORD
