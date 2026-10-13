# ============================================================
# split_net_impl.tcl
# Implementation split out from split_net.tcl to keep stage source files lighter.
# ============================================================

proc ::tier_split_or2::iterm_name_list {iterms} {
  set out {}
  foreach iterm $iterms {
    lappend out [::tier_split_or2::iterm_full_name $iterm]
  }
  return [lsort -unique $out]
}

proc ::tier_split_or2::cleanup_failed_split {net moved_inst_sinks branch_net_name buffer_inst_name} {
  foreach sink $moved_inst_sinks {
    catch {$sink connect $net}
  }
  if {$buffer_inst_name ne ""} {
    catch {delete_instance $buffer_inst_name}
  }
  if {$branch_net_name ne ""} {
    set branch_net [_pin3d_find_net_by_name $branch_net_name]
    if {$branch_net ne "" && $branch_net ne "NULL"} {
      catch {::odb::dbNet_destroy $branch_net}
    }
  }
}

proc ::tier_split_or2::build_split_record {net driver_iterm buffer_tier retained_tier buffer_master_name buffer_inst_name branch_net_name moved_inst_sinks retained_inst_sinks {decision_info {}}} {
  set driver_tier [::tier_split_or2::classify_iterm $driver_iterm]
  set record [dict create \
    original_net [$net getName] \
    branch_net $branch_net_name \
    split_inst $buffer_inst_name \
    buffer_master $buffer_master_name \
    driver_tier $driver_tier \
    buffer_tier $buffer_tier \
    retained_tier $retained_tier \
    driver_pin [::tier_split_or2::iterm_full_name $driver_iterm] \
    moved_sinks [::tier_split_or2::iterm_name_list $moved_inst_sinks] \
    retained_sinks [::tier_split_or2::iterm_name_list $retained_inst_sinks]]
  if {$decision_info ne "" && [dict exists $decision_info upper] && [dict exists $decision_info bottom]} {
    set upper [dict get $decision_info upper]
    set bottom [dict get $decision_info bottom]
    if {[dict exists $decision_info selection_reason]} {
      dict set record selection_reason [dict get $decision_info selection_reason]
    }
    dict set record score_upper [dict get $upper score]
    dict set record score_bottom [dict get $bottom score]
    dict set record util_upper [dict get $upper util]
    dict set record util_bottom [dict get $bottom util]
    dict set record p_util_upper [dict get $upper p_util]
    dict set record p_util_bottom [dict get $bottom p_util]
    dict set record estimated_extra_hbt_upper [dict get $upper estimated_extra_hbt]
    dict set record estimated_extra_hbt_bottom [dict get $bottom estimated_extra_hbt]
    dict set record p_hbt_upper [dict get $upper p_hbt]
    dict set record p_hbt_bottom [dict get $bottom p_hbt]
    dict set record buffer_master_candidate_upper [dict get $upper buffer_master]
    dict set record buffer_master_candidate_bottom [dict get $bottom buffer_master]
    dict set record buffer_area_upper [dict get $upper buffer_area]
    dict set record buffer_area_bottom [dict get $bottom buffer_area]
    dict set record core_area [dict get $upper core_area]
    dict set record p_area_upper [dict get $upper p_area]
    dict set record p_area_bottom [dict get $bottom p_area]
    dict set record high_util_forbid_upper [dict get $upper high_util_forbid]
    dict set record high_util_forbid_bottom [dict get $bottom high_util_forbid]
  }
  return $record
}

proc ::tier_split_or2::name_matches_any {name patterns} {
  foreach p $patterns {
    if {$p ne "" && [regexp -- $p $name]} {
      return 1
    }
  }
  return 0
}

proc ::tier_split_or2::dbu_per_um {} {
  set tech [ord::get_db_tech]
  return [$tech getDbUnitsPerMicron]
}

proc ::tier_split_or2::split_y_dbu {} {
  variable CFG
  return [expr {round($CFG(split_y_um) * [::tier_split_or2::dbu_per_um])}]
}

proc ::tier_split_or2::inst_center_y_dbu {inst} {
  set box [$inst getBBox]
  return [expr {(double([$box yMin]) + double([$box yMax])) / 2.0}]
}

proc ::tier_split_or2::classify_inst {inst} {
  variable CFG
  variable INST_TIER_CACHE
  set name [$inst getName]
  if {[info exists INST_TIER_CACHE($name)]} {
    return $INST_TIER_CACHE($name)
  }

  if {[llength [info commands _or_inst_tier]]} {
    set canonical_tier [_or_inst_tier $inst]
    if {$canonical_tier eq "split_buffer"} {
      set INST_TIER_CACHE($name) $canonical_tier
      return $canonical_tier
    }
    if {$canonical_tier eq "upper" || $canonical_tier eq "bottom"} {
      set INST_TIER_CACHE($name) $canonical_tier
      return $canonical_tier
    }
  }

  if {[::tier_split_or2::name_matches_any $name $CFG(upper_inst_re)]} {
    set INST_TIER_CACHE($name) upper
    return upper
  }
  if {[::tier_split_or2::name_matches_any $name $CFG(lower_inst_re)]} {
    set INST_TIER_CACHE($name) bottom
    return bottom
  }

  if {$CFG(use_bbox_split)} {
    if {[::tier_split_or2::inst_center_y_dbu $inst] >= [::tier_split_or2::split_y_dbu]} {
      set INST_TIER_CACHE($name) upper
      return upper
    }
    set INST_TIER_CACHE($name) bottom
    return bottom
  }
  set INST_TIER_CACHE($name) unknown
  return unknown
}

proc ::tier_split_or2::iterm_full_name {iterm} {
  return "[[$iterm getInst] getName]/[[$iterm getMTerm] getName]"
}

proc ::tier_split_or2::classify_iterm {iterm} {
  variable CFG
  set full [::tier_split_or2::iterm_full_name $iterm]
  variable ITERM_TIER_CACHE
  if {[info exists ITERM_TIER_CACHE($full)]} {
    return $ITERM_TIER_CACHE($full)
  }

  if {[::tier_split_or2::name_matches_any $full $CFG(upper_pin_re)]} {
    set ITERM_TIER_CACHE($full) upper
    return upper
  }
  if {[::tier_split_or2::name_matches_any $full $CFG(lower_pin_re)]} {
    set ITERM_TIER_CACHE($full) bottom
    return bottom
  }
  set tier [::tier_split_or2::classify_inst [$iterm getInst]]
  set ITERM_TIER_CACHE($full) $tier
  return $tier
}

proc ::tier_split_or2::safe_sigtype {term} {
  if {[catch {set sig_type [$term getSigType]}]} {
    return SIGNAL
  }
  return $sig_type
}

proc ::tier_split_or2::safe_iotype {term} {
  if {[catch {set io_type [$term getIoType]}]} {
    return ""
  }
  return $io_type
}

proc ::tier_split_or2::bterm_role {bterm} {
  set dir [::tier_split_or2::safe_iotype $bterm]
  switch -- $dir {
    INPUT  { return driver }
    OUTPUT { return sink }
    default { return unsupported }
  }
}

proc ::tier_split_or2::bterm_tier {bterm} {
  variable BTERM_TIER_CACHE
  set name [$bterm getName]
  if {[info exists BTERM_TIER_CACHE($name)]} {
    return $BTERM_TIER_CACHE($name)
  }
  if {[llength [info commands _or_bterm_tier]]} {
    set tier [_or_bterm_tier $bterm]
    set BTERM_TIER_CACHE($name) $tier
    return $tier
  }
  set BTERM_TIER_CACHE($name) unknown
  return unknown
}

proc ::tier_split_or2::master_tier {master} {
  variable CFG
  set master_name [$master getName]
  if {[regexp -- $CFG(upper_master_re) $master_name]} {
    return upper
  }
  if {[regexp -- $CFG(lower_master_re) $master_name]} {
    return bottom
  }
  return unknown
}

proc ::tier_split_or2::master_has_site {master} {
  if {[catch {set site [$master getSite]}]} {
    return 0
  }
  return [expr {$site ne "" && $site ne "NULL"}]
}

