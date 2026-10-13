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

proc 3d_dp_run_tier_repair {tier} {
  3d_dp_reset_tier_library_mask
  apply_tier_policy $tier -fixlib 1 -allow_net "$tier-only"
  estimate_parasitics -placement

  if {[3d_dp_repair_env_flag OPENROAD_OPT_LG_ENABLE_REPAIR_DESIGN 1]} {
    puts "INFO(3D_DP): running $tier tier timing repair"
    repair_timing_helper
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
}

proc 3d_dp_run_compat_repairs {} {
  3d_dp_run_tier_repair upper
  3d_dp_run_tier_repair bottom
}
