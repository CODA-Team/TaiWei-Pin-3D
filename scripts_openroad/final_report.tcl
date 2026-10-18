# ============================================================
# final_report.tcl
# Generate final OpenROAD reports and publish 6_final.* outputs.
# ============================================================

# Core setup
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/handoff_manager.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/final_util.tcl
# Environment directories
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

# Stage handoff
set stage_name "final"
# Inputs : 5_route.def / 5_route.v / 5_route.sdc
# Outputs: 6_final.odb / 6_final.def / 6_final.v / 6_final.sdc / final_summary.txt
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

# Additional setup
handoff_log_paths $stage_paths
utl::set_metrics_stage "finish__{}"
load_design $DEF_IN $SDC_IN "Starting final report"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl

set_propagated_clock [all_clocks]
puts "Starting global connection cleanup"
global_connect

set split_topology_status [pin3d_validate_and_repair_split_topology \
  6_final $LOG_DIR $RESULTS_DIR 0]
if {[dict get $split_topology_status violated] > 0} {
  error "Final dual-boundary validation found [dict get $split_topology_status violated] invalid topology record(s); see 6_final.split_topology.summary.rpt"
}

source $::env(OPENROAD_SCRIPTS_DIR)/deleteRoutingObstructions.tcl
deleteRoutingObstructions

set final_cross_tier_report [file join $LOG_DIR "cross_tier_nets.list"]
set final_cross_tier_summary [file join $LOG_DIR "cross_tier_nets.summary.rpt"]
set saved_metric_report_mode_exists [info exists ::env(PIN3D_METRIC_REPORT_MODE)]
if {$saved_metric_report_mode_exists} {
  set saved_metric_report_mode $::env(PIN3D_METRIC_REPORT_MODE)
}
set saved_skip_heavy_exists [info exists ::env(PIN3D_SKIP_HEAVY_METRIC_REPORTS)]
if {$saved_skip_heavy_exists} {
  set saved_skip_heavy $::env(PIN3D_SKIP_HEAVY_METRIC_REPORTS)
}
if {[_pin3d_metric_report_mode] eq "off"} {
  unset -nocomplain ::env(PIN3D_SKIP_HEAVY_METRIC_REPORTS)
  set ::env(PIN3D_METRIC_REPORT_MODE) "summary"
}
set final_cross_tier_stats [report_cross_tier_snapshot $final_cross_tier_report -label "final"]
if {$saved_skip_heavy_exists} {
  set ::env(PIN3D_SKIP_HEAVY_METRIC_REPORTS) $saved_skip_heavy
} else {
  unset -nocomplain ::env(PIN3D_SKIP_HEAVY_METRIC_REPORTS)
}
if {$saved_metric_report_mode_exists} {
  set ::env(PIN3D_METRIC_REPORT_MODE) $saved_metric_report_mode
} else {
  unset -nocomplain ::env(PIN3D_METRIC_REPORT_MODE)
}
set fh [open $final_cross_tier_summary w]
puts $fh [_cross_tier_stats_brief $final_cross_tier_stats]
puts $fh [format "cross_tier_all %d" [dict get $final_cross_tier_stats cross_tier_all]]
puts $fh [format "upper_bottom %d" [dict get $final_cross_tier_stats upper_bottom]]
puts $fh [format "upper_io %d" [dict get $final_cross_tier_stats upper_io]]
puts $fh [format "bottom_io %d" [dict get $final_cross_tier_stats bottom_io]]
puts $fh [format "upper_bottom_io %d" [dict get $final_cross_tier_stats upper_bottom_io]]
puts $fh [format "unknown %d" [dict get $final_cross_tier_stats unknown]]
close $fh

if {[info exists ::env(RCX_RULES)]} {
  if {[_get PIN3D_REQUIRE_RCX_LAYER_MATCH 0]} {
    if {![file isfile $::env(RCX_RULES)]} {
      error "RCX rules file is missing: $::env(RCX_RULES)"
    }
    set model_fh [open $::env(RCX_RULES) r]
    set model_header [read $model_fh 4096]
    close $model_fh
    if {![regexp {LayerCount\s+(\d+)} $model_header -> model_layers]} {
      error "Cannot determine LayerCount from $::env(RCX_RULES)"
    }
    set routing_layers 0
    foreach layer [[ord::get_db_tech] getLayers] {
      if {[$layer getRoutingLevel] > 0} { incr routing_layers }
    }
    if {$model_layers != $routing_layers} {
      error "RCX layer mismatch: rules=$model_layers technology=$routing_layers; refusing extraction."
    }
    puts "INFO(RC): verified RCX rules=$::env(RCX_RULES) routing_layers=$routing_layers"
  }
}

puts "Writing final design files"
handoff_write_stage_outputs $stage_paths \
  -write_db 1 \
  -write_def 1 \
  -write_verilog 1 \
  -write_sdc 1 \
  -write_manifest 1

puts "Starting extraction"
if {[info exists ::env(RCX_RULES)]} {
  if {[info exists ::env(RCX_RC_CORNER)]} {
    set rc_corner $::env(RCX_RC_CORNER)
  }
  define_process_corner -ext_model_index 0 X
  extract_parasitics -ext_model_file $::env(RCX_RULES)
  write_spef $::env(RESULTS_DIR)/6_final.spef
  file delete $::env(DESIGN_NAME).totCap
  read_spef $::env(RESULTS_DIR)/6_final.spef
  set rc_meta [open [file join $LOG_DIR openrcx_config.txt] w]
  puts $rc_meta "rcx_rules=$::env(RCX_RULES)"
  puts $rc_meta "technology_lef=[_get TECH_LEF]"
  puts $rc_meta "spef=$::env(RESULTS_DIR)/6_final.spef"
  puts $rc_meta "model_scope=research; physical 3D calibration is not certified"
  close $rc_meta
} else {
  puts "OpenRCX is not enabled for this platform."
}

_configure_openroad_power_activity_for_eval

source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 6 "finish" true false
set finish_report [file join $REPORTS_DIR "6_finish.rpt"]
set wire_report [file join $REPORTS_DIR "6_wire_length.rpt"]
set drc_report [file join $REPORTS_DIR "5_route_drc.rpt"]
report_wire_length -detailed_route -summary
report_wire_length -net {*} -detailed_route -file $wire_report
_write_openroad_final_summary $SUMMARY_OUT $finish_report $wire_report $final_cross_tier_stats $drc_report
puts "Final summary written to $SUMMARY_OUT"

set display_ok [expr {[info exists ::env(DISPLAY)] && $::env(DISPLAY) ne ""}]
if {$display_ok} {
  if {[catch {source $::env(OPENROAD_SCRIPTS_DIR)/save_images.tcl} err]} {
    puts "WARN(OR): failed to write image : $err"
  }
} else {
  puts "INFO(OR): skip image output in headless mode"
}

set VISUALIZE_FINAL [_get VISUALIZE_FINAL "0"]
if {$VISUALIZE_FINAL eq "1"} {
  puts "gui::pause"
  gui::show
  gui::pause
}

exit
