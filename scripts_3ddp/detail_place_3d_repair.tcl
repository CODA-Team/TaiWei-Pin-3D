# Shared timing-repair wrapper for the 3D DP variant.
#
# This mirrors the repair portion of the baseline upper/bottom passes, but
# deliberately does not invoke OpenROAD's ordinary detailed placement.  The
# following 3d_detailed_placement command remains the only DP implementation
# in this variant.

proc 3d_dp_repair_env_flag {name default_value} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    return $default_value
  }

  set value [string tolower [string trim $::env($name)]]
  switch -- $value {
    1 - on - true - yes - enabled { return 1 }
    0 - off - false - no - disabled { return 0 }
    default { return $default_value }
  }
}

proc 3d_dp_repair_tie_fanout {cell_env} {
  if {![info exists ::env($cell_env)] || [llength $::env($cell_env)] < 2} {
    error "3d_dp: $cell_env must contain {cell pin} for tier repair"
  }

  set cell_name [lindex $::env($cell_env) 0]
  set pin_name [lindex $::env($cell_env) 1]
  set lib_cell [lindex [get_lib_cell $cell_name] 0]
  if {$lib_cell eq ""} {
    error "3d_dp: cannot find tie cell '$cell_name' from $cell_env"
  }

  set lib_name [get_name [get_property $lib_cell library]]
  repair_tie_fanout -separation 5 "$lib_name/$cell_name/$pin_name"
}

proc 3d_dp_reset_tier_library_mask {} {
  # Baseline upper and bottom repair run in separate OpenROAD processes.  This
  # adapter runs both in one database, so clear the previous tier's dont_use
  # mask before apply_tier_policy installs the next one.
  set tier_cells [concat \
    [_expand_libcells [_as_list DNU_FOR_UPPER]] \
    [_expand_libcells [_as_list DNU_FOR_BOTTOM]]]
  foreach cell [lsort -unique $tier_cells] {
    unset_dont_use $cell
  }
}

proc 3d_dp_repair_master_tier {db_inst} {
  set master_name [[$db_inst getMaster] getName]
  if {[string match "*_upper" $master_name]} {
    return upper
  }
  if {[string match "*_bottom" $master_name]} {
    return bottom
  }
  return ""
}

proc 3d_dp_other_tier {tier} {
  switch -- $tier {
    upper { return bottom }
    bottom { return upper }
    default { error "3d_dp: invalid tier '$tier'" }
  }
}

proc 3d_dp_capture_instance_tiers {} {
  set tiers [dict create]
  foreach db_inst [[ord::get_db_block] getInsts] {
    set name [$db_inst getName]
    set tier [3d_dp_repair_master_tier $db_inst]
    if {$tier eq ""} {
      error "3d_dp: cannot classify instance '$name' with master '[[$db_inst getMaster] getName]'"
    }
    dict set tiers $name $tier
  }
  return $tiers
}

proc 3d_dp_guard_inactive_tier {tier} {
  set block [ord::get_db_block]
  set expected [dict create]
  foreach db_inst [$block getInsts] {
    if {[3d_dp_repair_master_tier $db_inst] eq $tier} {
      dict set expected [$db_inst getName] 1
    }
  }

  # Resolve every database instance to an STA instance before changing any
  # state.  A partial guard is unsafe, so a missing mapping is fatal.
  set sta_by_name [dict create]
  foreach sta_inst [get_cells -hierarchical *] {
    set db_inst [sta::sta_to_db_inst $sta_inst]
    if {$db_inst eq "" || $db_inst eq "NULL"} {
      continue
    }
    set name [$db_inst getName]
    if {[dict exists $expected $name]} {
      dict set sta_by_name $name $sta_inst
    }
  }
  dict for {name unused} $expected {
    if {![dict exists $sta_by_name $name]} {
      error "3d_dp: cannot protect inactive $tier instance '$name': no STA mapping"
    }
  }

  set newly_protected {}
  set newly_protected_names {}
  set preexisting_protected_names {}
  try {
    dict for {name sta_inst} $sta_by_name {
      set db_inst [$block findInst $name]
      if {$db_inst eq "NULL"} {
        error "3d_dp: inactive $tier instance '$name' disappeared while installing guard"
      }
      if {[$db_inst isDoNotTouch]} {
        lappend preexisting_protected_names $name
      } else {
        rsz::set_dont_touch_instance $sta_inst 1
        lappend newly_protected $sta_inst
        lappend newly_protected_names $name
      }
      if {![$db_inst isDoNotTouch]} {
        error "3d_dp: failed to protect inactive $tier instance '$name'"
      }
    }
  } on error {message options} {
    foreach sta_inst $newly_protected {
      catch {rsz::set_dont_touch_instance $sta_inst 0}
    }
    return -options $options $message
  }

  set covered [expr {[llength $newly_protected_names]
                      + [llength $preexisting_protected_names]}]
  if {$covered != [dict size $expected]} {
    foreach sta_inst $newly_protected {
      catch {rsz::set_dont_touch_instance $sta_inst 0}
    }
    error "3d_dp: incomplete inactive $tier guard: expected [dict size $expected], covered $covered"
  }

  puts "INFO(3D_DP): guarded inactive $tier tier: total=$covered newly_protected=[llength $newly_protected_names] already_protected=[llength $preexisting_protected_names]"
  return [dict create \
    tier $tier \
    expected_names [dict keys $expected] \
    newly_protected $newly_protected \
    newly_protected_names $newly_protected_names \
    preexisting_protected_names $preexisting_protected_names]
}

