module port_shapes (
  input          scalar_i,
  input  [0:0]   zero_i,
  input  [5:5]   five_i,
  input  [7:4]   down_i,
  input  [2:5]   up_i,
  output         scalar_o,
  output [0:0]   zero_o,
  output [5:5]   five_o,
  output [7:4]   down_o,
  output [2:5]   up_o
);
  assign scalar_o = scalar_i;
  assign zero_o = zero_i;
  assign five_o = five_i;
  assign down_o = down_i;
  assign up_o = up_i;
endmodule
