proc 3d_dp_tier_counts {} {
  set counts [dict create upper 0 bottom 0]
  set block [ord::get_db_block]
  foreach inst [$block getInsts] {
    set master_name [[$inst getMaster] getName]
    if {[string match "*_upper" $master_name]} {
      dict incr counts upper
    } elseif {[string match "*_bottom" $master_name]} {
      dict incr counts bottom
    }
  }
  return $counts
}

proc 3d_dp_master_tier {inst} {
  set master_name [[$inst getMaster] getName]
  if {[string match "*_upper" $master_name]} {
    return upper
  }
  if {[string match "*_bottom" $master_name]} {
    return bottom
  }
  return ""
}

proc 3d_dp_cross_tier_net_count {} {
  set count 0
  foreach net [[ord::get_db_block] getNets] {
    set tiers [dict create]
    foreach iterm [$net getITerms] {
      set tier [3d_dp_master_tier [$iterm getInst]]
      if {$tier ne ""} {
        dict set tiers $tier 1
      }
    }
    # TDP assigns top-level terminals to the upper tier when the loaded DP
    # tech LEF has no hb_layer, which is how the existing Pin3D DP stages load.
    if {[llength [$net getBTerms]] > 0} {
      dict set tiers upper 1
    }
    if {[dict exists $tiers upper] && [dict exists $tiers bottom]} {
      incr count
    }
  }
  return $count
}

proc 3d_dp_snapshot {} {
  set block [ord::get_db_block]
  set protected [dict create]
  foreach inst [$block getInsts] {
    set status [$inst getPlacementStatus]
    if {$status in {FIRM LOCKED FIXED}} {
      dict set protected [$inst getName] [$inst getLocation]
    }
  }
  return [dict create \
    instance_count [llength [$block getInsts]] \
    tier_counts [3d_dp_tier_counts] \
    protected_locations $protected]
}

proc 3d_dp_validate_snapshot {before} {
  set block [ord::get_db_block]
  set after_count [llength [$block getInsts]]
  if {$after_count != [dict get $before instance_count]} {
    error "3d_dp changed instance count: [dict get $before instance_count] -> $after_count"
  }

  set after_tiers [3d_dp_tier_counts]
  if {$after_tiers ne [dict get $before tier_counts]} {
    error "3d_dp changed tier instance counts: [dict get $before tier_counts] -> $after_tiers"
  }

  dict for {name location} [dict get $before protected_locations] {
    set inst [$block findInst $name]
    if {$inst eq "NULL"} {
      error "3d_dp removed protected instance '$name'"
    }
    if {[$inst getLocation] ne $location} {
      error "3d_dp moved protected instance '$name': $location -> [$inst getLocation]"
    }
  }
}

proc detail_place_3d_clear_stage_outputs {stage_paths} {
  foreach key {def_out v_out sdc_out odb_out image_out manifest_out} {
    if {[dict exists $stage_paths $key]} {
      set path [dict get $stage_paths $key]
      if {$path ne "" && [file exists $path]} {
        file delete -force $path
      }
    }
  }
  foreach key {def_aliases v_aliases sdc_aliases odb_aliases} {
    if {[dict exists $stage_paths $key]} {
      foreach path [dict get $stage_paths $key] {
        if {$path ne "" && [file exists $path]} {
          file delete -force $path
        }
      }
    }
  }
}

proc detail_place_3d_require_stage_inputs {stage_paths} {
  foreach key {def_in v_in sdc_in odb_in} {
    if {[dict exists $stage_paths $key]} {
      set path [dict get $stage_paths $key]
      if {$path ne "" && (![file exists $path] || [file size $path] == 0)} {
        error "3d_dp: required handoff '$key' is missing or empty: $path"
      }
    }
  }
}

proc detail_place_3d_assert_stage_outputs {stage_paths} {
  foreach key {def_out v_out sdc_out odb_out} {
    if {[dict exists $stage_paths $key]} {
      set path [dict get $stage_paths $key]
      if {$path ne "" && (![file exists $path] || [file size $path] == 0)} {
        error "3d_dp: output handoff '$key' was not published: $path"
      }
    }
  }
}
