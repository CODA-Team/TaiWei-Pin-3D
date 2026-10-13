# placement_utils.tcl
# In placement phase
# ------------------------------------------------------------
# Mark instances as a given placement status by matching master name
# Usage:
#   mark_insts_by_master "*_bottom" FIRM
#   mark_insts_by_master "" FIRM
# ------------------------------------------------------------------------------
# master_has_site: expects a dbMaster object (pointer), NOT a name string.
# ------------------------------------------------------------------------------
proc master_has_site {m} {
  # Return 1 if master is bound to a SITE (typical stdcell), else 0.
  if {![catch {set s [::odb::dbMaster_getSite $m]}]} {
    if {$s ne "" && $s ne "NULL"} { return 1 }
  }
  return 0
}

# ------------------------------------------------------------------------------
# Helper: resolve master by name (slow path). Used by name-based test API.
# ------------------------------------------------------------------------------
proc _find_master_by_name {mname} {
  set db [ord::get_db]
  set libs [::odb::dbDatabase_getLibs $db]
  foreach lib $libs {
    set masters [::odb::dbLib_getMasters $lib]
    foreach m $masters {
      if {[$m getName] eq $mname} { return $m }
    }
  }
  return ""
}

# ------------------------------------------------------------------------------
# Name-based test API (for your colleague): master_has_site_by_name "CELLNAME"
# Uses cache to avoid repeated library scans.
# ------------------------------------------------------------------------------
proc master_has_site_by_name {mname} {
  # Cache: ::_MASTER_HAS_SITE_CACHE($mname) => 0/1
  if {[info exists ::_MASTER_HAS_SITE_CACHE($mname)]} {
    return $::_MASTER_HAS_SITE_CACHE($mname)
  }
  set m [_find_master_by_name $mname]
  if {$m eq ""} {
    set ::_MASTER_HAS_SITE_CACHE($mname) 0
    return 0
  }
  set v [master_has_site $m]
  set ::_MASTER_HAS_SITE_CACHE($mname) $v
  return $v
}

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
    # if master have site, it is CORE CELL
    if {[master_has_site_by_name $mname]} {
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
  }

  puts "INFO: Marked $cnt insts to '$status' by master pattern '$pattern'. Examples: [join $examples {, }]"
  return $cnt
}

# Helpers
proc ::_as_int {v default} {
  if {![info exists v]} { return $default }
  if {![string is integer -strict $v]} { return $default }
  return $v
}

proc ::_env_or {name default} {
  if {[info exists ::env($name)]} { return $::env($name) }
  return $default
}

# Recursively print all commands and child namespaces under a namespace
proc or_list_ns_cmds {ns {indent ""}} {
  # Print current namespace
  puts "${indent}Namespace: $ns"

  # Commands under current namespace (matched by pattern)
  set pattern "${ns}::*"
  set cmds [lsort [info commands $pattern]]
  foreach c $cmds {
    puts "${indent}  [string range $c 0 end]"
  }

  # Recursively traverse child namespaces
  set children [lsort [namespace children $ns]]
  foreach child $children {
    or_list_ns_cmds $child "${indent}  "
  }
}

# Robust density calculator
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

# Utility: delete instances by matching master name
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

# ------------------------------------------------------------
# OpenROAD: dont_use & FastRoute
# ------------------------------------------------------------
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
    # puts "set_dont_use $c"
  }
}

# A full 3D optimization stage may switch between upper and bottom inside one
# OpenROAD process. Clear the previous tier's library mask before installing
# the next one; otherwise the second repair pass has no legal tier cell left.
proc _unset_dont_use {cells} {
  if {![llength $cells]} { return }
  if {![llength [info commands unset_dont_use]]} {
    error "OpenROAD does not provide unset_dont_use; cannot switch tier repair libraries safely"
  }
  foreach c $cells {
    unset_dont_use $c
  }
}

proc _configure_tier_dont_use {tier dnu_up dnu_bottom} {
  set tier [string tolower $tier]
  if {$tier ni {upper bottom}} {
    error "_configure_tier_dont_use: tier must be upper or bottom"
  }

  _unset_dont_use [lsort -unique [concat $dnu_up $dnu_bottom]]
  if {[info exists ::env(DONT_USE_CELLS)] && $::env(DONT_USE_CELLS) ne ""} {
    _set_dont_use [_expand_libcells $::env(DONT_USE_CELLS)]
  }
  if {$tier eq "upper"} {
    _set_dont_use $dnu_up
  } else {
    _set_dont_use $dnu_bottom
  }
}

# FastRoute fallback setup (can be overridden by external Tcl)
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

proc pin3d_macro_place_halo_for_tier {tier} {
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
    return [list 0.0 0.0]
  }

  switch -- [llength $values] {
    1 {
      set halo_x [expr {double([lindex $values 0])}]
      set halo_y $halo_x
    }
    2 {
      set halo_x [expr {double([lindex $values 0])}]
      set halo_y [expr {double([lindex $values 1])}]
    }
    default {
      if {$tier_var ne "" && [info exists ::env($tier_var)] && $::env($tier_var) ne ""} {
        error "ERROR: $tier_var must have 1 or 2 values, got '$::env($tier_var)'"
      }
      error "ERROR: MACRO_PLACE_HALO must have 1 or 2 values, got '$::env(MACRO_PLACE_HALO)'"
    }
  }

  if {$halo_x < 0.0 || $halo_y < 0.0} {
    if {$tier_var ne "" && [info exists ::env($tier_var)] && $::env($tier_var) ne ""} {
      error "ERROR: $tier_var must be >= 0, got '$::env($tier_var)'"
    }
    error "ERROR: MACRO_PLACE_HALO must be >= 0, got '$::env(MACRO_PLACE_HALO)'"
  }

  return [list $halo_x $halo_y]
}

proc or_rebuild_rows_for_site {new_site tier} {
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
  if { [find_macros] != "" } {
    lassign [pin3d_macro_place_halo_for_tier $tier] halo_x halo_y
    set halo_max [expr max($halo_x, $halo_y)]
    set blockage_width $halo_max
    if {[info exists ::env(PIN3D_REBUILD_ROW_BLOCKAGE_HALO)] && $::env(PIN3D_REBUILD_ROW_BLOCKAGE_HALO) ne ""} {
      set override_vals $::env(PIN3D_REBUILD_ROW_BLOCKAGE_HALO)
      switch -- [llength $override_vals] {
        1 {
          set blockage_width [expr {double([lindex $override_vals 0])}]
        }
        2 {
          set bx [expr {double([lindex $override_vals 0])}]
          set by [expr {double([lindex $override_vals 1])}]
          set blockage_width [expr {max($bx, $by)}]
        }
        default {
          error "ERROR: PIN3D_REBUILD_ROW_BLOCKAGE_HALO must have 1 or 2 values, got '$::env(PIN3D_REBUILD_ROW_BLOCKAGE_HALO)'"
        }
      }
      if {$blockage_width < 0.0} {
        error "ERROR: PIN3D_REBUILD_ROW_BLOCKAGE_HALO must be >= 0, got $blockage_width"
      }
      puts "INFO: or_rebuild_rows_for_site uses override blockage halo $blockage_width um for tier '$tier'"
    }
    source $::env(OPENROAD_SCRIPTS_DIR)/placement_blockages.tcl
    clear_channels
    block_channels $blockage_width $tier
  }
  # make_rows will rebuild rows (and clear existing ones internally)
  make_rows -core_area [list $core_lx $core_ly $core_ux $core_uy] -site $new_site
}

proc _normalize_allow_net_class {raw_class} {
  set key [string tolower [string trim $raw_class]]
  switch -- $key {
    "" -
    "all" -
    "none" -
    "off" -
    "disabled" {
      return "all"
    }
    "upper" -
    "upper-only" -
    "upper_only" {
      return "upper_only"
    }
    "bottom" -
    "bottom-only" -
    "bottom_only" {
      return "bottom_only"
    }
    default {
      error "Unknown allow_net '$raw_class'. Use upper-only / bottom-only / all."
    }
  }
}

proc _format_allow_net_class {allow_net} {
  switch -- $allow_net {
    "upper_only" { return "upper-only" }
    "bottom_only" { return "bottom-only" }
    default { return "all" }
  }
}

