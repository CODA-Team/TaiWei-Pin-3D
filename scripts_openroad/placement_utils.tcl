# placement_utils.tcl
# In placement phase
# ----------------------------------------------------------------------
# Mark instances as a given placement status by matching master name
# Usage:
#   mark_insts_by_master "*_bottom" FIRM
#   mark_insts_by_master "" FIRM
# ----------------------------------------------------------------------
proc mark_insts_by_master {{pattern ""} {status "FIRM"}} {
  # 1) Parse pattern
  if {$pattern eq ""} {
    return 0
  }

  # 2) Validate target status (common OpenROAD/ODB values)
  set valid_status {UNPLACED PLACED FIRM LOCKED FIXED}
  if {[lsearch -exact $valid_status $status] < 0} {
    puts "WARN: '$status' not in valid statuses: $valid_status ; fallback to FIRM"
    set status FIRM
  }

  # 3) Get DB/Block
  set db   [ord::get_db]
  set chip [$db getChip]
  if {$chip eq ""} {
    puts "WARN: No chip loaded."
    return 0
  }
  set block [$chip getBlock]
  if {$block eq ""} {
    puts "WARN: No block in chip."
    return 0
  }

  # 4) Iterate instances; match by master name and set status
  set cnt 0
  set examples {}
  foreach inst [$block getInsts] {
    set mname [[$inst getMaster] getName]
    if {[string match -nocase $pattern $mname]} {
      if {[catch {$inst setPlacementStatus $status} err]} {
        puts "WARN: fail to set $status for [$inst getName]($mname): $err"
      } else {
        incr cnt
        if {[llength $examples] < 5} {
          lappend examples "[$inst getName]($mname)"
        }
      }
    }
  }

  puts "INFO: Marked $cnt insts to '$status' by master pattern '$pattern'. Examples: [join $examples {, }]"
  return $cnt
}

# ---------- Helpers ----------
proc ::_as_int {v default} {
  if {![info exists v]} { return $default }
  if {![string is integer -strict $v]} { return $default }
  return $v
}

proc ::_env_or {name default} {
  if {[info exists ::env($name)]} { return $::env($name) }
  return $default
}

# 递归打印某个 namespace 下的所有命令和子 namespace
proc or_list_ns_cmds {ns {indent ""}} {
  # 打印当前 namespace
  puts "${indent}Namespace: $ns"

  # 当前 namespace 下的命令（用 pattern 匹配）
  set pattern "${ns}::*"
  set cmds [lsort [info commands $pattern]]
  foreach c $cmds {
    puts "${indent}  [string range $c 0 end]"
  }

  # 递归进入子 namespace
  set children [lsort [namespace children $ns]]
  foreach child $children {
    or_list_ns_cmds $child "${indent}  "
  }
}

# ---------- Robust density calculator ----------
proc calculate_placement_density {} {
  set base_density [::_env_or PLACE_DENSITY 0.60]

  # 1) If no addon requested, just use base
  if {![info exists ::env(PLACE_DENSITY_LB_ADDON)]} {
    puts "INFO: PLACE_DENSITY_LB_ADDON not set, using PLACE_DENSITY=$base_density"
    return $base_density
  }

  # 3) Pad arguments must be integers; default to 0 if missing
  set pad_l [::_as_int $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) 0]
  set pad_r [::_as_int $::env(CELL_PAD_IN_SITES_GLOBAL_PLACEMENT) 0]
  # 4) Compute LB with catch to absorb GPL-0301 on older builds / invalid states 
  set lb 0.0
  set rc [catch {
    set lb [gpl::get_global_placement_uniform_density -pad_left $pad_l -pad_right $pad_r]
  } err]

  if {$rc} {
    puts "ERRORINFO:\n$::errorInfo"
    return $base_density
  }

  # 5) Apply addon blend and a tiny nudge
  set addon $::env(PLACE_DENSITY_LB_ADDON)
  if {$addon < 0.0} { set addon 0.0 }
  if {$addon > 1.0} { set addon 1.0 }

  set density [expr {$lb + ((1.0 - $lb) * $addon) + 0.01}]
  if {$density <= 0.0} { set density 0.10 }
  if {$density >= 1.0} { set density 0.98 }

  puts "INFO: PLACE_DENSITY_LB=$lb, ADDON=$addon -> density=$density (padL=$pad_l padR=$pad_r)"
  return $density
}

