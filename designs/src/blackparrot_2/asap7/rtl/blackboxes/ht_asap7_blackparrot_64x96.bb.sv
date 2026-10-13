(* blackbox *)
module ht_asap7_blackparrot_64x96
(
   rw0_wd_in,
   rw0_we_in,
   rw0_wmask_in,
   rw0_rd_out,
   rw0_clk,
   rw0_ce_in,
   rw0_addr_in
);
   input                    rw0_clk;
   input                    rw0_ce_in;
   input  [5:0]             rw0_addr_in;
   output reg [95:0]        rw0_rd_out;
   input                    rw0_we_in;
   input  [95:0]            rw0_wd_in;
   input  [95:0]             rw0_wmask_in;

endmodule
