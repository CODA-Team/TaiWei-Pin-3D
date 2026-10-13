module syn3d_macro_smoke (
  input          clk,
  input          rst_n,
  input          enable,
  input          write_enable,
  input  [5:0]   address,
  input  [15:0]  operand_a,
  input  [15:0]  operand_b,
  output [20:0]  result
);
  wire [16:0] sum_w = operand_a + operand_b;
  wire [31:0] product_w = operand_a * operand_b;
  wire [20:0] ram_q;
  reg  [20:0] accumulator_q;

  wire [20:0] arithmetic_w = {4'b0, sum_w} + product_w[20:0];
  wire [20:0] ram_d = accumulator_q + arithmetic_w;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      accumulator_q <= 21'b0;
    else if (enable)
      accumulator_q <= arithmetic_w ^ ram_q;
  end

  ram_64x21 macro_mem (
    .CLK (clk),
    .ADR (address),
    .D   (ram_d),
    .Q   (ram_q),
    .WE  (write_enable)
  );

  assign result = accumulator_q ^ ram_q;
endmodule