# ==== Utility: delete instances by matching master name ====
# pattern default "*_bottom*"; dry_run=1 only prints; verbose controls logging
proc delete_insts_by_master {{pattern ""} {dry_run 0} {verbose 1}} {
  set db   [ord::get_db]
  set chip [$db getChip]
  if {$chip eq ""} { puts "WARN: no chip"; return 0 }
  set block [$chip getBlock]
  if {$block eq ""} { puts "WARN: no block"; return 0 }
  
  if {$pattern eq ""} {
  puts "WARN: empty pattern, skip."
  return 0
  }
  set del_names {}
  foreach inst [$block getInsts] {
  set mname [[$inst getMaster] getName]
  if {[string match -nocase $pattern $mname]} {
    lappend del_names [$inst getName]
  }
  }

  if {$verbose} {
  puts "INFO: matched [llength $del_names] insts by master '$pattern'"
  puts "INFO: examples: [join [lrange $del_names 0 9] {, }]"
  }

  if {$dry_run} { return [llength $del_names] }

  set ok 0
  foreach name $del_names {
  if {[catch {delete_instance $name} err]} {
    puts "WARN: delete_instance $name failed: $err"
  } else {
    incr ok
  }
  }
  if {$verbose} { puts "INFO: actually deleted $ok insts." }
  return $ok
}

# ===============================
# OpenROAD: dont_use & FastRoute
# ===============================

# Get environment variable as list (missing/empty => {})
proc _as_list {envname} {
  if {[info exists ::env($envname)] && $::env($envname) ne ""} {
  return $::env($envname)
  }
  return {}
}

# Expand wildcard patterns to real lib cell names; keep original if command unsupported
proc _expand_libcells {patterns} {
  set out {}
  foreach p $patterns {
    # 1. Try to find cells matching the pattern
    if {![catch {set hits [get_lib_cells $p]}]} {
      if {[llength $hits] > 0} {
        foreach h $hits { 
          lappend out [::sta::LibertyCell_name $h] 
        }
        continue
      }
    }
  }
  return [lsort -unique $out]
}

# set_dont_use prefers batch; if it fails, fall back to per-cell
proc _set_dont_use {cells} {
  # puts "_set_dont_use $cells"
  if {![llength $cells]} { return }
  foreach c $cells { 
    set_dont_use $c 
    puts "set_dont_use $c"
  }
}

# ============= FastRoute fallback setup (can be overridden by external Tcl) =============
proc fastroute_setup {} {
  # Prefer user-provided external script
  if {[info exists ::env(FASTROUTE_TCL)] && $::env(FASTROUTE_TCL) ne ""} {
  puts "INFO(OR): Sourcing FASTROUTE_TCL = $::env(FASTROUTE_TCL)"
  catch { source $::env(FASTROUTE_TCL) }
  return
  }

  # Fallback: set signal layers and congestion adjustment from MIN/MAX_ROUTING_LAYER
  set minL [expr {[info exists ::env(MIN_ROUTING_LAYER)] ? $::env(MIN_ROUTING_LAYER) : "met1"}]
  set maxL [expr {[info exists ::env(MAX_ROUTING_LAYER)] ? $::env(MAX_ROUTING_LAYER) : "met5"}]

  catch { set_routing_layers -signal ${minL}-${maxL} }
  # Apply uniform layer adjustment (more conservative congestion); can be refined per-layer
  catch { set_global_routing_layer_adjustment ${minL}-${maxL} 0.5 }

  puts "INFO(OR): FastRoute default setup done: layers=${minL}-${maxL}, adjust=0.5"
}

# ============================================================
# Row rebuild for OpenROAD (site-snapped + die-clamped)
# ============================================================

proc _snap_down_dbu {x pitch} {
  if {$pitch <= 0} { error "ERROR: pitch must be > 0, got $pitch" }
  return [expr {($x / $pitch) * $pitch}]   ;# floor to pitch grid
}

