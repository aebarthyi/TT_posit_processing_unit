module posit_mac(clk, rst_n, in1_i, in2_i, mac_start_i, read_start_i, clear_start_i, posit_o, inf_o, zero_o, done_o, ovf_o);

function [31:0] log2;
input reg [31:0] value;
	begin
	value = value-1;
	for (log2=0; value>0; log2=log2+1)
        	value = value>>1;
      	end
endfunction

parameter N = 8;
parameter es = 2;
parameter Bs = log2(N);
parameter QUIRE_W = 64;
parameter QBP = 32;

input clk, rst_n;
input [N-1:0] in1_i, in2_i;
input mac_start_i, read_start_i, clear_start_i;
output [N-1:0] posit_o;
output inf_o, zero_o, done_o, ovf_o;

// =============================================
// MULTIPLY PATH
// =============================================

wire s1_w = in1_i[N-1];
wire s2_w = in2_i[N-1];
wire prod_sign_w = s1_w ^ s2_w;

wire zero_tmp1_w = |in1_i[N-2:0];
wire zero_tmp2_w = |in2_i[N-2:0];
wire inf1_w = in1_i[N-1] & ~zero_tmp1_w;
wire inf2_w = in2_i[N-1] & ~zero_tmp2_w;
wire zero1_w = ~in1_i[N-1] & ~zero_tmp1_w;
wire zero2_w = ~in2_i[N-1] & ~zero_tmp2_w;
wire prod_inf_w = inf1_w | inf2_w;
wire prod_zero_w = zero1_w | zero2_w;

wire [N-1:0] xin1_w = s1_w ? -in1_i : in1_i;
wire [N-1:0] xin2_w = s2_w ? -in2_i : in2_i;

wire rc1_w, rc2_w;
wire [Bs-1:0] regime1_w, regime2_w;
wire [es-1:0] e1_w, e2_w;
wire [N-es-1:0] mant1_w, mant2_w;

data_extract_v1 #(.N(N),.es(es)) de1(
	.in(xin1_w), .rc(rc1_w), .regime(regime1_w), .exp(e1_w), .mant(mant1_w));
data_extract_v1 #(.N(N),.es(es)) de2(
	.in(xin2_w), .rc(rc2_w), .regime(regime2_w), .exp(e2_w), .mant(mant2_w));

wire [N-es:0] m1_w = {zero_tmp1_w, mant1_w};
wire [N-es:0] m2_w = {zero_tmp2_w, mant2_w};

// Mantissa multiply
wire [2*(N-es)+1:0] prod_mant_w = m1_w * m2_w;
wire mant_ovf_w = prod_mant_w[2*(N-es)+1];

