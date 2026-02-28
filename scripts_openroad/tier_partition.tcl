# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2019-2025, The OpenROAD Authors
#
# ------------------------------------------------------------
# SIMPLE TritonPart sweep (single-process, N points)
#
# Two mutually-exclusive modes (both run N=PAR_BAL_ITERATION times):
#
# Mode A) PAR_SCALE_FACTOR is set (e.g. "0.05 0.95"):
#   - Treat PAR_SCALE_FACTOR as the CENTER of base_balance (NOT passed as -scale_factor)
#   - Scan base_balance around the center:
#       delta in [0.01 .. 0.06], N points (includes endpoints)
#       base_balance = {b0_center + delta, b1_center - delta}
#   - UB (balance_constraint) is FIXED to 1.0
#
# Mode B) PAR_SCALE_FACTOR is not set:
#   - Scan UB (balance_constraint) uniformly on [PAR_BAL_LO .. PAR_BAL_HI], N points
#   - base_balance is FIXED to {0.5 0.5}
#
# Inputs (env) [ONLY these partition knobs are read]:
#   - PAR_BAL_LO, PAR_BAL_HI
#   - PAR_BAL_ITERATION (N)
#   - PAR_SCALE_FACTOR  (two floats that sum to 1.0; enables Mode A)
#
# Outputs:
#   - $RESULTS_DIR/partition.txt
#   - $RESULTS_DIR/partition.result.tcl
#   - $RESULTS_DIR/partition.simple_plan.txt
#   - $RESULTS_DIR/partition_sweep/part.*.seed*.txt (+ optional cut_nets dumps)
# ------------------------------------------------------------
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl

