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
// PRODUCT TO FIXED POINT
// =============================================

localparam PROD_W = 2*(N-es)+2;
localparam SHIFT_BASE = QBP - (PROD_W - 1);

wire signed [7:0] raw_shift_w = $signed({scale_w[Bs+es+1], scale_w}) + SHIFT_BASE[7:0];

wire prod_udf_w = raw_shift_w[7];
wire prod_ovf_w = (~raw_shift_w[7]) & (raw_shift_w > (QUIRE_W - PROD_W));

wire [5:0] left_shift_amt_w = prod_udf_w ? 6'd0 :
	(prod_ovf_w ? 6'd50 : raw_shift_w[5:0]);

wire [QUIRE_W-1:0] prod_base_w = {{(QUIRE_W-PROD_W){1'b0}}, prod_mN_w};

// =============================================
// SHARED BARREL SHIFTER
// =============================================
// Cycle 0 (done_r=0): shifts product into quire position
// Cycle 1 (done_r=1): normalizes quire magnitude for posit conversion

wire quire_sign_w = quire_r[QUIRE_W-1];
wire [QUIRE_W-1:0] quire_abs_w = quire_sign_w ? -quire_r : quire_r;

wire [5:0] lzc_w;
LOD_N #(.N(QUIRE_W)) quire_lod(.in(quire_abs_w), .out(lzc_w));

wire [QUIRE_W-1:0] shared_shift_in_w = done_r ? quire_abs_w : prod_base_w;
wire [5:0] shared_shift_amt_w = done_r ? lzc_w : left_shift_amt_w;
wire [QUIRE_W-1:0] shared_shift_out_w;
DSR_left_N_S #(.N(QUIRE_W), .S(6)) shared_shift(
	.a(shared_shift_in_w), .b(shared_shift_amt_w), .c(shared_shift_out_w));

// Product placement (valid when done_r=0)
wire [QUIRE_W-1:0] prod_fixed_w = (prod_udf_w | prod_zero_w | prod_inf_w) ?
	{QUIRE_W{1'b0}} : shared_shift_out_w;

// Quire normalized (valid when done_r=1)
wire [QUIRE_W-1:0] quire_shifted_w = shared_shift_out_w;

// =============================================
// QUIRE REGISTER
// =============================================
// Merged negator: conditional complement + carry-in instead of separate negation

reg [QUIRE_W-1:0] quire_r;
reg ovf_r;

wire [QUIRE_W-1:0] prod_comp_w = prod_sign_w ? ~prod_fixed_w : prod_fixed_w;
wire [QUIRE_W-1:0] quire_next_w = quire_r + prod_comp_w + {{QUIRE_W-1{1'b0}}, prod_sign_w};

// Overflow: signs of quire and effective addend agree but result sign differs
wire eff_neg_w = prod_sign_w & (|prod_fixed_w);
wire acc_ovf_w = (~quire_r[QUIRE_W-1] & ~eff_neg_w & quire_next_w[QUIRE_W-1]) |
	(quire_r[QUIRE_W-1] & eff_neg_w & ~quire_next_w[QUIRE_W-1]);

always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		quire_r <= {QUIRE_W{1'b0}};
		ovf_r <= 1'b0;
	end else if (clear_start_i & ~done_r) begin
		quire_r <= {QUIRE_W{1'b0}};
		ovf_r <= 1'b0;
	end else if (mac_start_i & ~done_r & ~prod_inf_w) begin
		if (acc_ovf_w | prod_ovf_w) begin
			quire_r <= prod_sign_w ?
				{1'b1, {QUIRE_W-1{1'b0}}} + 1 :
				{1'b0, {QUIRE_W-1{1'b1}}};
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

// Scale = (63 - lzc) - 32 = 31 - lzc
wire signed [6:0] q_scale_w = 7'sd31 - {1'b0, lzc_w};

// Extract mantissa, G, R, S from shifted quire (valid when done_r=1)
wire [N-es-2:0] q_frac_w = quire_shifted_w[QUIRE_W-2 : QUIRE_W-2-(N-es-2)];
wire q_G_w = quire_shifted_w[QUIRE_W-2-(N-es-1)];
wire q_R_w = quire_shifted_w[QUIRE_W-2-(N-es)];
wire q_St_w = |quire_shifted_w[QUIRE_W-2-(N-es+1):0];

// Decompose scale into regime and exponent
wire [es-1:0] q_e_o_w;
wire [Bs:0] q_r_o_w;
reg_exp_op #(.es(es), .Bs(Bs)) quire_reg_exp(
	.exp_o(q_scale_w[es+Bs:0]), .e_o(q_e_o_w), .r_o(q_r_o_w[Bs-1:0]));
assign q_r_o_w[Bs] = 1'b0;

// Pack: regime indicator + exponent + fraction + GRS
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
wire [N-1:0] maxpos_w = {1'b0, {N-1{1'b1}}};
wire [N-1:0] neg_maxpos_w = {1'b1, {N-2{1'b0}}, 1'b1};
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
