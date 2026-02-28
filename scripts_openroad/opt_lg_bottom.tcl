# opt_lg_bottom.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl
set DEF_IN       "$::env(DESIGN_NAME)_3D.lg.def"
set VERILOG_IN   "$::env(DESIGN_NAME)_3D.lg.v"
set DEF_OUT      "$::env(DESIGN_NAME)_3D.lg.def"
set VERILOG_OUT  "$::env(DESIGN_NAME)_3D.lg.v"

# Load design
load_design $DEF_IN 2_floorplan.sdc "Starting bottom optimization and legalization"

# Source helper utilities
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl

mark_insts_by_master "*upper*" FIRM

apply_tier_policy bottom -cts_safe 1 -fixlib 1

source $::env(OPENROAD_SCRIPTS_DIR)/opt_lg_design.tcl

mark_insts_by_master "*upper*" PLACED

write_def    $env(RESULTS_DIR)/$DEF_OUT
write_verilog $env(RESULTS_DIR)/$VERILOG_OUT

source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 3 "detailed place_bottom" true false
save_image -resolution 0.1 $::env(LOG_DIR)/3_4_opt_lg_bottom_legalized.webp

exit
