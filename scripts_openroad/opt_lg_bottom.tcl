# ============================================================
# opt_lg_bottom.tcl
# Run the bottom-side legalization and detail optimization pass.
# ============================================================

# Core setup
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/handoff_manager.tcl

# Environment directories
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

# Stage handoff
set stage_name "legalize-bottom"
# Inputs : ${DESIGN_NAME}_3D.lg.def / ${DESIGN_NAME}_3D.lg.v / 2_floorplan.sdc
# Outputs: ${DESIGN_NAME}_3D.lg.def / ${DESIGN_NAME}_3D.lg.v / 3_place.sdc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

# Additional setup
handoff_log_paths $stage_paths
load_design $DEF_IN $SDC_IN "Starting bottom optimization and legalization"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
set before_report [file join $LOG_DIR "legalize_bottom.before.nets"]
set after_report [file join $LOG_DIR "legalize_bottom.after.nets"]
set summary_report [file join $LOG_DIR "legalize_bottom.cross_tier.summary.rpt"]
set mixed_before_report [file join $LOG_DIR "legalize_bottom.mixed_fanout.before.nets"]
set mixed_after_report [file join $LOG_DIR "legalize_bottom.mixed_fanout.after.nets"]
set mixed_summary_report [file join $LOG_DIR "legalize_bottom.mixed_fanout.summary.rpt"]
set split_before_report [file join $LOG_DIR "legalize_bottom.split.before.rpt"]
set split_after_report [file join $LOG_DIR "legalize_bottom.split.after.rpt"]
set split_summary_report [file join $LOG_DIR "legalize_bottom.split.summary.rpt"]
set attribution_report [file join $LOG_DIR "legalize_bottom.cross_tier.delta.rpt"]

# mark_insts_by_master "*upper*" FIRM

apply_tier_policy bottom -fixlib 1 -allow_net bottom-only
source $::env(OPENROAD_SCRIPTS_DIR)/tier_local_tree.tcl
set local_tree_stats [pin3d_build_local_trees_for_tier bottom -report [file join $LOG_DIR "legalize_bottom.local_tree.rpt"]]
if {[dict get $local_tree_stats buffers] > 0} {
  log_cmd detailed_placement
  set local_tree_topology [pin3d_validate_and_repair_split_topology "3_4_lg_bottom_local_tree" $LOG_DIR $RESULTS_DIR 0]
  if {[dict get $local_tree_topology violated] > 0} {
    error "PIN3D split topology validation failed after bottom local-tree construction"
  }
}
report_cross_tier_snapshot $before_report -label "legalize_bottom before"
report_mixed_fanout_snapshot $mixed_before_report -label "legalize_bottom before"
report_split_structure_snapshot $split_before_report -label "legalize_bottom before"

source $::env(OPENROAD_SCRIPTS_DIR)/opt_lg_design.tcl
pin3d_metrics_invalidate_cache
set split_topology_status [pin3d_validate_and_repair_split_topology \
  "3_4_lg_bottom" $LOG_DIR $RESULTS_DIR 0]
if {[dict get $split_topology_status violated] > 0} {
  error "PIN3D split topology validation failed after bottom legalization"
}
report_cross_tier_transition $summary_report $before_report $after_report -label "legalize_bottom"
report_mixed_fanout_transition $mixed_summary_report $mixed_before_report $mixed_after_report -label "legalize_bottom"
report_split_structure_transition $split_summary_report $split_before_report $split_after_report -label "legalize_bottom"
report_cross_tier_delta_attribution $attribution_report $before_report $after_report -label "legalize_bottom"

# mark_insts_by_master "*upper*" PLACED

handoff_write_stage_outputs $stage_paths \
  -copy_sdc 1 \
  -write_image 1 \
  -write_manifest 1

source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 3 "detailed place_bottom" true false

exit
