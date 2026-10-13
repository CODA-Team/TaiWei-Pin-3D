// Local benchmark wrapper for the pinned BlackParrot source configuration.
module black_parrot (
  input  logic         clk_i,
  input  logic         reset_i,
  output logic [26:0]  mem_cmd_o,
  output logic         mem_cmd_v_o,
  input  logic         mem_cmd_yumi_i,
  output logic [566:0] mem_data_cmd_o,
  output logic         mem_data_cmd_v_o,
  input  logic         mem_data_cmd_yumi_i,
  input  logic [54:0]  mem_resp_i,
  input  logic         mem_resp_v_i,
  output logic         mem_resp_ready_o,
  input  logic [538:0] mem_data_resp_i,
  input  logic         mem_data_resp_v_i,
  output logic         mem_data_resp_ready_o
);
  logic [7:0]   cce_inst_addr;
  logic [94:0]  cce_inst_data;
  logic [377:0] unused_cmt_trace_stage_reg;
  logic [127:0] unused_cmt_trace_result;
  logic [6:0]   unused_cmt_trace_exc;

  bp_multi_top #(
    .core_els_p(1),
    .vaddr_width_p(56),
    .paddr_width_p(22),
    .asid_width_p(10),
    .branch_metadata_fwd_width_p(36),
    .btb_indx_width_p(9),
    .bht_indx_width_p(5),
    .ras_addr_width_p(22),
    .num_cce_p(1),
    .num_lce_p(2),
    .lce_assoc_p(8),
    .lce_sets_p(64),
    .cce_block_size_in_bytes_p(64),
    .cce_num_inst_ram_els_p(256)
  ) multi_top (
    .clk_i(clk_i),
    .reset_i(reset_i),
    .cce_inst_boot_rom_addr_o(cce_inst_addr),
    .cce_inst_boot_rom_data_i(cce_inst_data),
    .mem_resp_i(mem_resp_i),
    .mem_resp_v_i(mem_resp_v_i),
    .mem_resp_ready_o(mem_resp_ready_o),
    .mem_data_resp_i(mem_data_resp_i),
    .mem_data_resp_v_i(mem_data_resp_v_i),
    .mem_data_resp_ready_o(mem_data_resp_ready_o),
    .mem_cmd_o(mem_cmd_o),
    .mem_cmd_v_o(mem_cmd_v_o),
    .mem_cmd_yumi_i(mem_cmd_yumi_i),
    .mem_data_cmd_o(mem_data_cmd_o),
    .mem_data_cmd_v_o(mem_data_cmd_v_o),
    .mem_data_cmd_yumi_i(mem_data_cmd_yumi_i),
    .cmt_trace_stage_reg_o(unused_cmt_trace_stage_reg),
    .cmt_trace_result_o(unused_cmt_trace_result),
    .cmt_trace_exc_o(unused_cmt_trace_exc)
  );

  bp_cce_inst_rom #(
    .width_p(95),
    .addr_width_p(8)
  ) cce_inst_rom (
    .addr_i(cce_inst_addr),
    .data_o(cce_inst_data)
  );
endmodule
