# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# tier_cell_policy.tcl — Upper/Bottom “do-not-use + filler/tap” policy
# Depends on environment variables (all optional, will try to auto-fallback if empty):
#   DONT_USE_CELLS_UPPER
#   DONT_USE_CELLS_BOTTOM
#   FILL_CELLS_UPPER
#   FILL_CELLS_BOTTOM
#   TAPCELL_UPPER   ;# Optional: if you want to explicitly specify for addWellTap/by layer
#   TAPCELL_BOTTOM
# Usage:
#   source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl
#   apply_tier_policy upper   ;# or bottom
# ==========================================

proc _as_list {envname} {
  if {[info exists ::env($envname)] && $::env($envname) ne ""} {
    return $::env($envname)
  }
  return {}
}

# Compatible set_dont_use (recognized by Innovus/Encounter/Genus)
proc _set_dont_use {cells {flag true}} {
  foreach c $cells {
    catch { set_dont_use $c $flag }
    # Some versions don't accept the boolean second argument, so fallback to single-argument syntax (sets to true)
    if {$flag} { catch { set_dont_use $c } }
    puts "set_dont_use $c"
  }
}

# Expand wildcard names into lib cell objects/names, as robustly as possible
# Expand wildcard names into lib cell objects/names, robustly for Common UI
proc _expand_libcells {patterns} {
  set out {}
  foreach p $patterns {
    if {![catch {set hits [get_lib_cells $p]}]} {
      if {[llength $hits] > 0} {
        foreach h $hits {
          if {[catch {set name [get_object_name $h]} err]} {
             if {[catch {set name [get_property $h name]} err2]} {
                set name $h
             }
          }
          lappend out $name
        }
        continue
      }
    }
    lappend out $p
  }
  return [lsort -unique $out]
}

# Optional: Restrict optimization to an "allowlist" (stronger than just don't_use)
# After passing an allow list, it will apply dont_use to "all_cells - allow_list"; disabled by default.
proc _enforce_allowlist {allow_patterns} {
  if {![llength $allow_patterns]} { return }
  set allow  [_expand_libcells $allow_patterns]
  # Get the full set (all standard cells)
  set all ""
  catch { set all [get_lib_cells *] }
  if {$all eq ""} { return }
  # Calculate the difference
  array set mark {}
  foreach a $allow { set mark($a) 1 }
  set ban {}
  foreach a $all { if {![info exists mark($a)]} { lappend ban $a } }
  _set_dont_use $ban true
}

proc box_flat4 {box} {
  if {[llength $box] == 1} { set box [lindex $box 0] }
  if {[llength $box] == 2 && [llength [lindex $box 0]] == 2} {
    set ll [lindex $box 0]; set ur [lindex $box 1]
    return [list [lindex $ll 0] [lindex $ll 1] [lindex $ur 0] [lindex $ur 1]]
  }
  return $box
}

proc rebuild_rows_for_site {site_name {core_margin 0}} {
  # 1. Basic validation
  if {$site_name eq ""} {
    puts "ERROR(INV): rebuild_rows_for_site: empty site_name."
    return
  }

  # 2. Retrieve DieBox
  set die_bbox [get_db current_design .bbox]
  
  # --- ROBUSTNESS FIX ---
  # If die_bbox is nested like {{0.0 0.0 11.4 11.2}}, llength will be 1.
  # If die_bbox is flat like {0.0 0.0 11.4 11.2}, llength will be 4.
  # We peel off the outer layer if it is nested.
  set die_bbox [lindex $die_bbox 0]
  set core_margin $::env(CORE_MARGIN)
  # Now die_bbox is guaranteed to be flat: {0.0 0.0 11.4 11.2}
  lassign $die_bbox die_x1 die_y1 die_x2 die_y2

  # 3. Calculate new area with margin applied
  set new_x1 [expr $die_x1 + $core_margin]
  set new_y1 [expr $die_y1 + $core_margin]
  set new_x2 [expr $die_x2 - $core_margin]
  set new_y2 [expr $die_y2 - $core_margin]

  # Sanity check
  if {$new_x1 >= $new_x2 || $new_y1 >= $new_y2} {
    puts "ERROR(INV): CORE_MARGIN ($core_margin) is too large for the current DieBox {$die_bbox}."
    return
  }

  puts "INFO(INV): Rebuilding rows for site '$site_name'"
  puts "INFO(INV): Row Area: {$new_x1 $new_y1 $new_x2 $new_y2}"

  # 4. Delete and Re-create
  deleteRow -all
  createRow -site $site_name -area [list $new_x1 $new_y1 $new_x2 $new_y2]
}