proc _snap_up_dbu {x pitch} {
  if {$pitch <= 0} { error "ERROR: pitch must be > 0, got $pitch" }
  if {$x % $pitch == 0} { return $x }
  return [expr {(($x / $pitch) + 1) * $pitch}]  ;# ceil to pitch grid
}

proc _clamp_dbu {x lo hi} {
  if {$x < $lo} { return $lo }
  if {$x > $hi} { return $hi }
  return $x
}

# Get die area in DBU: {lx ly ux uy}
proc or_get_die_area_dbu {block} {
  lassign [ord::get_die_area] dlx_um dly_um dux_um duy_um
  return [list \
    [$block micronsToDbu $dlx_um] \
    [$block micronsToDbu $dly_um] \
    [$block micronsToDbu $dux_um] \
    [$block micronsToDbu $duy_um] \
  ]
}

# Find a dbSite by name from any library in the current db. (must find or error)
proc or_find_site_by_name_in_db {site_name} {
  set db [ord::get_db]
  foreach lib [$db getLibs] {
    set s [odb::dbLib_findSite $lib $site_name]
    if {$s ne "" && $s ne "NULL"} { return $s }
  }
  error "ERROR: cannot resolve site '$site_name' via odb::dbLib_findSite in any dbLib."
}

proc or_rebuild_rows_for_site {new_site} {
  # die area (microns): {lx ly ux uy}
  lassign [ord::get_die_area] die_lx die_ly die_ux die_uy

  # core margin (microns)
  set m 0.0
  if {[info exists ::env(CORE_MARGIN)] && $::env(CORE_MARGIN) ne ""} {
    set m [expr {double($::env(CORE_MARGIN))}]
  }
  if {$m < 0.0} {
    error "ERROR: CORE_MARGIN must be >= 0, got $m"
  }

  # core area = die area inset by margin
  set core_lx [expr {$die_lx + $m}]
  set core_ly [expr {$die_ly + $m}]
  set core_ux [expr {$die_ux - $m}]
  set core_uy [expr {$die_uy - $m}]

  if {$core_ux <= $core_lx || $core_uy <= $core_ly} {
    error "ERROR: CORE_MARGIN ($m um) too large for die_area {$die_lx $die_ly $die_ux $die_uy}"
  }

  # deterministic: site must exist in dbLib 
  set site [or_find_site_by_name_in_db $new_site]
  if {[$site getWidth] <= 0 || [$site getHeight] <= 0} {
    error "ERROR: invalid site '$new_site' (w=[$site getWidth] h=[$site getHeight])"
  }

  # make_rows will rebuild rows (and clear existing ones internally)
  make_rows -core_area [list $core_lx $core_ly $core_ux $core_uy] -site $new_site
}

# ------------------------------------------------------------
# OpenROAD: set_dont_touch for instances matched by MASTER name pattern
#   pattern: "*_bottom" / "*_upper"
# Notes:
#   - Instance-only. No net locking. No lock_nets option.
#   - Do NOT call this in CTS stage if your CTS script rewires clocks.
# Options:
#   -quiet 1/0 (default 0)
# Return: number of matched instances
# ------------------------------------------------------------
proc or_set_dont_touch_by_master {pattern args} {
  array set opt { -quiet 0 }
  if {([llength $args] % 2) != 0} {
    error "or_set_dont_touch_by_master: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} { error "or_set_dont_touch_by_master: unknown option $k" }
    set opt($k) $v
  }

  if {$pattern eq ""} {
    if {!$opt(-quiet)} { puts "INFO(OR): dont_touch: empty pattern, skip." }
    return 0
  }
  if {![llength [info commands set_dont_touch]]} {
    error "OpenROAD: set_dont_touch command not found."
  }

  set block [ord::get_db_block]
  if {$block eq ""} {
    puts "WARN(OR): dont_touch: no db block"
    return 0
  }

  set inst_names {}
  foreach inst [$block getInsts] {
    set mname [[$inst getMaster] getName]
    if {[string match -nocase $pattern $mname]} {
      lappend inst_names [$inst getName]
    }
  }

  set cnt [llength $inst_names]
  if {$cnt == 0} {
    if {!$opt(-quiet)} { puts "INFO(OR): dont_touch: no inst matches master '$pattern'." }
    return 0
  }

  set cells [get_cells $inst_names]
  if {[catch { set_dont_touch $cells } err]} {
    if {!$opt(-quiet)} { puts "WARN(OR): dont_touch: failed: $err" }
  } else {
    if {!$opt(-quiet)} {
      puts "INFO(OR): dont_touch: locked $cnt insts by master '$pattern'. Examples: [join [lrange $inst_names 0 4] {, }]"
    }
  }
  return $cnt
}

