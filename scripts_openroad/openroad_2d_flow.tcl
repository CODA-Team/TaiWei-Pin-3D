source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl

proc save_2d_stage {stage_name} {
  set result_base [file join $::env(RESULTS_DIR) $stage_name]
  set image_path [file join $::env(LOG_DIR) "${stage_name}.webp"]

  puts "INFO(OR): Saving 2D stage '$stage_name'"
  write_db "${result_base}.odb"
  write_def "${result_base}.def"
  write_verilog "${result_base}.v"
  write_sdc -no_timestamp "${result_base}.sdc"

  set display_ok [expr {[info exists ::env(DISPLAY)] && $::env(DISPLAY) ne ""}]
  set qt_offscreen [expr {
    [info exists ::env(QT_QPA_PLATFORM)] &&
    $::env(QT_QPA_PLATFORM) eq "offscreen"
  }]
  if {$display_ok || $qt_offscreen} {
    if {[catch {save_image -resolution 0.1 $image_path} image_error]} {
      puts "WARN(OR): failed to write 2D stage image $image_path : $image_error"
    }
  } else {
    puts "INFO(OR): skip 2D stage image $image_path in headless mode"
  }
}

proc legalize_inserted_cells {stage_name} {
  puts "INFO(OR): Legalizing cells inserted during $stage_name"
  set dpl_args {}
  if {[info exists ::env(PLATFORM)] && $::env(PLATFORM) eq "asap7"} {
    set dpl_args [list -max_displacement {100 100}]
  }

  set failed [catch {log_cmd detailed_placement {*}$dpl_args} message options]
  if {$failed} {
    if {![string match "*DPL-0036*" $message]} {
      return -options $options $message
    }
    puts "WARN(OR): Initial detailed placement failed during $stage_name: $message"
    puts "INFO(OR): Running improve_placement before strict legalization retry"
    improve_placement
    optimize_mirroring
    log_cmd detailed_placement {*}$dpl_args
  }
  check_placement -verbose
}

set DEF_IN 2_2_floorplan_io.def

load_design $DEF_IN 1_synth.sdc "start 2D flow from start"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl

source $::env(OPENROAD_SCRIPTS_DIR)/io_place.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/place_macro_util.tcl
save_2d_stage 2_5_floorplan_macro

source $::env(PDN_TCL)
if {[catch {
    pdngen
} errorMessage]} {
    puts "ErrorPDN: $errorMessage"
}

if { [info exists ::env(POST_PDN_TCL)] && [file exists $::env(POST_PDN_TCL)] } {
  source $::env(POST_PDN_TCL)
}
save_2d_stage 2_floorplan

set place_density [calculate_placement_density]
fastroute_setup

set global_placement_args "-routability_driven -timing_driven -keep_resize_below_overflow 1"
puts "Running global placement with density: $place_density"
global_placement -density $place_density \
    -skip_initial_place \
    -pad_left $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
    -pad_right $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) \
    {*}$global_placement_args

estimate_parasitics -placement
source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 3 "global place" false false
save_2d_stage 3_3_place_gpl

source $::env(OPENROAD_SCRIPTS_DIR)/opt_lg_design.tcl
report_metrics 3 "detailed place_upper" true false
save_2d_stage 3_place

repair_clock_inverters

set cts_args [list \
  -sink_clustering_enable \
  -repair_clock_nets \
  -root_buf $::env(CTS_BUF_CELL) \
  -buf_list $::env(CTS_BUF_CELL)
  ]

append_env_var cts_args CTS_BUF_DISTANCE -distance_between_buffers 1
append_env_var cts_args CTS_CLUSTER_SIZE -sink_clustering_size 1
append_env_var cts_args CTS_CLUSTER_DIAMETER -sink_clustering_max_diameter 1
append_env_var cts_args CTS_BUF_LIST -buf_list 1
append_env_var cts_args CTS_LIB_NAME -library 1


if { [env_var_exists_and_non_empty CTS_ARGS] } {
  set cts_args $::env(CTS_ARGS)
}

log_cmd clock_tree_synthesis {*}$cts_args

utl::push_metrics_stage "cts__{}__pre_repair_timing"
estimate_parasitics -placement
utl::pop_metrics_stage
save_2d_stage 4_0_cts

set_placement_padding -global \
  -left $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT) \
  -right $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT)

# CTS leaves a long wire from the pad to the clock tree root.
log_cmd repair_clock_nets

# place clock buffers
legalize_inserted_cells post_cts

estimate_parasitics -placement

if { ![info exists ::env(SKIP_CTS_REPAIR_TIMING)] } {
  set ::env(SKIP_CTS_REPAIR_TIMING) 0
}
if { $::env(SKIP_CTS_REPAIR_TIMING) } {
  repair_timing_helper
  set result [catch { detailed_placement } msg]
  if { $result != 0 } {
    save_progress 4_1_error
    puts "Detailed placement failed in CTS: $msg"
    exit $result
  }
  check_placement -verbose
}

source_env_var_if_exists POST_CTS_TCL
save_2d_stage 4_cts

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

  set skip_incremental_repair [_pin3d_boolean_env SKIP_INCREMENTAL_REPAIR 0]
  if {!$skip_incremental_repair} {

    # Repair design using global route parasitics
    repair_design_helper

    # Running DPL to fix overlapped instances
    # Run to get modified net by DPL
    log_cmd global_route -start_incremental
    legalize_inserted_cells post_repair_design
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
    legalize_inserted_cells post_repair_timing
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
  save_2d_stage 5_1_grt
}

global_route_helper

set_propagated_clock [all_clocks]

set additional_args ""
if { ![info exists ::env(OR_K)] } {
  set ::env(OR_K) 1.0
}
# if { ![info exists ::env(REPAIR_PDN_VIA_LAYER)] } {
#   set ::env(REPAIR_PDN_VIA_LAYER) 1
# }
if { ![info exists ::env(DETAILED_ROUTE_END_ITERATION)] } {
  set ::env(DETAILED_ROUTE_END_ITERATION) 20
}
append_env_var additional_args DB_PROCESS_NODE -db_process_node 1
append_env_var additional_args OR_K -or_k 1
# append_env_var additional_args REPAIR_PDN_VIA_LAYER -repair_pdn_vias 1
append_env_var additional_args DETAILED_ROUTE_END_ITERATION -droute_end_iter 1
append additional_args " -verbose 1 -no_pin_access"

# return -code return

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
  if { [repair_antennas] } {
    detailed_route {*}$all_args
  }
  while { [check_antennas] && $repair_antennas_iters < $::env(MAX_REPAIR_ANTENNAS_ITER_DRT) } {
    repair_antennas
    detailed_route {*}$all_args
    incr repair_antennas_iters
  }
} else {
  utl::metric_int "antenna_diodes_count" -1
}

source_env_var_if_exists POST_DETAIL_ROUTE_TCL

check_antennas -report_file $env(REPORTS_DIR)/drt_antennas.log

if { ![design_is_routed] } {
  error "Design has unrouted nets."
}

# report_metrics 5 "detailed route"
save_2d_stage 5_route
file copy -force \
  $::env(RESULTS_DIR)/5_route.odb \
  $::env(RESULTS_DIR)/5_2_route.odb

exit
