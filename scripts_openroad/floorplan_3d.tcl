# ============================================================
# floorplan_3d.tcl
# Build the 3D floorplan from the generated 3D netlist view.
# ============================================================

# Core setup
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/handoff_manager.tcl

# Environment directories
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

# Stage handoff
set stage_name "floorplan-3d"
# Inputs : ${DESIGN_NAME}_3D.fp.v / 1_synth.sdc
# Outputs: 2_3_floorplan_3d.def / 2_3_floorplan_3d.v / 1_synth.sdc
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths

# Additional setup
handoff_log_paths $stage_paths
load_design $V_IN $SDC_IN "Starting 3D floorplan"
source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/floorplan_utils.tcl
# ------------------------------------------------------------
# 0) read env knobs (align with Innovus semantics)
# ------------------------------------------------------------
# Innovus: CORE_UTIL=60 means 60%
set core_util_pct 60
if {[info exists ::env(CORE_UTILIZATION)] && $::env(CORE_UTILIZATION) ne ""} {
  set core_util_pct $::env(CORE_UTILIZATION)
}
set U_target [expr {double($core_util_pct) / 100.0}]
if {$U_target <= 0.0 || $U_target > 1.0} {
  utl::error FP 100 "CORE_UTILIZATION must be in (0,100]. got $core_util_pct"
}

set aspect_ratio 1.0
if {[info exists ::env(CORE_ASPECT_RATIO)] && $::env(CORE_ASPECT_RATIO) ne ""} {
  set aspect_ratio [expr {double($::env(CORE_ASPECT_RATIO))}]
} elseif {[info exists ::env(ASPECT_RATIO)] && $::env(ASPECT_RATIO) ne ""} {
  set aspect_ratio [expr {double($::env(ASPECT_RATIO))}]
}
if {$aspect_ratio <= 0.0} {
  utl::error FP 101 "CORE_ASPECT_RATIO (or legacy ASPECT_RATIO) must be > 0. got $aspect_ratio"
}

set mL 0.0; set mR 0.0; set mT 0.0; set mB 0.0
if {[info exists ::env(CORE_MARGIN)] && $::env(CORE_MARGIN) ne ""} {
  # Supports "0.2" or "0.2 0.2 0.2 0.2" (L B R T)
  set cm $::env(CORE_MARGIN)
  set toks [split $cm]
  if {[llength $toks] == 1} {
    set mL [expr {double([lindex $toks 0])}]
    set mB $mL; set mR $mL; set mT $mL
  } elseif {[llength $toks] == 4} {
    set mL [expr {double([lindex $toks 0])}]
    set mB [expr {double([lindex $toks 1])}]
    set mR [expr {double([lindex $toks 2])}]
    set mT [expr {double([lindex $toks 3])}]
  } else {
    utl::error FP 102 "CORE_MARGIN must be 'x' or 'L B R T'. got: $cm"
  }
}

# ------------------------------------------------------------
# 2) delete old track grids (keep your original behavior)
# ------------------------------------------------------------
set block [ord::get_db_block]
set tgs [::odb::dbBlock_getTrackGrids $block]
puts "TrackGrids = [llength $tgs]"
foreach tg $tgs { ::odb::dbTrackGrid_destroy $tg }

# ------------------------------------------------------------
# 3) compute CORE_W/CORE_H by max-tier util (Innovus-style)
# ------------------------------------------------------------
lassign [get_tier_areas_um2] A_up A_bot C_up C_bot method
set A_max [expr {($A_up > $A_bot) ? $A_up : $A_bot}]

puts "INFO: Tier areas method=$method"
puts [format "INFO: upper:  inst=%d area=%.6f um^2" $C_up  $A_up]
puts [format "INFO: bottom: inst=%d area=%.6f um^2" $C_bot $A_bot]
puts [format "INFO: max-tier area=%.6f um^2, target_util=%.3f, aspect_ratio(H/W)=%.3f" \
  $A_max $U_target $aspect_ratio]

# If tier classification is unavailable (A_max=0), fall back to initialize_floorplan -utilization
if {$A_max <= 0.0} {
  puts "WARN: A_max <= 0 (cannot classify tier instances). Fallback to utilization-based initialize_floorplan."
  set site_opt {}
  if {[info exists ::env(PLACE_SITE)] && $::env(PLACE_SITE) ne ""} {
    set site_opt [list -site $::env(PLACE_SITE)]
  }
  initialize_floorplan -utilization $core_util_pct -aspect_ratio $aspect_ratio -core_space [list $mB $mT $mL $mR] {*}$site_opt
} else {
  set core_area_um2 [expr {$A_max / $U_target}]
  set CORE_W [expr {sqrt($core_area_um2 / double($aspect_ratio))}]
  set CORE_H [expr {$CORE_W * double($aspect_ratio)}]

  puts [format "INFO: Core W/H = %.6f / %.6f (um)" $CORE_W $CORE_H]
  puts [format "INFO: Margins L/B/R/T = %.6f %.6f %.6f %.6f (um)" $mL $mB $mR $mT]

  # Innovus floorPlan -s {CORE_W CORE_H mL mB mR mT}
  # OpenROAD: use die_area/core_area (microns)
  set die_lx 0.0
  set die_ly 0.0
  set die_ux [expr {$CORE_W + $mL + $mR}]
  set die_uy [expr {$CORE_H + $mB + $mT}]

  set core_lx $mL
  set core_ly $mB
  set core_ux [expr {$mL + $CORE_W}]
  set core_uy [expr {$mB + $CORE_H}]

  puts [format "INFO: DIE_AREA  = {%.6f %.6f %.6f %.6f}" $die_lx $die_ly $die_ux $die_uy]
  puts [format "INFO: CORE_AREA = {%.6f %.6f %.6f %.6f}" $core_lx $core_ly $core_ux $core_uy]

  set site_opt {}
  if {[info exists ::env(PLACE_SITE)] && $::env(PLACE_SITE) ne ""} {
    set site_opt [list -site $::env(PLACE_SITE)]
  }

  initialize_floorplan \
    -die_area  [list $die_lx $die_ly $die_ux $die_uy] \
    -core_area [list $core_lx $core_ly $core_ux $core_uy] \
    {*}$site_opt
}

# ------------------------------------------------------------
# 4) tracks
# ------------------------------------------------------------
if {[info exists ::env(MAKE_TRACKS)] && $::env(MAKE_TRACKS) ne ""} {
  source $::env(MAKE_TRACKS)
  set tgs [::odb::dbBlock_getTrackGrids $block]
  puts "New TrackGrids = [llength $tgs]"
} else {
  make_tracks
}

set floorplan_cross_tier_report [file join $LOG_DIR "2_3_floorplan_3d.nets"]
set floorplan_cross_tier_stats [report_cross_tier_snapshot $floorplan_cross_tier_report -label "floorplan_3d"]
puts "INFO(OR): floorplan cross-tier estimate=[dict get $floorplan_cross_tier_stats cross_tier_all]"

handoff_write_stage_outputs $stage_paths \
  -copy_sdc 1 \
  -write_image 1 \
  -write_manifest 1
exit
