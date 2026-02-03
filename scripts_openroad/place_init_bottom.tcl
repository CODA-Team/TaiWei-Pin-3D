# load read design and perform placement
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl
set DEF_IN $env(DESIGN_NAME)_3D.tmp.def
set VERILOG_IN $env(DESIGN_NAME)_3D.tmp.v
set DEF_OUT $env(DESIGN_NAME)_3D.tmp.def
set VERILOG_OUT $env(DESIGN_NAME)_3D.tmp.v

load_design $DEF_IN 2_floorplan.sdc "Starting place init upper"

source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
set place_density [calculate_placement_density]

mark_insts_by_master "*upper*" FIRM

puts "Running global placement with density: $place_density"
set global_placement_args ""
log_cmd global_placement -density $place_density \
        -pad_left $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
        -pad_right $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
        {*}$global_placement_args

mark_insts_by_master "*upper*" PLACED

write_def $env(RESULTS_DIR)/$DEF_OUT
write_verilog $env(RESULTS_DIR)/$VERILOG_OUT

save_image -resolution 0.1 $::env(LOG_DIR)/3_place_init_bottom.webp 

exit