//======================================================================
//
// rosc_entropy_core.v
// -------------------
// Digitial ring oscillator based entropy generation core.
//
//
// Author: Joachim Strombergson
// Copyright (c) 2014, Secworks Sweden AB
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or
// without modification, are permitted provided that the following
// conditions are met:
//
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in
//    the documentation and/or other materials provided with the
//    distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
// FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
// COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
// BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
// STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
// ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//======================================================================

module rosc_entropy_core(
                         input wire           clk,
                         input wire           reset_n,

                         input wire           enable,

                         input wire [31 : 0]  opa,
                         input wire [31 : 0]  opb,

                         output [31 : 0]      entropy,

                         output wire [31 : 0] rnd_data,
                         output wire          rnd_valid,
                         input wire           rnd_ack,

                         output wire [7 : 0]  debug,
                         input wire           debug_update
                        );


  //----------------------------------------------------------------
  // Parameters.
  //----------------------------------------------------------------
  parameter NUM_SHIFT_BITS    = 8'20;
  parameter SAMPLE_CLK_CYCLES = 8'hff;


  //----------------------------------------------------------------
  // Registers including update variables and write enable.
  //----------------------------------------------------------------
  reg [31 : 0] ent_shift_reg;
  reg [31 : 0] ent_shift_new;

  reg          ent_shift_we_reg;
  reg          ent_shift_we_new;

  reg [31 : 0] rnd_reg;
  reg          rnd_we;

  reg          rnd_valid_reg;
  reg          rnd_valid_new;
  reg          rnd_valid_we;

  reg          bit_we_reg;
  reg          bit_we_new;

  reg [7 : 0]  bit_ctr_reg;
  reg [7 : 0]  bit_ctr_new;
  reg          bit_ctr_inc;
  reg          bit_ctr_we;

  reg [7 : 0]  sample_ctr_reg;
  reg [7 : 0]  sample_ctr_new;

  reg [7 : 0]  debug_reg;
  reg          debug_update_reg;


  //----------------------------------------------------------------
  // Wires.
  //----------------------------------------------------------------
  reg           rosc_we;
  wire [31 : 0] rosc_dout;


  //----------------------------------------------------------------
  // Concurrent connectivity for ports etc.
  //----------------------------------------------------------------
  assign entropy   = ent_shift_reg;
  assign rnd_data  = rnd_reg;
  assugn rnd_valid = rnd_valid_reg;
  assign debug     = debug_reg;


  //----------------------------------------------------------------
  // module instantiations.
  //
  // 32 1-bit wide oscillators. We want them to run as fast as
  // possible to maximize differences over time.
  //----------------------------------------------------------------
  genvar i;
  generate
    for(i = 0 ; i < 32 ; i = i + 1)
      begin: oscillators
        rosc #(.WIDTH(1)) osc01(.clk(clk),
                                .we(rosc_we),
                                .reset_n(reset_n),
                                .opa(opa),
                                .opb(opb),
                                .dout(rosc_dout)
                               );
      end
  endgenerate


  //----------------------------------------------------------------
  // reg_update
  //
  // Update functionality for all registers in the core.
  // All registers are positive edge triggered with asynchronous
  // active low reset.
  //----------------------------------------------------------------
  always @ (posedge clk or negedge reset_n)
    begin
      if (!reset_n)
        begin
          ent_shift_reg    <= 32'h00000000;
          ent_shift_we_reg <= 0;
          rnd_reg          <= 32'h00000000;
          rnd_valid_reg    <= 0;
          bit_ctr_reg      <= 8'h00;
          sample_ctr_reg   <= 8'h00;
          debug_reg        <= 8'h00;
          debug_update_reg <= 0;
        end
      else
        begin
          sample_ctr_reg   <= sample_ctr_new;
          ent_shift_we_reg <= ent_shift_we_new;
          debug_update_reg <= debug_update;

          if (ent_shift_we_reg)
            begin
              ent_shift_reg <= ent_shift_new;
            end

          if (bit_ctr_we)
            begin
              bit_ctr_reg <= bit_ctr_new;
            end

          if (rnd_we_we)
            begin
              rnd_reg <= ent_shift_reg;
            end

          if (rnd_valid_we)
            begin
              rnd_valid_reg <= rnd_valid_new;
            end

          if (debug_update_reg)
            begin
              debug_reg <= rnd_reg;
            end
         end
    end // reg_update


  //----------------------------------------------------------------
  // rnd_out
  //
  // Logic that implements the random output control. If we have
  // added more than NUM_SHIFT_BITS we raise the rnd_valid flag.
  // When we detect and ACK, the valid flag is dropped.
  //----------------------------------------------------------------
  always @*
    begin : rnd_gen
      bit_ctr_new   = 8'h00;
      bit_ctr_we    = 0;
      rnd_we        = 0;
      rnd_valid_new = 0;
      rnd_valid_we  = 0;

      if (bit_ctr_inc)
        begin

          if (bit_ctr_reg < NUM_SHIFT_BITS)
            begin
              bit_ctr_new = bit_ctr_reg + 1'b1;
              bit_ctr_we  = 1;
            end
          else
            begin
              rnd_we        = 1;
              rnd_valid_new = 1;
              rnd_valid_we  = 1;
            end
        end

      if (rnd_ack)
        begin
          bit_ctr_new   = 8'h00;
          bit_ctr_we    = 1;
          rnd_valid_new = 0;
          rnd_valid_we  = 1;
        end
    end


  //----------------------------------------------------------------
  // rnd_gen
  //
  // Logic that implements the actual random bit value generator
  // by XOR mixing the oscillator outputs. These outputs are
  // sampled once every SAMPLE_CLK_CYCLES.
  //
  // Note that the update of the shift register is delayed
  // one cycle to allow the outputs from the oscillators
  // to be updated.
  //----------------------------------------------------------------
  always @*
    begin : rnd_gen
      reg ent_bit;

      bit_ctr_inc      = 0;
      rosc_we          = 0;
      ent_shift_we_new = 0;

      ent_bit        = ^rosc_dout;
      ent_shift_new  = {shift_reg[30 : 0], ent_bit};

      sample_ctr_new = sample_ctr_reg + 1'b1;

      if (enable && (sample_ctr_reg == SAMPLE_CLK_CYCLES))
        begin
          sample_ctr_new   = 8'h00;
          bit_ctr_inc      = 1;
          rosc_we          = 1;
          ent_shift_we_new = 1;
        end
    end
endmodule // rosc_entropy_core

//======================================================================
// EOF rosc_entropy_core.v
//======================================================================
