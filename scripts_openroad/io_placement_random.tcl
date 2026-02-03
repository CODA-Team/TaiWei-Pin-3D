# io_place_random.tcl
# Evenly place ALL top-level pins around four edges.
# Trick: place slightly OUTSIDE the intended edge, then use -force_to_die_boundary.

# 0) Load design
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
load_design 2_1_floorplan.odb 1_synth.sdc "Uniform IO placement (snap-to-edge)"

source $::env(OPENROAD_SCRIPTS_DIR)/io_place.tcl

# 8) Save
write_db      $::env(RESULTS_DIR)/2_2_floorplan_io.odb
write_def     $::env(RESULTS_DIR)/2_2_floorplan_io.def
write_verilog $::env(RESULTS_DIR)/2_2_floorplan_io.v

exit
