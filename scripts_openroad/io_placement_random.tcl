# Initial IO assignment followed by a coarse 2D placement.
# PIN3D_IO_FEEDBACK=1 adds one placement-informed IO/placement iteration and
# exports a normalized boundary assignment for the later 3D IO stage.

# 0) Load design
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
load_design 2_1_floorplan.odb 1_synth.sdc "Uniform IO placement (snap-to-edge)"

source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl

source $::env(OPENROAD_SCRIPTS_DIR)/io_place.tcl

set place_density [calculate_placement_density]

log_cmd global_placement -density $place_density \
    -pad_left $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
    -pad_right $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT)

if {[_pin3d_boolean_env PIN3D_IO_FEEDBACK 0]} {
  source $::env(OPENROAD_SCRIPTS_DIR)/io_feedback.tcl
  puts "IO-FEEDBACK: reassigning IO using coarse-placement cell coordinates"
  source $::env(OPENROAD_SCRIPTS_DIR)/io_place.tcl
  log_cmd global_placement -density $place_density -skip_initial_place \
      -pad_left $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
      -pad_right $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT)
  estimate_parasitics -placement
  ::pin3d_io_feedback::write_assignment \
      [file join $::env(RESULTS_DIR) io_feedback_assignment.list]
} else {
  # A reused results directory must not retain an enabled arm's handoff.
  file delete -force [file join $::env(RESULTS_DIR) io_feedback_assignment.list]
}

# 8) Save
write_db      $::env(RESULTS_DIR)/2_2_floorplan_io.odb
write_def     $::env(RESULTS_DIR)/2_2_floorplan_io.def
write_verilog $::env(RESULTS_DIR)/2_2_floorplan_io.v

exit