proc _or_pin3d_flow_switch_mode {env_name default_mode} {
  set raw_value $default_mode
  if {[info exists ::env($env_name)] && $::env($env_name) ne ""} {
    set raw_value $::env($env_name)
  }
  set key [string tolower [string trim $raw_value]]
  switch -- $key {
    "" -
    "1" -
    "on" -
    "true" -
    "yes" -
    "enabled" {
      return "on"
    }
    "0" -
    "off" -
    "false" -
    "no" -
    "disabled" {
      return "off"
    }
    default {
      error "Unknown ${env_name} value '$raw_value'. Use on/off."
    }
  }
}

proc pin3d_allow_net_flow_mode {} {
  return [_or_pin3d_flow_switch_mode "PIN3D_ALLOW_NET_FLOW" "on"]
}

proc pin3d_allow_net_flow_enabled {} {
  expr {[pin3d_allow_net_flow_mode] eq "on"}
}

proc pin3d_split_net_flow_mode {} {
  return [_or_pin3d_flow_switch_mode "PIN3D_SPLIT_NET_FLOW" "on"]
}

proc pin3d_split_net_flow_enabled {} {
  expr {[pin3d_split_net_flow_mode] eq "on"}
}

proc or_cts_owner_tier {} {
  set cts_layer "bottom"
  if {[info exists ::env(CTS_LAYER)] && $::env(CTS_LAYER) ne ""} {
    set cts_layer [string tolower $::env(CTS_LAYER)]
  }
  if {$cts_layer ne "upper" && $cts_layer ne "bottom"} {
    error "CTS_LAYER must be upper or bottom, got '$cts_layer'"
  }
  return $cts_layer
}

proc or_cts_fix_tier {} {
  if {[or_cts_owner_tier] eq "upper"} {
    return "bottom"
  }
  return "upper"
}

proc _requested_allow_net_class_with_default {default_class quiet} {
  set raw_class $default_class
  if {[info exists ::env(TIER_ALLOW_NET)] && $::env(TIER_ALLOW_NET) ne ""} {
    set raw_class $::env(TIER_ALLOW_NET)
  } elseif {[info exists ::env(ALLOW_NET)] && $::env(ALLOW_NET) ne ""} {
    set raw_class $::env(ALLOW_NET)
  }

  set active_class [_normalize_allow_net_class $raw_class]
  if {!$quiet} {
    puts "INFO(OR): Requested allow_net '$raw_class' -> $active_class"
  }
  return $active_class
}

proc _effective_allow_net_class {requested_class {quiet 0}} {
  set requested_class [_normalize_allow_net_class $requested_class]
  if {![pin3d_allow_net_flow_enabled]} {
    if {!$quiet} {
      puts "INFO(OR): PIN3D_ALLOW_NET_FLOW=off -> force allow_net all"
    }
    return "all"
  }
  return $requested_class
}

proc _report_allow_net_resolution {stage_label requested_class effective_class} {
  puts "INFO(OR): ${stage_label} PIN3D_ALLOW_NET_FLOW=[pin3d_allow_net_flow_mode] requested_allow_net=[_format_allow_net_class $requested_class] effective_allow_net=[_format_allow_net_class $effective_class]"
}

proc _or_is_split_buffer_name {name} {
  set trimmed [string trim $name]
  if {[string match "*__SPLITBUF__*" $trimmed]} {
    return 1
  }
  # Backward compatibility for older result variants.
  return [expr {[string match "*SPLITBUF*" $trimmed]}]
}

proc _pin3d_split_buffer_cells {} {
  array set seen {}
  set cells {}
  foreach pattern [list "*__SPLITBUF__*" "*__SPLITBUF*"] {
    foreach cell_obj [get_cells -hierarchical -quiet $pattern] {
      if {[info exists seen($cell_obj)]} {
        continue
      }
      set seen($cell_obj) 1
      lappend cells $cell_obj
    }
  }
  return $cells
}

proc _split_branch_name_match {name} {
  set name [string trim $name]
  return [expr {[string match "*__BRANCH*" $name] || [string match "*__BRIDGE*" $name]}]
}

proc pin3d_split_manifest_path {{results_dir ""}} {
  if {$results_dir eq ""} {
    set results_dir [_get RESULTS_DIR]
  }
  return [file join $results_dir "pin3d_split_manifest.list"]
}

proc pin3d_write_split_manifest {records {manifest_path ""}} {
  if {$manifest_path eq ""} {
    set manifest_path [pin3d_split_manifest_path]
  }
  set fh [open $manifest_path w]
  puts $fh "# PIN3D split manifest"
  puts $fh "# format: Tcl list per line => record <dict>"
  foreach record $records {
    puts $fh [list record $record]
  }
  close $fh
  return $manifest_path
}

proc pin3d_read_split_manifest {{manifest_path ""}} {
  if {$manifest_path eq ""} {
    set manifest_path [pin3d_split_manifest_path]
  }
  if {![file exists $manifest_path]} {
    return {}
  }

  set records {}
  set fh [open $manifest_path r]
  while {[gets $fh line] >= 0} {
    set trimmed [string trim $line]
    if {$trimmed eq "" || [string match "#*" $trimmed]} {
      continue
    }
    if {[catch {lassign $trimmed tag payload}]} {
      continue
    }
    if {$tag ne "record" || $payload eq ""} {
      continue
    }
    lappend records $payload
  }
  close $fh
  return $records
}

proc _pin3d_record_list_field {record key} {
  if {![dict exists $record $key]} {
    return {}
  }
  return [dict get $record $key]
}

proc _pin3d_is_split_pin_ref {name} {
  return [expr {[_or_is_split_buffer_name $name] && [string first "/" $name] >= 0}]
}

proc _pin3d_record_has_placeholder_split_refs {record} {
  foreach key {moved_sinks retained_sinks} {
    foreach sink_name [_pin3d_record_list_field $record $key] {
      if {[_pin3d_is_split_pin_ref $sink_name]} {
        return 1
      }
    }
  }
  return 0
}

proc _pin3d_rebuild_name_caches {} {
  unset -nocomplain ::_PIN3D_INST_CACHE ::_PIN3D_NET_CACHE ::_PIN3D_ITERM_CACHE

  array set ::_PIN3D_INST_CACHE {}
  array set ::_PIN3D_NET_CACHE {}
  array set ::_PIN3D_ITERM_CACHE {}

  set block [ord::get_db_block]
  foreach inst [$block getInsts] {
    set inst_name [$inst getName]
    set ::_PIN3D_INST_CACHE($inst_name) $inst
    foreach iterm [$inst getITerms] {
      set full_name "[[$iterm getInst] getName]/[[$iterm getMTerm] getName]"
      set ::_PIN3D_ITERM_CACHE($full_name) $iterm
    }
  }
  foreach net [$block getNets] {
    set ::_PIN3D_NET_CACHE([$net getName]) $net
  }
}

proc _pin3d_find_inst_by_name {inst_name} {
  if {[info exists ::_PIN3D_INST_CACHE($inst_name)]} {
    return $::_PIN3D_INST_CACHE($inst_name)
  }
  set block [ord::get_db_block]
  foreach inst [$block getInsts] {
    if {[$inst getName] eq $inst_name} {
      set ::_PIN3D_INST_CACHE($inst_name) $inst
      return $inst
    }
  }
  return ""
}

proc _pin3d_find_net_by_name {net_name} {
  if {[info exists ::_PIN3D_NET_CACHE($net_name)]} {
    return $::_PIN3D_NET_CACHE($net_name)
  }
  set block [ord::get_db_block]
  foreach net [$block getNets] {
    if {[$net getName] eq $net_name} {
      set ::_PIN3D_NET_CACHE($net_name) $net
      return $net
    }
  }
  return ""
}

proc _pin3d_iterm_full_name {iterm} {
  return "[[$iterm getInst] getName]/[[$iterm getMTerm] getName]"
}

proc _pin3d_find_iterm_by_name {full_name} {
  if {[info exists ::_PIN3D_ITERM_CACHE($full_name)]} {
    return $::_PIN3D_ITERM_CACHE($full_name)
  }
  set slash_idx [string last "/" $full_name]
  if {$slash_idx < 0} {
    return ""
  }
  set inst_name [string range $full_name 0 [expr {$slash_idx - 1}]]
  set pin_name [string range $full_name [expr {$slash_idx + 1}] end]
  set inst [_pin3d_find_inst_by_name $inst_name]
  if {$inst eq ""} {
    return ""
  }
  set iterm [$inst findITerm $pin_name]
  if {$iterm ne "" && $iterm ne "NULL"} {
    set ::_PIN3D_ITERM_CACHE($full_name) $iterm
  }
  return $iterm
}

