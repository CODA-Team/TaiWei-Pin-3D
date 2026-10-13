# ============================================================
# detail_route.tcl
# Run the OpenROAD detailed routing stage.
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
set stage_name "route-detail"
# Inputs : 5_1_grt.odb / 5_1_grt.sdc
# Outputs: 5_route.def / 5_route.v / 5_route.sdc / 5_route.odb
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

# Additional setup
handoff_log_paths $stage_paths
utl::set_metrics_stage "detailedroute__{}"
load_design $ODB_IN $SDC_IN "Start detailed route"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
set before_report [file join $LOG_DIR "5_route.before.nets"]
set after_report [file join $LOG_DIR "5_route.after.nets"]
set summary_report [file join $LOG_DIR "5_route.cross_tier.summary.rpt"]
set clock_before_report [file join $LOG_DIR "5_route.clock.before.nets"]
set clock_after_report [file join $LOG_DIR "5_route.clock.after.nets"]
set clock_summary_report [file join $LOG_DIR "5_route.clock.cross_tier.summary.rpt"]
apply_tier_policy [or_cts_owner_tier] -fixlib 1 -allow_net all 
report_cross_tier_snapshot $before_report -label "route before"
report_cross_tier_snapshot $clock_before_report -label "route clock before" -clock_only 1

if {![grt::have_routes]} {
  error "Global routing failed, run `make gui_grt` and inspect $::global_route_congestion_report"
}

set_propagated_clock [all_clocks]

set additional_args ""
if {![info exists ::env(OR_K)]} {
  set ::env(OR_K) 1.0
}
if {![info exists ::env(DETAILED_ROUTE_END_ITERATION)]} {
  set ::env(DETAILED_ROUTE_END_ITERATION) 20
}
append_env_var additional_args DB_PROCESS_NODE -db_process_node 1
append_env_var additional_args OR_K -or_k 1
append_env_var additional_args DETAILED_ROUTE_END_ITERATION -droute_end_iter 1
append additional_args " -verbose 1 -no_pin_access"

set arguments [expr {
  [env_var_exists_and_non_empty DETAILED_ROUTE_ARGS] ? $::env(DETAILED_ROUTE_ARGS) :
  [concat $additional_args {-drc_report_iter_step 5}]
}]
puts "Detailed route arguments: $arguments"

set all_args [concat [list \
  -output_drc $::env(REPORTS_DIR)/5_route_drc.rpt \
  -output_maze $::env(RESULTS_DIR)/maze.log] \
  $arguments]

log_cmd detailed_route {*}$all_args

if {
  ![env_var_equals SKIP_ANTENNA_REPAIR_POST_DRT 1] &&
  [env_var_exists_and_non_empty MAX_REPAIR_ANTENNAS_ITER_DRT]
} {
  set repair_antennas_iters 1
  if {[repair_antennas]} {
    detailed_route {*}$all_args
  }
  while {[check_antennas] && $repair_antennas_iters < $::env(MAX_REPAIR_ANTENNAS_ITER_DRT)} {
    repair_antennas
    detailed_route {*}$all_args
    incr repair_antennas_iters
  }
} else {
  utl::metric_int "antenna_diodes_count" -1
}

source_env_var_if_exists POST_DETAIL_ROUTE_TCL
check_antennas -report_file $env(REPORTS_DIR)/drt_antennas.log

if {![design_is_routed]} {
  error "Design has unrouted nets."
}

set split_topology_status [pin3d_validate_and_repair_split_topology \
  5_route $LOG_DIR $RESULTS_DIR 0]
if {[dict get $split_topology_status violated] > 0} {
  error "Post-route dual-boundary validation found [dict get $split_topology_status violated] invalid topology record(s); see 5_route.split_topology.summary.rpt"
}

pin3d_metrics_invalidate_cache
report_cross_tier_transition $summary_report $before_report $after_report -label "route"
report_cross_tier_transition $clock_summary_report $clock_before_report $clock_after_report -label "route clock" -clock_only 1

handoff_write_stage_outputs $stage_paths \
  -write_db 1 \
  -write_def 1 \
  -write_verilog 1 \
  -write_sdc 1 \
  -write_manifest 1

exit
