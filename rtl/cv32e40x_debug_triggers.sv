// Copyright 2022 Silicon Labs, Inc.
//
// This file, and derivatives thereof are licensed under the
// Solderpad License, Version 2.0 (the "License").
//
// Use of this file means you agree to the terms and conditions
// of the license and are in full compliance with the License.
//
// You may obtain a copy of the License at:
//
//     https://solderpad.org/licenses/SHL-2.0/
//
// Unless required by applicable law or agreed to in writing, software
// and hardware implementations thereof distributed under the License
// is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS
// OF ANY KIND, EITHER EXPRESSED OR IMPLIED.
//
// See the License for the specific language governing permissions and
// limitations under the License.

////////////////////////////////////////////////////////////////////////////////
// Engineer:       Oystein Knauserud - oystein.knauserud@silabs.com           //
//                                                                            //
// Design Name:    Debug triggers                                             //
// Project Name:   CV32E40X                                                   //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Module containing 0-4 triggers for debug                   //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

module cv32e40x_debug_triggers
import cv32e40x_pkg::*;
#(
  parameter int DBG_NUM_TRIGGERS = 1
)
(
  input  logic       clk,
  input  logic       rst_n,

  // CSR inputs write inputs
  input  logic [31:0] csr_wdata_i,
  input  logic        tselect_we_i,
  input  logic        tdata1_we_i,
  input  logic        tdata2_we_i,
  input  logic        tdata3_we_i,
  input  logic        tinfo_we_i,
  input  logic        tcontrol_we_i,

  // CSR read data outputs
  output logic [31:0] tselect_rdata_o,
  output logic [31:0] tdata1_rdata_o,
  output logic [31:0] tdata2_rdata_o,
  output logic [31:0] tdata3_rdata_o,
  output logic [31:0] tinfo_rdata_o,
  output logic [31:0] tcontrol_rdata_o,

  // IF stage inputs
  input  logic [31:0] pc_if_i,
  input  logic        ptr_in_if_i,
  input  privlvl_t    priv_lvl_if_i,

  // EX stage / LSU inputs
  input  logic        lsu_valid_ex_i,
  input  logic [31:0] lsu_addr_ex_i,
  input  logic        lsu_we_ex_i,
  input  logic [3:0]  lsu_be_ex_i,
  input  privlvl_t    priv_lvl_ex_i,

  // Controller inputs
  input ctrl_fsm_t    ctrl_fsm_i,

  // Trigger match outputs
  output logic        trigger_match_if_o,  // Instruction address match
  output logic        trigger_match_ex_o   // Load/Store address match
);

  // CSR write data
  logic [31:0] tselect_n;
  logic [31:0] tdata1_n;
  logic [31:0] tdata2_n;
  logic [31:0] tdata3_n;
  logic [31:0] tinfo_n;
  logic [31:0] tcontrol_n;

  // Signal for or'ing unused signals for easier lint
  logic unused_signals;



  generate
    if (DBG_NUM_TRIGGERS > 0) begin : gen_triggers
      // Internal CSR write enables
      logic [DBG_NUM_TRIGGERS-1 : 0] tdata1_we_int;
      logic [DBG_NUM_TRIGGERS-1 : 0] tdata2_we_int;

      // CSR instance outputs
      logic [31:0] tdata1_q[DBG_NUM_TRIGGERS];
      logic [31:0] tdata2_q[DBG_NUM_TRIGGERS];
      logic [31:0] tselect_q;

      // CSR read data, possibly WARL resolved
      logic [31:0] tdata1_rdata[DBG_NUM_TRIGGERS];
      logic [31:0] tdata2_rdata[DBG_NUM_TRIGGERS];

      // IF and EX stages trigger match
      logic [DBG_NUM_TRIGGERS-1 : 0] trigger_match_if;
      logic [DBG_NUM_TRIGGERS-1 : 0] trigger_match_ex;

      // Instruction address match
      logic [DBG_NUM_TRIGGERS-1 : 0] if_addr_match;

      // LSU address match signals
      logic [DBG_NUM_TRIGGERS-1 : 0] lsu_addr_match_en;
      logic [DBG_NUM_TRIGGERS-1 : 0] lsu_addr_match;
      logic [3:0]                    lsu_byte_addr_match[DBG_NUM_TRIGGERS];

      // Enable matching based on privilege level per trigger
      logic [DBG_NUM_TRIGGERS-1 : 0] priv_lvl_match_en_if;
      logic [DBG_NUM_TRIGGERS-1 : 0] priv_lvl_match_en_ex;

      logic [1:0]  lsu_addr_high_lsb; // Lower two bits of the highest accessed address
      logic [31:0] lsu_addr_high;     // The highest accessed address of an LSU transaction

      // Write data
      always_comb begin
        // Tselect is WARL (0 -> DBG_NUM_TRIGGERS-1)
        tselect_n     = (csr_wdata_i < DBG_NUM_TRIGGERS) ? csr_wdata_i : tselect_rdata_o;

        // todo: handle WARL based on trigger type
        tdata1_n      = {
                          TTYPE_MCONTROL6,       // type    : address/data match
                          1'b1,                  // dmode   : access from D mode only
                          2'b00,                 // zero  26:25
                          3'b000,                // zero, vs, vu, hit 24:22
                          1'b0,                  // zero, select 21
                          1'b0,                  // zero, timing 20
                          4'b0000,               // zero, size (match any size) 19:16
                          4'b0001,               // action, WARL(1), enter debug 15:12
                          1'b0,                  // zero, chain 11
                          mcontrol6_match_resolve(csr_wdata_i[MCONTROL6_MATCH_HIGH:MCONTROL6_MATCH_LOW]), // match, WARL(0,2,3) 10:7
                          csr_wdata_i[6],        // M  6
                          1'b0,                  // zero 5
                          1'b0,                  // zero, S 4
                          1'b0,                  // zero, U 3
                          csr_wdata_i[2],        // EXECUTE 2
                          csr_wdata_i[1],        // STORE 1
                          csr_wdata_i[0]};       // LOAD 0

        tdata2_n      = csr_wdata_i;
        tdata3_n      = tdata3_rdata_o;   // Read only
        tinfo_n       = tinfo_rdata_o;    // Read only
        tcontrol_n    = tcontrol_rdata_o; // Read only
      end

      // Calculate highest value of address[1:0] based on lsu_be_ex_i
      always_comb begin
        for (int b=0; b<4; b++) begin : gen_byte_checks
          if (lsu_be_ex_i[b]) begin
            lsu_addr_high_lsb = 2'(b);
          end // if
        end // for
      end // always

      assign lsu_addr_high = {lsu_addr_ex_i[31:2], lsu_addr_high_lsb};

      // Generate DBG_NUM_TRIGGERS instances of tdata1, tdata2 and match checks
      for (genvar idx=0; idx<DBG_NUM_TRIGGERS; idx++) begin : tmatch_csr

        ////////////////////////////////////
        // Instruction address match (IF)
        ////////////////////////////////////

        // With timing=0 we enter debug before executing the instruction at the match address. We use the IF stage PC
        // for comparison, and any trigger match will cause the instruction to act as a NOP with no side effects until it
        // reaches WB where debug mode is entered.
        //
        // Trigger match is disabled while in debug mode.
        //
        // Trigger CSRs can only be written from debug mode, writes from any other privilege level are ignored.
        //   Thus we do not have an issue where a write to the tdata2 CSR immediately before the matched instruction
        //   could be missed since we must write in debug mode, then dret to machine mode (kills pipeline) before
        //   returning to dpc.
        //   No instruction address match on any pointer type (CLIC and Zc tablejumps).

        // Check for address match using tdata2.match for checking rule
        assign if_addr_match[idx] = (tdata1_rdata[idx][MCONTROL6_MATCH_HIGH:MCONTROL6_MATCH_LOW] == 4'h0) ? (pc_if_i == tdata2_rdata[idx]) :
                                    (tdata1_rdata[idx][MCONTROL6_MATCH_HIGH:MCONTROL6_MATCH_LOW] == 4'h2) ? (pc_if_i >= tdata2_rdata[idx]) : (pc_if_i < tdata2_rdata[idx]);

        // Check if matching is enabled for the current privilege level from IF
        assign priv_lvl_match_en_if[idx] = (tdata1_rdata[idx][MCONTROL6_M] && (priv_lvl_if_i == PRIV_LVL_M)) ||
                                           (tdata1_rdata[idx][MCONTROL6_U] && (priv_lvl_if_i == PRIV_LVL_U));

        // Check for trigger match from IF
        assign trigger_match_if[idx] = tdata1_rdata[idx][MCONTROL6_EXECUTE] && priv_lvl_match_en_if[idx] && !ctrl_fsm_i.debug_mode && !ptr_in_if_i &&
                                       if_addr_match[idx];

        ///////////////////////////////////////
        // Load/Store address match (EX)
        ///////////////////////////////////////

        // todo: LSU address matching must be revisited once the atomics are implemented
        // As for instruction address match, the load/store address match happens before the a bus transaction is visible on the OBI bus.
        // For split misaligned transfers, each transfer is checked separately. This means that half a store may be visible externally even if
        // the second part matches tdata2 and debug is entered. For loads the RF write will not happen until the last part finished anyway, so no state update
        // will happen regardless of which transaction matches.
        // The BE of the transaction is used to determine which bytes of a word is being accessed.

        // Check if any accessed byte matches the lower two bits of tdata2
        always_comb begin
          for (int b=0; b<4; b++) begin
            if (lsu_be_ex_i[b] && (2'(b) == tdata2_rdata[idx][1:0])) begin
              lsu_byte_addr_match[idx][b] = 1'b1;
            end else begin
              lsu_byte_addr_match[idx][b] = 1'b0;
            end
          end
        end

        // Check address matches for (==), (>=) and (<)
        // For ==, check that we match the 32-bit aligned word and that any of the accessed bytes matches tdata2[1:0]
        // For >=, check that the highest accessed address is greater than or equal to tdata2
        // For <, check that the highest accessed address is less than tdata2
        assign lsu_addr_match[idx] = (tdata1_rdata[idx][MCONTROL6_MATCH_HIGH:MCONTROL6_MATCH_LOW] == 4'h0) ? ((lsu_addr_ex_i[31:2] == tdata2_rdata[idx][31:2]) && (|lsu_byte_addr_match[idx])) :
                                     (tdata1_rdata[idx][MCONTROL6_MATCH_HIGH:MCONTROL6_MATCH_LOW] == 4'h2) ? (lsu_addr_high >= tdata2_rdata[idx]) :
                                                                                                             (lsu_addr_high <  tdata2_rdata[idx]) ;

        // Check if matching is enabled for the current privilege level from EX
        assign priv_lvl_match_en_ex[idx] = (tdata1_rdata[idx][MCONTROL6_M] && (priv_lvl_ex_i == PRIV_LVL_M)) ||
                                           (tdata1_rdata[idx][MCONTROL6_U] && (priv_lvl_ex_i == PRIV_LVL_U));

        // Enable LSU address matching
        assign lsu_addr_match_en[idx] = lsu_valid_ex_i && ((tdata1_q[idx][MCONTROL6_LOAD] && !lsu_we_ex_i) || (tdata1_q[idx][MCONTROL6_STORE] && lsu_we_ex_i));

        // Signal trigger match for LSU address
        assign trigger_match_ex[idx] = priv_lvl_match_en_ex[idx] &&  lsu_addr_match_en[idx] && lsu_addr_match[idx] && !ctrl_fsm_i.debug_mode;


        cv32e40x_csr
        #(
          .WIDTH      (32),
          .RESETVALUE (TDATA1_RST_VAL)
        )
        tdata1_csr_i
        (
          .clk                ( clk                   ),
          .rst_n              ( rst_n                 ),
          .wr_data_i          ( tdata1_n              ),
          .wr_en_i            ( tdata1_we_int[idx]    ),
          .rd_data_o          ( tdata1_q[idx]         )
        );

        cv32e40x_csr
        #(
          .WIDTH      (32),
          .RESETVALUE (32'd0)
        )
        tdata2_csr_i
        (
          .clk                ( clk                   ),
          .rst_n              ( rst_n                 ),
          .wr_data_i          ( tdata2_n              ),
          .wr_en_i            ( tdata2_we_int[idx]    ),
          .rd_data_o          ( tdata2_q[idx]         )
        );

        // Set write enables
        assign tdata1_we_int[idx] = tdata1_we_i && (tselect_q == idx);
        assign tdata2_we_int[idx] = tdata2_we_i && (tselect_q == idx);

        // Assign read data
        // todo: WARL
        assign tdata1_rdata[idx] = tdata1_q[idx];
        assign tdata2_rdata[idx] = tdata2_q[idx];
      end // for

      // CSR instance for tselect
      cv32e40x_csr
      #(
        .WIDTH      (32),
        .RESETVALUE (32'd0)
      )
      tselect_csr_i
      (
        .clk                ( clk                   ),
        .rst_n              ( rst_n                 ),
        .wr_data_i          ( tselect_n             ),
        .wr_en_i            ( tselect_we_i          ),
        .rd_data_o          ( tselect_q             )
      );

      // Assign CSR read data outputs
      always_comb begin
        tdata1_rdata_o = tdata1_rdata[0];
        tdata2_rdata_o = tdata2_rdata[0];

        // Iterate through triggers and set tdata1/tdata2 rdata for the currently selected trigger
        for (int i=0; i<DBG_NUM_TRIGGERS; i++) begin
          if(tselect_q == i) begin
            tdata1_rdata_o = tdata1_rdata[i];
            tdata2_rdata_o = tdata2_rdata[i];
          end
        end
      end

      assign tdata3_rdata_o   = 32'h00000000;
      assign tselect_rdata_o  = tselect_q;
      assign tinfo_rdata_o    = 32'h4; // todo: update
      assign tcontrol_rdata_o = 32'h00000000;

      // Set trigger match for IF
      assign trigger_match_if_o = |trigger_match_if;

      // Set trigger match for EX
      assign trigger_match_ex_o = |trigger_match_ex;

      assign unused_signals = tinfo_we_i | tcontrol_we_i | tdata3_we_i | (|tinfo_n) | (|tdata3_n) | (|tcontrol_n);

    end else begin : gen_no_triggers
      // Tie off outputs
      assign tdata1_rdata_o = '0;
      assign tdata2_rdata_o = '0;
      assign tdata3_rdata_o = '0;
      assign tselect_rdata_o = '0;
      assign tinfo_rdata_o = '0;
      assign tcontrol_rdata_o = '0;
      assign trigger_match_if_o = '0;
      assign trigger_match_ex_o = '0;
      assign tdata1_n = '0;
      assign tdata2_n = '0;
      assign tdata3_n = '0;
      assign tselect_n = '0;
      assign tinfo_n = '0;
      assign tcontrol_n = '0;

      assign unused_signals = (|tdata1_n) | (|tdata2_n) | (|tdata3_n) | (|tselect_n) | (|tinfo_n) | (|tcontrol_n) |
                              (|csr_wdata_i) | tdata1_we_i | tdata2_we_i | tdata3_we_i | tselect_we_i | tinfo_we_i | tcontrol_we_i;
    end
  endgenerate
endmodule
