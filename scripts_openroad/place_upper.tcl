# place_upper.tcl
# load read design and perform placement
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl
set DEF_IN $env(DESIGN_NAME)_3D.tmp.def
set VERILOG_IN $env(DESIGN_NAME)_3D.tmp.v
set DEF_OUT $env(DESIGN_NAME)_3D.tmp.def
set VERILOG_OUT $env(DESIGN_NAME)_3D.tmp.v

load_design $DEF_IN 2_floorplan.sdc "Starting place upper"

source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl

set place_density [calculate_placement_density]
mark_insts_by_master "*bottom*" FIRM
puts "Marked bottom instances as FIRM"

# apply_tier_policy upper -cts_safe 1 -fixlib 1
apply_tier_policy upper -cts_safe 1 
fastroute_setup

log_cmd global_placement -density $place_density \
    -incremental \
    -pad_left $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
    -pad_right $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) 

set global_placement_args "-routability_driven -timing_driven"
puts "Running global placement with density: $place_density"
log_cmd global_placement -density $place_density \
    -incremental \
    -pad_left $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
    -pad_right $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
    {*}$global_placement_args

mark_insts_by_master "*bottom*" PLACED
puts "Marked bottom instances as PLACED"

write_def $env(RESULTS_DIR)/$DEF_OUT
write_verilog $env(RESULTS_DIR)/$VERILOG_OUT


estimate_parasitics -placement
source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 3 "global place_upper" false false
save_image -resolution 0.1 $::env(LOG_DIR)/3_place_upper.webp 

exit