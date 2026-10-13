// PDK binding for the exact generic memories used by blackparrot-2.
module bsg_mem_1rw_sync #(
  parameter width_p = -1,
  parameter els_p = -1,
  parameter addr_width_lp = $clog2(els_p)
) (
  input  logic                     clk_i,
  input  logic                     reset_i,
  input  logic [width_p-1:0]       data_i,
  input  logic [addr_width_lp-1:0] addr_i,
  input  logic                     v_i,
  input  logic                     w_i,
  output logic [width_p-1:0]       data_o
);
  logic unused_reset;
  assign unused_reset = reset_i;

  generate
    if ((width_p == 64) && (els_p == 512)) begin : g_d512_w64
      ht_asap7_blackparrot_512x64 mem (
        .rw0_clk(clk_i),
        .rw0_ce_in(v_i),
        .rw0_we_in(w_i),
        .rw0_wmask_in({8{w_i}}),
        .rw0_addr_in(addr_i),
        .rw0_wd_in(data_i),
        .rw0_rd_out(data_o)
      );
    end else if ((width_p == 95) && (els_p == 256)) begin : g_d256_w95
      ht_asap7_blackparrot_256x95 mem (
        .rw0_clk(clk_i),
        .rw0_ce_in(v_i),
        .rw0_we_in(w_i),
        .rw0_addr_in(addr_i),
        .rw0_wd_in(data_i),
        .rw0_rd_out(data_o)
      );
    end else begin : g_unsupported
      blackparrot_unsupported_bsg_mem_1rw_sync #(
        .width_p(width_p),
        .els_p(els_p)
      ) unsupported_configuration();
    end
  endgenerate
endmodule

module bsg_mem_1rw_sync_mask_write_bit #(
  parameter width_p = -1,
  parameter els_p = -1,
  parameter addr_width_lp = $clog2(els_p)
) (
  input  logic                     clk_i,
  input  logic                     reset_i,
  input  logic [width_p-1:0]       data_i,
  input  logic [addr_width_lp-1:0] addr_i,
  input  logic                     v_i,
  input  logic [width_p-1:0]       w_mask_i,
  input  logic                     w_i,
  output logic [width_p-1:0]       data_o
);
  logic unused_reset;
  assign unused_reset = reset_i;

  generate
    if ((width_p == 192) && (els_p == 64)) begin : g_d64_w192
      ht_asap7_blackparrot_64x96 mem_lo (
        .rw0_clk(clk_i),
        .rw0_ce_in(v_i),
        .rw0_we_in(w_i),
        .rw0_wmask_in(w_mask_i[95:0]),
        .rw0_addr_in(addr_i),
        .rw0_wd_in(data_i[95:0]),
        .rw0_rd_out(data_o[95:0])
      );
      ht_asap7_blackparrot_64x96 mem_hi (
        .rw0_clk(clk_i),
        .rw0_ce_in(v_i),
        .rw0_we_in(w_i),
        .rw0_wmask_in(w_mask_i[191:96]),
        .rw0_addr_in(addr_i),
        .rw0_wd_in(data_i[191:96]),
        .rw0_rd_out(data_o[191:96])
      );
    end else if ((width_p == 96) && (els_p == 64)) begin : g_d64_w96
      ht_asap7_blackparrot_64x96 mem (
        .rw0_clk(clk_i),
        .rw0_ce_in(v_i),
        .rw0_we_in(w_i),
        .rw0_wmask_in(w_mask_i),
        .rw0_addr_in(addr_i),
        .rw0_wd_in(data_i),
        .rw0_rd_out(data_o)
      );
    end else if ((width_p == 15) && (els_p == 64)) begin : g_d64_w15
      ht_asap7_blackparrot_64x15 mem (
        .rw0_clk(clk_i),
        .rw0_ce_in(v_i),
        .rw0_we_in(w_i),
        .rw0_wmask_in(w_mask_i),
        .rw0_addr_in(addr_i),
        .rw0_wd_in(data_i),
        .rw0_rd_out(data_o)
      );
    end else if ((width_p == 7) && (els_p == 64)) begin : g_d64_w7
      ht_asap7_blackparrot_64x7 mem (
        .rw0_clk(clk_i),
        .rw0_ce_in(v_i),
        .rw0_we_in(w_i),
        .rw0_wmask_in(w_mask_i),
        .rw0_addr_in(addr_i),
        .rw0_wd_in(data_i),
        .rw0_rd_out(data_o)
      );
    end else begin : g_unsupported
      blackparrot_unsupported_bsg_mem_1rw_sync_mask_write_bit #(
        .width_p(width_p),
        .els_p(els_p)
      ) unsupported_configuration();
    end
  endgenerate
endmodule

module bsg_mem_1rw_sync_mask_write_byte #(
  parameter els_p = -1,
  parameter addr_width_lp = $clog2(els_p),
  parameter data_width_p = -1,
  parameter write_mask_width_lp = data_width_p >> 3
) (
  input  logic                              clk_i,
  input  logic                              reset_i,
  input  logic                              v_i,
  input  logic                              w_i,
  input  logic [addr_width_lp-1:0]          addr_i,
  input  logic [data_width_p-1:0]           data_i,
  input  logic [write_mask_width_lp-1:0]    write_mask_i,
  output logic [data_width_p-1:0]           data_o
);
  logic unused_reset;
  assign unused_reset = reset_i;

  generate
    if ((data_width_p == 64) && (els_p == 512)) begin : g_d512_w64
      ht_asap7_blackparrot_512x64 mem (
        .rw0_clk(clk_i),
        .rw0_ce_in(v_i),
        .rw0_we_in(w_i),
        .rw0_wmask_in(write_mask_i),
        .rw0_addr_in(addr_i),
        .rw0_wd_in(data_i),
        .rw0_rd_out(data_o)
      );
    end else begin : g_unsupported
      blackparrot_unsupported_bsg_mem_1rw_sync_mask_write_byte #(
        .data_width_p(data_width_p),
        .els_p(els_p)
      ) unsupported_configuration();
    end
  endgenerate
endmodule
