module d3d_tie_smoke_const_loads (
  input  wire [15:0] data_i,
  output wire [7:0] const0_o,
  output wire [7:0] const1_o
);
  wire constant_zero = 1'b0;
  wire constant_one  = 1'b1;

  // Functional gates survive floorplan's normal remove_buffers pass while
  // keeping both constant polarities observable at real instance inputs.
  (* keep = 1 *) OR2_X1 zero_load_0 (.A1(data_i[0]), .A2(constant_zero), .ZN(const0_o[0]));
  (* keep = 1 *) OR2_X1 zero_load_1 (.A1(data_i[1]), .A2(constant_zero), .ZN(const0_o[1]));
  (* keep = 1 *) OR2_X1 zero_load_2 (.A1(data_i[2]), .A2(constant_zero), .ZN(const0_o[2]));
  (* keep = 1 *) OR2_X1 zero_load_3 (.A1(data_i[3]), .A2(constant_zero), .ZN(const0_o[3]));
  (* keep = 1 *) OR2_X1 zero_load_4 (.A1(data_i[4]), .A2(constant_zero), .ZN(const0_o[4]));
  (* keep = 1 *) OR2_X1 zero_load_5 (.A1(data_i[5]), .A2(constant_zero), .ZN(const0_o[5]));
  (* keep = 1 *) OR2_X1 zero_load_6 (.A1(data_i[6]), .A2(constant_zero), .ZN(const0_o[6]));
  (* keep = 1 *) OR2_X1 zero_load_7 (.A1(data_i[7]), .A2(constant_zero), .ZN(const0_o[7]));

  (* keep = 1 *) AND2_X1 one_load_0 (.A1(data_i[8]),  .A2(constant_one), .ZN(const1_o[0]));
  (* keep = 1 *) AND2_X1 one_load_1 (.A1(data_i[9]),  .A2(constant_one), .ZN(const1_o[1]));
  (* keep = 1 *) AND2_X1 one_load_2 (.A1(data_i[10]), .A2(constant_one), .ZN(const1_o[2]));
  (* keep = 1 *) AND2_X1 one_load_3 (.A1(data_i[11]), .A2(constant_one), .ZN(const1_o[3]));
  (* keep = 1 *) AND2_X1 one_load_4 (.A1(data_i[12]), .A2(constant_one), .ZN(const1_o[4]));
  (* keep = 1 *) AND2_X1 one_load_5 (.A1(data_i[13]), .A2(constant_one), .ZN(const1_o[5]));
  (* keep = 1 *) AND2_X1 one_load_6 (.A1(data_i[14]), .A2(constant_one), .ZN(const1_o[6]));
  (* keep = 1 *) AND2_X1 one_load_7 (.A1(data_i[15]), .A2(constant_one), .ZN(const1_o[7]));
endmodule
