# write design def and verilog
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl

set ODB_IN "4_cts.odb"
set SDC_IN "3_place.sdc"
set DEF_OUT "4_2_cts.def"
set VERILOG_OUT "4_2_cts.v"

load_design $ODB_IN $SDC_IN "Reading design from ODB"

write_def    $::env(RESULTS_DIR)/$DEF_OUT
write_verilog $::env(RESULTS_DIR)/$VERILOG_OUT

exit