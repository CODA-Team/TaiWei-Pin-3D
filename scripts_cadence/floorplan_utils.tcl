# ============================================================
# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# tier_floorplan_utils.tcl
#   - Tier-aware instance area and core sizing helpers
#   - Assumes master name suffix: *_upper or *_bottom
# ============================================================

# Ensure namespace exists
namespace eval tier {}

namespace eval tier {

  # Sum a list of numeric values (ignore empty)
  proc _sum_list {lst} {
    set s 0.0
    foreach v $lst {
      if {$v eq ""} { continue }
      set s [expr {$s + double($v)}]
    }
    return $s
  }

  # Get total instance area for tier: upper|bottom
  proc get_inst_area {tier} {
    set t [string tolower $tier]
    if {$t ne "upper" && $t ne "bottom"} {
      error "tier::get_inst_area: tier must be upper or bottom (got '$tier')"
    }

    set pat "*_${t}"
    set insts {}
    catch { set insts [dbGet -p2 top.insts.cell.name $pat] }

    if {![llength $insts]} {
      puts "WARN: tier::get_inst_area: no instances match pattern '$pat' (tier=$t)."
      return 0.0
    }

    # Prefer inst.area; fallback to master(cell).area
    set areas {}
    if {[catch { set areas [dbGet $insts.area] }]} {
      catch { set areas [dbGet $insts.cell.area] }
    }

    set a [_sum_list $areas]
    puts "INFO: tier=$t inst_count=[llength $insts] total_area=$a"
    return $a
  }

  # Compute core W/H (microns) so that max-tier util == target_util
  # aspect_ratio = H/W
  proc core_wh_for_max_tier_util {target_util aspect_ratio} {
    if {$target_util <= 0.0 || $target_util > 1.0} {
      error "tier::core_wh_for_max_tier_util: target_util must be in (0,1]. got $target_util"
    }
    if {$aspect_ratio <= 0.0} {
      error "tier::core_wh_for_max_tier_util: aspect_ratio must be > 0. got $aspect_ratio"
    }

    set A_upper  [get_inst_area upper]
    set A_bottom [get_inst_area bottom]
    set A_max    [expr {($A_upper > $A_bottom) ? $A_upper : $A_bottom}]

    if {$A_max <= 0.0} {
      return [list 0.0 0.0 $A_upper $A_bottom $A_max]
    }

    set core_area [expr {$A_max / $target_util}]
    set W [expr {sqrt($core_area / double($aspect_ratio))}]
    set H [expr {$W * double($aspect_ratio)}]
    return [list $W $H $A_upper $A_bottom $A_max]
  }
}

proc _mt_layer_exists {layer} {
  if {![catch {dbGet head.layers.name} layers] && $layers ne ""} {
    return [expr {[lsearch -exact $layers $layer] >= 0}]
  }
  return 1
}

proc _mt_box4 {use_core} {
  # Return {lx ly ux uy} as a Tcl list of 4 numbers (microns)
  set r [expr {$use_core ? [dbGet top.fPlan.coreBox] : [dbGet top.fPlan.box]}]
  set r [string trim $r]
  # 1) Normal case: r itself is a 4-element Tcl list
  if {[llength $r] == 4} { return $r }
  # 2) Some cases: r is a 1-element list whose element is the 4-element list
  if {[llength $r] == 1} {
    set r1 [lindex $r 0]
    if {[llength $r1] == 4} { return $r1 }
  }
  # 3) Last resort: strip braces and re-parse
  set r2 $r
  regsub -all {[{}]} $r2 "" r2
  set r2 [string trim $r2]
  if {[llength $r2] == 4} { return $r2 }

  error "make_tracks: cannot parse box (expect 4 numbers), got: '$r'"
}

proc _mt_num_tracks {start step lo hi} {
  if {$step <= 0} { return 0 }
  if {$start < $lo} {
    set start [expr {$start + ceil( ($lo - $start)/$step )*$step}]
  }
  set span [expr {$hi - $start}]
  if {$span < 0} { return 0 }
  return [expr {int(floor($span/$step)) + 1}]
}

proc make_tracks {layer args} {
  array set opt {
    -x_offset ""
    -x_pitch  ""
    -y_offset ""
    -y_pitch  ""
    -use_core 0
    -quiet    0
  }

  if {[llength $args] % 2} {
    error "make_tracks $layer: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} { error "make_tracks $layer: unknown option $k" }
    set opt($k) $v
  }

  if {![llength [info commands createTrack]]} {
    error "make_tracks: createTrack not found."
  }

  if {![_mt_layer_exists $layer]} {
    if {!$opt(-quiet)} { puts "INFO(make_tracks): skip $layer (layer not in tech DB)" }
    return
  }

  lassign [_mt_box4 $opt(-use_core)] lx ly ux uy

  if {$opt(-x_offset) ne "" && $opt(-x_pitch) ne ""} {
    set startX [expr {double($lx) + double($opt(-x_offset))}]
    set stepX  [expr {double($opt(-x_pitch))}]
    set numX   [_mt_num_tracks $startX $stepX $lx $ux]
    if {$numX > 0 && [catch {createTrack -dir X -layer $layer -num $numX -start $startX -step $stepX} e] && !$opt(-quiet)} {
      puts "WARN(make_tracks): createTrack failed ($layer X). Err: $e"
    }
  }

  if {$opt(-y_offset) ne "" && $opt(-y_pitch) ne ""} {
    set startY [expr {double($ly) + double($opt(-y_offset))}]
    set stepY  [expr {double($opt(-y_pitch))}]
    set numY   [_mt_num_tracks $startY $stepY $ly $uy]
    if {$numY > 0 && [catch {createTrack -dir Y -layer $layer -num $numY -start $startY -step $stepY} e] && !$opt(-quiet)} {
      puts "WARN(make_tracks): createTrack failed ($layer Y). Err: $e"
    }
  }
}