proc _pin3d_iterm_net {iterm} {
  if {$iterm eq "" || $iterm eq "NULL"} {
    return ""
  }
  if {[catch {set net [$iterm getNet]}]} {
    return ""
  }
  if {$net eq "" || $net eq "NULL"} {
    return ""
  }
  return $net
}

proc _pin3d_iterm_net_name {iterm} {
  set net [_pin3d_iterm_net $iterm]
  if {$net eq ""} {
    return ""
  }
  return [$net getName]
}

proc _pin3d_safe_sigtype_from_mterm {mterm} {
  if {[catch {set sig_type [$mterm getSigType]}]} {
    return "SIGNAL"
  }
  return $sig_type
}

proc _pin3d_safe_iotype_from_mterm {mterm} {
  if {[catch {set io_type [$mterm getIoType]}]} {
    return ""
  }
  return $io_type
}

proc _pin3d_buffer_master_usable {master_name} {
  if {![regexp -nocase -- {^buf} $master_name]} {
    return 0
  }
  if {[regexp -nocase -- {^(clkbuf|tbuf)} $master_name]} {
    return 0
  }
  return 1
}

proc _pin3d_master_signal_io_summary {master} {
  set input_name ""
  set output_name ""
  set input_count 0
  set output_count 0
  foreach mterm [$master getMTerms] {
    set sig_type [_pin3d_safe_sigtype_from_mterm $mterm]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
      continue
    }
    switch -- [_pin3d_safe_iotype_from_mterm $mterm] {
      INPUT {
        incr input_count
        set input_name [$mterm getName]
      }
      OUTPUT {
        incr output_count
        set output_name [$mterm getName]
      }
      INOUT {
        return [list -1 -1 "" ""]
      }
    }
  }
  return [list $input_count $output_count $input_name $output_name]
}

proc _pin3d_buffer_inst_io {inst {allow_split_tag 0}} {
  if {$inst eq "" || $inst eq "NULL"} {
    return ""
  }
  set inst_name [$inst getName]
  set master [$inst getMaster]
  set master_name [$master getName]
  set is_split_tagged [_or_is_split_buffer_name $inst_name]
  if {!$allow_split_tag && $is_split_tagged} {
    return ""
  }
  if {!$is_split_tagged && ![_pin3d_buffer_master_usable $master_name]} {
    return ""
  }
  lassign [_pin3d_master_signal_io_summary $master] input_count output_count input_name output_name
  if {$input_count != 1 || $output_count != 1 || $input_name eq "" || $output_name eq ""} {
    return ""
  }
  set input_iterm [$inst findITerm $input_name]
  set output_iterm [$inst findITerm $output_name]
  if {$input_iterm eq "" || $output_iterm eq ""} {
    return ""
  }
  return [dict create \
    input $input_iterm \
    output $output_iterm \
    input_name $input_name \
    output_name $output_name \
    master_name $master_name \
    inst_name $inst_name]
}

proc _pin3d_buffer_drive_score {master_name} {
  set score 999999
  if {[regexp -nocase -- {[_x]([0-9]+)[a-z]*(?:_|$)} $master_name -> drive]} {
    set score $drive
  }
  return $score
}

proc _pin3d_next_power_of_two {value} {
  if {$value <= 1} {
    return 1
  }
  set power 1
  while {$power < $value} {
    set power [expr {$power * 2}]
  }
  return $power
}

proc _pin3d_required_buffer_drive_score {moved_sink_count} {
  set per_drive_unit 24
  if {[info exists ::env(PIN3D_SPLIT_FANOUT_PER_DRIVE)] && $::env(PIN3D_SPLIT_FANOUT_PER_DRIVE) ne ""} {
    set per_drive_unit $::env(PIN3D_SPLIT_FANOUT_PER_DRIVE)
  }
  if {$per_drive_unit < 1} {
    set per_drive_unit 24
  }
  set units [expr {int(ceil(double(max($moved_sink_count, 1)) / double($per_drive_unit)))}]
  return [_pin3d_next_power_of_two $units]
}

proc _pin3d_choose_tier_buffer_master {tier {preferred_master ""} {moved_sink_count 1}} {
  set candidates {}
  set db [ord::get_db]
  foreach lib [::odb::dbDatabase_getLibs $db] {
    foreach master [::odb::dbLib_getMasters $lib] {
      if {![master_has_site $master]} {
        continue
      }
      set master_name [$master getName]
      if {![_pin3d_buffer_master_usable $master_name]} {
        continue
      }
      if {$tier eq "upper"} {
        if {![string match "*_upper" $master_name]} {
          continue
        }
      } else {
        if {![string match "*_bottom" $master_name] && ![string match "*_lower" $master_name]} {
          continue
        }
      }
      lassign [_pin3d_master_signal_io_summary $master] input_count output_count input_name output_name
      if {$input_count == 1 && $output_count == 1 && $input_name ne "" && $output_name ne ""} {
        lappend candidates [list [_pin3d_buffer_drive_score $master_name] $master_name]
      }
    }
  }
  if {[llength $candidates] == 0} {
    return ""
  }
  set sorted [lsort -integer -index 0 [lsort -dictionary -index 1 $candidates]]
  set required_drive [_pin3d_required_buffer_drive_score $moved_sink_count]
  if {$preferred_master ne ""} {
    foreach item $sorted {
      if {[lindex $item 1] eq $preferred_master} {
        return $preferred_master
      }
    }
  }
  foreach item $sorted {
    if {[lindex $item 0] >= $required_drive} {
      return [lindex $item 1]
    }
  }
  return [lindex [lindex $sorted end] 1]
}

proc _pin3d_same_tier_buffer_reachable {inst split_tier} {
  if {$inst eq "" || $inst eq "NULL"} {
    return ""
  }
  set inst_tier [_or_inst_tier $inst]
  if {$inst_tier ne $split_tier} {
    return ""
  }
  return [_pin3d_buffer_inst_io $inst 0]
}

proc _pin3d_collect_downstream_branch_domain {branch_net split_tier} {
  array set seen_nets {}
  array set seen_buffers {}
  array set sink_lookup {}
  set branch_nets {}
  set cross_tier_branch_nets {}
  set queue [list $branch_net]

  while {[llength $queue] > 0} {
    set net [lindex $queue 0]
    set queue [lrange $queue 1 end]
    if {$net eq "" || $net eq "NULL"} {
      continue
    }
    set net_name [$net getName]
    if {[info exists seen_nets($net_name)]} {
      continue
    }
    set seen_nets($net_name) 1
    lappend branch_nets $net_name

    lassign [tier_net_structural_presence_detail_counts $net] upper_count bottom_count io_count unknown_count
    set category [_cross_tier_category_from_presence \
      [expr {$upper_count > 0}] \
      [expr {$bottom_count > 0}] \
      [expr {$io_count > 0}] \
      [expr {$unknown_count > 0}]]
    if {$category ne "" && $category ne "Unknown_Tier"} {
      lappend cross_tier_branch_nets $net_name
    }

    foreach iterm [$net getITerms] {
      set mterm [$iterm getMTerm]
      set sig_type [_pin3d_safe_sigtype_from_mterm $mterm]
      if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
        continue
      }
      if {[_pin3d_safe_iotype_from_mterm $mterm] ne "INPUT"} {
        continue
      }

      set inst [$iterm getInst]
      set buffer_info [_pin3d_same_tier_buffer_reachable $inst $split_tier]
      if {$buffer_info ne ""} {
        set inst_name [$inst getName]
        if {![info exists seen_buffers($inst_name)]} {
          set seen_buffers($inst_name) 1
        }
        set out_net [_pin3d_iterm_net [dict get $buffer_info output]]
        if {$out_net ne ""} {
          lappend queue $out_net
        }
        continue
      }
      set sink_lookup([_pin3d_iterm_full_name $iterm]) 1
    }
  }

  return [dict create \
    sink_names [lsort [array names sink_lookup]] \
    branch_nets [lsort -unique $branch_nets] \
    branch_cross_tier_nets [lsort -unique $cross_tier_branch_nets] \
    branch_buffers [lsort [array names seen_buffers]]]
}

