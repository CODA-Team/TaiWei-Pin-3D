# ============================================================
# cts.tcl
# Run the owner-tier OpenROAD CTS owner-tree stage.
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
set stage_name "cts"
# Inputs : 3_place.def / 3_place.v / 3_place.sdc
# Outputs: 4_0_cts.def / 4_0_cts.v / 4_0_cts.sdc / 4_0_cts.odb
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
load_design $DEF_IN $SDC_IN "Starting CTS..."
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/cts_stage_common.tcl
set before_report [file join $LOG_DIR "cts.before.nets"]
set after_report [file join $LOG_DIR "cts.after.nets"]
set summary_report [file join $LOG_DIR "cts.cross_tier.summary.rpt"]
set mixed_before_report [file join $LOG_DIR "cts.mixed_fanout.before.nets"]
set mixed_after_report [file join $LOG_DIR "cts.mixed_fanout.after.nets"]
set mixed_summary_report [file join $LOG_DIR "cts.mixed_fanout.summary.rpt"]
set split_before_report [file join $LOG_DIR "cts.split.before.rpt"]
set split_after_report [file join $LOG_DIR "cts.split.after.rpt"]
set split_summary_report [file join $LOG_DIR "cts.split.summary.rpt"]
set attribution_report [file join $LOG_DIR "cts.cross_tier.delta.rpt"]
set clock_before_report [file join $LOG_DIR "cts.clock.before.nets"]
set clock_after_report [file join $LOG_DIR "cts.clock.after.nets"]
set clock_summary_report [file join $LOG_DIR "cts.clock.cross_tier.summary.rpt"]

set active_tier [or_cts_owner_tier]
set fixed_tier [or_cts_receive_tier]
set requested_allow_net [or_cts_requested_allow_net $active_tier]
set effective_allow_net [or_cts_effective_allow_net $active_tier]
or_cts_report_stage_banner "owner-tree" $active_tier $fixed_tier $requested_allow_net $effective_allow_net
or_cts_set_fixed_tier_status $fixed_tier FIRM
apply_tier_policy $active_tier -fixlib 1 -allow_net $effective_allow_net \
  -skip_clock_nets 1 -inactive_cell_mask 0
report_cross_tier_snapshot $before_report -label "cts before"
report_mixed_fanout_snapshot $mixed_before_report -label "cts before"
report_split_structure_snapshot $split_before_report -label "cts before"
report_cross_tier_snapshot $clock_before_report -label "cts clock before" -clock_only 1

set repair_clock_inverters_enable 0
if {[info exists ::env(OPENROAD_CTS_REPAIR_CLOCK_INVERTERS)]} {
  set repair_clock_inverters_enable $::env(OPENROAD_CTS_REPAIR_CLOCK_INVERTERS)
}
if {$repair_clock_inverters_enable} {
  log_cmd repair_clock_inverters
} else {
  puts "INFO(OR): OPENROAD_CTS_REPAIR_CLOCK_INVERTERS=0, skipping repair_clock_inverters."
}

set cts_args [or_cts_common_args]

log_cmd clock_tree_synthesis {*}$cts_args

set_placement_padding -global \
  -left $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT) \
  -right $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT)

set owner_repair_clock_nets 0
if {[info exists ::env(OPENROAD_CTS_OWNER_REPAIR_CLOCK_NETS)]} {
  set owner_repair_clock_nets $::env(OPENROAD_CTS_OWNER_REPAIR_CLOCK_NETS)
}
if {$owner_repair_clock_nets} {
  log_cmd repair_clock_nets
} else {
  puts "INFO(OR): OPENROAD_CTS_OWNER_REPAIR_CLOCK_NETS=0, skipping extra owner-tree repair_clock_nets."
}
set result [catch {detailed_placement} msg]
if {$result != 0} {
  save_progress 4_0_cts_error
  puts "Detailed placement failed in CTS owner-tree: $msg"
  exit $result
}
utl::push_metrics_stage "cts__{}__owner_tree"
estimate_parasitics -placement
utl::pop_metrics_stage
set err [catch {check_placement -verbose} err_message]
if {$err} {
  puts "WARNING: $err_message"
}
# CTS must reconnect clock ITerms on both dies.  Once clock construction is
# complete, restore the inactive-die lock before data-path repair_timing.
_apply_inactive_tier_cell_dont_touch $active_tier 0

set skip_cts_post_repair 0
if {[info exists ::env(OPENROAD_CTS_OWNER_REPAIR_TIMING)]} {
  set skip_cts_post_repair $::env(OPENROAD_CTS_OWNER_REPAIR_TIMING)
}
if {!$skip_cts_post_repair} {
  pin3d_repair_timing_helper
  set result [catch {detailed_placement} msg]
  if {$result != 0} {
    save_progress 4_0_cts_error
    puts "Detailed placement failed in CTS owner-tree repair: $msg"
    exit $result
  }
  estimate_parasitics -placement
  set err [catch {check_placement -verbose} err_message]
  if {$err} {
    puts "WARNING: $err_message"
  }
} else {
  puts "INFO(OR): OPENROAD_CTS_OWNER_REPAIR_TIMING=0, skipping owner-tree repair_timing."
}

or_cts_set_fixed_tier_status $fixed_tier PLACED

set split_topology_status [pin3d_validate_and_repair_split_topology \
  "4_0_cts" $LOG_DIR $RESULTS_DIR 0]
if {[dict get $split_topology_status violated] > 0} {
  error "PIN3D split topology validation failed after CTS owner-tree optimization"
}
pin3d_metrics_invalidate_cache
report_cross_tier_transition $summary_report $before_report $after_report -label "cts"
report_mixed_fanout_transition $mixed_summary_report $mixed_before_report $mixed_after_report -label "cts"
report_split_structure_transition $split_summary_report $split_before_report $split_after_report -label "cts"
report_cross_tier_delta_attribution $attribution_report $before_report $after_report -label "cts"
report_cross_tier_transition $clock_summary_report $clock_before_report $clock_after_report -label "cts clock" -clock_only 1

source_env_var_if_exists POST_CTS_TCL
source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 4 "cts" false false

handoff_write_stage_outputs $stage_paths \
  -write_db 1 \
  -write_def 1 \
  -write_verilog 1 \
  -write_sdc 1 \
  -write_image 1 \
  -write_manifest 1

exit
