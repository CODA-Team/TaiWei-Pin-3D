// Local-authorship hold: no redistribution license has been granted.
// Explicit replacement for only the FIRRTL-generated Queue_6 module.
//
// The eight physical banks reproduce the legacy mapping boundary: each bank
// stores 16 logical bits, one bit in each physical byte lane. The read address
// looks ahead on a dequeue to compensate for the registered macro read.

module Queue_6 (
  input  logic         clock,
  input  logic         reset,
  output logic         io_enq_ready,
  input  logic         io_enq_valid,
  input  logic [127:0] io_enq_bits,
  input  logic         io_deq_ready,
  output logic         io_deq_valid,
  output wire  [127:0] io_deq_bits
);
  logic [8:0] enq_ptr_value;
  logic [8:0] deq_ptr_value;
  logic       maybe_full;
  logic [127:0] bypass_data_q;
  logic         bypass_valid_q;

  wire ptr_match = enq_ptr_value == deq_ptr_value;
  wire empty = ptr_match && !maybe_full;
  wire full = ptr_match && maybe_full;
  wire do_enq = io_enq_ready && io_enq_valid;
  wire do_deq = io_deq_ready && io_deq_valid;
  wire [8:0] deq_ptr_next = deq_ptr_value + 9'd1;
  wire [8:0] macro_read_addr = reset ? 9'd0 :
                               (do_deq ? deq_ptr_next : deq_ptr_value);

  assign io_enq_ready = !full;
  assign io_deq_valid = !empty;

  always_ff @(posedge clock) begin
    if (reset) begin
      enq_ptr_value <= 9'd0;
      deq_ptr_value <= 9'd0;
      maybe_full <= 1'b0;
      bypass_data_q <= 128'd0;
      bypass_valid_q <= 1'b0;
    end else begin
      // Match the legacy macro mapping's synchronous read-during-write bypass.
      bypass_valid_q <= do_enq && enq_ptr_value == macro_read_addr;
      if (do_enq) begin
        bypass_data_q <= io_enq_bits;
      end
      if (do_enq) begin
        enq_ptr_value <= enq_ptr_value + 9'd1;
      end
      if (do_deq) begin
        deq_ptr_value <= deq_ptr_value + 9'd1;
      end
      if (do_enq != do_deq) begin
        maybe_full <= do_enq;
      end
    end
  end

  genvar bank;
  genvar lane;
  generate
    for (bank = 0; bank < 8; bank = bank + 1) begin : gen_bank
      wire [127:0] physical_read_data;
      wire [127:0] physical_write_data;

      for (lane = 0; lane < 16; lane = lane + 1) begin : gen_lane
        assign physical_write_data[lane * 8 +: 8] =
          {7'b0, io_enq_bits[bank * 16 + lane]};
        assign io_deq_bits[bank * 16 + lane] =
          bypass_valid_q ? bypass_data_q[bank * 16 + lane] :
                           physical_read_data[lane * 8];
      end

      vta_q_512x128 macro_bank (
        .PORT_R_CLK(clock),
        .PORT_R_ADDR(macro_read_addr),
        .PORT_R_RD_DATA(physical_read_data),
        .PORT_W_CLK(clock),
        .PORT_W_ADDR(enq_ptr_value),
        .PORT_W_WR_DATA(physical_write_data),
        .PORT_W_WR_EN({16{do_enq}})
      );
    end
  endgenerate
endmodule
