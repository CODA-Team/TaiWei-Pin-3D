// Regenerated with VLSIDA/bsg_fakeram instead of the previous
// mixed-provenance macros, for tool consistency across the project.
// These keep their original outer names/ports (every u_*_* instantiation
// site below is unchanged) and wrap the new ht_asap7_leon3vtabus_* macros
// internally.
module fakeram_asap7_256x16_1rw(clk, ce, we, addr, din, dout);
  input clk, ce, we; input [7:0] addr; input [15:0] din; output [15:0] dout;
  ht_asap7_leon3vtabus_256x16_1rw macro_mem (
    .rw0_clk(clk), .rw0_ce_in(ce), .rw0_we_in(we),
    .rw0_addr_in(addr), .rw0_wd_in(din),
    .rw0_wmask_in({16{we}}), .rw0_rd_out(dout)
  );
endmodule
module fakeram_asap7_256x16_1r1w(rclk, wclk, re, we, raddr, waddr, din, dout);
  input rclk, wclk, re, we; input [7:0] raddr, waddr; input [15:0] din; output [15:0] dout;
  ht_asap7_leon3vtabus_256x16_1r1w macro_mem (
    .r0_clk(rclk), .r0_ce_in(re), .r0_addr_in(raddr), .r0_rd_out(dout),
    .w0_clk(wclk), .w0_ce_in(we), .w0_we_in(we), .w0_addr_in(waddr), .w0_wd_in(din)
  );
endmodule

module generic_syncram_Bbehavioral_Ltechmap_10_32_0_0_1(clk, address, datain, write, enable, dataout);
  input clk;
  input [9:0] address;
  input [31:0] datain;
  input write, enable;
  output [31:0] dataout;
  wire [31:0] datain_p = datain;
  wire [31:0] din_pad = datain_p;
  wire [127:0] douts;
  fakeram_asap7_256x16_1rw u_0_0(.clk(clk), .addr(address[7:0]), .din(din_pad[0 +: 16]), .we(enable & write & (address[9:8] == 2'd0)), .ce(enable & (address[9:8] == 2'd0)), .dout(douts[0 +: 16]));
  fakeram_asap7_256x16_1rw u_0_1(.clk(clk), .addr(address[7:0]), .din(din_pad[16 +: 16]), .we(enable & write & (address[9:8] == 2'd0)), .ce(enable & (address[9:8] == 2'd0)), .dout(douts[16 +: 16]));
  fakeram_asap7_256x16_1rw u_1_0(.clk(clk), .addr(address[7:0]), .din(din_pad[0 +: 16]), .we(enable & write & (address[9:8] == 2'd1)), .ce(enable & (address[9:8] == 2'd1)), .dout(douts[32 +: 16]));
  fakeram_asap7_256x16_1rw u_1_1(.clk(clk), .addr(address[7:0]), .din(din_pad[16 +: 16]), .we(enable & write & (address[9:8] == 2'd1)), .ce(enable & (address[9:8] == 2'd1)), .dout(douts[48 +: 16]));
  fakeram_asap7_256x16_1rw u_2_0(.clk(clk), .addr(address[7:0]), .din(din_pad[0 +: 16]), .we(enable & write & (address[9:8] == 2'd2)), .ce(enable & (address[9:8] == 2'd2)), .dout(douts[64 +: 16]));
  fakeram_asap7_256x16_1rw u_2_1(.clk(clk), .addr(address[7:0]), .din(din_pad[16 +: 16]), .we(enable & write & (address[9:8] == 2'd2)), .ce(enable & (address[9:8] == 2'd2)), .dout(douts[80 +: 16]));
  fakeram_asap7_256x16_1rw u_3_0(.clk(clk), .addr(address[7:0]), .din(din_pad[0 +: 16]), .we(enable & write & (address[9:8] == 2'd3)), .ce(enable & (address[9:8] == 2'd3)), .dout(douts[96 +: 16]));
  fakeram_asap7_256x16_1rw u_3_1(.clk(clk), .addr(address[7:0]), .din(din_pad[16 +: 16]), .we(enable & write & (address[9:8] == 2'd3)), .ce(enable & (address[9:8] == 2'd3)), .dout(douts[112 +: 16]));
  reg [1:0] rsel; always @(posedge clk) rsel <= address[9:8];
  wire [31:0] rdata = douts[rsel*32 +: 32];
  assign dataout = rdata[31:0];
