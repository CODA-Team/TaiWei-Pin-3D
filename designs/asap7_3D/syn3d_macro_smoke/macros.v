module ram_64x21(CLK, ADR, D, Q, WE);
  input CLK, WE;
  input [5:0] ADR;
  input [20:0] D;
  output [20:0] Q;

  fakeram7_64x21 mem (
    .clk     (CLK),
    .rd_out  (Q),
    .ce_in   (1'b1),
    .we_in   (WE),
    .addr_in (ADR),
    .wd_in   (D)
  );
endmodule