proc _pin3d_find_bterm_by_name {bterm_name} {
  set block [ord::get_db_block]
  if {![catch {set bterm [$block findBTerm $bterm_name]}] && $bterm ne "" && $bterm ne "NULL"} {
    return $bterm
  }
  foreach bterm [$block getBTerms] {
    if {[$bterm getName] eq $bterm_name} {
      return $bterm
    }
  }
  return ""
}

proc _pin3d_driver_net_from_split_record {record} {
  set driver_kind iterm
  if {[dict exists $record driver_kind]} {
    set driver_kind [dict get $record driver_kind]
  }
  set driver_pin [dict get $record driver_pin]
  if {$driver_kind eq "bterm"} {
    set driver_obj [_pin3d_find_bterm_by_name $driver_pin]
  } else {
    set driver_obj [_pin3d_find_iterm_by_name $driver_pin]
  }
  if {$driver_obj eq "" || $driver_obj eq "NULL"} {
    return ""
  }
  if {[catch {set driver_net [$driver_obj getNet]}] || $driver_net eq "" || $driver_net eq "NULL"} {
    return ""
  }
  return $driver_net
}

proc _pin3d_domain_wrong_tier_nets {net_names expected_tier} {
  set wrong {}
  foreach net_name $net_names {
    set net [_pin3d_find_net_by_name $net_name]
    if {$net eq "" || $net eq "NULL"} {
      continue
    }
    lassign [tier_net_structural_presence_detail_counts $net] upper_count bottom_count io_count unknown_count
    if {$expected_tier eq "upper"} {
      set invalid [expr {$bottom_count > 0 || $unknown_count > 0}]
    } else {
      set invalid [expr {$upper_count > 0 || $unknown_count > 0}]
    }
    if {$invalid} {
      lappend wrong $net_name
    }
  }
  return [lsort -unique $wrong]
}

proc _pin3d_validate_dual_boundary_entry {record} {
  foreach key {split_src_inst split_dst_inst bridge_net source_tier destination_tier moved_sinks retained_sinks driver_pin} {
    if {![dict exists $record $key]} {
      return [dict create status violated reason "dual_manifest_missing_${key}"]
    }
  }

  set source_tier [dict get $record source_tier]
  set destination_tier [dict get $record destination_tier]
  set src_inst [_pin3d_find_inst_by_name [dict get $record split_src_inst]]
  set dst_inst [_pin3d_find_inst_by_name [dict get $record split_dst_inst]]
  if {$src_inst eq ""} {
    return [dict create status violated reason source_boundary_buffer_missing]
  }
  if {$dst_inst eq ""} {
    return [dict create status violated reason destination_boundary_buffer_missing]
  }
  set src_info [_pin3d_buffer_inst_io $src_inst 1]
  set dst_info [_pin3d_buffer_inst_io $dst_inst 1]
  if {$src_info eq "" || $dst_info eq ""} {
    return [dict create status violated reason boundary_buffer_invalid]
  }
  if {[_or_split_buffer_physical_tier $src_inst] ne $source_tier} {
    return [dict create status violated reason source_boundary_buffer_tier_mismatch]
  }
  if {[_or_split_buffer_physical_tier $dst_inst] ne $destination_tier} {
    return [dict create status violated reason destination_boundary_buffer_tier_mismatch]
  }

  set bridge_net [_pin3d_iterm_net [dict get $src_info output]]
  set dst_input_net [_pin3d_iterm_net [dict get $dst_info input]]
  if {$bridge_net eq "" || $dst_input_net ne $bridge_net} {
    return [dict create status violated reason bridge_endpoint_connection_invalid]
  }
  if {[$bridge_net getName] ne [dict get $record bridge_net]} {
    return [dict create status violated reason bridge_net_identity_changed]
  }
  set bridge_signal_iterms 0
  foreach iterm [$bridge_net getITerms] {
    set sig_type [_pin3d_safe_sigtype_from_mterm [$iterm getMTerm]]
    if {$sig_type ne "POWER" && $sig_type ne "GROUND"} {
      incr bridge_signal_iterms
    }
  }
  set bridge_bterms 0
  catch {set bridge_bterms [llength [$bridge_net getBTerms]]}
  if {$bridge_signal_iterms != 2 || $bridge_bterms != 0} {
    return [dict create status violated reason bridge_not_point_to_point]
  }

  set driver_net [_pin3d_driver_net_from_split_record $record]
  if {$driver_net eq ""} {
    return [dict create status violated reason driver_or_driver_net_missing]
  }
  set source_domain [_pin3d_collect_downstream_branch_domain $driver_net $source_tier]
  set source_reachable [dict get $source_domain sink_names]
  set source_boundary_sink [_pin3d_iterm_full_name [dict get $src_info input]]
  set missing_source_boundary [_list_minus [list $source_boundary_sink] $source_reachable]
  set missing_source [_list_minus [dict get $record retained_sinks] $source_reachable]
  set wrong_source_nets [_pin3d_domain_wrong_tier_nets [dict get $source_domain branch_nets] $source_tier]

  set destination_root [_pin3d_iterm_net [dict get $dst_info output]]
  if {$destination_root eq ""} {
    return [dict create status violated reason destination_local_root_missing]
  }
  set destination_domain [_pin3d_collect_downstream_branch_domain $destination_root $destination_tier]
  set destination_reachable [dict get $destination_domain sink_names]
  set missing_moved [_list_minus [dict get $record moved_sinks] $destination_reachable]
  set leaked_retained {}
  foreach retained_sink [dict get $record retained_sinks] {
    if {[lsearch -exact $destination_reachable $retained_sink] >= 0} {
      lappend leaked_retained $retained_sink
    }
  }
  set wrong_destination_nets [_pin3d_domain_wrong_tier_nets [dict get $destination_domain branch_nets] $destination_tier]

  set details [dict create \
    missing_source_boundary $missing_source_boundary \
    missing_source $missing_source \
    missing_moved $missing_moved \
    leaked_retained $leaked_retained \
    source_wrong_tier_nets $wrong_source_nets \
    destination_wrong_tier_nets $wrong_destination_nets \
    source_buffers [dict get $source_domain branch_buffers] \
    destination_buffers [dict get $destination_domain branch_buffers]]
  # Resizer may legally swap equivalent gate inputs, clone logic, or move loads
  # between same-tier trees.  Manifest sink identities therefore become stale
  # after repair_timing.  The immutable contract is the source-buffer input,
  # the point-to-point bridge, a non-empty destination domain, and tier purity.
  if {[llength $missing_source_boundary] > 0} {
    return [dict merge [dict create status violated reason source_boundary_not_reachable] $details]
  }
  if {[llength $wrong_source_nets] > 0} {
    return [dict merge [dict create status violated reason source_local_tree_crosses_tier] $details]
  }
  if {[llength $wrong_destination_nets] > 0} {
    return [dict merge [dict create status violated reason destination_local_tree_crosses_tier] $details]
  }
  if {[llength $destination_reachable] == 0} {
    return [dict merge [dict create status violated reason destination_local_domain_empty] $details]
  }

  set direct_topology 1
  if {[_pin3d_iterm_net_name [dict get $src_info input]] ne [dict get $record original_net]} {
    set direct_topology 0
  }
  if {[dict exists $record branch_net] && [_pin3d_iterm_net_name [dict get $dst_info output]] ne [dict get $record branch_net]} {
    set direct_topology 0
  }
  if {[llength [dict get $source_domain branch_buffers]] > 0 || [llength [dict get $destination_domain branch_buffers]] > 0} {
    set direct_topology 0
  }
  if {[llength $missing_source] > 0 || [llength $missing_moved] > 0 || [llength $leaked_retained] > 0} {
    set direct_topology 0
  }
  if {$direct_topology} {
    return [dict merge [dict create status valid reason direct_dual_boundary_preserved] $details]
  }
  set rewrite_reason dual_boundary_with_local_buffer_trees
  if {[llength $missing_source] > 0 || [llength $missing_moved] > 0 || [llength $leaked_retained] > 0} {
    set rewrite_reason dual_boundary_with_local_logic_rewrite
  }
  return [dict merge [dict create status equivalent reason $rewrite_reason] $details]
}