proc ::tier_split_or2::master_io_summary {master} {
  set in_cnt 0
  set out_cnt 0
  set input_term ""
  set output_term ""

  foreach mterm [$master getMTerms] {
    set sig_type [::tier_split_or2::safe_sigtype $mterm]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
      continue
    }
    set dir [::tier_split_or2::safe_iotype $mterm]
    switch -- $dir {
      INPUT {
        incr in_cnt
        set input_term [$mterm getName]
      }
      OUTPUT {
        incr out_cnt
        set output_term [$mterm getName]
      }
      INOUT {
        return [list -1 -1 "" ""]
      }
    }
  }
  return [list $in_cnt $out_cnt $input_term $output_term]
}

proc ::tier_split_or2::buffer_name_is_usable {master_name} {
  if {![regexp -nocase -- {^buf} $master_name]} {
    return 0
  }
  if {[regexp -nocase -- {^(clkbuf|tbuf)} $master_name]} {
    return 0
  }
  return 1
}

proc ::tier_split_or2::find_master_by_name {master_name} {
  variable MASTER_LOOKUP
  if {[info exists MASTER_LOOKUP($master_name)]} {
    return $MASTER_LOOKUP($master_name)
  }
  set db [ord::get_db]
  foreach lib [::odb::dbDatabase_getLibs $db] {
    foreach master [::odb::dbLib_getMasters $lib] {
      if {[$master getName] eq $master_name} {
        set MASTER_LOOKUP($master_name) $master
        return $master
      }
    }
  }
  return ""
}

proc ::tier_split_or2::buffer_drive_score {master_name} {
  set score 999999
  if {[regexp -nocase -- {[_x]([0-9]+)[a-z]*(?:_|$)} $master_name -> drive]} {
    set score $drive
  }
  return $score
}

proc ::tier_split_or2::next_power_of_two {value} {
  if {$value <= 1} {
    return 1
  }
  set power 1
  while {$power < $value} {
    set power [expr {$power * 2}]
  }
  return $power
}

proc ::tier_split_or2::required_buffer_drive_score {moved_sink_count} {
  set per_drive_unit 24
  if {[info exists ::env(PIN3D_SPLIT_FANOUT_PER_DRIVE)] && $::env(PIN3D_SPLIT_FANOUT_PER_DRIVE) ne ""} {
    set per_drive_unit $::env(PIN3D_SPLIT_FANOUT_PER_DRIVE)
  }
  if {$per_drive_unit < 1} {
    set per_drive_unit 24
  }

  set units [expr {int(ceil(double(max($moved_sink_count, 1)) / double($per_drive_unit)))}]
  return [::tier_split_or2::next_power_of_two $units]
}

proc ::tier_split_or2::opposite_tier {tier} {
  switch -- $tier {
    upper {
      return bottom
    }
    bottom {
      return upper
    }
    default {
      return unknown
    }
  }
}

proc ::tier_split_or2::choose_buffer_master {tier moved_sink_count} {
  variable CFG
  variable BUFFER_MASTER_CHOICES
  if {![info exists BUFFER_MASTER_CHOICES($tier)]} {
    set candidates {}
    set db [ord::get_db]
    set dbu [::tier_split_or2::dbu_per_um]
    foreach lib [::odb::dbDatabase_getLibs $db] {
      foreach master [::odb::dbLib_getMasters $lib] {
        set master_name [$master getName]
        if {![::tier_split_or2::master_has_site $master]} {
          continue
        }
        if {![::tier_split_or2::buffer_name_is_usable $master_name]} {
          continue
        }
        if {$tier eq "upper"} {
          if {$CFG(buffer_master_upper_re) ne "" && ![regexp -- $CFG(buffer_master_upper_re) $master_name]} {
            continue
          }
        } else {
          if {$CFG(buffer_master_lower_re) ne "" && ![regexp -- $CFG(buffer_master_lower_re) $master_name]} {
            continue
          }
        }
        if {[::tier_split_or2::master_tier $master] ne $tier} {
          continue
        }
        lassign [::tier_split_or2::master_io_summary $master] in_cnt out_cnt input_term output_term
        if {$in_cnt == 1 && $out_cnt == 1 && $input_term ne "" && $output_term ne ""} {
          lappend candidates [list [::tier_split_or2::buffer_drive_score $master_name] $master_name $input_term $output_term [::tier_split_or2::master_area_um2 $master $dbu]]
        }
      }
    }
    set BUFFER_MASTER_CHOICES($tier) [lsort -integer -index 0 [lsort -dictionary -index 1 $candidates]]
  }

  set sorted $BUFFER_MASTER_CHOICES($tier)
  if {[llength $sorted] == 0} {
    return ""
  }
  set required_drive [::tier_split_or2::required_buffer_drive_score $moved_sink_count]
  foreach item $sorted {
    if {[lindex $item 0] >= $required_drive} {
      return [concat [lrange $item 1 end] [list [lindex $item 0] $required_drive]]
    }
  }
  set largest [lindex $sorted end]
  return [concat [lrange $largest 1 end] [list [lindex $largest 0] $required_drive]]
}

proc ::tier_split_or2::driver_ok {driver_iterm} {
  set inst [$driver_iterm getInst]
  set master [$inst getMaster]

  if {![catch {set master_type [$master getType]}] && $master_type eq "BLOCK"} {
    return [list 0 "driver_is_block"]
  }
  foreach iterm [$inst getITerms] {
    set sig_type [::tier_split_or2::safe_sigtype [$iterm getMTerm]]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
      continue
    }
    set dir [::tier_split_or2::safe_iotype [$iterm getMTerm]]
    if {$dir eq "INOUT"} {
      return [list 0 "driver_has_inout"]
    }
  }
  return [list 1 ""]
}

proc ::tier_split_or2::object_label {kind obj} {
  switch -- $kind {
    iterm {
      return [::tier_split_or2::iterm_full_name $obj]
    }
    bterm {
      return [$obj getName]
    }
    default {
      return "<unknown>"
    }
  }
}

proc ::tier_split_or2::get_net_driver {net} {
  variable CFG
  set drivers {}

  foreach iterm [$net getITerms] {
    set sig_type [::tier_split_or2::safe_sigtype [$iterm getMTerm]]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
      continue
    }
    if {[::tier_split_or2::safe_iotype [$iterm getMTerm]] eq "OUTPUT"} {
      lappend drivers [list iterm $iterm]
    }
  }

  if {![catch {set bterms [$net getBTerms]}]} {
    foreach bterm $bterms {
      set sig_type [::tier_split_or2::safe_sigtype $bterm]
      if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
        continue
      }
      if {[::tier_split_or2::bterm_role $bterm] eq "driver"} {
        lappend drivers [list bterm $bterm]
      }
    }
  }

  if {[llength $drivers] != 1} {
    return [list "" "driver_count_[llength $drivers]"]
  }

  lassign [lindex $drivers 0] driver_kind driver_obj
  if {$driver_kind eq "bterm"} {
    if {$CFG(skip_port_driven_nets)} {
      return [list "" "top_level_term_net_not_supported"]
    }
    set tier [::tier_split_or2::bterm_tier $driver_obj]
    if {$tier ni {upper bottom}} {
      return [list "" "top_level_term_driver_tier_unknown"]
    }
    return [list [list $driver_kind $driver_obj] ""]
  }

  lassign [::tier_split_or2::driver_ok $driver_obj] ok reason
  if {!$ok} {
    return [list "" $reason]
  }
  return [list [list $driver_kind $driver_obj] ""]
}

