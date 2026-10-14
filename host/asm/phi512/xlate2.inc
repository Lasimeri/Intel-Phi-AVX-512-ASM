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
	FORM MN_Vpcmpgtq, xl_cmpq_pred, 3, 0
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
	FORM MN_Vshuff64x2, xl_shuf_blocks, 0, 0
	FORM MN_Vshufi64x2, xl_shuf_blocks, 0, 0
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
