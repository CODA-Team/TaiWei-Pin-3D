# ============================================================
# cts_post.tcl
# Run the receive-tier OpenROAD post-CTS optimization stage.
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
set stage_name "cts-post"
# Inputs : 4_0_cts.def / 4_0_cts.v / 4_0_cts.sdc / 4_0_cts.odb
# Outputs: 4_cts.def / 4_cts.v / 4_cts.sdc / 4_cts.odb
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

proc save_progress {stage_name} {
  puts "Run 'make gui_${stage_name}.odb' to load progress snapshot"
  write_db $::env(RESULTS_DIR)/${stage_name}.odb
  write_sdc -no_timestamp $::env(RESULTS_DIR)/${stage_name}.sdc
}

# Additional setup
handoff_log_paths $stage_paths
utl::set_metrics_stage "cts__{}"
load_design $DEF_IN $SDC_IN "Starting POST CTS..."
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/cts_stage_common.tcl
set before_report [file join $LOG_DIR "cts_post.before.nets"]
set after_report [file join $LOG_DIR "cts_post.after.nets"]
set summary_report [file join $LOG_DIR "cts_post.cross_tier.summary.rpt"]
set mixed_before_report [file join $LOG_DIR "cts_post.mixed_fanout.before.nets"]
set mixed_after_report [file join $LOG_DIR "cts_post.mixed_fanout.after.nets"]
set mixed_summary_report [file join $LOG_DIR "cts_post.mixed_fanout.summary.rpt"]
set split_before_report [file join $LOG_DIR "cts_post.split.before.rpt"]
set split_after_report [file join $LOG_DIR "cts_post.split.after.rpt"]
set split_summary_report [file join $LOG_DIR "cts_post.split.summary.rpt"]
set attribution_report [file join $LOG_DIR "cts_post.cross_tier.delta.rpt"]
set clock_before_report [file join $LOG_DIR "cts_post.clock.before.nets"]
set clock_after_report [file join $LOG_DIR "cts_post.clock.after.nets"]
set clock_summary_report [file join $LOG_DIR "cts_post.clock.cross_tier.summary.rpt"]

set active_tier [or_cts_receive_tier]
set fixed_tier [or_cts_owner_tier]
set requested_allow_net [or_cts_requested_allow_net $active_tier]
set effective_allow_net [or_cts_effective_allow_net $active_tier]
or_cts_report_stage_banner "receive-opt" $active_tier $fixed_tier $requested_allow_net $effective_allow_net
or_cts_set_fixed_tier_status $fixed_tier FIRM
apply_tier_policy $active_tier -fixlib 1 -allow_net $effective_allow_net \
  -skip_clock_nets 1 -inactive_cell_mask 0
report_cross_tier_snapshot $before_report -label "cts_post before"
report_mixed_fanout_snapshot $mixed_before_report -label "cts_post before"
report_split_structure_snapshot $split_before_report -label "cts_post before"
report_cross_tier_snapshot $clock_before_report -label "cts_post clock before" -clock_only 1

utl::push_metrics_stage "cts__{}__pre_repair_timing"
estimate_parasitics -placement
utl::pop_metrics_stage

set_placement_padding -global \
  -left $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT) \
  -right $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT)

log_cmd repair_clock_nets
log_cmd detailed_placement
estimate_parasitics -placement

# repair_clock_nets needs access to clock ITerms on both dies.  Restore the
# inactive-die lock before allowing data-path repair_timing to run.
_apply_inactive_tier_cell_dont_touch $active_tier 0

set skip_cts_post_repair 0
if {[info exists ::env(SKIP_CTS_POST_REPAIR_TIMING)]} {
  set skip_cts_post_repair $::env(SKIP_CTS_POST_REPAIR_TIMING)
} elseif {[info exists ::env(SKIP_CTS_REPAIR_TIMING)]} {
  set skip_cts_post_repair $::env(SKIP_CTS_REPAIR_TIMING)
}
if {!$skip_cts_post_repair} {
  pin3d_repair_timing_helper
  set result [catch {detailed_placement} msg]
  if {$result != 0} {
    save_progress 4_cts_error
    puts "Detailed placement failed in CTS post: $msg"
    exit $result
  }
  set err [catch {check_placement -verbose} err_message]
  if {$err} {
    puts "WARNING: $err_message"
  }
} else {
  puts "INFO(OR): SKIP_CTS_POST_REPAIR_TIMING=$skip_cts_post_repair, skipping post-CTS repair_timing."
}

or_cts_set_fixed_tier_status $fixed_tier PLACED

set split_topology_status [pin3d_validate_and_repair_split_topology \
  "4_1_cts_post" $LOG_DIR $RESULTS_DIR 0]
if {[dict get $split_topology_status violated] > 0} {
  error "PIN3D split topology validation failed after CTS receive-tier optimization"
}
pin3d_metrics_invalidate_cache
report_cross_tier_transition $summary_report $before_report $after_report -label "cts_post"
report_mixed_fanout_transition $mixed_summary_report $mixed_before_report $mixed_after_report -label "cts_post"
report_split_structure_transition $split_summary_report $split_before_report $split_after_report -label "cts_post"
report_cross_tier_delta_attribution $attribution_report $before_report $after_report -label "cts_post"
report_cross_tier_transition $clock_summary_report $clock_before_report $clock_after_report -label "cts_post clock" -clock_only 1

source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 4 "cts_post" false false

handoff_write_stage_outputs $stage_paths \
  -write_db 1 \
  -write_def 1 \
  -write_verilog 1 \
  -write_sdc 1 \
  -write_image 1 \
  -write_manifest 1

exit
