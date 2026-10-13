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
source $::env(OPENROAD_SCRIPTS_DIR)/tier_local_tree.tcl
set ::or_route_global_stage_paths $stage_paths
if {![info exists ::env(GLOBAL_ROUTE_ARGS)]} {
  set ::env(GLOBAL_ROUTE_ARGS) {}
}

proc pin3d_reapply_route_repair_masks {tier} {
  if {$tier eq "upper"} {
    set active_class upper_only
  } elseif {$tier eq "bottom"} {
    set active_class bottom_only
  } else {
    error "pin3d_reapply_route_repair_masks: tier must be upper or bottom"
  }
  _apply_net_class_optimization_mask $active_class 0
  _apply_inactive_tier_cell_dont_touch $tier 0
  _protect_pin3d_split_buffers 0 1
  _protect_pin3d_bridge_nets 0 1
  puts "INFO(OR): Reapplied route repair masks after incremental boundary active_tier=$tier"
}

proc pin3d_route_master_tier {master} {
  set name [$master getName]
  if {[string match -nocase "*_upper" $name]} {
    return upper
  }
  if {[string match -nocase "*_bottom" $name] ||
      [string match -nocase "*_lower" $name]} {
    return bottom
  }
  return unknown
}

# The upper and bottom placements share XY coordinates.  The existing
# legalization stages hide the inactive die with a COVER LEF view; reproduce
# that view in-process for route-stage DPL, then restore every master exactly.
proc pin3d_apply_route_cover_mask {active_tier} {
  if {$active_tier ni {upper bottom}} {
    error "pin3d_apply_route_cover_mask: tier must be upper or bottom"
  }
  if {[info exists ::pin3d_route_saved_master_types]} {
    error "pin3d_apply_route_cover_mask: previous cover mask was not released"
  }
  set ::pin3d_route_saved_master_types [dict create]
  set active_restored 0
  set inactive_covered 0
  set failures 0
  foreach lib [::odb::dbDatabase_getLibs [ord::get_db]] {
    foreach master [::odb::dbLib_getMasters $lib] {
      set tier [pin3d_route_master_tier $master]
      if {$tier ni {upper bottom}} {
        continue
      }
      set name [$master getName]
      set original_type [$master getType]
      dict set ::pin3d_route_saved_master_types $name $original_type
      if {$tier eq $active_tier} {
        set target_type $original_type
        incr active_restored
      } else {
        set target_type COVER
        incr inactive_covered
      }
      if {[catch {$master setType $target_type}]} {
        incr failures
      }
    }
  }
  puts "INFO(OR): Route COVER mask active=$active_tier active_masters=$active_restored inactive_covered=$inactive_covered failures=$failures"
  if {$failures > 0} {
    error "Failed to apply route COVER mask for $active_tier tier"
  }
}

proc pin3d_release_route_cover_mask {} {
  if {![info exists ::pin3d_route_saved_master_types]} {
    return
  }
  set restored 0
  set failures 0
  foreach lib [::odb::dbDatabase_getLibs [ord::get_db]] {
    foreach master [::odb::dbLib_getMasters $lib] {
      set name [$master getName]
      if {![dict exists $::pin3d_route_saved_master_types $name]} {
        continue
      }
      if {[catch {$master setType [dict get $::pin3d_route_saved_master_types $name]}]} {
        incr failures
      } else {
        incr restored
      }
    }
  }
  unset ::pin3d_route_saved_master_types
  puts "INFO(OR): Released route COVER mask restored=$restored failures=$failures"
  if {$failures > 0} {
    error "Failed to release route COVER mask"
  }
}

proc pin3d_detailed_placement_for_tier {tier} {
  pin3d_apply_route_cover_mask $tier
  set code [catch {log_cmd detailed_placement} result options]
  pin3d_release_route_cover_mask
  if {$code} {
    return -options $options $result
  }
  return $result
}

proc pin3d_release_route_repair_masks {} {
  _apply_net_class_optimization_mask all 0
  _release_tier_cell_dont_touch 0
  _protect_pin3d_split_buffers 0 1
  _protect_pin3d_bridge_nets 0 1
}

proc pin3d_prepare_route_local_trees {} {
  set inserted_buffers 0
  foreach tier {upper bottom} {
    apply_tier_policy $tier -fixlib 1 -allow_net "${tier}-only"
    set report_path [file join $::env(LOG_DIR) "global_route.local_tree_${tier}.rpt"]
    set stats [pin3d_build_local_trees_for_tier $tier -report $report_path]
    incr inserted_buffers [dict get $stats buffers]
    if {[dict get $stats buffers] > 0} {
      pin3d_detailed_placement_for_tier $tier
    }
  }
  pin3d_release_route_repair_masks

  if {$inserted_buffers > 0} {
    set topology_status [pin3d_validate_and_repair_split_topology "5_1_grt_local_tree" $::env(LOG_DIR) $::env(RESULTS_DIR) 0]
    if {[dict get $topology_status violated] > 0} {
      error "PIN3D split topology validation failed after route-stage local-tree construction"
    }
  }
  puts "INFO(OR): route-stage PIN3D local-tree preparation inserted_buffers=$inserted_buffers"
}

proc pin3d_incremental_route_after_repair {tier repair_kind} {
  set report_name "congestion_post_repair_${repair_kind}_${tier}.rpt"
  log_cmd global_route -start_incremental
  # The incremental GRT journal resets resizer dont_touch state.  Restore the
  # netlist masks, then use the same inactive-die COVER view as staged
  # legalization while DPL is active.
  pin3d_reapply_route_repair_masks $tier
  pin3d_detailed_placement_for_tier $tier
  log_cmd global_route -end_incremental -congestion_report_file [file join $::env(REPORTS_DIR) $report_name]
  pin3d_reapply_route_repair_masks $tier
  estimate_parasitics -global_routing
}

proc pin3d_global_route_repair_tier {tier} {
  puts "INFO(OR): global-route incremental repair active_tier=$tier"
  apply_tier_policy $tier -fixlib 1 -allow_net "${tier}-only"

  repair_design_helper
  pin3d_incremental_route_after_repair $tier design

  puts "Repair setup and hold violations on $tier tier..."
  pin3d_repair_timing_helper
  pin3d_incremental_route_after_repair $tier timing

  set topology_status [pin3d_validate_and_repair_split_topology "5_1_grt_$tier" $::env(LOG_DIR) $::env(RESULTS_DIR) 0]
  if {[dict get $topology_status violated] > 0} {
    error "PIN3D split topology validation failed after $tier global-route repair"
  }
}

proc global_route_helper {} {
  source $::env(OPENROAD_SCRIPTS_DIR)/deleteRoutingObstructions.tcl
  deleteRoutingObstructions
  source_env_var_if_exists PRE_GLOBAL_ROUTE_TCL
  pin3d_prepare_route_local_trees

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

  set skip_incremental_repair [_pin3d_boolean_env SKIP_INCREMENTAL_REPAIR 0]
  puts "INFO(OR): SKIP_INCREMENTAL_REPAIR=$skip_incremental_repair (default=0)"
  if {!$skip_incremental_repair} {
    foreach tier {upper bottom} {
      pin3d_global_route_repair_tier $tier
    }
    pin3d_release_route_repair_masks
  } else {
    puts "INFO(OR): skipping global-route incremental repair by request"
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