# ------------------------------------------------------------
# Apply tier policy (CTS-safe switch)
#   - default: set_dont_touch on the other tier instances
#   - if -cts_safe 1: do NOT set_dont_touch (avoid ODB-0370 in CTS rewiring)
# Options:
#   -cts_safe 0/1   (default 0)
#   -quiet    0/1   (default 0)
# ------------------------------------------------------------
proc apply_tier_policy {tier args} {
  set tier [string tolower $tier]
  if {$tier ne "upper" && $tier ne "bottom"} {
    error "apply_tier_policy: tier must be 'upper' or 'bottom'"
  }

  array set opt {
    -cts_safe 0
    -quiet    0
    -fixlib   0
  }
  if {([llength $args] % 2) != 0} {
    error "apply_tier_policy: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} { error "apply_tier_policy: unknown option $k" }
    set opt($k) $v
  }

  set dnu_up  [_as_list DNU_FOR_UPPER]
  set dnu_bot [_as_list DNU_FOR_BOTTOM]

  if {$tier eq "upper"} {
    # dont_use for synthesis/placement choices
    if {$opt(-fixlib)} { 
      _set_dont_use [_expand_libcells $dnu_up] 
    }

    set ::env(TIEHI_CELL_AND_PORT) $::env(UPPER_TIEHI_CELL_AND_PORT)
    set ::env(TIELO_CELL_AND_PORT) $::env(UPPER_TIELO_CELL_AND_PORT)
    if {[info exists ::env(UPPER_SITE)]} { set ::env(PLACE_SITE) $::env(UPPER_SITE) }

    # optional freeze handled elsewhere (per your note)

    # default: set_dont_touch other tier; CTS-safe: skip
    if {!$opt(-cts_safe)} {
      puts "INFO(OR): cts_safe=0."
      or_set_dont_touch_by_master "*_bottom" -quiet $opt(-quiet)
    } else {
      puts "INFO(OR): cts_safe=1 -> skip set_dont_touch for other tier."
    }

    if {!$opt(-quiet)} {
      puts "INFO(OR): Tier=UPPER applied. cts_safe=$opt(-cts_safe)"
    }
  } else {
    if {$opt(-fixlib)} { 
      _set_dont_use [_expand_libcells $dnu_bot] 
    }

    set ::env(TIEHI_CELL_AND_PORT) $::env(BOTTOM_TIEHI_CELL_AND_PORT)
    set ::env(TIELO_CELL_AND_PORT) $::env(BOTTOM_TIELO_CELL_AND_PORT)
    if {[info exists ::env(BOTTOM_SITE)]} { set ::env(PLACE_SITE) $::env(BOTTOM_SITE) }

    if {!$opt(-cts_safe)} {
      puts "INFO(OR): cts_safe=0."
      or_set_dont_touch_by_master "*_upper" -quiet $opt(-quiet)
    } else {
      puts "INFO(OR): cts_safe=1 -> skip set_dont_touch for other tier."
    }

    if {!$opt(-quiet)} {
      puts "INFO(OR): Tier=BOTTOM applied. cts_safe=$opt(-cts_safe)"
    }
  }

  if {[info exists ::env(DONT_USE_CELLS)] && $::env(DONT_USE_CELLS) ne ""} {
    _set_dont_use [_expand_libcells $::env(DONT_USE_CELLS)]
    if {!$opt(-quiet)} { puts "INFO(OR): Applied DONT_USE_CELLS = '$::env(DONT_USE_CELLS)'." }
  }

  or_rebuild_rows_for_site $::env(PLACE_SITE)
}