// Normalize: leading 1 at MSB
wire [2*(N-es)+1:0] prod_mN_w = mant_ovf_w ? prod_mant_w : {prod_mant_w[2*(N-es):0], 1'b0};

// Scale = {r1,e1} + {r2,e2} + mant_overflow
wire [Bs+1:0] r1_w = rc1_w ? {2'b0, regime1_w} : -regime1_w;
wire [Bs+1:0] r2_w = rc2_w ? {2'b0, regime2_w} : -regime2_w;
wire [Bs+es+1:0] scale_w;
add_N_Cin #(.N(Bs+es+1)) scale_add({r1_w, e1_w}, {r2_w, e2_w}, mant_ovf_w, scale_w);

// =============================================
// PRODUCT TO 64-BIT FIXED POINT
// =============================================

// prod_mN_w is (2*(N-es)+2) bits with leading 1 at MSB
// Product value = prod_mN_w * 2^(scale_w - (2*(N-es)+1))
// In Q32.32: quire_val = int_val * 2^-32
// So fixed_point_int = prod_mN_w * 2^(scale_w - (2*(N-es)+1) + 32)
//                    = prod_mN_w << (scale_w + 32 - 2*(N-es) - 1)
//                    = prod_mN_w << (scale_w + 32 - 11)  [for N=8,es=2: 2*6+1=13, wait]
// 2*(N-es)+1 = 2*6+1 = 13. prod_mN_w MSB at bit 13. No wait:
// [2*(N-es)+1:0] means MSB index is 2*(N-es)+1 = 13. Width is 14 bits.
// Hmm let me recount. m1 is [N-es:0] = 7 bits. m2 is 7 bits.
// prod = m1*m2: max = (2^7-1)^2 = 16129, fits in 14 bits.
// [2*(N-es)+1:0] = [13:0] = 14 bits. MSB is bit 13.
// After normalization, leading 1 is at bit 13.
//
// Product value = prod_mN_w[13:0] * 2^(scale_w - 13)
// Fixed point = prod_mN_w * 2^(scale_w - 13 + 32) = prod_mN_w << (scale_w + 19)

localparam PROD_W = 2*(N-es)+2; // 14 bits for N=8,es=2
localparam SHIFT_BASE = QBP - (PROD_W - 1); // 32 - 13 = 19

// Compute left shift amount: scale_w + SHIFT_BASE
// scale_w is [Bs+es+1:0] = [6:0] = 7 bits signed
// SHIFT_BASE = 19
// Result range: scale_w in [-48,48] + 19 = [-29, 67]
wire signed [7:0] raw_shift_w = $signed({scale_w[Bs+es+1], scale_w}) + SHIFT_BASE[7:0];

wire prod_udf_w = raw_shift_w[7]; // negative shift = underflow
wire prod_ovf_w = (~raw_shift_w[7]) & (raw_shift_w > (QUIRE_W - PROD_W)); // > 50

wire [5:0] left_shift_amt_w = prod_udf_w ? 6'd0 :
	(prod_ovf_w ? 6'd50 : raw_shift_w[5:0]);

wire [QUIRE_W-1:0] prod_base_w = {{(QUIRE_W-PROD_W){1'b0}}, prod_mN_w};
wire [QUIRE_W-1:0] prod_shifted_w;
DSR_left_N_S #(.N(QUIRE_W), .S(6)) prod_shift(
	.a(prod_base_w), .b(left_shift_amt_w), .c(prod_shifted_w));

wire [QUIRE_W-1:0] prod_fixed_w = (prod_udf_w | prod_zero_w | prod_inf_w) ?
	{QUIRE_W{1'b0}} : prod_shifted_w;

// 2's complement for negative products
wire [QUIRE_W-1:0] prod_tc_w = prod_sign_w ? -prod_fixed_w : prod_fixed_w;

// =============================================
// QUIRE REGISTER
// =============================================

reg [QUIRE_W-1:0] quire_r;
reg ovf_r;

wire [QUIRE_W-1:0] quire_next_w = quire_r + prod_tc_w;

// Overflow detection: sign of quire and product agree but result sign differs
wire acc_ovf_w = (~quire_r[QUIRE_W-1] & ~prod_tc_w[QUIRE_W-1] & quire_next_w[QUIRE_W-1]) |
	(quire_r[QUIRE_W-1] & prod_tc_w[QUIRE_W-1] & ~quire_next_w[QUIRE_W-1]);

always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		quire_r <= {QUIRE_W{1'b0}};
		ovf_r <= 1'b0;
	end else if (clear_start_i & ~done_r) begin
		quire_r <= {QUIRE_W{1'b0}};
		ovf_r <= 1'b0;
	end else if (mac_start_i & ~done_r & ~prod_inf_w) begin
		if (acc_ovf_w | prod_ovf_w) begin
			// Clamp to max positive or max negative on overflow
			quire_r <= prod_tc_w[QUIRE_W-1] ?
				{1'b1, {QUIRE_W-1{1'b0}}} + 1 :  // most negative representable
				{1'b0, {QUIRE_W-1{1'b1}}};        // most positive representable
		end else begin
			quire_r <= quire_next_w;
		end
		ovf_r <= ovf_r | acc_ovf_w | prod_ovf_w;
	end
end

// =============================================
// QUIRE TO POSIT8 CONVERSION
// =============================================

wire quire_zero_w = (quire_r == {QUIRE_W{1'b0}});
wire quire_sign_w = quire_r[QUIRE_W-1];
wire [QUIRE_W-1:0] quire_abs_w = quire_sign_w ? -quire_r : quire_r;

// Leading one detector on magnitude (64-bit)
wire [5:0] lzc_w; // leading zero count
LOD_N #(.N(QUIRE_W)) quire_lod(.in(quire_abs_w), .out(lzc_w));

// Scale = (63 - lzc) - 32 = 31 - lzc
wire signed [6:0] q_scale_w = 7'sd31 - {1'b0, lzc_w};

// Left-shift quire magnitude so leading 1 is at bit 63
wire [QUIRE_W-1:0] quire_shifted_w;
DSR_left_N_S #(.N(QUIRE_W), .S(6)) quire_shift(
	.a(quire_abs_w), .b(lzc_w), .c(quire_shifted_w));

// Extract mantissa, G, R, S from shifted quire
// Bit 63 = leading 1 (implicit)
// Bits [62:62-(N-es-2)] = fraction bits for posit
wire [N-es-2:0] q_frac_w = quire_shifted_w[QUIRE_W-2 : QUIRE_W-2-(N-es-2)];
wire q_G_w = quire_shifted_w[QUIRE_W-2-(N-es-1)];
wire q_R_w = quire_shifted_w[QUIRE_W-2-(N-es)];
wire q_St_w = |quire_shifted_w[QUIRE_W-2-(N-es+1):0];

// Decompose scale into regime and exponent using reg_exp_op
wire [es-1:0] q_e_o_w;
wire [Bs:0] q_r_o_w;
reg_exp_op #(.es(es), .Bs(Bs)) quire_reg_exp(
	.exp_o(q_scale_w[es+Bs:0]), .e_o(q_e_o_w), .r_o(q_r_o_w[Bs-1:0]));
assign q_r_o_w[Bs] = 1'b0;

// Pack: regime indicator + sign + exponent + fraction + GRS
wire [2*N-1+3:0] q_tmp_o_w = {
	{N{~q_scale_w[es+Bs]}},
	q_scale_w[es+Bs],
	q_e_o_w,
	q_frac_w,
	q_G_w, q_R_w, q_St_w
};

// Right-shift by regime magnitude to insert regime bits
wire [3*N-1+3:0] q_tmp1_o_w;
DSR_right_N_S #(.N(3*N+3), .S(Bs+1)) quire_dsr(
	.a({q_tmp_o_w, {N{1'b0}}}),
	.b(q_r_o_w[Bs] ? {Bs{1'b1}} : q_r_o_w),
	.c(q_tmp1_o_w));

// Rounding (RNE)
wire q_L_w = q_tmp1_o_w[N+4];
wire q_Gp_w = q_tmp1_o_w[N+3];
wire q_Rp_w = q_tmp1_o_w[N+2];
wire q_Stp_w = |q_tmp1_o_w[N+1:0];
wire q_ulp_w = (q_Gp_w & (q_Rp_w | q_Stp_w)) | (q_L_w & q_Gp_w & ~(q_Rp_w | q_Stp_w));
wire [N-1:0] q_rnd_ulp_w = {{N-1{1'b0}}, q_ulp_w};

wire [N:0] q_rnd_w;
add_N #(.N(N)) quire_rnd(q_tmp1_o_w[2*N-1+3:N+3], q_rnd_ulp_w, q_rnd_w);

wire [N-1:0] q_posit_abs_w = (q_r_o_w < N-es-2) ? q_rnd_w[N-1:0] : q_tmp1_o_w[2*N-1+3:N+3];

// Apply sign
wire [N-1:0] q_posit_signed_w = quire_sign_w ? -q_posit_abs_w : q_posit_abs_w;

// Final posit output
// Overflow → maxpos (positive) or -maxpos (negative), preserving sign
wire [N-1:0] maxpos_w = {1'b0, {N-1{1'b1}}};        // 0x7F
wire [N-1:0] neg_maxpos_w = {1'b1, {N-2{1'b0}}, 1'b1}; // 0x81
assign posit_o = ovf_r ? (quire_sign_w ? neg_maxpos_w : maxpos_w) :
	quire_zero_w ? {N{1'b0}} :
	(~quire_shifted_w[QUIRE_W-1]) ? {quire_sign_w, {N-1{1'b0}}} :
	{quire_sign_w, q_posit_signed_w[N-1:1]};

// =============================================
// OUTPUT SIGNALS
// =============================================

reg done_r;
always @(posedge clk or negedge rst_n) begin
	if (!rst_n) done_r <= 1'b0;
	else done_r <= (mac_start_i | read_start_i | clear_start_i) & ~done_r;
end

assign done_o = done_r;
assign inf_o = (prod_inf_w & mac_start_i) | ovf_r;
assign zero_o = quire_zero_w & ~ovf_r;
assign ovf_o = ovf_r;

endmodule