proc ::tier_split_or2::collect_sinks_by_tier {net} {
  set upper_inst_sinks {}
  set bottom_inst_sinks {}
  set upper_term_sinks {}
  set bottom_term_sinks {}
  set unknown_sinks {}

  foreach iterm [$net getITerms] {
    set sig_type [::tier_split_or2::safe_sigtype [$iterm getMTerm]]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
      continue
    }
    if {[::tier_split_or2::safe_iotype [$iterm getMTerm]] ne "INPUT"} {
      continue
    }
    switch -- [::tier_split_or2::classify_iterm $iterm] {
      upper {
        lappend upper_inst_sinks $iterm
      }
      bottom {
        lappend bottom_inst_sinks $iterm
      }
      split_buffer {
        continue
      }
      default {
        lappend unknown_sinks [list iterm $iterm]
      }
    }
  }

  if {![catch {set bterms [$net getBTerms]}]} {
    foreach bterm $bterms {
      set sig_type [::tier_split_or2::safe_sigtype $bterm]
      if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
        continue
      }
      if {[::tier_split_or2::bterm_role $bterm] ne "sink"} {
        continue
      }
      switch -- [::tier_split_or2::bterm_tier $bterm] {
        upper {
          lappend upper_term_sinks $bterm
        }
        bottom {
          lappend bottom_term_sinks $bterm
        }
        default {
          lappend unknown_sinks [list bterm $bterm]
        }
      }
    }
  }

  return [dict create \
    upper_inst $upper_inst_sinks \
    bottom_inst $bottom_inst_sinks \
    upper_term $upper_term_sinks \
    bottom_term $bottom_term_sinks \
    unknown $unknown_sinks]
}

proc ::tier_split_or2::numeric_or_zero {value} {
  if {[catch {expr {double($value)}} result]} {
    return 0.0
  }
  return $result
}

proc ::tier_split_or2::master_area_um2 {master dbu} {
  if {$master eq "" || $master eq "NULL"} {
    return 0.0
  }
  if {[catch {set w [$master getWidth]}] || [catch {set h [$master getHeight]}]} {
    return 0.0
  }
  return [expr {double($w) * double($h) / double($dbu * $dbu)}]
}

proc ::tier_split_or2::compute_tier_global_utilization {block} {
  variable TIER_UTILIZATION
  if {$TIER_UTILIZATION ne ""} {
    return $TIER_UTILIZATION
  }

  set dbu [::tier_split_or2::dbu_per_um]
  lassign [ord::get_die_area] die_lx die_ly die_ux die_uy
  set margin 0.0
  if {[info exists ::env(CORE_MARGIN)] && $::env(CORE_MARGIN) ne ""} {
    set margin [::tier_split_or2::numeric_or_zero $::env(CORE_MARGIN)]
  }
  set width [expr {max(0.0, double($die_ux) - double($die_lx) - 2.0 * $margin)}]
  set height [expr {max(0.0, double($die_uy) - double($die_ly) - 2.0 * $margin)}]
  set core_area [expr {$width * $height}]

  set upper_area 0.0
  set bottom_area 0.0
  set upper_count 0
  set bottom_count 0
  foreach inst [$block getInsts] {
    set tier [::tier_split_or2::classify_inst $inst]
    if {$tier ni {upper bottom}} {
      continue
    }
    set area [::tier_split_or2::master_area_um2 [$inst getMaster] $dbu]
    if {$tier eq "upper"} {
      set upper_area [expr {$upper_area + $area}]
      incr upper_count
    } else {
      set bottom_area [expr {$bottom_area + $area}]
      incr bottom_count
    }
  }

  set util_upper 0.0
  set util_bottom 0.0
  set total_cell_area [expr {$upper_area + $bottom_area}]
  if {$core_area > 0.0} {
    set util_upper [expr {$upper_area / $core_area}]
    set util_bottom [expr {$bottom_area / $core_area}]
  }
  set TIER_UTILIZATION [dict create \
    upper $util_upper \
    bottom $util_bottom \
    upper_area $upper_area \
    bottom_area $bottom_area \
    total_cell_area $total_cell_area \
    upper_count $upper_count \
    bottom_count $bottom_count \
    core_area $core_area \
    method "master_area_over_core_area"]
  return $TIER_UTILIZATION
}

proc ::tier_split_or2::util_penalty {util} {
  variable CFG
  set util [::tier_split_or2::numeric_or_zero $util]
  if {$util <= $CFG(util_safe)} {
    return 0.0
  }
  return [expr {exp(double($CFG(util_alpha)) * ($util - double($CFG(util_safe)))) - 1.0}]
}

proc ::tier_split_or2::estimated_extra_hbt {candidate_tier driver_tier retained_opposite_tier_sink_count} {
  if {$candidate_tier ne $driver_tier} {
    return 1
  }
  return $retained_opposite_tier_sink_count
}

proc ::tier_split_or2::hbt_penalty {estimated_extra_hbt} {
  return [expr {log(1.0 + double($estimated_extra_hbt)) / log(2.0)}]
}

proc ::tier_split_or2::buffer_area_penalty {buffer_area core_area} {
  set buffer_area [::tier_split_or2::numeric_or_zero $buffer_area]
  set core_area [::tier_split_or2::numeric_or_zero $core_area]
  if {$buffer_area <= 0.0 || $core_area <= 0.0} {
    return 0.0
  }
  return [expr {$buffer_area / $core_area}]
}

proc ::tier_split_or2::candidate_feasibility {candidate_tier upper_inst_count bottom_inst_count upper_term_count bottom_term_count} {
  if {$candidate_tier eq "upper"} {
    if {$upper_inst_count <= 0 && $upper_term_count <= 0} {
      return [list 0 no_supported_upper_sinks]
    }
    if {$upper_term_count > 0} {
      return [list 0 top_level_upper_sink_rewire_not_supported]
    }
  } else {
    if {$bottom_inst_count <= 0 && $bottom_term_count <= 0} {
      return [list 0 no_supported_bottom_sinks]
    }
    if {$bottom_term_count > 0} {
      return [list 0 top_level_bottom_sink_rewire_not_supported]
    }
  }
  return [list 1 ""]
}

proc ::tier_split_or2::evaluate_buffer_tier_score {block candidate_tier driver_tier upper_inst_count bottom_inst_count upper_term_count bottom_term_count} {
  variable CFG
  set tier_util [::tier_split_or2::compute_tier_global_utilization $block]
  set util [dict get $tier_util $candidate_tier]
  set p_util [::tier_split_or2::util_penalty $util]
  set core_area [dict get $tier_util core_area]
  if {$candidate_tier eq "upper"} {
    set retained_opposite_count [expr {$bottom_inst_count + $bottom_term_count}]
    set moved_sink_count [expr {$upper_inst_count + $upper_term_count}]
  } else {
    set retained_opposite_count [expr {$upper_inst_count + $upper_term_count}]
    set moved_sink_count [expr {$bottom_inst_count + $bottom_term_count}]
  }
  set estimated_extra_hbt [::tier_split_or2::estimated_extra_hbt $candidate_tier $driver_tier $retained_opposite_count]
  set p_hbt [::tier_split_or2::hbt_penalty $estimated_extra_hbt]
  lassign [::tier_split_or2::candidate_feasibility $candidate_tier $upper_inst_count $bottom_inst_count $upper_term_count $bottom_term_count] feasible infeasible_reason
  set buffer_master ""
  set buffer_area 0.0
  if {$feasible} {
    set buffer_info [::tier_split_or2::choose_buffer_master $candidate_tier $moved_sink_count]
    if {$buffer_info eq ""} {
      set feasible 0
      set infeasible_reason no_tier_buffer_master
    } else {
      lassign $buffer_info buffer_master _ _ buffer_area _ _
    }
  }
  set p_area [::tier_split_or2::buffer_area_penalty $buffer_area $core_area]
  set score [expr {double($CFG(util_weight)) * $p_util + double($CFG(hbt_weight)) * $p_hbt + double($CFG(area_weight)) * $p_area}]
  set forbidden [expr {$util >= double($CFG(high_util_forbid))}]
  return [dict create \
    tier $candidate_tier \
    score $score \
    util $util \
    p_util $p_util \
    estimated_extra_hbt $estimated_extra_hbt \
    p_hbt $p_hbt \
    buffer_master $buffer_master \
    buffer_area $buffer_area \
    core_area $core_area \
    p_area $p_area \
    feasible $feasible \
    infeasible_reason $infeasible_reason \
    high_util_forbid $forbidden]
}

