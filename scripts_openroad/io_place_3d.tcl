# ============================================================
# io_place_3d.tcl
# Place IO pins on top of the existing 3D floorplan.
# ============================================================

# Core setup
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/handoff_manager.tcl

# Environment directories
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

# Stage handoff
set stage_name "io-place"
# Inputs : 2_3_floorplan_3d.def / 2_3_floorplan_3d.v / 1_synth.sdc
# Outputs: 2_4_floorplan_io.def / 2_4_floorplan_io.v / 1_synth.sdc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

# Additional setup
handoff_log_paths $stage_paths
load_design $DEF_IN $SDC_IN "Starting IO assignment"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/floorplan_utils.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/io_place_3d_helpers.tcl
if {[_pin3d_boolean_env PIN3D_IO_FEEDBACK 0]} {
  source $::env(OPENROAD_SCRIPTS_DIR)/io_place_helpers.tcl
  source $::env(OPENROAD_SCRIPTS_DIR)/io_feedback.tcl
  ::pin3d_io_feedback::place_in_3d \
      [file join $RESULTS_DIR io_feedback_assignment.list]
} else {
  set ::PIN3D_TIERED_IO 1
  source $::env(OPENROAD_SCRIPTS_DIR)/io_place.tcl
  unset ::PIN3D_TIERED_IO
}

handoff_write_stage_outputs $stage_paths \
  -copy_sdc 1 \
  -write_manifest 1
exit
