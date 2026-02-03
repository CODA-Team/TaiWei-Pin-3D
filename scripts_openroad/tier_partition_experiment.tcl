# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2019-2025, The OpenROAD Authors
#
# ============================================================
# SIMPLE TritonPart balance sweep (single-process, N points)
# Log-only parallel-friendly variant:
#   - If env(PAR_LOG_ONLY)=1: do NOT write RESULTS_DIR outputs
#   - Per-run result is printed as a single line:
#       FINAL <timestamp> balance=... seed=... cut=... feasible=... abs_diff=...
#   - Solution file is written to /tmp with pid isolation (safe for parallel)
# ============================================================

source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl

proc _ts {} { return [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"] }

proc _get {name def} {
  if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
  return $def
}

proc _clamp {x lo hi} {
  if {$x < $lo} { return $lo }
  if {$x > $hi} { return $hi }
  return $x
}

proc write_kv_file {outfile kv_dict} {
  set fh [open $outfile w]
  puts $fh $kv_dict
  close $fh
}

# ----------------------------
# Knobs (override via env)
# ----------------------------
set ::PAR_BAL_LO_DEFAULT   1.0
set ::PAR_BAL_HI_DEFAULT   5.0
set ::PAR_BAL_ITER_DEFAULT 5

set ::PAR_FIXED_SEED 1
if {[info exists ::env(PAR_FIXED_SEED)] && $::env(PAR_FIXED_SEED) ne ""} {
  set ::PAR_FIXED_SEED [expr {int($::env(PAR_FIXED_SEED))}]
}

set ::PAR_SEEDS_PER_POINT 10
if {[info exists ::env(PAR_SEEDS_PER_POINT)] && $::env(PAR_SEEDS_PER_POINT) ne ""} {
  set ::PAR_SEEDS_PER_POINT [expr {int($::env(PAR_SEEDS_PER_POINT))}]
}

# log-only mode
set ::LOG_ONLY 0
if {[info exists ::env(PAR_LOG_ONLY)] && $::env(PAR_LOG_ONLY) ne ""} {
  set ::LOG_ONLY [expr {int($::env(PAR_LOG_ONLY))}]
}

# If bash provides PAR_SEED, force single-seed mode (one run = one seed)
if {[info exists ::env(PAR_SEED)] && $::env(PAR_SEED) ne ""} {
  set s [expr {int($::env(PAR_SEED))}]
  set ::PAR_FIXED_SEED $s
  set ::PAR_SEEDS_PER_POINT 1
  puts [format {INFO %s: PAR_SEED=%d -> PAR_FIXED_SEED=%d PAR_SEEDS_PER_POINT=1} [_ts] $s $::PAR_FIXED_SEED]
  flush stdout
}

# hb_layer density-based cut budget knobs
set ::HB_CUT_LAYER         "hb_layer"
set ::HB_LAYER_WIDTH_UM    0.8
set ::HB_LAYER_SPACING_UM  0.8
set ::HB_LAYER_RES_OHM     0.02
set ::HB_VIA_DENSITY       0.5
set ::CUTS_PER_NET         1
set ::CUT_TOL              0

set ::IGNORE_NET_NAMES {VDD VSS VPWR VGND TOP_VDD TOP_VSS BOT_VDD BOT_VSS}
set ::DUMP_CUT_NETS      false
set ::CUT_NETS_DUMP_FILE "cut_nets.list"

# ============================================================
# Load design + floorplan
# ============================================================
load_design 2_2_floorplan_io.v 1_synth.sdc "Start Triton Partitioning (Uniform Sweep)"

# ============================================================
# ODB helpers: die area, dbu
# ============================================================
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

# ============================================================
# CUT(nets) from solution
# ============================================================
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

# ============================================================
# TritonPart (timing-aware)
# ============================================================
proc run_triton_part {solution_file balance seed} {
  puts [format {INFO %s: triton_part_design balance=%.4f seed=%d timing_aware=true -> %s} \
    [_ts] $balance $seed $solution_file]
  flush stdout

  triton_part_design \
    -num_parts 2 \
    -balance_constraint $balance \
    -seed $seed \
    -solution_file $solution_file \
    -timing_aware_flag true
}

# ============================================================
# Target cut budget from hb_layer density
# ============================================================
puts [format {INFO %s: HB layer=%s width=%.3fum spacing=%.3fum density=%.3f cuts_per_net=%d tol=%d log_only=%d} \
  [_ts] $::HB_CUT_LAYER $::HB_LAYER_WIDTH_UM $::HB_LAYER_SPACING_UM $::HB_VIA_DENSITY $::CUTS_PER_NET $::CUT_TOL $::LOG_ONLY]
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

# ============================================================
# Build sweep range + N points (include endpoints)
# ============================================================
set ::PAR_BAL_ITER [expr {int([_get PAR_BAL_ITERATION $::PAR_BAL_ITER_DEFAULT])}]
if {$::PAR_BAL_ITER < 2} {
  utl::error PAR 965 "PAR_BAL_ITERATION must be >= 2 (got $::PAR_BAL_ITER)."
}

set hard_lo [expr {double([_get PAR_BAL_LO $::PAR_BAL_LO_DEFAULT])}]
set hard_hi [expr {double([_get PAR_BAL_HI $::PAR_BAL_HI_DEFAULT])}]
if {$hard_hi < $hard_lo} { set tmp $hard_lo; set hard_lo $hard_hi; set hard_hi $tmp }

set lo $hard_lo
set hi $hard_hi
if {[info exists ::env(PAR_BAL_REF)] && $::env(PAR_BAL_REF) ne "" &&
    [info exists ::env(PAR_BAL_HALFSPAN)] && $::env(PAR_BAL_HALFSPAN) ne ""} {
  set ref      [expr {double($::env(PAR_BAL_REF))}]
  set halfspan [expr {double($::env(PAR_BAL_HALFSPAN))}]
  if {$halfspan < 0} { set halfspan [expr {-$halfspan}] }
  set lo [_clamp [expr {$ref - $halfspan}] $hard_lo $hard_hi]
  set hi [_clamp [expr {$ref + $halfspan}] $hard_lo $hard_hi]
  if {$hi < $lo} { set tmp $lo; set lo $hi; set hi $tmp }
}

set span [expr {$hi - $lo}]
if {$span <= 0.0} {
  utl::error PAR 963 [format "Invalid sweep range: lo=%.6f hi=%.6f" $lo $hi]
}

set step [expr {$span / double($::PAR_BAL_ITER - 1)}]
if {$step <= 0.0} {
  utl::error PAR 964 [format "Invalid step: %.6f" $step]
}

set balances {}
for {set i 0} {$i < $::PAR_BAL_ITER} {incr i} {
  set x [expr {$lo + double($i)*$step}]
  if {$i == ($::PAR_BAL_ITER - 1)} { set x $hi }
  lappend balances [format "%.6f" $x]
}

# Plan file (skip when log-only)
set plan_file [file join $::env(RESULTS_DIR) partition.simple_plan.txt]
set plan "SIMPLE PARTITION SWEEP @ [_ts]\n"
append plan [format "hard_lo=%.6f hard_hi=%.6f eff_lo=%.6f eff_hi=%.6f\n" $hard_lo $hard_hi $lo $hi]
append plan [format "N=%d step=%.6f points=%s\n" $::PAR_BAL_ITER $step [join $balances ","]]
append plan [format "target_cut=%d tol=%d timing_aware=true base_seed=%d seeds_per_point=%d\n" \
  $target_cut $::CUT_TOL $::PAR_FIXED_SEED $::PAR_SEEDS_PER_POINT]

if {!$::LOG_ONLY} {
  set fh [open $plan_file w]
  puts $fh $plan
  close $fh
}

puts [format {INFO %s: Sweep %d points (include endpoints) with %d seeds each: %s} \
  [_ts] $::PAR_BAL_ITER $::PAR_SEEDS_PER_POINT [join $balances ","]]
flush stdout

# ============================================================
# Evaluate points, pick best
# ============================================================
set best ""
set best_feasible 0

foreach b $balances {
  set bal [expr {double($b)}]

  for {set k 0} {$k < $::PAR_SEEDS_PER_POINT} {incr k} {
    set current_seed [expr {$::PAR_FIXED_SEED + $k}]

    # Solution file path:
    # - log-only: /tmp + pid to avoid clobber in parallel runs
    # - normal:  RESULTS_DIR/partition_sweep/...
    if {$::LOG_ONLY} {
      set sol [file join "/tmp" [format {part.pid%d.ub%.6f.seed%d.txt} [pid] $bal $current_seed]]
    } else {
      set out_dir [file join $::env(RESULTS_DIR) partition_sweep]
      if {![file exists $out_dir]} { file mkdir $out_dir }
      set sol [file join $out_dir [format {part.ub%.6f.seed%d.txt} $bal $current_seed]]
    }

    run_triton_part $sol $bal $current_seed

    # cut nets count
    set dump_file ""
    if {!$::LOG_ONLY && $::DUMP_CUT_NETS} {
      set dump_file [file join $out_dir [format {cut_nets.ub%.6f.seed%d.list} $bal $current_seed]]
    }
    set cut [calc_cut_nets_from_solution $sol $::IGNORE_NET_NAMES $dump_file]
    set feasible [expr {$cut <= ($target_cut + $::CUT_TOL)}]
    set abs_diff [expr {abs($cut - $target_cut)}]

    puts [format {INFO %s: STAT balance=%.6f seed=%d cut=%d target=%d tol=%d feasible=%s abs_diff=%d} \
      [_ts] $bal $current_seed $cut $target_cut $::CUT_TOL $feasible $abs_diff]
    flush stdout

    set cur [dict create balance $bal cut $cut feasible $feasible abs_diff $abs_diff solution_file $sol seed $current_seed]

    if {$best eq ""} {
      set best $cur
      set best_feasible $feasible
      continue
    }

    if {$best_feasible} {
      if {$feasible} {
        set bc [dict get $best cut]
        set bb [dict get $best balance]
        if {$cut < $bc || ($cut == $bc && $bal < $bb)} { set best $cur }
      }
    } else {
      if {$feasible} {
        set best $cur
        set best_feasible 1
      } else {
        set bd [dict get $best abs_diff]
        set bc [dict get $best cut]
        set bb [dict get $best balance]
        if {$abs_diff < $bd ||
            ($abs_diff == $bd && $cut < $bc) ||
            ($abs_diff == $bd && $cut == $bc && $bal < $bb)} {
          set best $cur
        }
      }
    }
  }
}

if {$best eq ""} { utl::error PAR 962 "No valid sweep result." }

# ============================================================
# Final output: log-only prints FINAL line; normal mode writes files
# ============================================================
if {!$::LOG_ONLY} {
  set final_sol [file join $::env(RESULTS_DIR) partition.txt]
  file copy -force [dict get $best solution_file] $final_sol

  set final_sum [file join $::env(RESULTS_DIR) partition.result.tcl]
  set sum_dict [dict create \
    seed [dict get $best seed] \
    timing_aware true \
    target $target_cut \
    tol $::CUT_TOL \
    hard_lo $hard_lo \
    hard_hi $hard_hi \
    eff_lo $lo \
    eff_hi $hi \
    step $step \
    points $balances \
    balance [dict get $best balance] \
    cut [dict get $best cut] \
    feasible [dict get $best feasible] \
    abs_diff [dict get $best abs_diff] \
    solution_file [dict get $best solution_file]]
  write_kv_file $final_sum $sum_dict

  puts [format {INFO %s: FINAL best balance=%.6f seed=%d cut=%d feasible=%s -> %s} \
    [_ts] [dict get $best balance] [dict get $best seed] [dict get $best cut] [dict get $best feasible] $final_sol]
  puts [format {INFO %s: summary=%s} [_ts] $final_sum]
} else {
  puts [format {FINAL %s balance=%.6f seed=%d cut=%d feasible=%s abs_diff=%d} \
    [_ts] [dict get $best balance] [dict get $best seed] [dict get $best cut] \
    [dict get $best feasible] [dict get $best abs_diff]]
}
flush stdout
exit