proc ::tier_split_or2::prefer_score_record {upper_eval bottom_eval driver_tier} {
  variable CFG
  set upper_feasible [dict get $upper_eval feasible]
  set bottom_feasible [dict get $bottom_eval feasible]
  if {!$upper_feasible && !$bottom_feasible} {
    return [list "" no_supported_instance_sinks]
  }
  if {$upper_feasible && !$bottom_feasible} {
    return [list upper only_upper_feasible]
  }
  if {$bottom_feasible && !$upper_feasible} {
    return [list bottom only_bottom_feasible]
  }

  set upper_forbidden [dict get $upper_eval high_util_forbid]
  set bottom_forbidden [dict get $bottom_eval high_util_forbid]
  if {$upper_forbidden && !$bottom_forbidden} {
    return [list bottom upper_high_util_guard]
  }
  if {$bottom_forbidden && !$upper_forbidden} {
    return [list upper bottom_high_util_guard]
  }

  set score_upper [dict get $upper_eval score]
  set score_bottom [dict get $bottom_eval score]
  set min_score [expr {($score_upper < $score_bottom) ? $score_upper : $score_bottom}]
  set diff [expr {abs($score_upper - $score_bottom)}]
  if {$min_score <= 1.0e-12} {
    set near_tie [expr {$diff < double($CFG(near_tie_ratio))}]
  } else {
    set near_tie [expr {($diff / $min_score) < double($CFG(near_tie_ratio))}]
  }
  if {!$near_tie} {
    if {$score_upper <= $score_bottom} {
      return [list upper lower_score]
    }
    return [list bottom lower_score]
  }

  set p_util_upper [dict get $upper_eval p_util]
  set p_util_bottom [dict get $bottom_eval p_util]
  if {$p_util_upper < $p_util_bottom} {
    return [list upper near_tie_lower_util_penalty]
  }
  if {$p_util_bottom < $p_util_upper} {
    return [list bottom near_tie_lower_util_penalty]
  }

  set hbt_upper [dict get $upper_eval estimated_extra_hbt]
  set hbt_bottom [dict get $bottom_eval estimated_extra_hbt]
  if {$hbt_upper < $hbt_bottom} {
    return [list upper near_tie_lower_estimated_extra_hbt]
  }
  if {$hbt_bottom < $hbt_upper} {
    return [list bottom near_tie_lower_estimated_extra_hbt]
  }

  set p_area_upper [dict get $upper_eval p_area]
  set p_area_bottom [dict get $bottom_eval p_area]
  if {$p_area_upper < $p_area_bottom} {
    return [list upper near_tie_lower_area_penalty]
  }
  if {$p_area_bottom < $p_area_upper} {
    return [list bottom near_tie_lower_area_penalty]
  }

  set opposite [::tier_split_or2::opposite_tier $driver_tier]
  if {$opposite in {upper bottom}} {
    return [list $opposite near_tie_opposite_driver_tier]
  }
  return [list upper near_tie_lexical_upper]
}

proc ::tier_split_or2::choose_buffer_tier {block driver_tier upper_inst_count bottom_inst_count upper_term_count bottom_term_count} {
  if {$driver_tier ni {upper bottom}} {
    return [list "" driver_tier_unknown [dict create]]
  }
  set upper_eval [::tier_split_or2::evaluate_buffer_tier_score $block upper $driver_tier $upper_inst_count $bottom_inst_count $upper_term_count $bottom_term_count]
  set bottom_eval [::tier_split_or2::evaluate_buffer_tier_score $block bottom $driver_tier $upper_inst_count $bottom_inst_count $upper_term_count $bottom_term_count]
  lassign [::tier_split_or2::prefer_score_record $upper_eval $bottom_eval $driver_tier] tier reason
  return [list $tier $reason [dict create upper $upper_eval bottom $bottom_eval selection_reason $reason]]
}

proc ::tier_split_or2::format_decision_fields {decision} {
  if {$decision eq "" || ![dict exists $decision upper] || ![dict exists $decision bottom]} {
    return ""
  }
  set upper [dict get $decision upper]
  set bottom [dict get $decision bottom]
  return [format "score_upper=%.6g score_bottom=%.6g util_upper=%.6g util_bottom=%.6g p_util_upper=%.6g p_util_bottom=%.6g estimated_extra_hbt_upper=%d estimated_extra_hbt_bottom=%d p_hbt_upper=%.6g p_hbt_bottom=%.6g buffer_master_upper=%s buffer_master_bottom=%s buffer_area_upper=%.6g buffer_area_bottom=%.6g core_area=%.6g p_area_upper=%.6g p_area_bottom=%.6g high_util_forbid_upper=%d high_util_forbid_bottom=%d" \
    [dict get $upper score] \
    [dict get $bottom score] \
    [dict get $upper util] \
    [dict get $bottom util] \
    [dict get $upper p_util] \
    [dict get $bottom p_util] \
    [dict get $upper estimated_extra_hbt] \
    [dict get $bottom estimated_extra_hbt] \
    [dict get $upper p_hbt] \
    [dict get $bottom p_hbt] \
    [dict get $upper buffer_master] \
    [dict get $bottom buffer_master] \
    [dict get $upper buffer_area] \
    [dict get $bottom buffer_area] \
    [dict get $upper core_area] \
    [dict get $upper p_area] \
    [dict get $bottom p_area] \
    [dict get $upper high_util_forbid] \
    [dict get $bottom high_util_forbid]]
}
proc ::tier_split_or2::sanitize_name_component {name} {
  regsub -all {[^A-Za-z0-9_]} $name "_" clean_name
  return $clean_name
}

proc ::tier_split_or2::init_existing_names {block} {
  variable NAME_SET
  array unset NAME_SET
  foreach net [$block getNets] {
    set NAME_SET([$net getName]) 1
  }
  foreach inst [$block getInsts] {
    set NAME_SET([$inst getName]) 1
  }
}

proc ::tier_split_or2::ensure_unique_name {block base_name} {
  variable NAME_SET
  set name $base_name
  set idx 0
  while {[info exists NAME_SET($name)]} {
    incr idx
    set name "${base_name}_${idx}"
  }
  set NAME_SET($name) 1
  return $name
}

proc ::tier_split_or2::remember_created_split_objects {buffer_inst branch_net buffer_in_it buffer_out_it moved_inst_sinks} {
  set ::_PIN3D_INST_CACHE([$buffer_inst getName]) $buffer_inst
  set ::_PIN3D_NET_CACHE([$branch_net getName]) $branch_net
  set ::_PIN3D_ITERM_CACHE([::tier_split_or2::iterm_full_name $buffer_in_it]) $buffer_in_it
  set ::_PIN3D_ITERM_CACHE([::tier_split_or2::iterm_full_name $buffer_out_it]) $buffer_out_it
  foreach sink $moved_inst_sinks {
    set ::_PIN3D_ITERM_CACHE([::tier_split_or2::iterm_full_name $sink]) $sink
  }
}

proc ::tier_split_or2::fast_verify_inserted_split {net driver_obj buffer_in_it buffer_out_it branch_net moved_inst_sinks retained_inst_sinks} {
  if {[_pin3d_iterm_net $buffer_in_it] ne $net} {
    return [dict create status violated reason buffer_input_not_on_original_net]
  }
  if {[_pin3d_iterm_net $buffer_out_it] ne $branch_net} {
    return [dict create status violated reason buffer_output_not_on_branch_net]
  }
  foreach sink $moved_inst_sinks {
    if {[_pin3d_iterm_net $sink] ne $branch_net} {
      return [dict create status violated reason moved_sink_not_on_branch_net]
    }
  }
  foreach sink $retained_inst_sinks {
    if {[_pin3d_iterm_net $sink] eq $branch_net} {
      return [dict create status violated reason retained_sink_leaked_to_branch_net]
    }
  }
  if {[_pin3d_iterm_net $driver_obj] ne $net} {
    return [dict create status violated reason driver_not_on_original_net]
  }
  if {[net_has_mixed_fanout $net]} {
    return [dict create status violated reason original_net_still_mixed_fanout]
  }
  if {[net_has_mixed_fanout $branch_net]} {
    return [dict create status violated reason branch_net_still_mixed_fanout]
  }
  return [dict create status valid reason direct_split_insert_ok]
}

