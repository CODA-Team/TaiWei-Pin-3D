// Local-authorship hold: no redistribution license has been granted.
// Single-outstanding LEON external-IO to VTA host-AXI bridge.

module vta_host_bridge (
  input  logic        clk,
  input  logic        rstn,

  input  logic [27:0] l_address,
  input  logic [31:0] l_dataout,
  input  logic        l_iosn,
  input  logic        l_writen,
  input  logic        l_read,
  input  logic [31:0] l_datain_ext,
  output logic [31:0] l_datain,
  output logic        l_brdyn,
  output logic        l_bexcn,
  output logic        l_irq,
  output logic        l_owns_cycle,

  output logic        io_host_aw_valid,
  output logic [15:0] io_host_aw_bits_addr,
  input  logic        io_host_aw_ready,
  output logic        io_host_w_valid,
  output logic [31:0] io_host_w_bits_data,
  input  logic        io_host_w_ready,
  input  logic        io_host_b_valid,
  input  logic [1:0]  io_host_b_bits_resp,
  output logic        io_host_b_ready,
  output logic        io_host_ar_valid,
  output logic [15:0] io_host_ar_bits_addr,
  input  logic        io_host_ar_ready,
  input  logic        io_host_r_valid,
  input  logic [31:0] io_host_r_bits_data,
  input  logic [1:0]  io_host_r_bits_resp,
  output logic        io_host_r_ready
);
  typedef enum logic [2:0] {
    IDLE,
    WRITE_SEND,
    WRITE_RESPONSE,
    READ_SEND,
    READ_RESPONSE,
    COMPLETE
  } state_t;

  state_t state;
  logic aw_valid_q;
  logic w_valid_q;
  logic ar_valid_q;
  logic [15:0] address_q;
  logic [31:0] write_data_q;
  logic [31:0] read_data_q;
  logic response_error_q;
  logic irq_q;

  wire selected = !l_iosn && l_address[20];
  wire write_request = selected && !l_writen;
  wire read_request = selected && l_read;
  wire request_active = write_request || read_request;

  assign io_host_aw_valid = aw_valid_q;
  assign io_host_aw_bits_addr = address_q;
  assign io_host_w_valid = w_valid_q;
  assign io_host_w_bits_data = write_data_q;
  assign io_host_ar_valid = ar_valid_q;
  assign io_host_ar_bits_addr = address_q;
  assign io_host_b_ready = state == WRITE_RESPONSE;
  assign io_host_r_ready = state == READ_RESPONSE;

  assign l_owns_cycle = selected || state != IDLE;
  assign l_datain = state == COMPLETE ? read_data_q : l_datain_ext;
  assign l_brdyn = state == COMPLETE ? 1'b0 : 1'b1;
  assign l_bexcn = state == COMPLETE && response_error_q ? 1'b0 : 1'b1;
  assign l_irq = irq_q;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state <= IDLE;
      aw_valid_q <= 1'b0;
      w_valid_q <= 1'b0;
      ar_valid_q <= 1'b0;
      address_q <= 16'd0;
      write_data_q <= 32'd0;
      read_data_q <= 32'd0;
      response_error_q <= 1'b0;
      irq_q <= 1'b0;
    end else begin
      irq_q <= 1'b0;

      case (state)
        IDLE: begin
          response_error_q <= 1'b0;
          if (write_request) begin
            address_q <= l_address[15:0];
            write_data_q <= l_dataout;
            aw_valid_q <= 1'b1;
            w_valid_q <= 1'b1;
            state <= WRITE_SEND;
          end else if (read_request) begin
            address_q <= l_address[15:0];
            ar_valid_q <= 1'b1;
            state <= READ_SEND;
          end
        end

        WRITE_SEND: begin
          if (aw_valid_q && io_host_aw_ready) begin
            aw_valid_q <= 1'b0;
          end
          if (w_valid_q && io_host_w_ready) begin
            w_valid_q <= 1'b0;
          end
          if ((!aw_valid_q || io_host_aw_ready) &&
              (!w_valid_q || io_host_w_ready)) begin
            state <= WRITE_RESPONSE;
          end
        end

        WRITE_RESPONSE: begin
          if (io_host_b_valid) begin
            response_error_q <= io_host_b_bits_resp != 2'b00;
            irq_q <= 1'b1;
            state <= COMPLETE;
          end
        end

        READ_SEND: begin
          if (ar_valid_q && io_host_ar_ready) begin
            ar_valid_q <= 1'b0;
            state <= READ_RESPONSE;
          end
        end

        READ_RESPONSE: begin
          if (io_host_r_valid) begin
            read_data_q <= io_host_r_bits_data;
            response_error_q <= io_host_r_bits_resp != 2'b00;
            state <= COMPLETE;
          end
        end

        COMPLETE: begin
          if (!request_active) begin
            state <= IDLE;
          end
        end

        default: state <= IDLE;
      endcase
    end
  end
endmodule

