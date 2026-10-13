# Adapted from scripts_openroad/io_placement_random.tcl for the 3D-Syn handoff.

source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
load_design 2_1_floorplan.backend.odb 1_synth.sdc "3D-Syn backend IO placement"

source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/io_place.tcl

set place_density [calculate_placement_density]
log_cmd global_placement -density $place_density \
  -pad_left $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
  -pad_right $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT)

write_db $::env(RESULTS_DIR)/2_2_floorplan_io.backend.odb
write_def $::env(RESULTS_DIR)/2_2_floorplan_io.backend.def
write_verilog $::env(RESULTS_DIR)/2_2_floorplan_io.backend.v

exit
