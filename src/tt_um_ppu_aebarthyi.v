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
  // states
  localparam WAIT_IN1 = 2'b00;
  localparam WAIT_IN2_INST = 2'b01;
  localparam COMPUTING = 2'b10;
  localparam COMPLETE = 2'b11;
  localparam ADD = 2'b01;
  localparam MULT = 2'b10;

  reg [1:0] ppu_state_d, ppu_state_q;
  wire input1_valid, input2_valid, instruction_valid, ready_in, ready_out;
  
  assign instruction_valid = ui_in[2];
  assign input1_valid = ui_in[0];
  assign input2_valid = ui_in[1];
  assign ready_in = ui_in[5];

  reg [7:0] input1_reg_d, input2_reg_d, input1_reg_q, input2_reg_q, output_reg_d, output_reg_q, opcode_reg_d, opcode_reg_q;

  //FSM transition logic
  always @(*) begin
    ppu_state_d = ppu_state_q;

    case(ppu_state_q)
        WAIT_IN1: begin
            if(input1_valid & ~input2_valid) ppu_state_d = WAIT_IN2_INST;
        end
        WAIT_IN2_INST: begin
            if(input2_valid & instruction_valid & ~input1_valid) ppu_state_d = COMPUTING;
        end
        COMPUTING: begin
            if(done_add | done_mult) ppu_state_d = COMPLETE;
        end
        COMPLETE: begin
            if(ready_in) ppu_state_d = WAIT_IN1;
        end
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ppu_state_q <= WAIT_IN1;
    end else if (ena) begin
        ppu_state_q <= ppu_state_d;
    end
  end

  wire [7:0] posit_add_o, posit_mult_o;
  wire start_add, start_mult, done_add, done_mult;
  wire ready_o, valid_o;
  assign opcode_reg_d = ui_in[4:3];
  assign uio_oe = {8{(ppu_state_q == COMPUTING) | (ppu_state_q == COMPLETE)}};
  assign start_add = (ppu_state_q == COMPUTING) & (opcode_reg_q == ADD);
  assign start_mult = (ppu_state_q == COMPUTING) & (opcode_reg_q == MULT);

  wire zero_add, inf_add, zero_mult, inf_mult;
  reg zero, inf;

  posit_add #(.N(8),.es(2)) posit_adder(input1_reg_q, input2_reg_q, start_add, posit_add_o, inf_add, zero_add, done_add);
  posit_mult #(.N(8),.es(2)) posit_multiplier(input1_reg_q, input2_reg_q, start_mult, posit_mult_o, inf_mult, zero_mult, done_mult);

  //OUTPUT LOGIC
  always @(*) begin
    output_reg_d = 8'b0;
    inf = 0;
    zero = 0;
    case(opcode_reg_q)
        ADD: begin
           output_reg_d = posit_add_o;
           inf = inf_add;
           zero = zero_add;
        end
        MULT: begin
           output_reg_d = posit_mult_o;
           inf = inf_mult;
           zero = zero_mult;
        end
    endcase
  end
  
  //INPUT/OUTPUT REGS
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        input1_reg_q <= 8'b0;
        input2_reg_q <= 8'b0;
        opcode_reg_q <= 8'b0;
        output_reg_q <= 8'b0;
    end else begin
        case(ppu_state_q)
            WAIT_IN1: begin
                if(input1_valid) input1_reg_q <= uio_in;
            end
            WAIT_IN2_INST: begin
                if(input2_valid) input2_reg_q <= uio_in;
                if(instruction_valid) opcode_reg_q <= ui_in[4:3];
            end
            COMPUTING: begin
                if(done_add | done_mult) output_reg_q <= output_reg_d;
            end
        endcase
    end
  end
  
  assign uio_out = output_reg_q;
  reg [7:0] uo_out_l;
  assign ready_o = (ppu_state_q == WAIT_IN1) | (ppu_state_q == WAIT_IN2_INST);
  assign valid_o = (ppu_state_q == COMPLETE);

  assign uo_out = {4'b0, ready_o, inf, zero, valid_o};

endmodule