proc _pin3d_validate_split_entry {record} {
  if {[dict exists $record record_type] && [dict get $record record_type] eq "dual_boundary"} {
    return [_pin3d_validate_dual_boundary_entry $record]
  }
  set split_tier [dict get $record buffer_tier]
  set split_inst_name [dict get $record split_inst]
  set original_net_name [dict get $record original_net]
  set original_net [_pin3d_find_net_by_name $original_net_name]
  set split_inst [_pin3d_find_inst_by_name $split_inst_name]
  set split_info ""
  set literal_split_boundary 0
  if {$split_inst ne ""} {
    set split_info [_pin3d_buffer_inst_io $split_inst 1]
    if {$split_info ne ""} {
      set literal_split_boundary 1
    }
  }

  set branch_net ""
  if {$literal_split_boundary} {
    set branch_net [_pin3d_iterm_net [dict get $split_info output]]
  }
  if {$branch_net eq "" && [dict exists $record branch_net]} {
    set branch_net [_pin3d_find_net_by_name [dict get $record branch_net]]
  }
  if {$branch_net eq ""} {
    if {$split_inst eq ""} {
      return [dict create status violated reason split_buffer_missing]
    }
    if {$split_info eq ""} {
      return [dict create status violated reason split_buffer_invalid]
    }
    return [dict create status violated reason split_branch_missing]
  }

  set branch_domain [_pin3d_collect_downstream_branch_domain $branch_net $split_tier]
  set reachable_sinks [dict get $branch_domain sink_names]
  set branch_cross_tier_nets [dict get $branch_domain branch_cross_tier_nets]
  set branch_buffers [dict get $branch_domain branch_buffers]

  set moved_sinks [_pin3d_record_list_field $record moved_sinks]
  set retained_sinks [_pin3d_record_list_field $record retained_sinks]
  set manifest_recovered 0
  if {[_pin3d_record_has_placeholder_split_refs $record]} {
    set moved_sinks $reachable_sinks
    set retained_sinks {}
    set manifest_recovered 1
  }
  set missing_moved [_list_minus $moved_sinks $reachable_sinks]
  set leaked_retained {}
  foreach retained_sink $retained_sinks {
    if {[lsearch -exact $reachable_sinks $retained_sink] >= 0} {
      lappend leaked_retained $retained_sink
    }
  }

  set driver_net_name ""
  set driver_iterm [_pin3d_find_iterm_by_name [dict get $record driver_pin]]
  if {$driver_iterm ne ""} {
    set driver_net_name [_pin3d_iterm_net_name $driver_iterm]
  }
  set moved_on_driver {}
  if {$driver_net_name ne ""} {
    foreach moved_sink $moved_sinks {
      set moved_iterm [_pin3d_find_iterm_by_name $moved_sink]
      if {$moved_iterm eq ""} {
        continue
      }
      if {[_pin3d_iterm_net_name $moved_iterm] eq $driver_net_name} {
        lappend moved_on_driver $moved_sink
      }
    }
  }

  set direct_branch_sinks {}
  set branch_net_name [$branch_net getName]
  foreach moved_sink $moved_sinks {
    set moved_iterm [_pin3d_find_iterm_by_name $moved_sink]
    if {$moved_iterm eq ""} {
      continue
    }
    if {[_pin3d_iterm_net_name $moved_iterm] eq $branch_net_name} {
      lappend direct_branch_sinks $moved_sink
    }
  }

  set original_net_mixed_fanout 0
  if {$original_net ne "" && $original_net ne "NULL"} {
    set original_net_mixed_fanout [net_has_mixed_fanout $original_net]
  }
  set branch_net_mixed_fanout [net_has_mixed_fanout $branch_net]

  if {[llength $missing_moved] > 0} {
    return [dict create \
      status violated \
      reason moved_sinks_not_reachable \
      manifest_recovered $manifest_recovered \
      missing_moved $missing_moved \
      leaked_retained $leaked_retained \
      moved_on_driver $moved_on_driver \
      original_net_mixed_fanout $original_net_mixed_fanout \
      branch_net_mixed_fanout $branch_net_mixed_fanout \
      branch_cross_tier_nets $branch_cross_tier_nets \
      branch_buffers $branch_buffers]
  }
  if {[llength $leaked_retained] > 0} {
    return [dict create \
      status violated \
      reason retained_sinks_leaked_to_branch \
      manifest_recovered $manifest_recovered \
      missing_moved $missing_moved \
      leaked_retained $leaked_retained \
      moved_on_driver $moved_on_driver \
      original_net_mixed_fanout $original_net_mixed_fanout \
      branch_net_mixed_fanout $branch_net_mixed_fanout \
      branch_cross_tier_nets $branch_cross_tier_nets \
      branch_buffers $branch_buffers]
  }
  if {[llength $moved_on_driver] > 0} {
    return [dict create \
      status violated \
      reason moved_sinks_still_on_driver_net \
      manifest_recovered $manifest_recovered \
      missing_moved $missing_moved \
      leaked_retained $leaked_retained \
      moved_on_driver $moved_on_driver \
      original_net_mixed_fanout $original_net_mixed_fanout \
      branch_net_mixed_fanout $branch_net_mixed_fanout \
      branch_cross_tier_nets $branch_cross_tier_nets \
      branch_buffers $branch_buffers]
  }
  if {$original_net_mixed_fanout} {
    return [dict create \
      status violated \
      reason original_net_still_mixed_fanout \
      manifest_recovered $manifest_recovered \
      missing_moved $missing_moved \
      leaked_retained $leaked_retained \
      moved_on_driver $moved_on_driver \
      original_net_mixed_fanout $original_net_mixed_fanout \
      branch_net_mixed_fanout $branch_net_mixed_fanout \
      branch_cross_tier_nets $branch_cross_tier_nets \
      branch_buffers $branch_buffers]
  }
  if {$branch_net_mixed_fanout} {
    return [dict create \
      status violated \
      reason branch_net_still_mixed_fanout \
      manifest_recovered $manifest_recovered \
      missing_moved $missing_moved \
      leaked_retained $leaked_retained \
      moved_on_driver $moved_on_driver \
      original_net_mixed_fanout $original_net_mixed_fanout \
      branch_net_mixed_fanout $branch_net_mixed_fanout \
      branch_cross_tier_nets $branch_cross_tier_nets \
      branch_buffers $branch_buffers]
  }
  if {[llength $branch_cross_tier_nets] > 0} {
    return [dict create \
      status violated \
      reason extra_cross_tier_branch \
      manifest_recovered $manifest_recovered \
      missing_moved $missing_moved \
      leaked_retained $leaked_retained \
      moved_on_driver $moved_on_driver \
      original_net_mixed_fanout $original_net_mixed_fanout \
      branch_net_mixed_fanout $branch_net_mixed_fanout \
      branch_cross_tier_nets $branch_cross_tier_nets \
      branch_buffers $branch_buffers]
  }

  if {!$literal_split_boundary} {
    return [dict create \
      status equivalent \
      reason [expr {$manifest_recovered ? "manifest_recovered_same_tier" : "split_buffer_rewritten_same_tier"}] \
      manifest_recovered $manifest_recovered \
      missing_moved {} \
      leaked_retained {} \
      moved_on_driver {} \
      original_net_mixed_fanout 0 \
      branch_net_mixed_fanout 0 \
      branch_cross_tier_nets {} \
      branch_buffers $branch_buffers]
  }

  if {[llength $branch_buffers] > 0 || [llength $direct_branch_sinks] != [llength $moved_sinks]} {
    return [dict create \
      status equivalent \
      reason [expr {$manifest_recovered ? "manifest_recovered_branch_rewritten" : "branch_rewritten_same_tier"}] \
      manifest_recovered $manifest_recovered \
      missing_moved {} \
      leaked_retained {} \
      moved_on_driver {} \
      original_net_mixed_fanout 0 \
      branch_net_mixed_fanout 0 \
      branch_cross_tier_nets {} \
      branch_buffers $branch_buffers]
  }

  return [dict create \
    status valid \
    reason [expr {$manifest_recovered ? "manifest_recovered_direct_split_preserved" : "direct_split_preserved"}] \
    manifest_recovered $manifest_recovered \
    missing_moved {} \
    leaked_retained {} \
    moved_on_driver {} \
    original_net_mixed_fanout 0 \
    branch_net_mixed_fanout 0 \
    branch_cross_tier_nets {} \
    branch_buffers {}]
}