proc ::tier_split_or2::record_skip {fp net_name reason details} {
  variable CFG
  if {!$CFG(log_skip_details)} {
    return
  }
  if {$details eq ""} {
    puts $fp "SKIP $net_name reason=$reason"
  } else {
    puts $fp "SKIP $net_name reason=$reason $details"
  }
}

proc ::tier_split_or2::anchor_inst_for_move {driver_iterm moved_inst_sinks} {
  if {[llength $moved_inst_sinks] > 0} {
    return [[lindex $moved_inst_sinks 0] getInst]
  }
  return [$driver_iterm getInst]
}

proc ::tier_split_or2::split_net_with_buffer {block net driver_info sinks_by_tier fp} {
  variable CFG

  set net_name [$net getName]
  lassign $driver_info driver_kind driver_obj
  if {$driver_kind ne "iterm"} {
    ::tier_split_or2::record_skip $fp $net_name "top_level_term_driver_not_supported" ""
    return [list 0 "top_level_term_driver_not_supported"]
  }

  set upper_inst_sinks [dict get $sinks_by_tier upper_inst]
  set bottom_inst_sinks [dict get $sinks_by_tier bottom_inst]
  set upper_term_sinks [dict get $sinks_by_tier upper_term]
  set bottom_term_sinks [dict get $sinks_by_tier bottom_term]

  set driver_tier [::tier_split_or2::classify_iterm $driver_obj]
  set upper_inst_count [llength $upper_inst_sinks]
  set bottom_inst_count [llength $bottom_inst_sinks]
  set upper_term_count [llength $upper_term_sinks]
  set bottom_term_count [llength $bottom_term_sinks]
  lassign [::tier_split_or2::choose_buffer_tier $block $driver_tier $upper_inst_count $bottom_inst_count $upper_term_count $bottom_term_count] buffer_tier tier_reason decision
  if {$buffer_tier eq ""} {
    ::tier_split_or2::record_skip $fp $net_name $tier_reason "driver_tier=$driver_tier"
    return [list 0 $tier_reason ""]
  }

  set moved_inst_sinks {}
  set moved_term_sinks {}
  set retained_tier ""
  if {$buffer_tier eq "upper"} {
    set moved_inst_sinks $upper_inst_sinks
    set moved_term_sinks $upper_term_sinks
    set retained_inst_sinks $bottom_inst_sinks
    set retained_tier bottom
  } else {
    set moved_inst_sinks $bottom_inst_sinks
    set moved_term_sinks $bottom_term_sinks
    set retained_inst_sinks $upper_inst_sinks
    set retained_tier upper
  }

  if {[llength $moved_inst_sinks] == 0 && [llength $moved_term_sinks] == 0} {
    ::tier_split_or2::record_skip $fp $net_name "no_sinks_on_selected_buffer_tier" "buffer_tier=$buffer_tier"
    return [list 0 "no_sinks_on_selected_buffer_tier"]
  }
  if {[llength $moved_term_sinks] > 0} {
    ::tier_split_or2::record_skip $fp $net_name "top_level_sink_rewire_not_supported" "buffer_tier=$buffer_tier"
    return [list 0 "top_level_sink_rewire_not_supported"]
  }

  set moved_sink_count [expr {[llength $moved_inst_sinks] + [llength $moved_term_sinks]}]
  set buffer_info [::tier_split_or2::choose_buffer_master $buffer_tier $moved_sink_count]
  if {$buffer_info eq ""} {
    ::tier_split_or2::record_skip $fp $net_name "no_tier_buffer_master" "buffer_tier=$buffer_tier"
    return [list 0 "no_tier_buffer_master"]
  }
  lassign $buffer_info buffer_master_name buffer_in_pin buffer_out_pin buffer_area chosen_drive required_drive
  set buffer_master [::tier_split_or2::find_master_by_name $buffer_master_name]
  if {$buffer_master eq ""} {
    ::tier_split_or2::record_skip $fp $net_name "buffer_master_lookup_failed" "buffer_master=$buffer_master_name"
    return [list 0 "buffer_master_lookup_failed"]
  }

  set safe_net_name [::tier_split_or2::sanitize_name_component $net_name]
  set inst_name [::tier_split_or2::ensure_unique_name $block "${safe_net_name}$CFG(buffer_inst_suffix)_${buffer_tier}"]
  set branch_net_name [::tier_split_or2::ensure_unique_name $block "${safe_net_name}$CFG(branch_net_suffix)_${buffer_tier}"]

  set decision_fields [::tier_split_or2::format_decision_fields $decision]
  puts $fp "ACTION net=$net_name driver=[::tier_split_or2::object_label $driver_kind $driver_obj] driver_tier=$driver_tier selection=$tier_reason chosen_tier=$buffer_tier $decision_fields buffer_master=$buffer_master_name buffer_area=$buffer_area buffer_tier=$buffer_tier retained_tier=$retained_tier moved_sink_count=$moved_sink_count chosen_drive=$chosen_drive required_drive=$required_drive new_inst=$inst_name new_net=$branch_net_name"

  if {$CFG(dry_run)} {
    foreach sink $moved_inst_sinks {
      puts $fp "  DRYRUN MOVE [::tier_split_or2::iterm_full_name $sink] -> $branch_net_name"
    }
    set dry_record [::tier_split_or2::build_split_record $net $driver_obj $buffer_tier $retained_tier $buffer_master_name $inst_name $branch_net_name $moved_inst_sinks $retained_inst_sinks $decision]
    return [list 1 "" $dry_record]
  }

  set buffer_inst [odb::dbInst_create $block $buffer_master $inst_name]
  if {$buffer_inst eq "" || $buffer_inst eq "NULL"} {
    ::tier_split_or2::record_skip $fp $net_name "dbInst_create_failed" "buffer_master=$buffer_master_name"
    return [list 0 "dbInst_create_failed" ""]
  }

  set anchor_inst [::tier_split_or2::anchor_inst_for_move $driver_obj $moved_inst_sinks]
  set anchor_loc [$anchor_inst getLocation]
  $buffer_inst setLocation [lindex $anchor_loc 0] [lindex $anchor_loc 1]
  catch {$buffer_inst setOrient [$anchor_inst getOrient]}
  catch {$buffer_inst setPlacementStatus [$anchor_inst getPlacementStatus]}

  set branch_net [odb::dbNet_create $block $branch_net_name]
  if {$branch_net eq "" || $branch_net eq "NULL"} {
    ::tier_split_or2::record_skip $fp $net_name "dbNet_create_failed" "new_net=$branch_net_name"
    catch {delete_instance $inst_name}
    return [list 0 "dbNet_create_failed" ""]
  }

  set buffer_in_it [$buffer_inst findITerm $buffer_in_pin]
  set buffer_out_it [$buffer_inst findITerm $buffer_out_pin]
  if {$buffer_in_it eq "" || $buffer_out_it eq ""} {
    ::tier_split_or2::record_skip $fp $net_name "buffer_pin_lookup_failed" "buffer_master=$buffer_master_name"
    catch {delete_instance $inst_name}
    catch {::odb::dbNet_destroy $branch_net}
    return [list 0 "buffer_pin_lookup_failed" ""]
  }

  $buffer_in_it connect $net
  $buffer_out_it connect $branch_net

  foreach sink $moved_inst_sinks {
    $sink connect $branch_net
    puts $fp "  MOVE SINK [::tier_split_or2::iterm_full_name $sink] -> $branch_net_name"
  }

  ::tier_split_or2::remember_created_split_objects $buffer_inst $branch_net $buffer_in_it $buffer_out_it $moved_inst_sinks
  set record [::tier_split_or2::build_split_record $net $driver_obj $buffer_tier $retained_tier $buffer_master_name $inst_name $branch_net_name $moved_inst_sinks $retained_inst_sinks $decision]
  set verify_status [::tier_split_or2::fast_verify_inserted_split $net $driver_obj $buffer_in_it $buffer_out_it $branch_net $moved_inst_sinks $retained_inst_sinks]
  set verify_state [dict get $verify_status status]
  if {$verify_state ne "valid"} {
    puts $fp "  VERIFY_FAIL status=$verify_state reason=[dict get $verify_status reason]"
    ::tier_split_or2::cleanup_failed_split $net $moved_inst_sinks $branch_net_name $inst_name
    return [list 0 "verify_[dict get $verify_status reason]" ""]
  }

  puts $fp "  VERIFY_OK status=$verify_state"
  return [list 1 "" $record]
}

