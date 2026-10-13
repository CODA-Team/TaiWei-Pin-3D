# Run the integrated OpenROAD 3D detailed placement stage.

source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/handoff_manager.tcl
set detail_place_3d_script_dir [file dirname [file normalize [info script]]]
source [file join $detail_place_3d_script_dir detail_place_3d_config.tcl]
source [file join $detail_place_3d_script_dir detail_place_3d_checks.tcl]
source [file join $detail_place_3d_script_dir detail_place_3d_post.tcl]

if {![llength [info commands 3d_detailed_placement]]} {
  error "3d_dp: installed OpenROAD lacks 3d_detailed_placement; rebuild and install the TDP-enabled OpenROAD binary"
}

set LOG_DIR [_get LOG_DIR]
set RESULTS_DIR [_get RESULTS_DIR]
set REPORTS_DIR [_get REPORTS_DIR]
set OBJECTS_DIR [_get OBJECTS_DIR]

set stage_paths [detail_place_3d_stage_paths $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths
handoff_log_paths $stage_paths
# Remove only this stage's old public handoff before running.  A failure must
# not permit CTS to consume stale 3_place files from an earlier attempt.
detail_place_3d_clear_stage_outputs $stage_paths
detail_place_3d_require_stage_inputs $stage_paths

set hbt_dir [file join $OBJECTS_DIR 3ddp]
file mkdir $hbt_dir
set pre_repair_def [file join $hbt_dir pre_repair.def]
if {![file exists $pre_repair_def] || [file size $pre_repair_def] == 0} {
  error "3d_dp: required repaired private DEF is missing: $pre_repair_def"
}

# Run TDP in a fresh OpenROAD process so repair's single-tier policy state is
# not carried into the global 3D optimization.
load_design $pre_repair_def $SDC_IN "Starting 3D detailed placement"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl

set config [3d_dp_resolve_config]
set before [3d_dp_snapshot]
set audit_paths [3d_dp_capture_audit $LOG_DIR]
set cross_tier_nets [3d_dp_cross_tier_net_count]
puts "INFO(3D_DP): detected $cross_tier_nets cross-tier nets"

set hbt_json [file join $hbt_dir hbt_array.json]
file delete -force $hbt_json
set generator [file join $detail_place_3d_script_dir generate_hbt_array.py]
set design_config [3d_dp_env_or_default DESIGN_CONFIG ""]
if {$design_config eq "" || ![file exists $design_config]} {
  error "3d_dp: DESIGN_CONFIG must name the active design config.mk"
}
set generate_cmd [list python3 $generator \
  --max-core-utilization [dict get $config hbt_max_core_utilization] \
  --required-connections $cross_tier_nets \
  --source-def $pre_repair_def \
  --source-lef [dict get $config hbt_source_lef] \
  --design-config $design_config \
  --output $hbt_json]
puts "INFO(3D_DP): [exec {*}$generate_cmd 2>@1]"

set placement_report [file join $REPORTS_DIR 3ddp_placement.rpt]
# Enable TDP's parallel candidate evaluation for the integrated 3D DP stage.
set ::env(TDP_PAR) 1
3d_detailed_placement \
  -tech [dict get $config tech] \
  -hbt $hbt_json \
  -max_displacement [dict get $config max_displacement] \
  -m [dict get $config margin] \
  -report_file_name $placement_report

3d_dp_run_postprocess $audit_paths
3d_dp_validate_snapshot $before

handoff_write_stage_outputs $stage_paths \
  -copy_sdc 1 \
  -write_image 1 \
  -write_manifest 1
detail_place_3d_assert_stage_outputs $stage_paths

source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 3 "3d detailed place" true false
exit