proc _pin3d_anchor_inst_for_split_repair {driver_iterm moved_iterms} {
  if {[llength $moved_iterms] > 0} {
    return [[lindex $moved_iterms 0] getInst]
  }
  if {$driver_iterm ne ""} {
    return [$driver_iterm getInst]
  }
  return ""
}

proc _pin3d_repair_split_entry {record {quiet 0}} {
  if {[dict exists $record record_type] && [dict get $record record_type] eq "dual_boundary"} {
    return [dict create repaired 0 reason dual_boundary_auto_repair_disabled]
  }
  set driver_iterm [_pin3d_find_iterm_by_name [dict get $record driver_pin]]
  if {$driver_iterm eq ""} {
    return [dict create repaired 0 reason driver_pin_missing]
  }
  set driver_net [_pin3d_iterm_net $driver_iterm]
  if {$driver_net eq ""} {
    return [dict create repaired 0 reason driver_net_missing]
  }

  set moved_iterms {}
  foreach moved_sink [dict get $record moved_sinks] {
    set moved_iterm [_pin3d_find_iterm_by_name $moved_sink]
    if {$moved_iterm ne ""} {
      lappend moved_iterms $moved_iterm
    }
  }
  if {[llength $moved_iterms] == 0} {
    return [dict create repaired 0 reason moved_sinks_missing]
  }

  set split_inst_name [dict get $record split_inst]
  set existing_split_inst [_pin3d_find_inst_by_name $split_inst_name]
  if {$existing_split_inst ne ""} {
    catch {delete_instance $split_inst_name}
  }

  set buffer_master_name [_pin3d_choose_tier_buffer_master \
    [dict get $record buffer_tier] \
    [dict get $record buffer_master] \
    [llength $moved_iterms]]
  if {$buffer_master_name eq ""} {
    return [dict create repaired 0 reason no_tier_buffer_master]
  }

  set buffer_master [_find_master_by_name $buffer_master_name]
  if {$buffer_master eq ""} {
    return [dict create repaired 0 reason buffer_master_lookup_failed]
  }

  set block [ord::get_db_block]
  set branch_net_name [dict get $record branch_net]
  set branch_net [_pin3d_find_net_by_name $branch_net_name]
  if {$branch_net eq ""} {
    set branch_net [odb::dbNet_create $block $branch_net_name]
  }
  if {$branch_net eq "" || $branch_net eq "NULL"} {
    return [dict create repaired 0 reason branch_net_create_failed]
  }

  set split_inst [odb::dbInst_create $block $buffer_master $split_inst_name]
  if {$split_inst eq "" || $split_inst eq "NULL"} {
    return [dict create repaired 0 reason split_buffer_create_failed]
  }

  set split_info [_pin3d_buffer_inst_io $split_inst 1]
  if {$split_info eq ""} {
    return [dict create repaired 0 reason split_buffer_pin_lookup_failed]
  }

  set anchor_inst [_pin3d_anchor_inst_for_split_repair $driver_iterm $moved_iterms]
  if {$anchor_inst ne ""} {
    set anchor_loc [$anchor_inst getLocation]
    $split_inst setLocation [lindex $anchor_loc 0] [lindex $anchor_loc 1]
    catch {$split_inst setOrient [$anchor_inst getOrient]}
    catch {$split_inst setPlacementStatus [$anchor_inst getPlacementStatus]}
  }

  catch {[dict get $split_info input] connect $driver_net}
  catch {[dict get $split_info output] connect $branch_net}
  foreach moved_iterm $moved_iterms {
    catch {$moved_iterm connect $branch_net}
  }

  _pin3d_rebuild_name_caches
  set post_status [_pin3d_validate_split_entry $record]
  if {[dict get $post_status status] eq "violated"} {
    return [dict create repaired 0 reason [dict get $post_status reason]]
  }
  return [dict create repaired 1 reason [dict get $post_status reason]]
}

proc pin3d_validate_and_repair_split_topology {stage_label {log_dir ""} {results_dir ""} {allow_repair ""}} {
  if {$results_dir eq ""} {
    set results_dir [_get RESULTS_DIR]
  }
  if {$log_dir eq ""} {
    set log_dir [_get LOG_DIR]
  }

  set manifest_path [pin3d_split_manifest_path $results_dir]
  set records [pin3d_read_split_manifest $manifest_path]
  if {[llength $records] == 0} {
    return [dict create manifest_present 0 total 0 valid 0 equivalent 0 violated 0 repaired 0 repair_failed 0]
  }

  set auto_repair 1
  if {[info exists ::env(PIN3D_SPLIT_AUTO_REPAIR)] && $::env(PIN3D_SPLIT_AUTO_REPAIR) ne ""} {
    set auto_repair $::env(PIN3D_SPLIT_AUTO_REPAIR)
  }
  if {$allow_repair ne ""} {
    set auto_repair $allow_repair
  }

  _pin3d_rebuild_name_caches

  set report_path [file join $log_dir "${stage_label}.split_topology.summary.rpt"]
  set fh [open $report_path w]
  puts $fh "label $stage_label"
  puts $fh "manifest_path $manifest_path"
  puts $fh "auto_repair $auto_repair"

  array set counts {
    total 0
    valid 0
    equivalent 0
    violated 0
    repaired 0
    repair_failed 0
    ignored_clock 0
  }

  array set clock_net_lookup {}
  foreach clock_net_name [_clock_net_name_set] {
    set clock_net_lookup($clock_net_name) 1
  }

  foreach record $records {
    set net_name [dict get $record original_net]
    if {[info exists clock_net_lookup($net_name)]} {
      incr counts(ignored_clock)
      puts $fh [format "split_net %s status=ignored reason=clock_net_record" $net_name]
      continue
    }
    incr counts(total)
    set status_info [_pin3d_validate_split_entry $record]
    set status [dict get $status_info status]
    set reason [dict get $status_info reason]

    if {$status eq "valid" || $status eq "equivalent"} {
      incr counts($status)
      puts $fh [format "split_net %s status=%s reason=%s" $net_name $status $reason]
      continue
    }

    incr counts(violated)
    puts $fh [format "split_net %s status=violated reason=%s" $net_name $reason]
    foreach key {missing_source missing_moved leaked_retained moved_on_driver source_wrong_tier_nets destination_wrong_tier_nets original_net_mixed_fanout branch_net_mixed_fanout branch_cross_tier_nets branch_buffers source_buffers destination_buffers} {
      if {[dict exists $status_info $key] && [llength [dict get $status_info $key]] > 0} {
        puts $fh [format "  %s %s" $key [dict get $status_info $key]]
      }
    }

    if {$auto_repair} {
      set repair_info [_pin3d_repair_split_entry $record 1]
      if {[dict get $repair_info repaired]} {
        incr counts(repaired)
        puts $fh [format "  repaired 1 reason=%s" [dict get $repair_info reason]]
      } else {
        incr counts(repair_failed)
        puts $fh [format "  repaired 0 reason=%s" [dict get $repair_info reason]]
      }
    }
  }

  foreach key {total valid equivalent violated repaired repair_failed ignored_clock} {
    puts $fh [format "%s %d" $key $counts($key)]
  }
  close $fh

  puts "INFO(OR): split topology $stage_label total=$counts(total) valid=$counts(valid) equivalent=$counts(equivalent) violated=$counts(violated) repaired=$counts(repaired) repair_failed=$counts(repair_failed) ignored_clock=$counts(ignored_clock)"
  return [dict create \
    manifest_present 1 \
    total $counts(total) \
    valid $counts(valid) \
    equivalent $counts(equivalent) \
    violated $counts(violated) \
    repaired $counts(repaired) \
    repair_failed $counts(repair_failed) \
    ignored_clock $counts(ignored_clock)]
}

proc _pin3d_split_buffer_db_insts {} {
  set block [ord::get_db_block]
  set out {}
  foreach inst [$block getInsts] {
    if {[_or_inst_tier $inst] eq "split_buffer"} {
      lappend out $inst
    }
  }
  return $out
}

proc _net_touches_split_buffer_inst {net_ptr} {
  foreach iterm [$net_ptr getITerms] {
    if {[_or_inst_tier [$iterm getInst]] eq "split_buffer"} {
      return 1
    }
  }
  return 0
}