proc ::tier_split_or2::driver_tier {driver_kind driver_obj} {
  switch -- $driver_kind {
    iterm { return [::tier_split_or2::classify_iterm $driver_obj] }
    bterm { return [::tier_split_or2::bterm_tier $driver_obj] }
    default { return unknown }
  }
}

proc ::tier_split_or2::driver_net {driver_obj} {
  if {$driver_obj eq "" || $driver_obj eq "NULL"} {
    return ""
  }
  if {[catch {set net [$driver_obj getNet]}]} {
    return ""
  }
  if {$net eq "" || $net eq "NULL"} {
    return ""
  }
  return $net
}

proc ::tier_split_or2::cleanup_failed_dual_split {original_net moved_inst_sinks branch_net_name bridge_net_name src_inst_name dst_inst_name} {
  foreach sink $moved_inst_sinks {
    catch {$sink connect $original_net}
  }
  foreach inst_name [list $src_inst_name $dst_inst_name] {
    if {$inst_name ne ""} {
      catch {delete_instance $inst_name}
    }
  }
  foreach net_name [list $branch_net_name $bridge_net_name] {
    if {$net_name eq ""} {
      continue
    }
    set net [_pin3d_find_net_by_name $net_name]
    if {$net ne "" && $net ne "NULL"} {
      catch {::odb::dbNet_destroy $net}
    }
  }
  _pin3d_rebuild_name_caches
}

proc ::tier_split_or2::remember_created_dual_split_objects {src_inst dst_inst bridge_net branch_net src_in src_out dst_in dst_out moved_inst_sinks} {
  foreach inst [list $src_inst $dst_inst] {
    set ::_PIN3D_INST_CACHE([$inst getName]) $inst
  }
  foreach net [list $bridge_net $branch_net] {
    set ::_PIN3D_NET_CACHE([$net getName]) $net
  }
  foreach iterm [concat [list $src_in $src_out $dst_in $dst_out] $moved_inst_sinks] {
    set ::_PIN3D_ITERM_CACHE([::tier_split_or2::iterm_full_name $iterm]) $iterm
  }
}

proc ::tier_split_or2::build_dual_split_record {net driver_kind driver_obj source_tier destination_tier src_master_name dst_master_name src_inst_name dst_inst_name bridge_net_name branch_net_name moved_inst_sinks retained_inst_sinks} {
  return [dict create \
    record_type dual_boundary \
    original_net [$net getName] \
    bridge_net $bridge_net_name \
    branch_net $branch_net_name \
    split_src_inst $src_inst_name \
    split_dst_inst $dst_inst_name \
    source_buffer_master $src_master_name \
    destination_buffer_master $dst_master_name \
    source_tier $source_tier \
    destination_tier $destination_tier \
    driver_kind $driver_kind \
    driver_pin [::tier_split_or2::object_label $driver_kind $driver_obj] \
    moved_sinks [::tier_split_or2::iterm_name_list $moved_inst_sinks] \
    retained_sinks [::tier_split_or2::iterm_name_list $retained_inst_sinks] \
    split_inst $dst_inst_name \
    buffer_master $dst_master_name \
    driver_tier $source_tier \
    buffer_tier $destination_tier \
    retained_tier $source_tier]
}

proc ::tier_split_or2::fast_verify_dual_split {original_net driver_obj source_tier destination_tier src_inst dst_inst src_in src_out dst_in dst_out bridge_net branch_net moved_inst_sinks retained_inst_sinks} {
  if {[::tier_split_or2::driver_net $driver_obj] ne $original_net} {
    return [dict create status violated reason driver_not_on_original_net]
  }
  if {[_pin3d_iterm_net $src_in] ne $original_net} {
    return [dict create status violated reason source_buffer_input_not_on_original_net]
  }
  if {[_pin3d_iterm_net $src_out] ne $bridge_net || [_pin3d_iterm_net $dst_in] ne $bridge_net} {
    return [dict create status violated reason bridge_endpoint_connection_invalid]
  }
  if {[_pin3d_iterm_net $dst_out] ne $branch_net} {
    return [dict create status violated reason destination_buffer_output_not_on_branch_net]
  }
  if {[::tier_split_or2::master_tier [$src_inst getMaster]] ne $source_tier} {
    return [dict create status violated reason source_buffer_tier_mismatch]
  }
  if {[::tier_split_or2::master_tier [$dst_inst getMaster]] ne $destination_tier} {
    return [dict create status violated reason destination_buffer_tier_mismatch]
  }
  foreach sink $moved_inst_sinks {
    if {[_pin3d_iterm_net $sink] ne $branch_net} {
      return [dict create status violated reason moved_sink_not_on_branch_net]
    }
  }
  foreach sink $retained_inst_sinks {
    if {[_pin3d_iterm_net $sink] ne $original_net} {
      return [dict create status violated reason retained_sink_not_on_original_net]
    }
  }
  set bridge_signal_iterms 0
  foreach iterm [$bridge_net getITerms] {
    set sig_type [::tier_split_or2::safe_sigtype [$iterm getMTerm]]
    if {$sig_type ne "POWER" && $sig_type ne "GROUND"} {
      incr bridge_signal_iterms
    }
  }
  set bridge_bterms 0
  catch {set bridge_bterms [llength [$bridge_net getBTerms]]}
  if {$bridge_signal_iterms != 2 || $bridge_bterms != 0} {
    return [dict create status violated reason bridge_not_point_to_point]
  }
  if {[net_has_mixed_fanout $original_net]} {
    return [dict create status violated reason original_net_still_mixed_fanout]
  }
  if {[net_has_mixed_fanout $branch_net]} {
    return [dict create status violated reason branch_net_still_mixed_fanout]
  }
  return [dict create status valid reason direct_dual_boundary_split_ok]
}

