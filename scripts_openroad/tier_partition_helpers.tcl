# ============================================================
# tier_partition_helpers.tcl
# Helper/setup section split out from tier_partition.tcl.
# ============================================================
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

proc append_plan_line {var_name line} {
  upvar 1 $var_name plan_text
  append plan_text $line "\n"
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
if {$::PAR_BAL_HI < $::PAR_BAL_LO} {
  set tmp $::PAR_BAL_LO
  set ::PAR_BAL_LO $::PAR_BAL_HI
  set ::PAR_BAL_HI $tmp
}

# Deterministic seed
set ::PAR_FIXED_SEED 1

# hb_layer density-based cut budget knobs
set ::HB_CUT_LAYER         [_get HB_CUT_LAYER "hb_layer"]
set ::HB_LAYER_WIDTH_UM    [expr {double([_get HB_LAYER_WIDTH_UM 0.5])}]
set ::HB_LAYER_SPACING_UM  [expr {double([_get HB_LAYER_SPACING_UM 0.5])}]
set ::HB_LAYER_RES_OHM     0.02
set ::HB_VIA_DENSITY       0.5
set ::CUTS_PER_NET         1
set ::CUT_TOL              0

set ::IGNORE_NET_NAMES {VDD VSS VPWR VGND TOP_VDD TOP_VSS BOT_VDD BOT_VSS}
set ::DUMP_CUT_NETS      false
set ::CUT_NETS_DUMP_FILE "cut_nets.list"

# Mode B pin side for cut evaluation
set ::PIN_PARTITION_MODE_B [expr {int([_get PIN_PARTITION_MODE_B 0])}]
if {$::PIN_PARTITION_MODE_B != 0 && $::PIN_PARTITION_MODE_B != 1} {
  utl::error PAR 967 "PIN_PARTITION_MODE_B must be 0 or 1."
}

# ------------------------------------------------------------
# Load design + floorplan
# ------------------------------------------------------------
load_design 2_2_floorplan_io.odb 1_synth.sdc "Start Triton Partitioning (N-point sweep)"

set fp_def [file join $::env(RESULTS_DIR) 2_2_floorplan_io.def]
if {![file exists $fp_def]} {
  utl::error PAR 961 "Floorplan DEF not found: $fp_def"
}
# read_def -floorplan_initialize $fp_def

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

proc choose_pin_partition_for_cut {mode base_balance ratio0 ratio1} {
  if {$mode eq "BB_SWEEP"} {
    if {$ratio0 > $ratio1} {
      return 0
    }
    if {$ratio1 > $ratio0} {
      return 1
    }

    set b0 [expr {double([lindex $base_balance 0])}]
    set b1 [expr {double([lindex $base_balance 1])}]
    if {$b0 > $b1} {
      return 0
    }
    if {$b1 > $b0} {
      return 1
    }
    return 0
  }

  return $::PIN_PARTITION_MODE_B
}

proc calc_cut_nets_from_solution {solution_file ignore_net_names dump_file pin_partition} {
  set block [ord::get_db_block]
  if {$block eq "NULL"} { utl::error PAR 940 "No db block." }

  if {$pin_partition != 0 && $pin_partition != 1} {
    utl::error PAR 943 [format "Invalid pin_partition: %s" $pin_partition]
  }

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
    set has_mapped_inst 0
    set has_bterm 0

    foreach iterm [odb::dbNet_getITerms $net] {
      set inst  [odb::dbITerm_getInst $iterm]
      set iname [odb::dbInst_getName $inst]
      if {![info exists part($iname)]} {
        continue
      }

      set has_mapped_inst 1
      set pid $part($iname)
      if {$pid == 0} {
        set seen0 1
      } elseif {$pid == 1} {
        set seen1 1
      }
      if {$seen0 && $seen1} {
        break
      }
    }

    if {![catch {set bterms [odb::dbNet_getBTerms $net]}]} {
      foreach bterm $bterms {
        set has_bterm 1
        break
      }
    }

    if {$has_bterm} {
      if {$pin_partition == 0} {
        set seen0 1
      } else {
        set seen1 1
      }
    }

    # Ignore nets that do not involve any mapped internal instance.
    # Pure port-only nets should not consume the cut budget.
    if {!$has_mapped_inst} {
      continue
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
# Partition-area balance from solution
# ------------------------------------------------------------
proc _inst_area_dbu2 {inst} {
  set master [odb::dbInst_getMaster $inst]
  if {$master eq "NULL"} { return 0.0 }
  set w [odb::dbMaster_getWidth $master]
  set h [odb::dbMaster_getHeight $master]
  return [expr {double($w) * double($h)}]
}

proc calc_part_area_balance_from_solution {solution_file target_base_balance} {
  set block [ord::get_db_block]
  if {$block eq "NULL"} { utl::error PAR 941 "No db block." }

  array set part {}
  array set part [read_solution_part_map_kv $solution_file]

  set a0 0.0
  set a1 0.0

  foreach inst [odb::dbBlock_getInsts $block] {
    set iname [odb::dbInst_getName $inst]
    if {![info exists part($iname)]} { continue }
    set pid $part($iname)
    set area [_inst_area_dbu2 $inst]
    if {$pid == 0} {
      set a0 [expr {$a0 + $area}]
    } else {
      set a1 [expr {$a1 + $area}]
    }
  }

  set atot [expr {$a0 + $a1}]
  if {$atot <= 0.0} {
    utl::error PAR 942 "Partitioned area is zero when evaluating area balance."
  }

  set r0 [expr {$a0 / $atot}]
  set r1 [expr {$a1 / $atot}]

  set t0 [expr {double([lindex $target_base_balance 0])}]
  set t1 [expr {double([lindex $target_base_balance 1])}]
  set balance_err [expr {abs($r0 - $t0) + abs($r1 - $t1)}]

  return [dict create \
    area0 $a0 area1 $a1 \
    ratio0 $r0 ratio1 $r1 \
    target0 $t0 target1 $t1 \
    balance_err $balance_err]
}

# ------------------------------------------------------------
# Candidate comparison
#
# BB_SWEEP:
#   prefer feasible
#   among feasible: minimize target_balance_err, then cut, then ub
#   among infeasible: minimize target_balance_err, then abs_diff, then cut, then ub
#
# UB_SWEEP:
#   prefer feasible
#   among feasible: minimize cut, then ub
#   among infeasible: minimize abs_diff, then cut, then ub
# ------------------------------------------------------------
proc candidate_better {cur best mode} {
  set cfeas [dict get $cur feasible]
  set bfeas [dict get $best feasible]

  if {$cfeas && !$bfeas} { return 1 }
  if {!$cfeas && $bfeas} { return 0 }

  if {$mode eq "BB_SWEEP"} {
    if {$cfeas && $bfeas} {
      set cbal [dict get $cur balance_err]
      set bbal [dict get $best balance_err]
      if {$cbal < $bbal} { return 1 }
      if {$cbal > $bbal} { return 0 }

      set cc [dict get $cur cut]
      set bc [dict get $best cut]
      if {$cc < $bc} { return 1 }
      if {$cc > $bc} { return 0 }

      set cub [dict get $cur ub]
      set bub [dict get $best ub]
      if {$cub < $bub} { return 1 }
      return 0
    } else {
      set cbal [dict get $cur balance_err]
      set bbal [dict get $best balance_err]
      if {$cbal < $bbal} { return 1 }
      if {$cbal > $bbal} { return 0 }

      set cd [dict get $cur abs_diff]
      set bd [dict get $best abs_diff]
      if {$cd < $bd} { return 1 }
      if {$cd > $bd} { return 0 }

      set cc [dict get $cur cut]
      set bc [dict get $best cut]
      if {$cc < $bc} { return 1 }
      if {$cc > $bc} { return 0 }

      set cub [dict get $cur ub]
      set bub [dict get $best ub]
      if {$cub < $bub} { return 1 }
      return 0
    }
  } else {
    if {$cfeas && $bfeas} {
      set cc [dict get $cur cut]
      set bc [dict get $best cut]
      if {$cc < $bc} { return 1 }
      if {$cc > $bc} { return 0 }

      set cub [dict get $cur ub]
      set bub [dict get $best ub]
      if {$cub < $bub} { return 1 }
      return 0
    } else {
      set cd [dict get $cur abs_diff]
      set bd [dict get $best abs_diff]
      if {$cd < $bd} { return 1 }
      if {$cd > $bd} { return 0 }

      set cc [dict get $cur cut]
      set bc [dict get $best cut]
      if {$cc < $bc} { return 1 }
      if {$cc > $bc} { return 0 }

      set cub [dict get $cur ub]
      set bub [dict get $best ub]
      if {$cub < $bub} { return 1 }
      return 0
    }
  }
}

# ------------------------------------------------------------
# TritonPart runner (timing-aware)
# ------------------------------------------------------------
proc run_triton_part {solution_file ub seed base_balance} {
  puts [format {INFO %s: triton_part_design ub=%.6f seed=%d timing_aware=true base_balance=%s pin_constraints=disabled -> %s} \
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

proc evaluate_candidate {point mode target_balance target_cut out_dir} {
  set ub [dict get $point ub]
  set base_balance [dict get $point base_balance]
  set tag [dict get $point tag]
  set sol [file join $out_dir [format {part.%s.seed%d.txt} $tag $::PAR_FIXED_SEED]]

  run_triton_part $sol $ub $::PAR_FIXED_SEED $base_balance

  set bal_stats [calc_part_area_balance_from_solution $sol $target_balance]
  set ratio0 [dict get $bal_stats ratio0]
  set ratio1 [dict get $bal_stats ratio1]
  set balance_err [dict get $bal_stats balance_err]
  set pin_partition [choose_pin_partition_for_cut $mode $base_balance $ratio0 $ratio1]

  set dump_file ""
  if {$::DUMP_CUT_NETS} {
    set dump_file [file join $out_dir [format {cut_nets.%s.seed%d.list} $tag $::PAR_FIXED_SEED]]
  }

  set cut [calc_cut_nets_from_solution $sol $::IGNORE_NET_NAMES $dump_file $pin_partition]
  set feasible [expr {$cut <= ($target_cut + $::CUT_TOL)}]
  set abs_diff [expr {abs($cut - $target_cut)}]

  puts [format {INFO %s: STAT tag=%s ub=%.6f base_balance=%s pin_partition=%d target_balance=%s cut=%d target=%d tol=%d feasible=%s abs_diff=%d area_ratio={%.6f %.6f} target_balance_err=%.6f} \
    [_ts] $tag $ub $base_balance $pin_partition $target_balance $cut $target_cut $::CUT_TOL $feasible $abs_diff $ratio0 $ratio1 $balance_err]
  flush stdout

  return [dict create \
    tag $tag \
    ub $ub \
    base_balance $base_balance \
    target_balance $target_balance \
    pin_partition $pin_partition \
    cut $cut \
    feasible $feasible \
    abs_diff $abs_diff \
    ratio0 $ratio0 \
    ratio1 $ratio1 \
    balance_err $balance_err \
    solution_file $sol \
    mode $mode]
}

# ------------------------------------------------------------
