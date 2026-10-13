# ============================================================
# global_route.tcl
# Run the OpenROAD global routing stage.
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
set stage_name "route-global"
# Inputs : 4_cts.def / 4_cts.v / 4_cts.sdc
# Outputs: 5_1_grt.odb / 5_1_grt.sdc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

# Additional setup
handoff_log_paths $stage_paths
utl::set_metrics_stage "globalroute__{}"
load_design $DEF_IN $SDC_IN "Start global route"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
apply_tier_policy [or_cts_owner_tier] -fixlib 1 -allow_net all 
set ::or_route_global_stage_paths $stage_paths
if {![info exists ::env(GLOBAL_ROUTE_ARGS)]} {
  set ::env(GLOBAL_ROUTE_ARGS) {}
}

proc global_route_helper {} {
  source $::env(OPENROAD_SCRIPTS_DIR)/deleteRoutingObstructions.tcl
  deleteRoutingObstructions
  source_env_var_if_exists PRE_GLOBAL_ROUTE_TCL

  proc do_global_route {} {
    set all_args [concat [list -congestion_report_file $::global_route_congestion_report] $::env(GLOBAL_ROUTE_ARGS)]
    log_cmd global_route {*}$all_args
  }

  source $::env(FASTROUTE_TCL)
  pin_access

  set result [catch {do_global_route} errMsg]
  if {$result != 0} {
    if {[env_var_exists_and_non_empty GENERATE_ARTIFACTS_ON_FAILURE] && !$::env(GENERATE_ARTIFACTS_ON_FAILURE)} {
      write_db $::env(RESULTS_DIR)/5_1_grt-failed.odb
      error $errMsg
    }
    handoff_write_stage_outputs $::or_route_global_stage_paths \
      -write_db 1 \
      -write_def 0 \
      -write_verilog 0 \
      -write_sdc 1 \
      -write_manifest 1
    return
  }

  set_placement_padding -global \
    -left $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT) \
    -right $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT)

  set_propagated_clock [all_clocks]
  estimate_parasitics -global_routing

  if {[env_var_exists_and_non_empty DONT_USE_CELLS]} {
    set_dont_use $::env(DONT_USE_CELLS)
  }

  if {[env_var_exists_and_non_empty SKIP_INCREMENTAL_REPAIR] && !$::env(SKIP_INCREMENTAL_REPAIR)} {
    # allow_net=all keeps PG hookup safe.  Re-protect the immutable dual
    # boundary only for the interval that can rewrite the signal topology.
    _protect_pin3d_split_buffers 0 1
    _protect_pin3d_bridge_nets 0 1
    repair_design_helper
    log_cmd global_route -start_incremental
    log_cmd detailed_placement
    log_cmd global_route -end_incremental \
      -congestion_report_file $::env(REPORTS_DIR)/congestion_post_repair_design.rpt

    puts "Repair setup and hold violations..."
    estimate_parasitics -global_routing
    repair_timing_helper
    log_cmd global_route -start_incremental
    log_cmd detailed_placement
    log_cmd global_route -end_incremental \
      -congestion_report_file $::env(REPORTS_DIR)/congestion_post_repair_timing.rpt
  }

  puts "Estimate parasitics..."
  estimate_parasitics -global_routing
  source [file join $::env(OPENROAD_SCRIPTS_DIR) "write_ref_sdc.tcl"]
  write_guides $::env(RESULTS_DIR)/route.guide

  handoff_write_stage_outputs $::or_route_global_stage_paths \
    -write_db 1 \
    -write_def 0 \
    -write_verilog 0 \
    -write_sdc 1 \
    -write_manifest 1
}

global_route_helper

exit
