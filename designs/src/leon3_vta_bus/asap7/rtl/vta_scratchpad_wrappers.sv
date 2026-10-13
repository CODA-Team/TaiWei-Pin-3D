// Real dual-port wrappers for leon3_vta_bus's 5 genuinely dual-port
// memory instances (previously fakeram blackboxes with no body -- these
// are the "unidentified/mixed provenance" macros this project's earlier
// audit couldn't trace; regenerated here with VLSIDA/bsg_fakeram for tool
// consistency, keeping the exact same outer module names/ports so no
// other RTL needs to change).
module tensorFile_0_ext (
  input [10:0] R0_addr,
  input R0_en,
  input R0_clk,
  output [63:0] R0_data,
  input [10:0] W0_addr,
  input W0_en,
  input W0_clk,
  input [63:0] W0_data
);
  ht_asap7_leon3vtabus_tensorFile_0_ext macro_mem (
    .r0_clk(R0_clk), .r0_ce_in(R0_en), .r0_addr_in(R0_addr), .r0_rd_out(R0_data),
    .w0_clk(W0_clk), .w0_ce_in(W0_en), .w0_we_in(W0_en), .w0_addr_in(W0_addr), .w0_wd_in(W0_data)
  );
endmodule

module tensorFile_0_0_ext (
  input [9:0] R0_addr,
  input R0_en,
  input R0_clk,
  output [63:0] R0_data,
  input [9:0] W0_addr,
  input W0_en,
  input W0_clk,
  input [63:0] W0_data
);
  ht_asap7_leon3vtabus_tensorFile_0_0_ext macro_mem (
    .r0_clk(R0_clk), .r0_ce_in(R0_en), .r0_addr_in(R0_addr), .r0_rd_out(R0_data),
    .w0_clk(W0_clk), .w0_ce_in(W0_en), .w0_we_in(W0_en), .w0_addr_in(W0_addr), .w0_wd_in(W0_data)
  );
endmodule

module tensorFile_0_1_ext (
  input [9:0] R0_addr,
  input R0_en,
  input R0_clk,
  output [31:0] R0_data,
  input [9:0] W0_addr,
  input W0_en,
  input W0_clk,
  input [31:0] W0_data
);
  ht_asap7_leon3vtabus_tensorFile_0_1_ext macro_mem (
    .r0_clk(R0_clk), .r0_ce_in(R0_en), .r0_addr_in(R0_addr), .r0_rd_out(R0_data),
    .w0_clk(W0_clk), .w0_ce_in(W0_en), .w0_we_in(W0_en), .w0_addr_in(W0_addr), .w0_wd_in(W0_data)
  );
endmodule

module mem_0_ext (
  input [8:0] R0_addr,
  input R0_en,
  input R0_clk,
  output [127:0] R0_data,
  input [8:0] W0_addr,
  input W0_en,
  input W0_clk,
  input [127:0] W0_data
);
  ht_asap7_leon3vtabus_mem_0_ext macro_mem (
    .r0_clk(R0_clk), .r0_ce_in(R0_en), .r0_addr_in(R0_addr), .r0_rd_out(R0_data),
    .w0_clk(W0_clk), .w0_ce_in(W0_en), .w0_we_in(W0_en), .w0_addr_in(W0_addr), .w0_wd_in(W0_data)
  );
endmodule

module tensorFile_0_2_ext (
  input [10:0] R0_addr,
  input R0_en,
  input R0_clk,
  output [127:0] R0_data,
  input [10:0] W0_addr,
  input W0_en,
  input W0_clk,
  input [127:0] W0_data
);
  ht_asap7_leon3vtabus_tensorFile_0_2_ext macro_mem (
    .r0_clk(R0_clk), .r0_ce_in(R0_en), .r0_addr_in(R0_addr), .r0_rd_out(R0_data),
    .w0_clk(W0_clk), .w0_ce_in(W0_en), .w0_we_in(W0_en), .w0_addr_in(W0_addr), .w0_wd_in(W0_data)
  );
endmodule
