utl::set_metrics_stage "globalroute__{}"
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl
# source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
load_design 4_cts.def 4_cts.sdc "Start global route"

# This proc is here to allow us to use 'return' to return early from this
# file which is sourced
proc global_route_helper { } {
  source_env_var_if_exists PRE_GLOBAL_ROUTE_TCL

  proc do_global_route { } {
    set all_args [concat [list \
      -congestion_report_file $::global_route_congestion_report] \
      $::env(GLOBAL_ROUTE_ARGS)]

    log_cmd global_route {*}$all_args
  }
  source $::env(FASTROUTE_TCL)
  pin_access

  set result [catch { do_global_route } errMsg]

  if { $result != 0 } {
    if { [env_var_exists_and_non_empty GENERATE_ARTIFACTS_ON_FAILURE] && !$::env(GENERATE_ARTIFACTS_ON_FAILURE) } {
      write_db $::env(RESULTS_DIR)/5_1_grt-failed.odb
      error $errMsg
    }
    write_sdc -no_timestamp $::env(RESULTS_DIR)/5_1_grt.sdc
    write_db $::env(RESULTS_DIR)/5_1_grt.odb
    return
  }

  set_placement_padding -global \
    -left $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT) \
    -right $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT)

  set_propagated_clock [all_clocks]
  estimate_parasitics -global_routing

  if { [env_var_exists_and_non_empty DONT_USE_CELLS] } {
    set_dont_use $::env(DONT_USE_CELLS)
  }

  if {[env_var_exists_and_non_empty SKIP_INCREMENTAL_REPAIR] && !$::env(SKIP_INCREMENTAL_REPAIR) } {

    # Repair design using global route parasitics
    repair_design_helper

    # Running DPL to fix overlapped instances
    # Run to get modified net by DPL
    log_cmd global_route -start_incremental
    log_cmd detailed_placement
    # Route only the modified net by DPL
    log_cmd global_route -end_incremental \
      -congestion_report_file $::env(REPORTS_DIR)/congestion_post_repair_design.rpt

    # Repair timing using global route parasitics
    puts "Repair setup and hold violations..."
    estimate_parasitics -global_routing

    repair_timing_helper

    # Running DPL to fix overlapped instances
    # Run to get modified net by DPL
    log_cmd global_route -start_incremental
    log_cmd detailed_placement
    # Route only the modified net by DPL
    log_cmd global_route -end_incremental \
      -congestion_report_file $::env(REPORTS_DIR)/congestion_post_repair_timing.rpt
  }


  # log_cmd global_route -start_incremental
  # recover_power_helper
  # # Route the modified nets by rsz journal restore
  # log_cmd global_route -end_incremental \
  #   -congestion_report_file $::env(REPORTS_DIR)/congestion_post_recover_power.rpt

  puts "Estimate parasitics..."
  estimate_parasitics -global_routing

  # report_metrics 5 "global route"

  # Write SDC to results with updated clock periods that are just failing.
  # Use make target update_sdc_clock to install the updated sdc.
  source [file join $::env(OPENROAD_SCRIPTS_DIR) "write_ref_sdc.tcl"]
  write_guides $::env(RESULTS_DIR)/route.guide
  write_db $::env(RESULTS_DIR)/5_1_grt.odb
  write_sdc -no_timestamp $::env(RESULTS_DIR)/5_1_grt.sdc
}

global_route_helper

exit