endmodule

module generic_syncram_Bbehavioral_Ltechmap_10_8_0_0_0(clk, address, datain, write, enable, dataout);
  input clk;
  input [9:0] address;
  input [7:0] datain;
  input write, enable;
  output [7:0] dataout;
  wire [7:0] datain_p = datain;
  wire [15:0] din_pad = {8'b0, datain_p};
  wire [63:0] douts;
  fakeram_asap7_256x16_1rw u_0_0(.clk(clk), .addr(address[7:0]), .din(din_pad[0 +: 16]), .we(enable & write & (address[9:8] == 2'd0)), .ce(enable & (address[9:8] == 2'd0)), .dout(douts[0 +: 16]));
  fakeram_asap7_256x16_1rw u_1_0(.clk(clk), .addr(address[7:0]), .din(din_pad[0 +: 16]), .we(enable & write & (address[9:8] == 2'd1)), .ce(enable & (address[9:8] == 2'd1)), .dout(douts[16 +: 16]));
  fakeram_asap7_256x16_1rw u_2_0(.clk(clk), .addr(address[7:0]), .din(din_pad[0 +: 16]), .we(enable & write & (address[9:8] == 2'd2)), .ce(enable & (address[9:8] == 2'd2)), .dout(douts[32 +: 16]));
  fakeram_asap7_256x16_1rw u_3_0(.clk(clk), .addr(address[7:0]), .din(din_pad[0 +: 16]), .we(enable & write & (address[9:8] == 2'd3)), .ce(enable & (address[9:8] == 2'd3)), .dout(douts[48 +: 16]));
  reg [1:0] rsel; always @(posedge clk) rsel <= address[9:8];
  wire [15:0] rdata = douts[rsel*16 +: 16];
  assign dataout = rdata[7:0];
endmodule

module generic_syncram_Bbehavioral_Ltechmap_8_24_0_0_1(clk, address, datain, write, enable, dataout);
  input clk;
  input [7:0] address;
  input [23:0] datain;
  input write, enable;
  output [23:0] dataout;
  wire [23:0] datain_p = datain;
  wire [31:0] din_pad = {8'b0, datain_p};
  wire [31:0] douts;
  fakeram_asap7_256x16_1rw u_0_0(.clk(clk), .addr(address[7:0]), .din(din_pad[0 +: 16]), .we(enable & write & 1'b1), .ce(enable & 1'b1), .dout(douts[0 +: 16]));
  fakeram_asap7_256x16_1rw u_0_1(.clk(clk), .addr(address[7:0]), .din(din_pad[16 +: 16]), .we(enable & write & 1'b1), .ce(enable & 1'b1), .dout(douts[16 +: 16]));
  assign dataout = douts[23:0];
endmodule

module generic_syncram_Bbehavioral_Ltechmap_8_32_0_0_1(clk, address, datain, write, enable, dataout);
  input clk;
  input [7:0] address;
  input [31:0] datain;
  input write, enable;
  output [31:0] dataout;
  wire [31:0] datain_p = datain;
  wire [31:0] din_pad = datain_p;
  wire [31:0] douts;
  fakeram_asap7_256x16_1rw u_0_0(.clk(clk), .addr(address[7:0]), .din(din_pad[0 +: 16]), .we(enable & write & 1'b1), .ce(enable & 1'b1), .dout(douts[0 +: 16]));
  fakeram_asap7_256x16_1rw u_0_1(.clk(clk), .addr(address[7:0]), .din(din_pad[16 +: 16]), .we(enable & write & 1'b1), .ce(enable & 1'b1), .dout(douts[16 +: 16]));
  assign dataout = douts[31:0];
endmodule

module generic_syncram_2p_Bbehav_Ltechmap_11_16_0_0_0(rclk, wclk, rdaddress, wraddress, data, wren, rden, q);
  input rclk, wclk;
  input [10:0] rdaddress, wraddress;
  input [15:0] data;
  input wren, rden;
  output [15:0] q;
  wire [15:0] din_pad = data;
  wire [127:0] qs;
  fakeram_asap7_256x16_1r1w u_0_0(.rclk(rclk), .wclk(wclk), .raddr(rdaddress[7:0]), .waddr(wraddress[7:0]), .din(din_pad[0 +: 16]), .we(wren & (wraddress[10:8] == 3'd0)), .re(rden & (rdaddress[10:8] == 3'd0)), .dout(qs[0 +: 16]));
  fakeram_asap7_256x16_1r1w u_1_0(.rclk(rclk), .wclk(wclk), .raddr(rdaddress[7:0]), .waddr(wraddress[7:0]), .din(din_pad[0 +: 16]), .we(wren & (wraddress[10:8] == 3'd1)), .re(rden & (rdaddress[10:8] == 3'd1)), .dout(qs[16 +: 16]));
  fakeram_asap7_256x16_1r1w u_2_0(.rclk(rclk), .wclk(wclk), .raddr(rdaddress[7:0]), .waddr(wraddress[7:0]), .din(din_pad[0 +: 16]), .we(wren & (wraddress[10:8] == 3'd2)), .re(rden & (rdaddress[10:8] == 3'd2)), .dout(qs[32 +: 16]));
  fakeram_asap7_256x16_1r1w u_3_0(.rclk(rclk), .wclk(wclk), .raddr(rdaddress[7:0]), .waddr(wraddress[7:0]), .din(din_pad[0 +: 16]), .we(wren & (wraddress[10:8] == 3'd3)), .re(rden & (rdaddress[10:8] == 3'd3)), .dout(qs[48 +: 16]));
  fakeram_asap7_256x16_1r1w u_4_0(.rclk(rclk), .wclk(wclk), .raddr(rdaddress[7:0]), .waddr(wraddress[7:0]), .din(din_pad[0 +: 16]), .we(wren & (wraddress[10:8] == 3'd4)), .re(rden & (rdaddress[10:8] == 3'd4)), .dout(qs[64 +: 16]));
  fakeram_asap7_256x16_1r1w u_5_0(.rclk(rclk), .wclk(wclk), .raddr(rdaddress[7:0]), .waddr(wraddress[7:0]), .din(din_pad[0 +: 16]), .we(wren & (wraddress[10:8] == 3'd5)), .re(rden & (rdaddress[10:8] == 3'd5)), .dout(qs[80 +: 16]));
  fakeram_asap7_256x16_1r1w u_6_0(.rclk(rclk), .wclk(wclk), .raddr(rdaddress[7:0]), .waddr(wraddress[7:0]), .din(din_pad[0 +: 16]), .we(wren & (wraddress[10:8] == 3'd6)), .re(rden & (rdaddress[10:8] == 3'd6)), .dout(qs[96 +: 16]));
  fakeram_asap7_256x16_1r1w u_7_0(.rclk(rclk), .wclk(wclk), .raddr(rdaddress[7:0]), .waddr(wraddress[7:0]), .din(din_pad[0 +: 16]), .we(wren & (wraddress[10:8] == 3'd7)), .re(rden & (rdaddress[10:8] == 3'd7)), .dout(qs[112 +: 16]));
  reg [2:0] rsel; always @(posedge rclk) rsel <= rdaddress[10:8];
  wire [15:0] rdata = qs[rsel*16 +: 16];
  assign q = rdata[15:0];
endmodule

module generic_syncram_2p_Bbehav_Ltechmap_3_32_0_0_0(rclk, wclk, rdaddress, wraddress, data, wren, rden, q);
  input rclk, wclk;
  input [2:0] rdaddress, wraddress;
  input [31:0] data;
  input wren, rden;
  output [31:0] q;
  wire [31:0] din_pad = data;
  wire [31:0] qs;
  fakeram_asap7_256x16_1r1w u_0_0(.rclk(rclk), .wclk(wclk), .raddr({5'b0, rdaddress}), .waddr({5'b0, wraddress}), .din(din_pad[0 +: 16]), .we(wren & 1'b1), .re(rden & 1'b1), .dout(qs[0 +: 16]));
  fakeram_asap7_256x16_1r1w u_0_1(.rclk(rclk), .wclk(wclk), .raddr({5'b0, rdaddress}), .waddr({5'b0, wraddress}), .din(din_pad[16 +: 16]), .we(wren & 1'b1), .re(rden & 1'b1), .dout(qs[16 +: 16]));
  assign q = qs[31:0];
endmodule

module generic_syncram_2p_Bbehav_Ltechmap_8_20_2_0_0(rclk, wclk, rdaddress, wraddress, data, wren, rden, q);
  input rclk, wclk;
  input [7:0] rdaddress, wraddress;
  input [19:0] data;
  input wren, rden;
  output [19:0] q;
  wire [31:0] din_pad = {12'b0, data};
  wire [31:0] qs;
  fakeram_asap7_256x16_1r1w u_0_0(.rclk(rclk), .wclk(wclk), .raddr(rdaddress[7:0]), .waddr(wraddress[7:0]), .din(din_pad[0 +: 16]), .we(wren & 1'b1), .re(rden & 1'b1), .dout(qs[0 +: 16]));
  fakeram_asap7_256x16_1r1w u_0_1(.rclk(rclk), .wclk(wclk), .raddr(rdaddress[7:0]), .waddr(wraddress[7:0]), .din(din_pad[16 +: 16]), .we(wren & 1'b1), .re(rden & 1'b1), .dout(qs[16 +: 16]));
  assign q = qs[19:0];
endmodule

module generic_syncram_2p_Bbehav_Ltechmap_8_21_2_0_0(rclk, wclk, rdaddress, wraddress, data, wren, rden, q);
  input rclk, wclk;
  input [7:0] rdaddress, wraddress;
  input [20:0] data;
  input wren, rden;
  output [20:0] q;
  wire [31:0] din_pad = {11'b0, data};
  wire [31:0] qs;
  fakeram_asap7_256x16_1r1w u_0_0(.rclk(rclk), .wclk(wclk), .raddr(rdaddress[7:0]), .waddr(wraddress[7:0]), .din(din_pad[0 +: 16]), .we(wren & 1'b1), .re(rden & 1'b1), .dout(qs[0 +: 16]));
  fakeram_asap7_256x16_1r1w u_0_1(.rclk(rclk), .wclk(wclk), .raddr(rdaddress[7:0]), .waddr(wraddress[7:0]), .din(din_pad[16 +: 16]), .we(wren & 1'b1), .re(rden & 1'b1), .dout(qs[16 +: 16]));
  assign q = qs[20:0];
endmodule

module generic_syncram_2p_Bbehav_Ltechmap_8_32_0_0_0(rclk, wclk, rdaddress, wraddress, data, wren, rden, q);
  input rclk, wclk;
  input [7:0] rdaddress, wraddress;
  input [31:0] data;
  input wren, rden;
  output [31:0] q;
  wire [31:0] din_pad = data;
  wire [31:0] qs;
  fakeram_asap7_256x16_1r1w u_0_0(.rclk(rclk), .wclk(wclk), .raddr(rdaddress[7:0]), .waddr(wraddress[7:0]), .din(din_pad[0 +: 16]), .we(wren & 1'b1), .re(rden & 1'b1), .dout(qs[0 +: 16]));
  fakeram_asap7_256x16_1r1w u_0_1(.rclk(rclk), .wclk(wclk), .raddr(rdaddress[7:0]), .waddr(wraddress[7:0]), .din(din_pad[16 +: 16]), .we(wren & 1'b1), .re(rden & 1'b1), .dout(qs[16 +: 16]));
  assign q = qs[31:0];
endmodule