proc ::tier_split_or2::split_net_with_dual_buffers {block net driver_info sinks_by_tier fp} {
  variable CFG

  set net_name [$net getName]
  lassign $driver_info driver_kind driver_obj
  set source_tier [::tier_split_or2::driver_tier $driver_kind $driver_obj]
  if {$source_tier ni {upper bottom}} {
    ::tier_split_or2::record_skip $fp $net_name driver_tier_unknown "driver=[::tier_split_or2::object_label $driver_kind $driver_obj]"
    return [list 0 driver_tier_unknown ""]
  }
  set destination_tier [::tier_split_or2::opposite_tier $source_tier]

  set retained_inst_sinks [dict get $sinks_by_tier ${source_tier}_inst]
  set retained_term_sinks [dict get $sinks_by_tier ${source_tier}_term]
  set moved_inst_sinks [dict get $sinks_by_tier ${destination_tier}_inst]
  set moved_term_sinks [dict get $sinks_by_tier ${destination_tier}_term]
  if {[llength [dict get $sinks_by_tier unknown]] > 0} {
    ::tier_split_or2::record_skip $fp $net_name unknown_sink_tier "count=[llength [dict get $sinks_by_tier unknown]]"
    return [list 0 unknown_sink_tier ""]
  }
  if {[llength $moved_inst_sinks] == 0 && [llength $moved_term_sinks] == 0} {
    ::tier_split_or2::record_skip $fp $net_name no_destination_tier_sinks "destination_tier=$destination_tier"
    return [list 0 no_destination_tier_sinks ""]
  }
  if {[llength $moved_term_sinks] > 0} {
    ::tier_split_or2::record_skip $fp $net_name top_level_sink_rewire_not_supported "destination_tier=$destination_tier count=[llength $moved_term_sinks]"
    return [list 0 top_level_sink_rewire_not_supported ""]
  }

  set src_buffer_info [::tier_split_or2::choose_buffer_master $source_tier 1]
  set dst_buffer_info [::tier_split_or2::choose_buffer_master $destination_tier [llength $moved_inst_sinks]]
  if {$src_buffer_info eq ""} {
    ::tier_split_or2::record_skip $fp $net_name no_source_tier_buffer_master "source_tier=$source_tier"
    return [list 0 no_source_tier_buffer_master ""]
  }
  if {$dst_buffer_info eq ""} {
    ::tier_split_or2::record_skip $fp $net_name no_destination_tier_buffer_master "destination_tier=$destination_tier"
    return [list 0 no_destination_tier_buffer_master ""]
  }
  lassign $src_buffer_info src_master_name src_in_pin src_out_pin src_area src_drive src_required_drive
  lassign $dst_buffer_info dst_master_name dst_in_pin dst_out_pin dst_area dst_drive dst_required_drive
  set src_master [::tier_split_or2::find_master_by_name $src_master_name]
  set dst_master [::tier_split_or2::find_master_by_name $dst_master_name]
  if {$src_master eq "" || $dst_master eq ""} {
    ::tier_split_or2::record_skip $fp $net_name buffer_master_lookup_failed "source_master=$src_master_name destination_master=$dst_master_name"
    return [list 0 buffer_master_lookup_failed ""]
  }

  set safe_net_name [::tier_split_or2::sanitize_name_component $net_name]
  set src_inst_name [::tier_split_or2::ensure_unique_name $block "${safe_net_name}$CFG(source_buffer_suffix)_${source_tier}"]
  set dst_inst_name [::tier_split_or2::ensure_unique_name $block "${safe_net_name}$CFG(destination_buffer_suffix)_${destination_tier}"]
  set bridge_net_name [::tier_split_or2::ensure_unique_name $block "${safe_net_name}$CFG(bridge_net_suffix)_${source_tier}_${destination_tier}"]
  set branch_net_name [::tier_split_or2::ensure_unique_name $block "${safe_net_name}$CFG(branch_net_suffix)_${destination_tier}"]
  puts $fp "ACTION_DUAL net=$net_name driver=[::tier_split_or2::object_label $driver_kind $driver_obj] driver_kind=$driver_kind source_tier=$source_tier destination_tier=$destination_tier retained_inst_sinks=[llength $retained_inst_sinks] retained_term_sinks=[llength $retained_term_sinks] moved_sinks=[llength $moved_inst_sinks] source_master=$src_master_name source_drive=$src_drive destination_master=$dst_master_name destination_drive=$dst_drive source_inst=$src_inst_name destination_inst=$dst_inst_name bridge_net=$bridge_net_name branch_net=$branch_net_name"

  set record [::tier_split_or2::build_dual_split_record $net $driver_kind $driver_obj $source_tier $destination_tier $src_master_name $dst_master_name $src_inst_name $dst_inst_name $bridge_net_name $branch_net_name $moved_inst_sinks $retained_inst_sinks]
  if {$CFG(dry_run)} {
    foreach sink $moved_inst_sinks {
      puts $fp "  DRYRUN MOVE [::tier_split_or2::iterm_full_name $sink] -> $branch_net_name"
    }
    return [list 1 "" $record]
  }

  set src_inst [odb::dbInst_create $block $src_master $src_inst_name]
  if {$src_inst eq "" || $src_inst eq "NULL"} {
    ::tier_split_or2::record_skip $fp $net_name source_dbInst_create_failed "master=$src_master_name"
    return [list 0 source_dbInst_create_failed ""]
  }
  set dst_inst [odb::dbInst_create $block $dst_master $dst_inst_name]
  if {$dst_inst eq "" || $dst_inst eq "NULL"} {
    catch {delete_instance $src_inst_name}
    ::tier_split_or2::record_skip $fp $net_name destination_dbInst_create_failed "master=$dst_master_name"
    return [list 0 destination_dbInst_create_failed ""]
  }

  set anchor_inst [[lindex $moved_inst_sinks 0] getInst]
  set anchor_loc [$anchor_inst getLocation]
  foreach split_inst [list $src_inst $dst_inst] {
    $split_inst setLocation [lindex $anchor_loc 0] [lindex $anchor_loc 1]
    catch {$split_inst setOrient [$anchor_inst getOrient]}
    catch {$split_inst setPlacementStatus [$anchor_inst getPlacementStatus]}
  }

  set bridge_net [odb::dbNet_create $block $bridge_net_name]
  set branch_net [odb::dbNet_create $block $branch_net_name]
  if {$bridge_net eq "" || $bridge_net eq "NULL" || $branch_net eq "" || $branch_net eq "NULL"} {
    ::tier_split_or2::cleanup_failed_dual_split $net $moved_inst_sinks $branch_net_name $bridge_net_name $src_inst_name $dst_inst_name
    ::tier_split_or2::record_skip $fp $net_name dual_net_create_failed "bridge=$bridge_net_name branch=$branch_net_name"
    return [list 0 dual_net_create_failed ""]
  }

  set src_in [$src_inst findITerm $src_in_pin]
  set src_out [$src_inst findITerm $src_out_pin]
  set dst_in [$dst_inst findITerm $dst_in_pin]
  set dst_out [$dst_inst findITerm $dst_out_pin]
  if {$src_in eq "" || $src_out eq "" || $dst_in eq "" || $dst_out eq ""} {
    ::tier_split_or2::cleanup_failed_dual_split $net $moved_inst_sinks $branch_net_name $bridge_net_name $src_inst_name $dst_inst_name
    ::tier_split_or2::record_skip $fp $net_name buffer_pin_lookup_failed "source_master=$src_master_name destination_master=$dst_master_name"
    return [list 0 buffer_pin_lookup_failed ""]
  }

  $src_in connect $net
  $src_out connect $bridge_net
  $dst_in connect $bridge_net
  $dst_out connect $branch_net
  foreach sink $moved_inst_sinks {
    $sink connect $branch_net
    puts $fp "  MOVE SINK [::tier_split_or2::iterm_full_name $sink] -> $branch_net_name"
  }

  ::tier_split_or2::remember_created_dual_split_objects $src_inst $dst_inst $bridge_net $branch_net $src_in $src_out $dst_in $dst_out $moved_inst_sinks
  set verify_status [::tier_split_or2::fast_verify_dual_split $net $driver_obj $source_tier $destination_tier $src_inst $dst_inst $src_in $src_out $dst_in $dst_out $bridge_net $branch_net $moved_inst_sinks $retained_inst_sinks]
  if {[dict get $verify_status status] ne "valid"} {
    puts $fp "  VERIFY_FAIL status=[dict get $verify_status status] reason=[dict get $verify_status reason]"
    ::tier_split_or2::cleanup_failed_dual_split $net $moved_inst_sinks $branch_net_name $bridge_net_name $src_inst_name $dst_inst_name
    return [list 0 "verify_[dict get $verify_status reason]" ""]
  }

  puts $fp "  VERIFY_OK status=valid topology=dual_boundary"
  return [list 1 "" $record]
}

