# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# place_macro_util.tcl
# Common helpers for die-by-die macro placement.
# The tier visibility and overlap behavior are defined by LEF views.
# This file does not create extra blockages for the opposite tier.
# ==========================================

if {![namespace exists pmu]} {
  namespace eval pmu {}
}

proc pmu::is_macro_like_inst {inst_ptr} {
  if {$inst_ptr eq "" || $inst_ptr eq "0x0"} {
    return 0
  }

  set sub_class [string tolower [dbGet $inst_ptr.cell.subClass]]
  set base_class [string tolower [dbGet $inst_ptr.cell.baseClass]]
  if {[string match "*block*" $sub_class] || [string match "*block*" $base_class]} {
    return 1
  }
  if {[string match "*ring*" $sub_class] || [string match "*ring*" $base_class]} {
    return 1
  }
  set site_name [dbGet $inst_ptr.cell.site.name]
  if {$site_name eq "" || $site_name eq "0x0"} {
    return 1
  }
  return 0
}

proc pmu::_get_halos {{tier ""}} {
  set normalized_tier [string tolower [string trim $tier]]
  switch -- $normalized_tier {
    upper { set tier_var MACRO_PLACE_HALO_UPPER }
    bottom { set tier_var MACRO_PLACE_HALO_BOTTOM }
    default { set tier_var "" }
  }

  if {$tier_var ne "" && [info exists ::env($tier_var)] && $::env($tier_var) ne ""} {
    set values $::env($tier_var)
  } elseif {[info exists ::env(MACRO_PLACE_HALO)] && $::env(MACRO_PLACE_HALO) ne ""} {
    set values $::env(MACRO_PLACE_HALO)
  } else {
    return [list 0 0]
  }

  switch -- [llength $values] {
    1 {
      set halo_x [lindex $values 0]
      set halo_y $halo_x
    }
    2 {
      lassign $values halo_x halo_y
    }
    default {
      if {$tier_var ne "" && [info exists ::env($tier_var)] && $::env($tier_var) ne ""} {
        error "pmu::_get_halos: $tier_var must have 1 or 2 values, got '$::env($tier_var)'"
      }
      error "pmu::_get_halos: MACRO_PLACE_HALO must have 1 or 2 values, got '$::env(MACRO_PLACE_HALO)'"
    }
  }

  return [list $halo_x $halo_y]
}

proc pmu::_norm_tier {tier} {
  set t [string tolower $tier]
  if {$t ne "upper" && $t ne "bottom"} {
    error "pmu::_norm_tier: tier must be upper or bottom, got '$tier'"
  }
  return $t
}

proc pmu::get_tier_macro_cells {tier} {
  set t [pmu::_norm_tier $tier]
  set pat "*_${t}"
  set cells {}

  foreach inst [dbGet -p2 top.insts.cell.name $pat] {
    if {[pmu::is_macro_like_inst $inst]} {
      lappend cells [dbGet $inst.cell.name]
    }
  }

  return [lsort -unique $cells]
}

proc pmu::get_tier_macro_insts {tier} {
  set t [pmu::_norm_tier $tier]
  set pat "*_${t}"
  set insts {}
  foreach inst [dbGet -p2 top.insts.cell.name $pat] {
    if {[pmu::is_macro_like_inst $inst]} {
      lappend insts $inst
    }
  }
  return $insts
}

proc pmu::set_tier_macro_status {tier status} {
  set insts [pmu::get_tier_macro_insts $tier]
  if {![llength $insts]} {
    puts "INFO(PMU): No ${tier} macros found."
    return
  }
  dbSet $insts.pStatus $status
  puts "INFO(PMU): Set [llength $insts] ${tier} macros to '$status'."
}

proc pmu::set_all_tier_macros_fixed {} {
  pmu::set_tier_macro_status upper fixed
  pmu::set_tier_macro_status bottom fixed
}

proc pmu::run_tier_macro_place {tier halo_x halo_y} {
  set tier_macros [pmu::get_tier_macro_insts $tier]
  if {![llength $tier_macros]} {
    puts "INFO(PMU): No ${tier} macros found; skipping macro placement."
    return 0
  }

  puts "INFO(PMU): run_tier_macro_place tier=$tier halo_x=$halo_x halo_y=$halo_y"
  addHaloToBlock -allMacro $halo_x $halo_y $halo_x $halo_y
  place_design -concurrent_macros
  refine_macro_place
  pmu::set_tier_macro_status $tier fixed
  puts "INFO(PMU): ${tier} macro placement done."
  return [llength $tier_macros]
}

proc pmu::save_stage {def_out v_out png_out} {
  fit
  catch { dumpToGIF $png_out }
  defOut -floorplan $def_out
  saveNetlist $v_out
  puts "INFO(PMU): DEF -> $def_out"
  puts "INFO(PMU): V   -> $v_out"
}
