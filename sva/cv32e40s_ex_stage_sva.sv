// Copyright 2021 Silicon Labs, Inc.
//   
// This file, and derivatives thereof are licensed under the
// Solderpad License, Version 2.0 (the "License");
// Use of this file means you agree to the terms and conditions
// of the license and are in full compliance with the License.
// You may obtain a copy of the License at
//   
//     https://solderpad.org/licenses/SHL-2.0/
//   
// Unless required by applicable law or agreed to in writing, software
// and hardware implementations thereof
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, EITHER EXPRESSED OR IMPLIED.
// See the License for the specific language governing permissions and
// limitations under the License.

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Authors:        Arjan Bink - arjan.bink@silabs.com                         //
//                                                                            //
// Description:    RTL assertions for the ex_stage module                     //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

module cv32e40s_ex_stage_sva
  import uvm_pkg::*;
  import cv32e40s_pkg::*;
(
  input logic           clk,
  input logic           rst_n,

  input logic           ex_ready_o,
  input logic           ex_valid_o,
  input logic           wb_ready_i,
  input ctrl_fsm_t      ctrl_fsm_i,
  input xsecure_ctrl_t  xsecure_ctrl_i,

  input id_ex_pipe_t    id_ex_pipe_i,
  input ex_wb_pipe_t    ex_wb_pipe_o,
  input logic           lsu_split_i,
  input logic           csr_illegal_i,
  input logic           alu_cmp_result,
  input logic [31:0]    branch_target_o,
  input logic           instr_valid
);

  // Halt implies not ready and not valid
  a_halt :
    assert property (@(posedge clk) disable iff (!rst_n)
                      (ctrl_fsm_i.halt_ex && !ctrl_fsm_i.kill_ex)
                      |-> (!ex_ready_o && !ex_valid_o))
      else `uvm_error("ex_stage", "Halt should imply not ready and not valid")

  // Kill implies ready and not valid
  a_kill :
    assert property (@(posedge clk) disable iff (!rst_n)
                      (ctrl_fsm_i.kill_ex)
                      |-> (ex_ready_o && !ex_valid_o))
      else `uvm_error("ex_stage", "Kill should imply ready and not valid")

  // csr_en suppressed for xif accepted and pipeline accepted CSR
  // todo: Add similar check for rf_we
  a_suppress_csr_xif_legal_pipeline_legal :
  assert property (@(posedge clk) disable iff (!rst_n)
                    (id_ex_pipe_i.xif_en && id_ex_pipe_i.csr_en && !csr_illegal_i) &&
                    (id_ex_pipe_i.instr_valid && ex_valid_o && wb_ready_i)
                    |=> !ex_wb_pipe_o.csr_en)
    else `uvm_error("ex_stage", "csr_en not suppressed after eXtension interface and pipeline accepted CSR")

  // csr_en suppressed for xif accepted and pipeline rejected CSR
  // todo: Add similar check for rf_we
  a_suppress_csr_xif_legal_pipeline_illegal :
  assert property (@(posedge clk) disable iff (!rst_n)
                    (id_ex_pipe_i.xif_en && id_ex_pipe_i.csr_en && csr_illegal_i) &&
                    (id_ex_pipe_i.instr_valid && ex_valid_o && wb_ready_i)
                    |=> !ex_wb_pipe_o.csr_en)
    else `uvm_error("ex_stage", "csr_en not suppressed after eXtension interface accepted and pipeline rejected CSR")

  // csr_en suppressed for xif reject and pipeline reject CSR
  // todo: Add similar check for rf_we
  a_suppress_csr_xif_illegal_pipeline_illegal :
  assert property (@(posedge clk) disable iff (!rst_n)
                    (!id_ex_pipe_i.xif_en && id_ex_pipe_i.csr_en && csr_illegal_i) &&
                    (id_ex_pipe_i.instr_valid && ex_valid_o && wb_ready_i)
                    |=> !ex_wb_pipe_o.csr_en)
    else `uvm_error("ex_stage", "csr_en not suppressed after eXtension interface rejected and pipeline rejected CSR")

    // csr_en not suppressed for xif reject and pipeline accept CSR
    // todo: Add similar check for rf_we
    a_suppress_csr_xif_illegal_pipeline_legal :
    assert property (@(posedge clk) disable iff (!rst_n)
                      (!id_ex_pipe_i.xif_en && id_ex_pipe_i.csr_en && !csr_illegal_i) &&
                      (id_ex_pipe_i.instr_valid && ex_valid_o && wb_ready_i)
                      |=> ex_wb_pipe_o.csr_en)
      else `uvm_error("ex_stage", "csr_en suppressed after eXtension interface rejected and pipeline accepted CSR")



  // First access of split LSU instruction should have rf_we deasserted
  a_split_rf_we:
  assert property (@(posedge clk) disable iff (!rst_n)
                    (ex_valid_o && wb_ready_i && id_ex_pipe_i.lsu_en && lsu_split_i)
                    |=> !ex_wb_pipe_o.rf_we);

  // Assert that branch instructions always result in bubbles when data independent timing is enabled
  a_dataindtiming_branch_bubbles:
    assert property (@(posedge clk) disable iff (!rst_n)
                     (wb_ready_i && $rose(id_ex_pipe_i.instr_meta.branch) && xsecure_ctrl_i.cpuctrl.dataindtiming)
                     |=> !ex_valid_o ##1 !ex_valid_o);

  // Assert that branch target for untaken branches with dataindtiming=1 match expected value.
  // (+2 for compressed branch instructions, +4 for uncompressed branch instructions)
  a_dataindtiming_branch_target:
    assert property (@(posedge clk) disable iff (!rst_n)
                     ((ctrl_fsm_i.pc_set && (ctrl_fsm_i.pc_mux == PC_BRANCH)) &&
                      xsecure_ctrl_i.cpuctrl.dataindtiming &&
                      !alu_cmp_result)
                      |-> id_ex_pipe_i.instr_meta.compressed ? branch_target_o == (id_ex_pipe_i.pc + 2) :
                                                               branch_target_o == (id_ex_pipe_i.pc + 4));

endmodule // cv32e40s_ex_stage_sva