proc ::tier_split_or2::run {} {
  variable CFG
  variable INST_TIER_CACHE
  variable ITERM_TIER_CACHE
  variable BTERM_TIER_CACHE
  variable TIER_UTILIZATION
  set block [ord::get_db_block]
  _pin3d_rebuild_name_caches
  array unset INST_TIER_CACHE
  array unset ITERM_TIER_CACHE
  array unset BTERM_TIER_CACHE
  set TIER_UTILIZATION {}
  set tier_util [::tier_split_or2::compute_tier_global_utilization $block]
  set fp [open $CFG(report_file) w]

  puts $fp "# tier_split_or2"
  puts $fp "# mode=dual_boundary_buffer_split"
  puts $fp "# dry_run=$CFG(dry_run)"
  puts $fp "# split_y_um=$CFG(split_y_um)"
  puts $fp "# tier_utilization method=[dict get $tier_util method] core_area=[dict get $tier_util core_area] util_upper=[dict get $tier_util upper] util_bottom=[dict get $tier_util bottom] area_upper=[dict get $tier_util upper_area] area_bottom=[dict get $tier_util bottom_area] total_cell_area=[dict get $tier_util total_cell_area]"
  puts $fp "# cost_policy util_safe=$CFG(util_safe) util_alpha=$CFG(util_alpha) util_weight=$CFG(util_weight) hbt_weight=$CFG(hbt_weight) area_weight=$CFG(area_weight) high_util_forbid=$CFG(high_util_forbid) near_tie_ratio=$CFG(near_tie_ratio)"
  puts $fp ""

  if {$CFG(dump_cell_tier)} {
    puts $fp "## CELL_TIER"
    foreach inst [$block getInsts] {
      puts $fp "CELL [$inst getName] [::tier_split_or2::classify_inst $inst]"
    }
    puts $fp ""
  }
  if {$CFG(dump_pin_tier)} {
    puts $fp "## PIN_TIER"
    foreach inst [$block getInsts] {
      foreach iterm [$inst getITerms] {
        puts $fp "PIN [::tier_split_or2::iterm_full_name $iterm] [::tier_split_or2::classify_iterm $iterm]"
      }
    }
    puts $fp ""
  }

  puts $fp "## NET_ACTIONS"

  set split_cnt 0
  set skip_cnt 0
  set mixed_tier_nets 0
  set crossing_nets 0
  set pure_crossing_nets 0
  set candidate_nets 0
  set manifest_records {}
  array set skip_reason_counts {}
  array set clock_net_lookup {}
  if {$CFG(skip_clock_nets)} {
    foreach clock_net_name [_clock_net_name_set] {
      set clock_net_lookup($clock_net_name) 1
    }
  }

  set original_net_names {}
  ::tier_split_or2::init_existing_names $block
  foreach net [$block getNets] {
    lappend original_net_names [$net getName]
  }

  foreach net_name $original_net_names {
    set net [_pin3d_find_net_by_name $net_name]
    if {$net eq "" || $net eq "NULL"} {
      continue
    }
    if {[_split_branch_name_match $net_name] || [_net_touches_split_buffer_inst $net]} {
      ::tier_split_or2::record_skip $fp $net_name "split_generated_net" ""
      incr skip_cnt
      if {![info exists skip_reason_counts(split_generated_net)]} {
        set skip_reason_counts(split_generated_net) 0
      }
      incr skip_reason_counts(split_generated_net)
      continue
    }
    if {$CFG(skip_clock_nets) && [info exists clock_net_lookup($net_name)]} {
      ::tier_split_or2::record_skip $fp $net_name "clock_net" ""
      incr skip_cnt
      if {![info exists skip_reason_counts(clock_net)]} {
        set skip_reason_counts(clock_net) 0
      }
      incr skip_reason_counts(clock_net)
      continue
    }

    set sinks_by_tier [::tier_split_or2::collect_sinks_by_tier $net]
    set upper_total [expr {[llength [dict get $sinks_by_tier upper_inst]] + [llength [dict get $sinks_by_tier upper_term]]}]
    set bottom_total [expr {[llength [dict get $sinks_by_tier bottom_inst]] + [llength [dict get $sinks_by_tier bottom_term]]}]
    set both_sink_tiers [expr {$upper_total > 0 && $bottom_total > 0}]

    if {$both_sink_tiers} {
      incr mixed_tier_nets
    }
    if {$CFG(require_both_sink_tiers) && !$both_sink_tiers} {
      continue
    }
    if {$upper_total == 0 && $bottom_total == 0} {
      continue
    }

    lassign [::tier_split_or2::get_net_driver $net] driver_info driver_reason
    if {$driver_info eq ""} {
      # With sinks on both tiers the net is unquestionably crossing even when
      # its driver is unsupported.  A one-tier sink net is only a crossing
      # candidate after the driver tier is known.
      if {!$both_sink_tiers} {
        continue
      }
      incr crossing_nets
      ::tier_split_or2::record_skip $fp $net_name $driver_reason ""
      incr skip_cnt
      if {![info exists skip_reason_counts($driver_reason)]} {
        set skip_reason_counts($driver_reason) 0
      }
      incr skip_reason_counts($driver_reason)
      continue
    }

    lassign $driver_info driver_kind driver_obj
    set source_tier [::tier_split_or2::driver_tier $driver_kind $driver_obj]
    set destination_tier [::tier_split_or2::opposite_tier $source_tier]
    if {$destination_tier ni {upper bottom}} {
      if {$both_sink_tiers} {
        incr crossing_nets
      }
      ::tier_split_or2::record_skip $fp $net_name driver_tier_unknown \
        "driver=[::tier_split_or2::object_label $driver_kind $driver_obj]"
      incr skip_cnt
      if {![info exists skip_reason_counts(driver_tier_unknown)]} {
        set skip_reason_counts(driver_tier_unknown) 0
      }
      incr skip_reason_counts(driver_tier_unknown)
      continue
    }
    set destination_total [expr {\
      [llength [dict get $sinks_by_tier ${destination_tier}_inst]] + \
      [llength [dict get $sinks_by_tier ${destination_tier}_term]]}]
    if {$destination_total == 0} {
      continue
    }
    incr crossing_nets
    if {!$both_sink_tiers} {
      incr pure_crossing_nets
    }
    incr candidate_nets

    lassign [::tier_split_or2::split_net_with_dual_buffers $block $net $driver_info $sinks_by_tier $fp] split_ok split_reason split_record
    if {$split_ok} {
      incr split_cnt
      if {$split_record ne ""} {
        lappend manifest_records $split_record
      }
    } else {
      incr skip_cnt
      if {$split_reason ne ""} {
        if {![info exists skip_reason_counts($split_reason)]} {
          set skip_reason_counts($split_reason) 0
        }
        incr skip_reason_counts($split_reason)
      }
    }
  }

  if {$CFG(manifest_file) ne ""} {
    pin3d_write_split_manifest $manifest_records $CFG(manifest_file)
  }

  puts $fp ""
  puts $fp "# split_count=$split_cnt"
  puts $fp "# skip_count=$skip_cnt"
  puts $fp "# mixed_tier_nets=$mixed_tier_nets"
  puts $fp "# mixed_fanout_nets=$mixed_tier_nets"
  puts $fp "# crossing_nets=$crossing_nets"
  puts $fp "# pure_crossing_nets=$pure_crossing_nets"
  puts $fp "# candidate_nets=$candidate_nets"
  puts $fp "# processed_residual=[expr {$candidate_nets - $split_cnt}]"
  puts $fp "# util_upper=[dict get $tier_util upper]"
  puts $fp "# util_bottom=[dict get $tier_util bottom]"
  puts $fp "# util_method=[dict get $tier_util method]"
  puts $fp "# total_cell_area=[dict get $tier_util total_cell_area]"
  if {[array size skip_reason_counts] > 0} {
    puts $fp "# skip_reasons"
    foreach reason [lsort [array names skip_reason_counts]] {
      puts $fp "#   $reason $skip_reason_counts($reason)"
    }
  }
  close $fp

  puts "tier_split_or2: wrote $CFG(report_file)"
  puts "tier_split_or2: split_count=$split_cnt skip_count=$skip_cnt crossing_nets=$crossing_nets mixed_tier_nets=$mixed_tier_nets pure_crossing_nets=$pure_crossing_nets candidate_nets=$candidate_nets dry_run=$CFG(dry_run)"
  return [dict create \
    split_count $split_cnt \
    skip_count $skip_cnt \
    mixed_tier_nets $mixed_tier_nets \
    mixed_fanout_nets $mixed_tier_nets \
    crossing_nets $crossing_nets \
    pure_crossing_nets $pure_crossing_nets \
    candidate_nets $candidate_nets \
    processed_residual [expr {$candidate_nets - $split_cnt}] \
    manifest_records $manifest_records \
    manifest_file $CFG(manifest_file) \
    dry_run $CFG(dry_run) \
    report_file $CFG(report_file) \
    skip_reason_counts [array get skip_reason_counts]]
}
