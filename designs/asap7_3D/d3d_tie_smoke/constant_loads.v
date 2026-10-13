module d3d_tie_smoke_const_loads (
  input  wire [15:0] data_i,
  output wire [7:0] const0_o,
  output wire [7:0] const1_o
);
  wire constant_zero = 1'b0;
  wire constant_one  = 1'b1;

  // Functional gates survive floorplan's normal remove_buffers pass while
  // keeping both constant polarities observable at real instance inputs.
  (* keep = 1 *) OR2x2_ASAP7_75t_R zero_load_0 (.A(data_i[0]), .B(constant_zero), .Y(const0_o[0]));
  (* keep = 1 *) OR2x2_ASAP7_75t_R zero_load_1 (.A(data_i[1]), .B(constant_zero), .Y(const0_o[1]));
  (* keep = 1 *) OR2x2_ASAP7_75t_R zero_load_2 (.A(data_i[2]), .B(constant_zero), .Y(const0_o[2]));
  (* keep = 1 *) OR2x2_ASAP7_75t_R zero_load_3 (.A(data_i[3]), .B(constant_zero), .Y(const0_o[3]));
  (* keep = 1 *) OR2x2_ASAP7_75t_R zero_load_4 (.A(data_i[4]), .B(constant_zero), .Y(const0_o[4]));
  (* keep = 1 *) OR2x2_ASAP7_75t_R zero_load_5 (.A(data_i[5]), .B(constant_zero), .Y(const0_o[5]));
  (* keep = 1 *) OR2x2_ASAP7_75t_R zero_load_6 (.A(data_i[6]), .B(constant_zero), .Y(const0_o[6]));
  (* keep = 1 *) OR2x2_ASAP7_75t_R zero_load_7 (.A(data_i[7]), .B(constant_zero), .Y(const0_o[7]));

  (* keep = 1 *) AND2x2_ASAP7_75t_R one_load_0 (.A(data_i[8]),  .B(constant_one), .Y(const1_o[0]));
  (* keep = 1 *) AND2x2_ASAP7_75t_R one_load_1 (.A(data_i[9]),  .B(constant_one), .Y(const1_o[1]));
  (* keep = 1 *) AND2x2_ASAP7_75t_R one_load_2 (.A(data_i[10]), .B(constant_one), .Y(const1_o[2]));
  (* keep = 1 *) AND2x2_ASAP7_75t_R one_load_3 (.A(data_i[11]), .B(constant_one), .Y(const1_o[3]));
  (* keep = 1 *) AND2x2_ASAP7_75t_R one_load_4 (.A(data_i[12]), .B(constant_one), .Y(const1_o[4]));
  (* keep = 1 *) AND2x2_ASAP7_75t_R one_load_5 (.A(data_i[13]), .B(constant_one), .Y(const1_o[5]));
  (* keep = 1 *) AND2x2_ASAP7_75t_R one_load_6 (.A(data_i[14]), .B(constant_one), .Y(const1_o[6]));
  (* keep = 1 *) AND2x2_ASAP7_75t_R one_load_7 (.A(data_i[15]), .B(constant_one), .Y(const1_o[7]));
endmodule
