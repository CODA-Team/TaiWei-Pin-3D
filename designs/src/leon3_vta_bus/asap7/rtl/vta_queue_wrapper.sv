// Real dual-port wrapper for vta_q_512x128 (previously a fakeram
// blackbox with no body). Generated with VLSIDA/bsg_fakeram using
// write_granularity=8, matching PORT_W_WR_EN's real 16-bit byte-granular
// mask exactly -- no bit-replication needed, PORT_W_WR_EN connects
// directly to w0_wmask_in.
module vta_q_512x128 (
  input PORT_R_CLK,
  input [8:0] PORT_R_ADDR,
  output [127:0] PORT_R_RD_DATA,
  input PORT_W_CLK,
  input [8:0] PORT_W_ADDR,
  input [127:0] PORT_W_WR_DATA,
  input [15:0] PORT_W_WR_EN
);
  ht_asap7_leon3vtabus_vta_q_512x128 macro_mem (
    .r0_clk(PORT_R_CLK), .r0_ce_in(1'b1), .r0_addr_in(PORT_R_ADDR), .r0_rd_out(PORT_R_RD_DATA),
    .w0_clk(PORT_W_CLK), .w0_ce_in(|PORT_W_WR_EN), .w0_we_in(|PORT_W_WR_EN),
    .w0_addr_in(PORT_W_ADDR), .w0_wd_in(PORT_W_WR_DATA), .w0_wmask_in(PORT_W_WR_EN)
  );
endmodule
