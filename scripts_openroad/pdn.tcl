source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl

load_design $env(DESIGN_NAME)_3D.fp.v 1_synth.sdc "Starting PDN generation"

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
if {[info exists ::env(ASPECT_RATIO)] && $::env(ASPECT_RATIO) ne ""} {
  set aspect_ratio [expr {double($::env(ASPECT_RATIO))}]
}
if {$aspect_ratio <= 0.0} {
  utl::error FP 101 "ASPECT_RATIO must be > 0. got $aspect_ratio"
}

set mL 0.0; set mR 0.0; set mT 0.0; set mB 0.0
if {[info exists ::env(CORE_MARGIN)] && $::env(CORE_MARGIN) ne ""} {
  # 支持 "0.2" 或 "0.2 0.2 0.2 0.2" (L B R T)
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

# 如果没法识别 tier（A_max=0），就退回 initialize_floorplan -utilization 的方式
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

if {[info exists ::env(PAUSE_VISUALIZE)] && $::env(PAUSE_VISUALIZE) ne "" && $::env(PAUSE_VISUALIZE) != "0"} {
  puts "INFO: PAUSE_VISUALIZE=$::env(PAUSE_VISUALIZE) -> Pausing for visualization. Press Enter to continue..."
  return -code return
}
# ------------------------------------------------------------
# 5) IO + PDN (keep your original flow)
# ------------------------------------------------------------
source $::env(OPENROAD_SCRIPTS_DIR)/io_place.tcl

[catch { source $::env(PDN_TCL)} errorMessage]
if { [info exists ::env(UPPER_SITE)] && [info exists ::env(BOTTOM_SITE)] } {
  puts "PDN sites: UPPER_SITE=$::env(UPPER_SITE), BOTTOM_SITE=$::env(BOTTOM_SITE)"
} else {
  if {[catch { pdngen } errorMessage]} {
    puts "ErrorPDN: $errorMessage"
  }
}

if { [info exists ::env(POST_PDN_TCL)] && [file exists $::env(POST_PDN_TCL)] } {
  source $::env(POST_PDN_TCL)
}

# supply nets check (keep)
set block [ord::get_db_block]
foreach net [$block getNets] {
  set type [$net getSigType]
  if {$type == "POWER" || $type == "GROUND"} {
    # check_power_grid -net [$net getName]
  }
}

write_def     $env(RESULTS_DIR)/2_6_floorplan_pdn.def
write_verilog $env(RESULTS_DIR)/2_6_floorplan_pdn.v
exit