proc _ts {} { return [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"] }

proc _get {name def} {
  if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
  return $def
}

proc write_kv_file {outfile kv_dict} {
  set fh [open $outfile w]
  puts $fh $kv_dict
  close $fh
}

proc _sum_floats {lst} {
  set s 0.0
  foreach x $lst { set s [expr {$s + double($x)}] }
  return $s
}

proc _validate_float_list_sum1 {name lst expected_len} {
  if {[llength $lst] != $expected_len} {
    utl::error PAR 970 [format "%s must have %d floats (got %d): %s" \
      $name $expected_len [llength $lst] $lst]
  }
  foreach x $lst {
    if {![string is double -strict $x]} {
      utl::error PAR 971 [format "%s contains non-float: %s (list=%s)" $name $x $lst]
    }
    if {[expr {double($x) <= 0.0}]} {
      utl::error PAR 972 [format "%s must be > 0 (got %s)" $name $x]
    }
  }
  set s [_sum_floats $lst]
  if {[expr {abs($s - 1.0) > 1e-6}]} {
    utl::error PAR 973 [format "%s must sum to 1.0 (got %.9f, list=%s)" $name $s $lst]
  }
}

proc _clamp01 {x} {
  if {$x < 0.0} { return 0.0 }
  if {$x > 1.0} { return 1.0 }
  return $x
}

# ------------------------------------------------------------
# Knobs (override via env)
# ------------------------------------------------------------
set ::PAR_BAL_LO_DEFAULT   1.0
set ::PAR_BAL_HI_DEFAULT   6.0
set ::PAR_BAL_ITER_DEFAULT 11

set ::PAR_BAL_ITER [expr {int([_get PAR_BAL_ITERATION $::PAR_BAL_ITER_DEFAULT])}]
if {$::PAR_BAL_ITER < 2} {
  utl::error PAR 965 "PAR_BAL_ITERATION must be >= 2."
}

set ::PAR_BAL_LO [expr {double([_get PAR_BAL_LO $::PAR_BAL_LO_DEFAULT])}]
set ::PAR_BAL_HI [expr {double([_get PAR_BAL_HI $::PAR_BAL_HI_DEFAULT])}]
if {$::PAR_BAL_HI < $::PAR_BAL_LO} { set tmp $::PAR_BAL_LO; set ::PAR_BAL_LO $::PAR_BAL_HI; set ::PAR_BAL_HI $tmp }

# Deterministic seed (NOT configurable via env; per your “only 4 vars” requirement)
set ::PAR_FIXED_SEED 1

# hb_layer density-based cut budget knobs (HBT pitch fix: width=0.5, spacing=0.5 => pitch=1.0um)
set ::HB_CUT_LAYER         "hb_layer"
set ::HB_LAYER_WIDTH_UM    0.5
set ::HB_LAYER_SPACING_UM  0.5
set ::HB_LAYER_RES_OHM     0.02
set ::HB_VIA_DENSITY       0.5
set ::CUTS_PER_NET         1
set ::CUT_TOL              0

set ::IGNORE_NET_NAMES {VDD VSS VPWR VGND TOP_VDD TOP_VSS BOT_VDD BOT_VSS}
set ::DUMP_CUT_NETS      false
set ::CUT_NETS_DUMP_FILE "cut_nets.list"

# ------------------------------------------------------------
# Load design + floorplan
# ------------------------------------------------------------
load_design 2_2_floorplan_io.v 1_synth.sdc "Start Triton Partitioning (N-point sweep)"

set fp_def [file join $::env(RESULTS_DIR) 2_2_floorplan_io.def]
if {![file exists $fp_def]} {
  utl::error PAR 961 "Floorplan DEF not found: $fp_def"
}
read_def -floorplan_initialize $fp_def

# ------------------------------------------------------------
# ODB helpers: die area, dbu
# ------------------------------------------------------------
proc _get_dbu {} {
  set db [ord::get_db]
  if {$db eq "NULL"} { utl::error PAR 910 "No db." }
  set tech [odb::dbDatabase_getTech $db]
  if {$tech eq "NULL"} { utl::error PAR 911 "No tech." }
  return [odb::dbTech_getDbUnitsPerMicron $tech]
}

proc _poly_bbox_area_dbu2 {coords} {
  set n [llength $coords]
  if {$n < 6 || ($n % 2) != 0} {
    utl::error PAR 912 "Invalid polygon die coords (need even count >= 6): $coords"
  }
  set minx 1e99; set miny 1e99
  set maxx -1e99; set maxy -1e99
  set area2 0.0

  set x0 [expr {double([lindex $coords 0])}]
  set y0 [expr {double([lindex $coords 1])}]
  set x_prev $x0
  set y_prev $y0

  set minx $x0; set maxx $x0
  set miny $y0; set maxy $y0

  for {set i 2} {$i < $n} {incr i 2} {
    set x [expr {double([lindex $coords $i])}]
    set y [expr {double([lindex $coords [expr {$i+1}]])}]
    if {$x < $minx} { set minx $x }
    if {$x > $maxx} { set maxx $x }
    if {$y < $miny} { set miny $y }
    if {$y > $maxy} { set maxy $y }
    set area2 [expr {$area2 + ($x_prev*$y - $x*$y_prev)}]
    set x_prev $x
    set y_prev $y
  }
  set area2 [expr {$area2 + ($x_prev*$y0 - $x0*$y_prev)}]
  set area2 [expr {abs($area2)}]
  return [list [expr {int($minx)}] [expr {int($miny)}] [expr {int($maxx)}] [expr {int($maxy)}] $area2]
}

proc _get_die_rect_coords_dbu {die_obj} {
  if {[llength $die_obj] >= 4} {
    if {[llength $die_obj] == 4} {
      set lx [lindex $die_obj 0]; set ly [lindex $die_obj 1]
      set ux [lindex $die_obj 2]; set uy [lindex $die_obj 3]
      if {[string is integer -strict $lx] && [string is integer -strict $ly] &&
          [string is integer -strict $ux] && [string is integer -strict $uy]} {
        set w [expr {$ux - $lx}]
        set h [expr {$uy - $ly}]
        set area2 [expr {2.0 * double($w) * double($h)}]
        return [list $lx $ly $ux $uy $area2]
      }
    }
    set n [llength $die_obj]
    if {$n >= 6 && ($n % 2) == 0} {
      return [_poly_bbox_area_dbu2 $die_obj]
    }
  }

  if {![catch {odb::Rect_xMin $die_obj} lx] &&
      ![catch {odb::Rect_yMin $die_obj} ly] &&
      ![catch {odb::Rect_xMax $die_obj} ux] &&
      ![catch {odb::Rect_yMax $die_obj} uy]} {
    set w [expr {$ux - $lx}]
    set h [expr {$uy - $ly}]
    set area2 [expr {2.0 * double($w) * double($h)}]
    return [list $lx $ly $ux $uy $area2]
  }

  if {![catch {odb::dbBox_xMin $die_obj} lx] &&
      ![catch {odb::dbBox_yMin $die_obj} ly] &&
      ![catch {odb::dbBox_xMax $die_obj} ux] &&
      ![catch {odb::dbBox_yMax $die_obj} uy]} {
    set w [expr {$ux - $lx}]
    set h [expr {$uy - $ly}]
    set area2 [expr {2.0 * double($w) * double($h)}]
    return [list $lx $ly $ux $uy $area2]
  }

  utl::error PAR 912 "Unsupported die area object type from dbBlock_getDieArea."
}

proc get_die_wh_area_um2 {} {
  set block [ord::get_db_block]
  if {$block eq "NULL"} { utl::error PAR 900 "No db block." }
  set dbu [_get_dbu]
  set die_obj [odb::dbBlock_getDieArea $block]
  lassign [_get_die_rect_coords_dbu $die_obj] lx ly ux uy area2_dbu2
  set w_um [expr {double($ux - $lx) / double($dbu)}]
  set h_um [expr {double($uy - $ly) / double($dbu)}]
  set a_um2 [expr {(double($area2_dbu2) * 0.5) / double($dbu*$dbu)}]
  return [list $w_um $h_um $a_um2]
}

proc estimate_max_hb_cuts_from_pitch {die_area_um2 pitch_x pitch_y density} {
  if {$pitch_x <= 0.0 || $pitch_y <= 0.0} { utl::error PAR 902 "Invalid pitch (<=0)." }
  if {$density < 0.0 || $density > 1.0} { utl::error PAR 904 "HB_VIA_DENSITY must be within [0, 1]." }
  set pitch_a [expr {double($pitch_x) * double($pitch_y)}]
  set grid_area [expr {int(floor(double($die_area_um2) / $pitch_a))}]
  if {$grid_area < 0} { set grid_area 0 }
  set nmax [expr {int(floor(double($density) * double($grid_area)))}]
  return [list $grid_area $nmax]
}

# ------------------------------------------------------------
# CUT(nets) from solution
# ------------------------------------------------------------
proc read_solution_part_map_kv {solution_file} {
  if {![file exists $solution_file]} { utl::error PAR 930 "Solution file not found: $solution_file" }
  set fh [open $solution_file r]
  set kv {}
  while {[gets $fh line] >= 0} {
    set s [string trim $line]
    if {$s eq ""} { continue }
    if {[string match "#*" $s]}  { continue }
    if {[string match "//*" $s]} { continue }
    set toks [split $s]
    if {[llength $toks] < 2} { continue }
    set name [lindex $toks 0]
    set pid  [lindex $toks end]
    if {![string is integer -strict $pid]} { continue }
    if {$pid != 0 && $pid != 1} { continue }
    lappend kv $name $pid
  }
  close $fh
  return $kv
}

proc calc_cut_nets_from_solution {solution_file ignore_net_names dump_file} {
  set block [ord::get_db_block]
  if {$block eq "NULL"} { utl::error PAR 940 "No db block." }

  array set part {}
  array set part [read_solution_part_map_kv $solution_file]

  set cut_nets 0
  set cut_names {}

  foreach net [odb::dbBlock_getNets $block] {
    set nname [odb::dbNet_getName $net]
    if {[llength $ignore_net_names] > 0 && [lsearch -exact $ignore_net_names $nname] >= 0} {
      continue
    }

    set seen0 0
    set seen1 0
    foreach iterm [odb::dbNet_getITerms $net] {
      set inst  [odb::dbITerm_getInst $iterm]
      set iname [odb::dbInst_getName $inst]
      if {![info exists part($iname)]} { continue }
      set pid $part($iname)
      if {$pid == 0} { set seen0 1 }
      if {$pid == 1} { set seen1 1 }
      if {$seen0 && $seen1} { break }
    }

    if {$seen0 && $seen1} {
      incr cut_nets
      if {$dump_file ne ""} { lappend cut_names $nname }
    }
  }

  if {$dump_file ne ""} {
    set fh [open $dump_file w]
    foreach n $cut_names { puts $fh $n }
    close $fh
  }
  return $cut_nets
}

# ------------------------------------------------------------
# TritonPart runner (timing-aware)
# ------------------------------------------------------------
proc run_triton_part {solution_file ub seed base_balance} {
  puts [format {INFO %s: triton_part_design ub=%.6f seed=%d timing_aware=true base_balance=%s -> %s} \
    [_ts] $ub $seed $base_balance $solution_file]
  flush stdout

  triton_part_design \
    -num_parts 2 \
    -balance_constraint $ub \
    -base_balance $base_balance \
    -seed $seed \
    -solution_file $solution_file \
    -timing_aware_flag true
}

# ------------------------------------------------------------
# Target cut budget from hb_layer density
# ------------------------------------------------------------
puts [format {INFO %s: HB layer=%s width=%.3fum spacing=%.3fum (pitch=%.3fum) density=%.3f cuts_per_net=%d tol=%d} \
  [_ts] $::HB_CUT_LAYER $::HB_LAYER_WIDTH_UM $::HB_LAYER_SPACING_UM \
  [expr {$::HB_LAYER_WIDTH_UM + $::HB_LAYER_SPACING_UM}] \
  $::HB_VIA_DENSITY $::CUTS_PER_NET $::CUT_TOL]
flush stdout

set pitch_x [expr {$::HB_LAYER_WIDTH_UM + $::HB_LAYER_SPACING_UM}]
set pitch_y [expr {$::HB_LAYER_WIDTH_UM + $::HB_LAYER_SPACING_UM}]
lassign [get_die_wh_area_um2] die_w die_h die_area
puts [format {INFO %s: DIE w=%.3fum h=%.3fum area=%.3fum^2} [_ts] $die_w $die_h $die_area]
flush stdout
lassign [estimate_max_hb_cuts_from_pitch $die_area $pitch_x $pitch_y $::HB_VIA_DENSITY] grid nmax
set target_cut [expr {int(floor(double($nmax) / double($::CUTS_PER_NET)))}]
puts [format {STAT %s: grid=%d max_hb_cuts=%d => CUT_NET_BUDGET(target)=%d} \
  [_ts] $grid $nmax $target_cut]
flush stdout

# ------------------------------------------------------------
# Decide mode + build N points
# ------------------------------------------------------------
set mode "UB_SWEEP"
set center_bb {}
if {[info exists ::env(PAR_SCALE_FACTOR)] && $::env(PAR_SCALE_FACTOR) ne ""} {
  set center_bb $::env(PAR_SCALE_FACTOR)
  _validate_float_list_sum1 "PAR_SCALE_FACTOR(as base_balance center)" $center_bb 2
  set mode "BB_SWEEP"
}

set plan_file [file join $::env(RESULTS_DIR) partition.simple_plan.txt]
set plan "PARTITION SWEEP @ [_ts]\n"
append plan "floorplan_def=$fp_def\n"
append plan [format "mode=%s N=%d seed=%d timing_aware=true\n" $mode $::PAR_BAL_ITER $::PAR_FIXED_SEED]
append plan [format "target_cut=%d tol=%d\n" $target_cut $::CUT_TOL]

# Points list as dicts: {ub <float> base_balance {a b} tag <string>}
set points {}

if {$mode eq "BB_SWEEP"} {
  # base_balance scan only; UB fixed to 1.0
  set ub_fixed 1.0

  set b0c [expr {double([lindex $center_bb 0])}]
  set b1c [expr {double([lindex $center_bb 1])}]

  set d_lo 0.01
  set d_hi 0.06
  if {$::PAR_BAL_ITER == 1} {
    utl::error PAR 966 "PAR_BAL_ITERATION must be >= 2 for BB sweep."
  }
  set d_step [expr {($d_hi - $d_lo) / double($::PAR_BAL_ITER - 1)}]

  set bb_points {}
  for {set i 0} {$i < $::PAR_BAL_ITER} {incr i} {
    set d [expr {$d_lo + double($i)*$d_step}]
    if {$i == ($::PAR_BAL_ITER - 1)} { set d $d_hi } ;# exact endpoint

    set b0 [expr {$b0c + $d}]
    set b1 [expr {$b1c - $d}]
    set b0 [_clamp01 $b0]
    set b1 [_clamp01 $b1]
    set s  [expr {$b0 + $b1}]
    if {$s <= 0.0} { utl::error PAR 981 [format "Invalid base_balance at delta %.6f: {%g %g}" $d $b0 $b1] }
    set b0 [expr {$b0 / $s}]
    set b1 [expr {$b1 / $s}]

    set b0s [format "%.6f" $b0]
    set b1s [format "%.6f" $b1]
    set ds  [format "%.6f" $d]
    set base_balance [list $b0s $b1s]

    # tag for filenames
    set bb_tag [string map {. p} $b0s]  ;# 0.060000 -> 0p060000
    lappend points [dict create ub $ub_fixed base_balance $base_balance tag "bb${bb_tag}" delta $ds]
    lappend bb_points [format "{%s %s}(d=%s)" $b0s $b1s $ds]
  }

  append plan [format "PAR_SCALE_FACTOR(center)=%s\n" $center_bb]
  append plan "UB fixed = 1.000000\n"
  append plan [format "delta_scan=\[0.01..0.06\] points=%s\n" [join $bb_points ", "]]

} else {
  # UB scan only; base_balance fixed to 0.5/0.5
  set base_balance [list "0.500000" "0.500000"]

  set span [expr {$::PAR_BAL_HI - $::PAR_BAL_LO}]
  if {$span <= 0.0} {
    utl::error PAR 963 [format "Invalid UB sweep range: lo=%.6f hi=%.6f" $::PAR_BAL_LO $::PAR_BAL_HI]
  }
  set step [expr {$span / double($::PAR_BAL_ITER - 1)}]
  if {$step <= 0.0} { utl::error PAR 964 [format "Invalid UB step: %.6f" $step] }

  set ub_points {}
  for {set i 0} {$i < $::PAR_BAL_ITER} {incr i} {
    set ub [expr {$::PAR_BAL_LO + double($i)*$step}]
    if {$i == ($::PAR_BAL_ITER - 1)} { set ub $::PAR_BAL_HI } ;# exact endpoint
    set ubs [format "%.6f" $ub]
    lappend points [dict create ub $ub base_balance $base_balance tag "ub${ubs}" delta ""]
    lappend ub_points $ubs
  }

  append plan [format "UB scan lo=%.6f hi=%.6f points=%s\n" $::PAR_BAL_LO $::PAR_BAL_HI [join $ub_points ","]]
  append plan "base_balance fixed = {0.5 0.5}\n"
}

set fh [open $plan_file w]; puts $fh $plan; close $fh

puts [format {INFO %s: mode=%s N=%d plan=%s} [_ts] $mode $::PAR_BAL_ITER $plan_file]
flush stdout

# ------------------------------------------------------------
# Evaluate points, pick best
# Selection policy:
#   - Prefer feasible (cut <= target_cut + tol)
#   - Among feasible: minimize cut, tie-break smaller ub
#   - If none feasible: minimize abs_diff, tie-break smaller cut, then smaller ub
# ------------------------------------------------------------
set out_dir [file join $::env(RESULTS_DIR) partition_sweep]
file mkdir $out_dir

set best ""
set best_feasible 0

foreach p $points {
  set ub [dict get $p ub]
  set base_balance [dict get $p base_balance]
  set tag [dict get $p tag]

  # filename: part.<tag>.seed<seed>.txt
  # tag is either "ub<...>" or "bb<...>"
  set sol [file join $out_dir [format {part.%s.seed%d.txt} $tag $::PAR_FIXED_SEED]]

  run_triton_part $sol $ub $::PAR_FIXED_SEED $base_balance

  set dump_file ""
  if {$::DUMP_CUT_NETS} {
    set dump_file [file join $out_dir [format {cut_nets.%s.seed%d.list} $tag $::PAR_FIXED_SEED]]
  }

  set cut [calc_cut_nets_from_solution $sol $::IGNORE_NET_NAMES $dump_file]
  set feasible [expr {$cut <= ($target_cut + $::CUT_TOL)}]
  set abs_diff [expr {abs($cut - $target_cut)}]

  puts [format {INFO %s: STAT tag=%s ub=%.6f base_balance=%s cut=%d target=%d tol=%d feasible=%s abs_diff=%d} \
    [_ts] $tag $ub $base_balance $cut $target_cut $::CUT_TOL $feasible $abs_diff]
  flush stdout

  set cur [dict create tag $tag ub $ub base_balance $base_balance cut $cut feasible $feasible abs_diff $abs_diff solution_file $sol mode $mode]

  if {$best eq ""} {
    set best $cur
    set best_feasible $feasible
    continue
  }

  set b_feas [dict get $best feasible]
  if {$b_feas} {
    if {$feasible} {
      set bc  [dict get $best cut]
      set bub [dict get $best ub]
      if {$cut < $bc || ($cut == $bc && $ub < $bub)} {
        set best $cur
      }
    }
  } else {
    if {$feasible} {
      set best $cur
      set best_feasible 1
    } else {
      set bdif [dict get $best abs_diff]
      set bc   [dict get $best cut]
      set bub  [dict get $best ub]
      if {$abs_diff < $bdif ||
          ($abs_diff == $bdif && $cut < $bc) ||
          ($abs_diff == $bdif && $cut == $bc && $ub < $bub)} {
        set best $cur
      }
    }
  }
}

if {$best eq ""} { utl::error PAR 962 "No valid sweep result." }

# ------------------------------------------------------------
# Finalize
# ------------------------------------------------------------
set final_sol [file join $::env(RESULTS_DIR) partition.txt]
file copy -force [dict get $best solution_file] $final_sol

set final_sum [file join $::env(RESULTS_DIR) partition.result.tcl]
set sum_dict [dict create \
  mode [dict get $best mode] \
  seed $::PAR_FIXED_SEED \
  timing_aware true \
  N $::PAR_BAL_ITER \
  PAR_BAL_LO $::PAR_BAL_LO \
  PAR_BAL_HI $::PAR_BAL_HI \
  PAR_SCALE_FACTOR $center_bb \
  target $target_cut \
  tol $::CUT_TOL \
  best_tag [dict get $best tag] \
  best_ub [dict get $best ub] \
  best_base_balance [dict get $best base_balance] \
  best_cut [dict get $best cut] \
  best_feasible [dict get $best feasible] \
  best_abs_diff [dict get $best abs_diff] \
  solution_file [dict get $best solution_file] \
  sweep_dir $out_dir \
  plan_file $plan_file]
write_kv_file $final_sum $sum_dict

puts [format {INFO %s: FINAL mode=%s best_tag=%s ub=%.6f base_balance=%s cut=%d feasible=%s -> %s} \
  [_ts] [dict get $best mode] [dict get $best tag] [dict get $best ub] [dict get $best base_balance] \
  [dict get $best cut] [dict get $best feasible] $final_sol]
puts [format {INFO %s: summary=%s} [_ts] $final_sum]
flush stdout

exit