proc 3d_dp_restore_inactive_tier_guard {guard} {
  set block [ord::get_db_block]
  set tier [dict get $guard tier]
  set restored 0
  foreach sta_inst [dict get $guard newly_protected] {
    rsz::set_dont_touch_instance $sta_inst 0
    incr restored
  }

  foreach name [dict get $guard newly_protected_names] {
    set db_inst [$block findInst $name]
    if {$db_inst eq "NULL"} {
      error "3d_dp: guarded inactive $tier instance '$name' disappeared before guard restore"
    }
    if {[$db_inst isDoNotTouch]} {
      error "3d_dp: temporary dont_touch was not restored for inactive $tier instance '$name'"
    }
  }
  foreach name [dict get $guard preexisting_protected_names] {
    set db_inst [$block findInst $name]
    if {$db_inst eq "NULL"} {
      error "3d_dp: pre-protected inactive $tier instance '$name' disappeared"
    }
    if {![$db_inst isDoNotTouch]} {
      error "3d_dp: original dont_touch was lost for inactive $tier instance '$name'"
    }
  }
  puts "INFO(3D_DP): restored inactive $tier tier guard: restored=$restored"
}

proc 3d_dp_assert_repair_tier_ownership {active_tier before_tiers guard} {
  set block [ord::get_db_block]
  set inactive_tier [dict get $guard tier]

  # An inactive instance must survive the pass.  dont_touch is the functional
  # protection; this assertion prevents an unexpected API corner case from
  # silently propagating to TDP.
  foreach name [dict get $guard expected_names] {
    set db_inst [$block findInst $name]
    if {$db_inst eq "NULL"} {
      error "3d_dp: $active_tier repair removed inactive $inactive_tier instance '$name'"
    }
  }

  set removed 0
  dict for {name expected_tier} $before_tiers {
    set db_inst [$block findInst $name]
    if {$db_inst eq "NULL"} {
      incr removed
      continue
    }
    set actual_tier [3d_dp_repair_master_tier $db_inst]
    if {$actual_tier eq ""} {
      error "3d_dp: $active_tier repair produced unknown tier for existing instance '$name'"
    }
    if {$actual_tier ne $expected_tier} {
      error "3d_dp: $active_tier repair moved existing instance '$name' from $expected_tier to $actual_tier"
    }
  }

  set new_count 0
  foreach db_inst [$block getInsts] {
    set name [$db_inst getName]
    set actual_tier [3d_dp_repair_master_tier $db_inst]
    if {$actual_tier eq ""} {
      error "3d_dp: $active_tier repair produced unknown tier for instance '$name'"
    }
    if {![dict exists $before_tiers $name]} {
      incr new_count
      if {$actual_tier ne $active_tier} {
        error "3d_dp: $active_tier repair created instance '$name' in $actual_tier tier"
      }
    }
  }

  puts "INFO(3D_DP): $active_tier repair tier ownership PASS: existing=[dict size $before_tiers] removed=$removed new=$new_count"
}

proc 3d_dp_run_tier_repair {tier} {
  set inactive_tier [3d_dp_other_tier $tier]
  set before_tiers [3d_dp_capture_instance_tiers]
  set guard [3d_dp_guard_inactive_tier $inactive_tier]

  try {
    3d_dp_reset_tier_library_mask
    apply_tier_policy $tier -fixlib 1 -allow_net "$tier-only"
    estimate_parasitics -placement

    if {[3d_dp_repair_env_flag OPENROAD_OPT_LG_ENABLE_REPAIR_DESIGN 1]} {
      # A hold repair may need to rewire loads in both tiers.  That operation
      # is incompatible with the inactive-tier ownership guard used by this
      # combined-database adapter.  Restrict compatibility repair to setup;
      # the ordinary downstream timing-repair stages still handle hold.
      puts "INFO(3D_DP): running $tier tier setup timing repair"
      repair_timing_helper -setup
    } else {
      puts "INFO(3D_DP): skip $tier tier timing repair"
    }

    if {[3d_dp_repair_env_flag OPENROAD_OPT_LG_ENABLE_TIE_FANOUT 1]} {
      puts "INFO(3D_DP): running $tier tier tie-fanout repair"
      3d_dp_repair_tie_fanout TIELO_CELL_AND_PORT
      3d_dp_repair_tie_fanout TIEHI_CELL_AND_PORT
    } else {
      puts "INFO(3D_DP): skip $tier tier tie-fanout repair"
    }

    3d_dp_assert_repair_tier_ownership $tier $before_tiers $guard
  } finally {
    3d_dp_restore_inactive_tier_guard $guard
  }
}

proc 3d_dp_run_compat_repairs {} {
  3d_dp_run_tier_repair upper
  3d_dp_run_tier_repair bottom
}