proc _pin3d_manifest_name_set {records key} {
  array set lookup {}
  foreach record $records {
    if {![dict exists $record $key]} {
      continue
    }
    set name [string trim [dict get $record $key]]
    if {$name eq ""} {
      continue
    }
    set lookup($name) 1
  }
  return [array names lookup]
}

proc _collect_split_structure_snapshot {} {
  set manifest_records [pin3d_read_split_manifest]
  if {[llength $manifest_records] > 0} {
    set split_buffer_instances {}
    set split_branch_nets {}
    array set related_lookup {}

    foreach inst_name [concat \
      [_pin3d_manifest_name_set $manifest_records split_inst] \
      [_pin3d_manifest_name_set $manifest_records split_src_inst] \
      [_pin3d_manifest_name_set $manifest_records split_dst_inst]] {
      set inst [_pin3d_find_inst_by_name $inst_name]
      if {$inst ne "" && $inst ne "NULL"} {
        lappend split_buffer_instances $inst_name
      }
    }

    foreach net_name [_pin3d_manifest_name_set $manifest_records branch_net] {
      set net [_pin3d_find_net_by_name $net_name]
      if {$net ne "" && $net ne "NULL"} {
        lappend split_branch_nets $net_name
      }
    }

    foreach net_name [concat \
      [_pin3d_manifest_name_set $manifest_records original_net] \
      [_pin3d_manifest_name_set $manifest_records branch_net] \
      [_pin3d_manifest_name_set $manifest_records bridge_net]] {
      set net [_pin3d_find_net_by_name $net_name]
      if {$net eq "" || $net eq "NULL"} {
        continue
      }
      lassign [tier_net_structural_presence_detail_counts $net] upper_count bottom_count io_count unknown_count
      set net_type [_cross_tier_category_from_presence \
        [expr {$upper_count > 0}] \
        [expr {$bottom_count > 0}] \
        [expr {$io_count > 0}] \
        [expr {$unknown_count > 0}]]
      if {$net_type ne "" && $net_type ne "Unknown_Tier"} {
        set related_lookup($net_name) 1
      }
    }

    return [dict create \
      manifest_present 1 \
      manifest_records [llength $manifest_records] \
      split_buffer_instances [lsort -unique $split_buffer_instances] \
      split_branch_nets [lsort -unique $split_branch_nets] \
      split_related_cross_tier_nets [lsort -unique [array names related_lookup]]]
  }

  set block [ord::get_db_block]
  set split_buffer_instances {}
  set split_branch_nets {}
  set split_related_cross_tier_nets {}

  foreach inst [$block getInsts] {
    if {[_or_inst_tier $inst] eq "split_buffer"} {
      lappend split_buffer_instances [$inst getName]
    }
  }

  foreach net [$block getNets] {
    set net_name [$net getName]
    set split_related [expr {[_split_branch_name_match $net_name] || [_net_touches_split_buffer_inst $net]}]
    if {[_split_branch_name_match $net_name]} {
      lappend split_branch_nets $net_name
    }
    if {!$split_related} {
      continue
    }

    lassign [tier_net_structural_presence_detail_counts $net] upper_count bottom_count io_count unknown_count
    set net_type [_cross_tier_category_from_presence \
      [expr {$upper_count > 0}] \
      [expr {$bottom_count > 0}] \
      [expr {$io_count > 0}] \
      [expr {$unknown_count > 0}]]
    if {$net_type ne "" && $net_type ne "Unknown_Tier"} {
      lappend split_related_cross_tier_nets $net_name
    }
  }

  return [dict create \
    manifest_present 0 \
    manifest_records 0 \
    split_buffer_instances [lsort -unique $split_buffer_instances] \
    split_branch_nets [lsort -unique $split_branch_nets] \
    split_related_cross_tier_nets [lsort -unique $split_related_cross_tier_nets]]
}

proc report_split_structure_snapshot {report_path args} {
  array set opt {
    -label ""
    -quiet 0
  }
  if {([llength $args] % 2) != 0} {
    error "report_split_structure_snapshot: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "report_split_structure_snapshot: unknown option $k"
    }
    set opt($k) $v
  }

  set snapshot [_collect_split_structure_snapshot]
  set split_buffer_instances [dict get $snapshot split_buffer_instances]
  set split_branch_nets [dict get $snapshot split_branch_nets]
  set split_related_cross_tier_nets [dict get $snapshot split_related_cross_tier_nets]

  if {$report_path ne ""} {
    set fh [open $report_path w]
    puts $fh "label $opt(-label)"
    puts $fh [format "manifest_present %d" [dict get $snapshot manifest_present]]
    puts $fh [format "manifest_records %d" [dict get $snapshot manifest_records]]
    puts $fh [format "split_buffer_instances %d" [llength $split_buffer_instances]]
    puts $fh [format "split_branch_nets %d" [llength $split_branch_nets]]
    puts $fh [format "split_related_cross_tier_nets %d" [llength $split_related_cross_tier_nets]]
    foreach inst_name $split_buffer_instances {
      puts $fh "split_buffer_instance $inst_name"
    }
    foreach net_name $split_branch_nets {
      puts $fh "split_branch_net $net_name"
    }
    foreach net_name $split_related_cross_tier_nets {
      puts $fh "split_related_cross_tier_net $net_name"
    }
    close $fh
  }

  if {!$opt(-quiet)} {
    puts "INFO(OR): split snapshot $opt(-label) split_buffers=[llength $split_buffer_instances] branch_nets=[llength $split_branch_nets] split_related_cross_tier=[llength $split_related_cross_tier_nets]"
  }

  return $snapshot
}

proc _list_minus {lhs rhs} {
  array set rhs_lookup {}
  foreach item $rhs {
    set rhs_lookup($item) 1
  }
  set out {}
  foreach item $lhs {
    if {![info exists rhs_lookup($item)]} {
      lappend out $item
    }
  }
  return [lsort -unique $out]
}

proc _read_split_structure_snapshot {report_path} {
  if {$report_path eq "" || ![file exists $report_path]} {
    return ""
  }

  set manifest_present 0
  set manifest_records 0
  set split_buffer_instances {}
  set split_branch_nets {}
  set split_related_cross_tier_nets {}

  set fh [open $report_path r]
  while {[gets $fh line] >= 0} {
    if {[regexp {^manifest_present\s+(.+)$} $line -> value]} {
      set manifest_present $value
      continue
    }
    if {[regexp {^manifest_records\s+(.+)$} $line -> value]} {
      set manifest_records $value
      continue
    }
    if {[regexp {^split_buffer_instance\s+(.+)$} $line -> name]} {
      lappend split_buffer_instances $name
      continue
    }
    if {[regexp {^split_branch_net\s+(.+)$} $line -> name]} {
      lappend split_branch_nets $name
      continue
    }
    if {[regexp {^split_related_cross_tier_net\s+(.+)$} $line -> name]} {
      lappend split_related_cross_tier_nets $name
      continue
    }
  }
  close $fh

  return [dict create \
    manifest_present $manifest_present \
    manifest_records $manifest_records \
    split_buffer_instances [lsort -unique $split_buffer_instances] \
    split_branch_nets [lsort -unique $split_branch_nets] \
    split_related_cross_tier_nets [lsort -unique $split_related_cross_tier_nets]]
}

