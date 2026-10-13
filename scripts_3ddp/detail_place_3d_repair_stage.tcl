# Build the private repaired handoff consumed by the 3D DP process.

source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/handoff_manager.tcl
set detail_place_3d_script_dir [file dirname [file normalize [info script]]]
source [file join $detail_place_3d_script_dir detail_place_3d_config.tcl]
source [file join $detail_place_3d_script_dir detail_place_3d_checks.tcl]
source [file join $detail_place_3d_script_dir detail_place_3d_repair.tcl]

set LOG_DIR [_get LOG_DIR]
set RESULTS_DIR [_get RESULTS_DIR]
set OBJECTS_DIR [_get OBJECTS_DIR]

set stage_paths [detail_place_3d_stage_paths $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths
detail_place_3d_clear_stage_outputs $stage_paths
detail_place_3d_require_stage_inputs $stage_paths
load_design $DEF_IN $SDC_IN "Starting 3D DP compatibility repair"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl

set hbt_dir [file join $OBJECTS_DIR 3ddp]
file mkdir $hbt_dir
set pre_repair_def [file join $hbt_dir pre_repair.def]
file delete -force $pre_repair_def

3d_dp_run_compat_repairs
write_def $pre_repair_def
if {![file exists $pre_repair_def] || [file size $pre_repair_def] == 0} {
  error "3d_dp: failed to publish repaired private DEF '$pre_repair_def'"
}
puts "INFO(3D_DP): published repaired private DEF $pre_repair_def"
exit
