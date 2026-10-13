// Local-authorship hold: no redistribution license has been granted.
// Deterministic models for the two small memories emitted by ReplSeqMem.

module vmeTag_array_ext (
  input  logic [3:0]  R0_addr,
  input  logic        R0_en,
  input  logic        R0_clk,
  output logic [39:0] R0_data,
  input  logic [3:0]  W0_addr,
  input  logic        W0_en,
  input  logic        W0_clk,
  input  logic [39:0] W0_data
);
  logic [39:0] mem [0:15];

  always_ff @(posedge W0_clk) begin
    if (W0_en) begin
      mem[W0_addr] <= W0_data;
    end
  end

  always_ff @(posedge R0_clk) begin
    if (R0_en) begin
      R0_data <= mem[R0_addr];
    end
  end
endmodule

module mem_ext (
  input  logic [2:0]   R0_addr,
  input  logic         R0_en,
  input  logic         R0_clk,
  output logic [127:0] R0_data,
  input  logic [2:0]   W0_addr,
  input  logic         W0_en,
  input  logic         W0_clk,
  input  logic [127:0] W0_data
);
  logic [127:0] mem [0:7];

  always_ff @(posedge W0_clk) begin
    if (W0_en) begin
      mem[W0_addr] <= W0_data;
    end
  end

  always_ff @(posedge R0_clk) begin
    if (R0_en) begin
      R0_data <= mem[R0_addr];
    end
  end
endmodule

