/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_ppu_aebarthyi (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);
  // States
  localparam IDLE = 2'b00;
  localparam WAIT_IN2_INST = 2'b01;
  localparam COMPUTING = 2'b10;
  localparam COMPLETE = 2'b11;

  // Opcodes
  localparam MAC = 2'b01;
  localparam READ = 2'b10;
  localparam CLEAR = 2'b11;

  reg [1:0] ppu_state_d, ppu_state_q;
  wire input1_valid_w, input2_valid_w, instruction_valid_w, ready_in_w;

  assign input1_valid_w = ui_in[0];
  assign input2_valid_w = ui_in[1];
  assign instruction_valid_w = ui_in[2];
  assign ready_in_w = ui_in[5];

  reg [7:0] input1_reg_d, input2_reg_d, input1_reg_q, input2_reg_q, output_reg_d, output_reg_q;
  reg [1:0] opcode_reg_d, opcode_reg_q;

  // FSM transition logic
  always @(*) begin
    ppu_state_d = ppu_state_q;

    case(ppu_state_q)
        IDLE: begin
            if(input1_valid_w & ~input2_valid_w & ~instruction_valid_w)
                ppu_state_d = WAIT_IN2_INST;
            else if(instruction_valid_w & ~input1_valid_w & ~input2_valid_w)
                ppu_state_d = COMPUTING; // READ or CLEAR
        end
        WAIT_IN2_INST: begin
            if(input2_valid_w & instruction_valid_w & ~input1_valid_w)
                ppu_state_d = COMPUTING;
        end
        COMPUTING: begin
            if(done_mac_w) ppu_state_d = COMPLETE;
        end
        COMPLETE: begin
            if(ready_in_w) ppu_state_d = IDLE;
        end
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ppu_state_q <= IDLE;
    end else if (ena) begin
        ppu_state_q <= ppu_state_d;
    end
  end

  // MAC unit signals
  wire [7:0] posit_mac_o;
  wire mac_start_w, read_start_w, clear_start_w, done_mac_w;
  wire inf_mac_w, zero_mac_w, ovf_mac_w;

  assign mac_start_w = (ppu_state_q == COMPUTING) & (opcode_reg_q == MAC);
  assign read_start_w = (ppu_state_q == COMPUTING) & (opcode_reg_q == READ);
  assign clear_start_w = (ppu_state_q == COMPUTING) & (opcode_reg_q == CLEAR);

  assign uio_oe = {8{(ppu_state_q == COMPUTING) | (ppu_state_q == COMPLETE)}};

  posit_mac #(.N(8), .es(2)) mac_unit(
      .clk(clk),
      .rst_n(rst_n),
      .in1_i(input1_reg_q),
      .in2_i(input2_reg_q),
      .mac_start_i(mac_start_w),
      .read_start_i(read_start_w),
      .clear_start_i(clear_start_w),
      .posit_o(posit_mac_o),
      .inf_o(inf_mac_w),
      .zero_o(zero_mac_w),
      .done_o(done_mac_w),
      .ovf_o(ovf_mac_w)
  );

  // Output logic
  always @(*) begin
    output_reg_d = posit_mac_o;
  end

  // Input/Output registers
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        input1_reg_q <= 8'b0;
        input2_reg_q <= 8'b0;
        opcode_reg_q <= 2'b0;
        output_reg_q <= 8'b0;
    end else begin
        case(ppu_state_q)
            IDLE: begin
                if(input1_valid_w) input1_reg_q <= uio_in;
                if(instruction_valid_w & ~input1_valid_w & ~input2_valid_w)
                    opcode_reg_q <= ui_in[4:3];
            end
            WAIT_IN2_INST: begin
                if(input2_valid_w) input2_reg_q <= uio_in;
                if(instruction_valid_w) opcode_reg_q <= ui_in[4:3];
            end
            COMPUTING: begin
                if(done_mac_w) output_reg_q <= output_reg_d;
            end
        endcase
    end
  end

  assign uio_out = output_reg_q;

  wire ready_o_w = (ppu_state_q == IDLE) | (ppu_state_q == WAIT_IN2_INST);
  wire valid_o_w = (ppu_state_q == COMPLETE);

  assign uo_out = {3'b0, ovf_mac_w, ready_o_w, inf_mac_w, zero_mac_w, valid_o_w};

endmodule
