module d3d_tie_smoke (
  input  wire        clk,
  input  wire        reset,
  input  wire [15:0] data_i,
  output wire [15:0] state_o,
  output wire [ 7:0] const0_o,
  output wire [ 7:0] const1_o
);
  reg [15:0] state_q;

  always @(posedge clk) begin
    if (reset)
      state_q <= 16'h1;
    else
      state_q <= {state_q[14:0], state_q[15] ^ state_q[13]} ^ data_i;
  end

  d3d_tie_smoke_const_loads constant_loads (
    .data_i(data_i),
    .const0_o(const0_o),
    .const1_o(const1_o)
  );

  assign state_o = state_q;
endmodule