proc report_split_structure_transition {summary_path before_report after_report args} {
  array set opt {
    -label ""
    -quiet 0
  }
  if {([llength $args] % 2) != 0} {
    error "report_split_structure_transition: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "report_split_structure_transition: unknown option $k"
    }
    set opt($k) $v
  }

  set before_snapshot [_read_split_structure_snapshot $before_report]
  if {$before_snapshot eq ""} {
    set before_snapshot [report_split_structure_snapshot $before_report -label "${opt(-label)} before" -quiet $opt(-quiet)]
  }
  set after_snapshot [report_split_structure_snapshot $after_report -label "${opt(-label)} after" -quiet $opt(-quiet)]

  set before_split_buffers [dict get $before_snapshot split_buffer_instances]
  set after_split_buffers [dict get $after_snapshot split_buffer_instances]
  set before_branch_nets [dict get $before_snapshot split_branch_nets]
  set after_branch_nets [dict get $after_snapshot split_branch_nets]
  set before_split_related [dict get $before_snapshot split_related_cross_tier_nets]
  set after_split_related [dict get $after_snapshot split_related_cross_tier_nets]

  set added_split_buffers [_list_minus $after_split_buffers $before_split_buffers]
  set removed_split_buffers [_list_minus $before_split_buffers $after_split_buffers]
  set added_branch_nets [_list_minus $after_branch_nets $before_branch_nets]
  set removed_branch_nets [_list_minus $before_branch_nets $after_branch_nets]

  if {$summary_path ne ""} {
    set fh [open $summary_path w]
    puts $fh "label $opt(-label)"
    puts $fh [format "before_manifest_present %d" [dict get $before_snapshot manifest_present]]
    puts $fh [format "after_manifest_present %d" [dict get $after_snapshot manifest_present]]
    puts $fh [format "before_manifest_records %d" [dict get $before_snapshot manifest_records]]
    puts $fh [format "after_manifest_records %d" [dict get $after_snapshot manifest_records]]
    puts $fh [format "before_split_buffer_instances %d" [llength $before_split_buffers]]
    puts $fh [format "after_split_buffer_instances %d" [llength $after_split_buffers]]
    puts $fh [format "before_split_branch_nets %d" [llength $before_branch_nets]]
    puts $fh [format "after_split_branch_nets %d" [llength $after_branch_nets]]
    puts $fh [format "before_split_related_cross_tier_nets %d" [llength $before_split_related]]
    puts $fh [format "after_split_related_cross_tier_nets %d" [llength $after_split_related]]
    puts $fh [format "delta_split_buffer_instances %d" [expr {[llength $after_split_buffers] - [llength $before_split_buffers]}]]
    puts $fh [format "delta_split_branch_nets %d" [expr {[llength $after_branch_nets] - [llength $before_branch_nets]}]]
    puts $fh [format "delta_split_related_cross_tier_nets %d" [expr {[llength $after_split_related] - [llength $before_split_related]}]]
    foreach name $removed_split_buffers {
      puts $fh "removed_split_buffer_instance $name"
    }
    foreach name $added_split_buffers {
      puts $fh "added_split_buffer_instance $name"
    }
    foreach name $removed_branch_nets {
      puts $fh "removed_split_branch_net $name"
    }
    foreach name $added_branch_nets {
      puts $fh "added_split_branch_net $name"
    }
    close $fh
  }

  if {!$opt(-quiet)} {
    puts "INFO(OR): split transition $opt(-label) split_buffers=[llength $before_split_buffers]->[llength $after_split_buffers] branch_nets=[llength $before_branch_nets]->[llength $after_branch_nets]"
  }

  return [dict create before $before_snapshot after $after_snapshot]
}

proc _protect_pin3d_split_buffers {quiet {protect 1}} {
  set split_cells [_pin3d_split_buffer_cells]
  set touched 0
  set failures 0
  foreach cell_obj $split_cells {
    if {$protect} {
      if {[catch {set_dont_touch $cell_obj} err]} {
        incr failures
        if {!$quiet} {
          puts "WARN(OR): failed to protect PIN3D split buffer $cell_obj : $err"
        }
        continue
      }
    } else {
      if {[catch {unset_dont_touch $cell_obj} err]} {
        incr failures
        if {!$quiet} {
          puts "WARN(OR): failed to unprotect PIN3D split buffer $cell_obj : $err"
        }
        continue
      }
    }
    incr touched
  }
  if {!$quiet} {
    if {$protect} {
      puts "INFO(OR): Protected PIN3D split buffers count=$touched failures=$failures"
    } else {
      puts "INFO(OR): Unprotected PIN3D split buffers count=$touched failures=$failures"
    }
  }
  return $touched
}

# OpenROAD's hold repair first collects timing-violating fanouts and only
# afterwards removes dont_touch loads.  A BTerm-driven dual-boundary net can
# therefore reach insertBufferBeforeLoads with an empty load set when the
# selected fanout is a protected split buffer (RSZ-3015/RSZ-3009).  Keep setup
# repair fully enabled, but guard the immutable port-root nets during the hold
# pass so repair continues below the already-built tier-local tree instead of
# trying to alter the cross-tier boundary.
proc _pin3d_bterm_crossing_root_net_names {} {
  array set seen {}
  set net_names {}
  foreach record [pin3d_read_split_manifest] {
    if {![dict exists $record record_type] ||
        [dict get $record record_type] ne "dual_boundary" ||
        ![dict exists $record driver_kind] ||
        [dict get $record driver_kind] ne "bterm" ||
        ![dict exists $record original_net]} {
      continue
    }
    set net_name [dict get $record original_net]
    if {$net_name eq "" || [info exists seen($net_name)]} {
      continue
    }
    set seen($net_name) 1
    lappend net_names $net_name
  }
  return [lsort $net_names]
}

proc _pin3d_begin_bterm_hold_guard {net_names} {
  set saved_states [dict create]
  set protected 0
  set already_protected 0
  set failures 0
  foreach net_name $net_names {
    set net_obj [_pin3d_find_net_by_name $net_name]
    if {$net_obj eq "" || $net_obj eq "NULL"} {
      incr failures
      puts "WARN(OR): cannot resolve PIN3D BTerm port-root net $net_name"
      continue
    }
    if {[catch {set original_state [$net_obj isDoNotTouch]} err]} {
      incr failures
      puts "WARN(OR): cannot read dont_touch state for port-root net $net_name : $err"
      continue
    }
    dict set saved_states $net_name $original_state
    if {$original_state} {
      incr already_protected
      continue
    }
    if {[catch {$net_obj setDoNotTouch 1} err]} {
      incr failures
      puts "WARN(OR): cannot enable hold guard for port-root net $net_name : $err"
    } else {
      incr protected
    }
  }
  puts "INFO(OR): PIN3D BTerm hold guard enabled protected=$protected already_protected=$already_protected failures=$failures nets=[join $net_names ,]"
  if {$failures > 0} {
    error "Failed to protect one or more PIN3D BTerm port-root nets for hold repair"
  }
  return $saved_states
}

proc _pin3d_end_bterm_hold_guard {saved_states} {
  set restored 0
  set failures 0
  dict for {net_name original_state} $saved_states {
    set net_obj [_pin3d_find_net_by_name $net_name]
    if {$net_obj eq "" || $net_obj eq "NULL"} {
      incr failures
      puts "WARN(OR): cannot resolve guarded port-root net $net_name during restore"
      continue
    }
    if {[catch {$net_obj setDoNotTouch $original_state} err]} {
      incr failures
      puts "WARN(OR): cannot restore port-root net $net_name dont_touch=$original_state : $err"
    } else {
      incr restored
    }
  }
  puts "INFO(OR): PIN3D BTerm hold guard released restored=$restored failures=$failures"
  if {$failures > 0} {
    error "Failed to restore one or more PIN3D BTerm port-root nets after hold repair"
  }
}

proc pin3d_repair_timing_helper {args} {
  if {[llength [info commands _pin3d_boolean_env]] &&
      ![_pin3d_boolean_env PIN3D_PORT_ROOT_HOLD_GUARD 1]} {
    return [repair_timing_helper {*}$args]
  }

  set port_root_nets [_pin3d_bterm_crossing_root_net_names]
  if {[llength $port_root_nets] == 0} {
    return [repair_timing_helper {*}$args]
  }

  # Explicit one-phase requests retain their requested behavior.  Current
  # Pin3D stages call this helper without -setup/-hold and take the guarded
  # split path below.
  if {[lsearch -exact $args -setup] >= 0 ||
      [lsearch -exact $args -hold] >= 0} {
    return [repair_timing_helper {*}$args]
  }

  puts "INFO(OR): PIN3D timing repair split into setup/hold port_root_guard_nets=[llength $port_root_nets]"
  repair_timing_helper {*}$args -setup

  set saved_states [_pin3d_begin_bterm_hold_guard $port_root_nets]
  set code [catch {repair_timing_helper {*}$args -hold} result options]
  set restore_code [catch {_pin3d_end_bterm_hold_guard $saved_states} restore_result restore_options]
  if {$restore_code} {
    return -options $restore_options $restore_result
  }
  if {$code} {
    return -options $options $result
  }
  return $result
}


# Tier classification, cross-tier/mixed-fanout reporting, and optimization masks.
if {![llength [info commands apply_tier_policy]]} {
  source $::env(OPENROAD_SCRIPTS_DIR)/placement_tier_metrics_policy.tcl
}