# Sets the placement status of tier-specific cells.
# Usage:
#   set_tier_placement_status bottom fixed  ;# Fixes bottom-tier cells
#   set_tier_placement_status bottom placed ;# Unfixes bottom-tier cells (sets to 'placed')
#   set_tier_placement_status upper fixed   ;# Fixes upper-tier cells
#   set_tier_placement_status upper placed  ;# Unfixes upper-tier cells (sets to 'placed')
proc set_tier_placement_status {tier status} {
  # Validate tier
  set tier_arg [string tolower $tier]
  if {![string match "upper" $tier_arg] && ![string match "bottom" $tier_arg]} {
    error "Invalid tier '$tier'. Must be 'upper' or 'bottom'."
    return
  }

  # Validate and normalize status
  set status_arg [string tolower $status]
  if {$status_arg eq "unfix"} {
    set status_arg "placed"
  }
  if {$status_arg ne "fixed" && $status_arg ne "placed"} {
    error "Invalid status '$status'. Must be 'fixed', 'placed', or 'unfix'."
    return
  }

  set match_pattern "*_${tier_arg}"

  # Use catch to avoid errors if dbGet is not available or no instances are found
  set insts {}
  catch { set insts [dbGet -p2 top.insts.cell.name $match_pattern] }

  if {[llength $insts]} {
    dbSet $insts.pStatus $status_arg
    puts "INFO: Set [llength $insts] ${tier_arg}-tier instances to '$status_arg'."
  } else {
    puts "INFO: No instances found matching '$match_pattern'."
  }
}

# ------------------------------------------------------------
# Helper: lock instances by master/ref suffix, optionally lock their nets
#   suffix: "*_upper" or "*_bottom"
# ------------------------------------------------------------
proc set_dont_touch_by_ref_suffix {suffix args} {
  array set opt {
    -quiet      0
  }
  if {([llength $args] % 2) != 0} {
    error "set_dont_touch_by_ref_suffix: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} { error "set_dont_touch_by_ref_suffix: unknown option $k" }
    set opt($k) $v
  }

  # 1) Find instances whose master/ref name matches suffix (master name is top.insts.cell.name)
  set inst_db {}
  catch { set inst_db [dbGet -p2 top.insts.cell.name $suffix] }
  if {$inst_db eq "" || [llength $inst_db] == 0} {
    if {!$opt(-quiet)} { puts "INFO: dont_touch: no instances match ref suffix '$suffix'." }
    return
  }

  # Convert to instance names -> get_cells collection
  set inst_names [dbGet $inst_db.name]
  if {$inst_names eq "" || [llength $inst_names] == 0} {
    if {!$opt(-quiet)} { puts "INFO: dont_touch: matched '$suffix' but cannot resolve instance names." }
    return
  }

  set cells [get_cells $inst_names]

  # 2) Dont touch cells (handle version differences)
  if {[catch {set_dont_touch $cells true} _e]} {
    catch {set_dont_touch $cells}
  }
  if {!$opt(-quiet)} { puts "INFO: dont_touch: locked [llength $inst_names] cells (ref suffix '$suffix')." }
}

# ------------------------------------------------------------
# Only modify apply_tier_policy: add option
#   -lock_other_tier_nets 1 (default): also lock nets of the other tier
#   CTS stage: call with -lock_other_tier_nets 0
# ------------------------------------------------------------
proc apply_tier_policy {tier args} {
  set tier [string tolower $tier]
  if {![string match "upper" $tier] && ![string match "bottom" $tier]} {
    error "apply_tier_policy: tier must be 'upper' or 'bottom'"
  }

  # New options (default: lock nets)
  array set opt {
    -quiet               0
    -fixlib 0
    -notouch 0
  }
  if {([llength $args] % 2) != 0} {
    error "apply_tier_policy: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} { error "apply_tier_policy: unknown option $k" }
    set opt($k) $v
  }

  # ---- your original env-driven lists (kept unchanged) ----
  set DNU_UP   [_as_list DNU_FOR_UPPER]
  set DNU_BOT  [_as_list DNU_FOR_BOTTOM]
  set FILL_UP  [_as_list FILL_CELLS_UPPER]
  set FILL_BOT [_as_list FILL_CELLS_BOTTOM]
  set TAP_UP   [_as_list TAPCELL_UPPER]
  set TAP_BOT  [_as_list TAPCELL_BOTTOM]

  if {$tier eq "upper"} {
    # (A) dont_use policy (unchanged)
    if {$opt(-fixlib)} {
      _set_dont_use [_expand_libcells $DNU_UP] true
    } 

    if {[llength $FILL_UP]} { setFillerMode -core $FILL_UP }

    if {[info exists ::env(UPPER_SITE)] && $::env(UPPER_SITE) ne ""} {
      set ::env(PLACE_SITE) $::env(UPPER_SITE)
    }

    # (B) NEW: lock the OTHER tier by master suffix "*_bottom"
    if {$opt(-notouch)} {
      set_dont_touch_by_ref_suffix "*_bottom" \
      -quiet $opt(-quiet)
    }

    # puts "INFO: Tier policy applied for UPPER: dont_use(bottom libs), dont_touch(bottom insts), filler=UPPER."
  } else {
    # bottom
    if {$opt(-fixlib)} {
      _set_dont_use [_expand_libcells $DNU_BOT] true
    }

    if {[llength $FILL_BOT]} { setFillerMode -core $FILL_BOT }

    if {[info exists ::env(BOTTOM_SITE)] && $::env(BOTTOM_SITE) ne ""} {
      set ::env(PLACE_SITE) $::env(BOTTOM_SITE)
    }

    # NEW: lock the OTHER tier by master suffix "*_upper"
    if {$opt(-notouch)} {
      set_dont_touch_by_ref_suffix "*_upper" \
        -quiet $opt(-quiet)
    }

    # puts "INFO: Tier policy applied for BOTTOM: dont_use(upper libs), dont_touch(upper insts), filler=BOTTOM."
  }
  puts "Rebuild Row for $tier"
  rebuild_rows_for_site $::env(PLACE_SITE)
}
