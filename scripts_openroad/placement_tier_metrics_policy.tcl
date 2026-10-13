# ============================================================
# placement_tier_metrics_policy.tcl
# Tier classification, cross-tier/mixed-fanout reporting, and optimization masks.
# Split out from placement_utils.tcl to keep stage source files lighter.
# ============================================================

if {![info exists ::pin3d_metric_snapshot_epoch]} {
  set ::pin3d_metric_snapshot_epoch 0
}
array unset ::pin3d_metric_snapshot_cache
array set ::pin3d_metric_snapshot_cache {}
array unset ::pin3d_metric_report_cache
array set ::pin3d_metric_report_cache {}
array unset ::pin3d_clock_net_name_cache
array set ::pin3d_clock_net_name_cache {}
array unset ::pin3d_clock_propagation_graph_cache
array set ::pin3d_clock_propagation_graph_cache {}

proc _pin3d_metric_report_mode {} {
  if {[info exists ::env(PIN3D_SKIP_HEAVY_METRIC_REPORTS)]} {
    set skip_flag $::env(PIN3D_SKIP_HEAVY_METRIC_REPORTS)
    if {$skip_flag ni {0 false FALSE off OFF no NO ""}} {
      return "off"
    }
  }

  set mode "off"
  if {[info exists ::env(PIN3D_METRIC_REPORT_MODE)] && $::env(PIN3D_METRIC_REPORT_MODE) ne ""} {
    set mode [string tolower $::env(PIN3D_METRIC_REPORT_MODE)]
  }

  switch -- $mode {
    full -
    detail {
      return "full"
    }
    summary -
    stats -
    fast {
      return "summary"
    }
    off -
    none -
    skip {
      return "off"
    }
    default {
      return "full"
    }
  }
}

proc pin3d_metrics_invalidate_cache {} {
  if {![info exists ::pin3d_metric_snapshot_epoch]} {
    set ::pin3d_metric_snapshot_epoch 0
  }
  incr ::pin3d_metric_snapshot_epoch
}

proc _pin3d_metric_snapshot_cache_key {clock_only sdc_path} {
  if {![info exists ::pin3d_metric_snapshot_epoch]} {
    set ::pin3d_metric_snapshot_epoch 0
  }
  return [format "%d|%d|%s" $::pin3d_metric_snapshot_epoch $clock_only $sdc_path]
}

proc _pin3d_metric_report_cache_get {report_path kind} {
  if {$report_path eq "" || ![info exists ::pin3d_metric_report_cache($report_path)]} {
    return ""
  }
  set entry $::pin3d_metric_report_cache($report_path)
  if {[dict get $entry kind] ne $kind} {
    return ""
  }
  return [dict get $entry snapshot]
}

proc _pin3d_metric_report_cache_put {report_path kind snapshot} {
  if {$report_path eq ""} {
    return
  }
  set ::pin3d_metric_report_cache($report_path) [dict create kind $kind snapshot $snapshot]
}

proc _or_inst_tier {inst} {
  set master [$inst getMaster]
  set mname [$master getName]
  set iname [$inst getName]
  if {[_or_is_split_buffer_name $mname] || [_or_is_split_buffer_name $iname]} {
    return "split_buffer"
  }
  if {[string match -nocase "*_upper" $mname]} {
    return "upper"
  }
  if {[string match -nocase "*_bottom" $mname] || [string match -nocase "*_lower" $mname]} {
    return "bottom"
  }
  return "unknown"
}

proc _net_tier_presence {net_ptr} {
  set upper_count 0
  set bottom_count 0
  set unknown_count 0

  foreach it [$net_ptr getITerms] {
    set mt [$it getMTerm]
    if {[catch {set st [$mt getSigType]}]} {
      set st "SIGNAL"
    }
    if {$st eq "POWER" || $st eq "GROUND"} {
      continue
    }

    set tier [_or_inst_tier [$it getInst]]
    switch -- $tier {
      upper   { incr upper_count }
      bottom  { incr bottom_count }
      split_buffer { continue }
      default { incr unknown_count }
    }
  }

  return [list $upper_count $bottom_count $unknown_count]
}

proc _or_layer_to_tier {layer_name} {
  set layer_name [string trim $layer_name]
  if {$layer_name eq ""} {
    return "unknown"
  }

  set lname [string tolower $layer_name]
  if {$lname eq "hb_layer"} {
    return "unknown"
  }
  if {[string match "via*" $lname]} {
    return "unknown"
  }
  if {[string match "*_m" $lname]} {
    return "upper"
  }
  return "bottom"
}

proc _or_bterm_routing_layers {bterm_ptr} {
  set layers {}
  if {$bterm_ptr eq ""} {
    return $layers
  }

  if {[catch {set bpins [$bterm_ptr getBPins]}]} {
    return $layers
  }
  foreach bpin $bpins {
    if {[catch {set boxes [$bpin getBoxes]}]} {
      continue
    }
    foreach box $boxes {
      if {[catch {set layer [$box getTechLayer]}]} {
        continue
      }
      if {$layer eq "" || $layer eq "NULL"} {
        continue
      }
      if {[catch {set layer_name [$layer getName]}]} {
        continue
      }
      if {$layer_name eq ""} {
        continue
      }
      lappend layers $layer_name
    }
  }
  return [lsort -unique $layers]
}

proc _or_bterm_tier {bterm_ptr} {
  set has_upper 0
  set has_bottom 0
  foreach layer [_or_bterm_routing_layers $bterm_ptr] {
    switch -- [_or_layer_to_tier $layer] {
      upper {
        set has_upper 1
      }
      bottom {
        set has_bottom 1
      }
      default {
      }
    }
  }

  if {$has_upper && !$has_bottom} {
    return "upper"
  }
  if {$has_bottom && !$has_upper} {
    return "bottom"
  }
  return "unknown"
}

proc _or_split_buffer_physical_tier {inst} {
  set master [$inst getMaster]
  set mname [$master getName]
  set iname [$inst getName]
  if {[string match -nocase "*_upper" $mname] || [string match -nocase "*_upper" $iname]} {
    return "upper"
  }
  if {[string match -nocase "*_bottom" $mname] || [string match -nocase "*_lower" $mname] \
      || [string match -nocase "*_bottom" $iname] || [string match -nocase "*_lower" $iname]} {
    return "bottom"
  }
  return "unknown"
}

proc tier_net_structural_presence_detail_counts {net_ptr} {
  set upper_count 0
  set bottom_count 0
  set io_count 0
  set unknown_count 0

  foreach it [$net_ptr getITerms] {
    set mt [$it getMTerm]
    if {[catch {set st [$mt getSigType]}]} {
      set st "SIGNAL"
    }
    if {$st eq "POWER" || $st eq "GROUND"} {
      continue
    }

    set inst [$it getInst]
    set tier [_or_inst_tier $inst]
    if {$tier eq "split_buffer"} {
      set tier [_or_split_buffer_physical_tier $inst]
    }
    switch -- $tier {
      upper   { incr upper_count }
      bottom  { incr bottom_count }
      default { incr unknown_count }
    }
  }

  if {![catch {set bterms [$net_ptr getBTerms]}]} {
    foreach bterm $bterms {
      if {[catch {set st [$bterm getSigType]}]} {
        set st "SIGNAL"
      }
      if {$st eq "POWER" || $st eq "GROUND"} {
        continue
      }
      incr io_count
      switch -- [_or_bterm_tier $bterm] {
        upper {
          incr upper_count
        }
        bottom {
          incr bottom_count
        }
        default {
          incr unknown_count
        }
      }
    }
  }

  return [list $upper_count $bottom_count $io_count $unknown_count]
}

proc tier_net_presence_detail_counts {net_ptr} {
  set upper_count 0
  set bottom_count 0
  set io_count 0
  set unknown_count 0

  foreach it [$net_ptr getITerms] {
    set mt [$it getMTerm]
    if {[catch {set st [$mt getSigType]}]} {
      set st "SIGNAL"
    }
    if {$st eq "POWER" || $st eq "GROUND"} {
      continue
    }

    set tier [_or_inst_tier [$it getInst]]
    switch -- $tier {
      upper   { incr upper_count }
      bottom  { incr bottom_count }
      split_buffer { continue }
      default { incr unknown_count }
    }
  }

  if {![catch {set bterms [$net_ptr getBTerms]}]} {
    foreach bterm $bterms {
      if {[catch {set st [$bterm getSigType]}]} {
        set st "SIGNAL"
      }
      if {$st eq "POWER" || $st eq "GROUND"} {
        continue
      }
      incr io_count
      switch -- [_or_bterm_tier $bterm] {
        upper {
          incr upper_count
        }
        bottom {
          incr bottom_count
        }
        default {
          incr unknown_count
        }
      }
    }
  }

  return [list $upper_count $bottom_count $io_count $unknown_count]
}

proc tier_net_mixed_fanout_detail_counts {net_ptr} {
  set upper_count 0
  set bottom_count 0
  set io_count 0
  set unknown_count 0

  foreach it [$net_ptr getITerms] {
    set mt [$it getMTerm]
    if {[catch {set st [$mt getSigType]}]} {
      set st "SIGNAL"
    }
    if {$st eq "POWER" || $st eq "GROUND"} {
      continue
    }
    if {[catch {set io_type [$mt getIoType]}]} {
      set io_type ""
    }
    if {$io_type ne "INPUT"} {
      continue
    }

    set tier [_or_inst_tier [$it getInst]]
    switch -- $tier {
      upper   { incr upper_count }
      bottom  { incr bottom_count }
      split_buffer { continue }
      default { incr unknown_count }
    }
  }

  if {![catch {set bterms [$net_ptr getBTerms]}]} {
    foreach bterm $bterms {
      if {[catch {set st [$bterm getSigType]}]} {
        set st "SIGNAL"
      }
      if {$st eq "POWER" || $st eq "GROUND"} {
        continue
      }
      if {[catch {set io_type [$bterm getIoType]}]} {
        set io_type ""
      }
      if {$io_type ne "OUTPUT"} {
        continue
      }

      incr io_count
      switch -- [_or_bterm_tier $bterm] {
        upper {
          incr upper_count
        }
        bottom {
          incr bottom_count
        }
        default {
          incr unknown_count
        }
      }
    }
  }

  return [list $upper_count $bottom_count $io_count $unknown_count]
}

proc _cross_tier_category_from_presence {has_upper has_bottom has_io has_unknown} {
  if {$has_upper && $has_bottom && $has_io} {
    return "Upper_Bottom_IO"
  }
  if {$has_upper && $has_bottom} {
    return "Upper_Bottom"
  }
  if {$has_upper && $has_io} {
    return "Upper_IO"
  }
  if {$has_bottom && $has_io} {
    return "Bottom_IO"
  }
  if {$has_unknown} {
    return "Unknown_Tier"
  }
  return ""
}

proc _mixed_fanout_category_from_presence {has_upper has_bottom has_io has_unknown} {
  if {$has_unknown} {
    return "Unknown_Tier"
  }
  if {$has_upper && $has_bottom && $has_io} {
    return "Upper_Bottom_IO"
  }
  if {$has_upper && $has_bottom} {
    return "Upper_Bottom"
  }
  return ""
}

proc _build_tier_metric_snapshot {args} {
  array set opt {
    -clock_only 0
    -sdc_path ""
  }
  if {([llength $args] % 2) != 0} {
    error "_build_tier_metric_snapshot: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "_build_tier_metric_snapshot: unknown option $k"
    }
    set opt($k) $v
  }

  set cache_key [_pin3d_metric_snapshot_cache_key $opt(-clock_only) $opt(-sdc_path)]
  if {[info exists ::pin3d_metric_snapshot_cache($cache_key)]} {
    return $::pin3d_metric_snapshot_cache($cache_key)
  }

  set report_mode [_pin3d_metric_report_mode]
  if {$report_mode eq "off"} {
    set empty_snapshot [dict create \
      mode $report_mode \
      clock_only $opt(-clock_only) \
      cross_entries [dict create] \
      mixed_entries [dict create] \
      cross_stats [dict create \
        cross_tier_all 0 \
        upper_bottom 0 \
        upper_io 0 \
        bottom_io 0 \
        upper_bottom_io 0 \
        unknown 0] \
      mixed_stats [dict create \
        mixed_fanout_all 0 \
        upper_bottom 0 \
        upper_bottom_io 0 \
        unknown 0]]
    set ::pin3d_metric_snapshot_cache($cache_key) $empty_snapshot
    return $empty_snapshot
  }

  set cross_total 0
  array set cross_counts {
    Upper_Bottom    0
    Upper_IO        0
    Bottom_IO       0
    Upper_Bottom_IO 0
    Unknown_Tier    0
  }

  set mixed_total 0
  array set mixed_counts {
    Upper_Bottom    0
    Upper_Bottom_IO 0
    Unknown_Tier    0
  }

  set cross_entries [dict create]
  set mixed_entries [dict create]
  set collect_entries [expr {$report_mode eq "full"}]
  array set clock_net_lookup {}
  if {$opt(-clock_only)} {
    foreach clock_net_name [_clock_net_name_set $opt(-sdc_path)] {
      set clock_net_lookup($clock_net_name) 1
    }
  }

  set block [ord::get_db_block]
  foreach net [$block getNets] {
    set sig_type [$net getSigType]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
      continue
    }
    set net_name [$net getName]
    if {$opt(-clock_only) && ![info exists clock_net_lookup($net_name)]} {
      continue
    }

    lassign [tier_net_structural_presence_detail_counts $net] upper_count bottom_count io_count unknown_count
    set cross_type [_cross_tier_category_from_presence \
      [expr {$upper_count > 0}] \
      [expr {$bottom_count > 0}] \
      [expr {$io_count > 0}] \
      [expr {$unknown_count > 0}]]
    if {$cross_type ne ""} {
      if {$cross_type ne "Unknown_Tier"} {
        incr cross_total
      }
      incr cross_counts($cross_type)
      if {$collect_entries} {
        dict set cross_entries $net_name $cross_type
      }
    }

    lassign [tier_net_mixed_fanout_detail_counts $net] upper_count bottom_count io_count unknown_count
    set mixed_type [_mixed_fanout_category_from_presence \
      [expr {$upper_count > 0}] \
      [expr {$bottom_count > 0}] \
      [expr {$io_count > 0}] \
      [expr {$unknown_count > 0}]]
    if {$mixed_type ne ""} {
      if {$mixed_type ne "Unknown_Tier"} {
        incr mixed_total
      }
      incr mixed_counts($mixed_type)
      if {$collect_entries} {
        dict set mixed_entries $net_name $mixed_type
      }
    }
  }

  set snapshot [dict create \
    mode $report_mode \
    clock_only $opt(-clock_only) \
    cross_entries $cross_entries \
    mixed_entries $mixed_entries \
    cross_stats [dict create \
      cross_tier_all $cross_total \
      upper_bottom $cross_counts(Upper_Bottom) \
      upper_io $cross_counts(Upper_IO) \
      bottom_io $cross_counts(Bottom_IO) \
      upper_bottom_io $cross_counts(Upper_Bottom_IO) \
      unknown $cross_counts(Unknown_Tier)] \
    mixed_stats [dict create \
      mixed_fanout_all $mixed_total \
      upper_bottom $mixed_counts(Upper_Bottom) \
      upper_bottom_io $mixed_counts(Upper_Bottom_IO) \
      unknown $mixed_counts(Unknown_Tier)]]
  set ::pin3d_metric_snapshot_cache($cache_key) $snapshot
  return $snapshot
}

proc _cross_tier_report_lines_from_snapshot {snapshot} {
  set mode [dict get $snapshot mode]
  set stats [dict get $snapshot cross_stats]
  set entries [dict get $snapshot cross_entries]
  set report_lines [list "# Cross-Tier Net Report"]
  if {$mode eq "full"} {
    lappend report_lines [format "%-40s | %s" "Net Name" "Type"]
    lappend report_lines "-----------------------------------------|------------------"
    foreach net_name [lsort [dict keys $entries]] {
      lappend report_lines [format "%-40s | %s" $net_name [dict get $entries $net_name]]
    }
  } elseif {$mode eq "summary"} {
    lappend report_lines "# detail_omitted 1"
    lappend report_lines "# report_mode summary"
  } else {
    lappend report_lines "# detail_omitted 1"
    lappend report_lines "# report_mode off"
  }
  lappend report_lines ""
  lappend report_lines [format "Total Cross-Tier Nets: %d" [dict get $stats cross_tier_all]]
  lappend report_lines "Category Totals:"
  foreach key {Upper_Bottom Upper_IO Bottom_IO Upper_Bottom_IO Unknown_Tier} {
    set mapped_key [string tolower $key]
    if {$mapped_key eq "upper_bottom"} {
      set value [dict get $stats upper_bottom]
    } elseif {$mapped_key eq "upper_io"} {
      set value [dict get $stats upper_io]
    } elseif {$mapped_key eq "bottom_io"} {
      set value [dict get $stats bottom_io]
    } elseif {$mapped_key eq "upper_bottom_io"} {
      set value [dict get $stats upper_bottom_io]
    } else {
      set value [dict get $stats unknown]
    }
    lappend report_lines [format "  %-18s %d" $key $value]
  }
  return $report_lines
}

proc _mixed_fanout_report_lines_from_snapshot {snapshot} {
  set mode [dict get $snapshot mode]
  set stats [dict get $snapshot mixed_stats]
  set entries [dict get $snapshot mixed_entries]
  set report_lines [list "# Mixed-Fanout Net Report"]
  if {$mode eq "full"} {
    lappend report_lines [format "%-40s | %s" "Net Name" "Type"]
    lappend report_lines "-----------------------------------------|------------------"
    foreach net_name [lsort [dict keys $entries]] {
      lappend report_lines [format "%-40s | %s" $net_name [dict get $entries $net_name]]
    }
  } elseif {$mode eq "summary"} {
    lappend report_lines "# detail_omitted 1"
    lappend report_lines "# report_mode summary"
  } else {
    lappend report_lines "# detail_omitted 1"
    lappend report_lines "# report_mode off"
  }
  lappend report_lines ""
  lappend report_lines [format "Total Mixed-Fanout Nets: %d" [dict get $stats mixed_fanout_all]]
  lappend report_lines "Category Totals:"
  foreach key {Upper_Bottom Upper_Bottom_IO Unknown_Tier} {
    if {$key eq "Upper_Bottom"} {
      set value [dict get $stats upper_bottom]
    } elseif {$key eq "Upper_Bottom_IO"} {
      set value [dict get $stats upper_bottom_io]
    } else {
      set value [dict get $stats unknown]
    }
    lappend report_lines [format "  %-18s %d" $key $value]
  }
  return $report_lines
}

proc _write_tier_metric_report {report_path lines} {
  if {$report_path eq ""} {
    return
  }
  set fh [open $report_path w]
  foreach line $lines {
    puts $fh $line
  }
  close $fh
}

proc extract_cross_tier_net_stats {list_rpt_path args} {
  array set opt {
    -clock_only 0
  }
  if {([llength $args] % 2) != 0} {
    error "extract_cross_tier_nets: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "extract_cross_tier_nets: unknown option $k"
    }
    set opt($k) $v
  }
  set snapshot [_build_tier_metric_snapshot -clock_only $opt(-clock_only)]
  _write_tier_metric_report $list_rpt_path [_cross_tier_report_lines_from_snapshot $snapshot]
  _pin3d_metric_report_cache_put $list_rpt_path cross_tier $snapshot
  return [dict get $snapshot cross_stats]
}

proc extract_mixed_fanout_net_stats {list_rpt_path args} {
  array set opt {
    -clock_only 0
  }
  if {([llength $args] % 2) != 0} {
    error "extract_mixed_fanout_net_stats: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "extract_mixed_fanout_net_stats: unknown option $k"
    }
    set opt($k) $v
  }
  set snapshot [_build_tier_metric_snapshot -clock_only $opt(-clock_only)]
  _write_tier_metric_report $list_rpt_path [_mixed_fanout_report_lines_from_snapshot $snapshot]
  _pin3d_metric_report_cache_put $list_rpt_path mixed_fanout $snapshot
  return [dict get $snapshot mixed_stats]
}

proc extract_cross_tier_nets {list_rpt_path args} {
  return [dict get [extract_cross_tier_net_stats $list_rpt_path {*}$args] cross_tier_all]
}

proc net_has_mixed_fanout {net_ptr} {
  lassign [tier_net_mixed_fanout_detail_counts $net_ptr] upper_count bottom_count io_count unknown_count
  set category [_mixed_fanout_category_from_presence \
    [expr {$upper_count > 0}] \
    [expr {$bottom_count > 0}] \
    [expr {$io_count > 0}] \
    [expr {$unknown_count > 0}]]
  return [expr {$category ne ""}]
}

proc _cross_tier_stats_brief {stats} {
  return [format "all=%d UB=%d UIO=%d BIO=%d UBIO=%d UNK=%d" \
    [dict get $stats cross_tier_all] \
    [dict get $stats upper_bottom] \
    [dict get $stats upper_io] \
    [dict get $stats bottom_io] \
    [dict get $stats upper_bottom_io] \
    [dict get $stats unknown]]
}

proc _mixed_fanout_stats_brief {stats} {
  return [format "all=%d UB=%d UBIO=%d UNK=%d" \
    [dict get $stats mixed_fanout_all] \
    [dict get $stats upper_bottom] \
    [dict get $stats upper_bottom_io] \
    [dict get $stats unknown]]
}

proc _read_cross_tier_report_stats {report_path} {
  if {$report_path eq "" || ![file exists $report_path]} {
    return ""
  }
  set cached_snapshot [_pin3d_metric_report_cache_get $report_path cross_tier]
  if {$cached_snapshot ne ""} {
    return [dict get $cached_snapshot cross_stats]
  }

  set stats [dict create \
    cross_tier_all 0 \
    upper_bottom 0 \
    upper_io 0 \
    bottom_io 0 \
    upper_bottom_io 0 \
    unknown 0]

  set fh [open $report_path r]
  while {[gets $fh line] >= 0} {
    if {[regexp {^Total Cross-Tier Nets:\s+([0-9]+)} $line -> value]} {
      dict set stats cross_tier_all $value
      continue
    }
    if {[regexp {^\s*Upper_Bottom\s+([0-9]+)} $line -> value]} {
      dict set stats upper_bottom $value
      continue
    }
    if {[regexp {^\s*Upper_IO\s+([0-9]+)} $line -> value]} {
      dict set stats upper_io $value
      continue
    }
    if {[regexp {^\s*Bottom_IO\s+([0-9]+)} $line -> value]} {
      dict set stats bottom_io $value
      continue
    }
    if {[regexp {^\s*Upper_Bottom_IO\s+([0-9]+)} $line -> value]} {
      dict set stats upper_bottom_io $value
      continue
    }
    if {[regexp {^\s*Unknown_Tier\s+([0-9]+)} $line -> value]} {
      dict set stats unknown $value
      continue
    }
  }
  close $fh
  return $stats
}

proc _read_mixed_fanout_report_stats {report_path} {
  if {$report_path eq "" || ![file exists $report_path]} {
    return ""
  }
  set cached_snapshot [_pin3d_metric_report_cache_get $report_path mixed_fanout]
  if {$cached_snapshot ne ""} {
    return [dict get $cached_snapshot mixed_stats]
  }

  set stats [dict create \
    mixed_fanout_all 0 \
    upper_bottom 0 \
    upper_bottom_io 0 \
    unknown 0]

  set fh [open $report_path r]
  while {[gets $fh line] >= 0} {
    if {[regexp {^Total Mixed-Fanout Nets:\s+([0-9]+)} $line -> value]} {
      dict set stats mixed_fanout_all $value
      continue
    }
    if {[regexp {^\s*Upper_Bottom\s+([0-9]+)} $line -> value]} {
      dict set stats upper_bottom $value
      continue
    }
    if {[regexp {^\s*Upper_Bottom_IO\s+([0-9]+)} $line -> value]} {
      dict set stats upper_bottom_io $value
      continue
    }
    if {[regexp {^\s*Unknown_Tier\s+([0-9]+)} $line -> value]} {
      dict set stats unknown $value
      continue
    }
  }
  close $fh
  return $stats
}

proc report_cross_tier_snapshot {report_path args} {
  array set opt {
    -label ""
    -clock_only 0
    -quiet 0
  }
  if {([llength $args] % 2) != 0} {
    error "report_cross_tier_snapshot: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "report_cross_tier_snapshot: unknown option $k"
    }
    set opt($k) $v
  }

  set stats [extract_cross_tier_net_stats $report_path -clock_only $opt(-clock_only)]
  if {!$opt(-quiet)} {
    set label $opt(-label)
    if {$label eq ""} {
      set label [file tail $report_path]
    }
    puts "INFO(OR): cross-tier snapshot $label mode=[_pin3d_metric_report_mode] [_cross_tier_stats_brief $stats]"
  }
  return $stats
}

proc report_mixed_fanout_snapshot {report_path args} {
  array set opt {
    -label ""
    -clock_only 0
    -quiet 0
  }
  if {([llength $args] % 2) != 0} {
    error "report_mixed_fanout_snapshot: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "report_mixed_fanout_snapshot: unknown option $k"
    }
    set opt($k) $v
  }

  set stats [extract_mixed_fanout_net_stats $report_path -clock_only $opt(-clock_only)]
  if {!$opt(-quiet)} {
    set label $opt(-label)
    if {$label eq ""} {
      set label [file tail $report_path]
    }
    puts "INFO(OR): mixed-fanout snapshot $label mode=[_pin3d_metric_report_mode] [_mixed_fanout_stats_brief $stats]"
  }
  return $stats
}

proc report_cross_tier_transition {summary_path before_report after_report args} {
  array set opt {
    -label ""
    -clock_only 0
    -quiet 0
  }
  if {([llength $args] % 2) != 0} {
    error "report_cross_tier_transition: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "report_cross_tier_transition: unknown option $k"
    }
    set opt($k) $v
  }

  set before_stats [_read_cross_tier_report_stats $before_report]
  if {$before_stats eq ""} {
    set before_stats [report_cross_tier_snapshot $before_report -label "${opt(-label)} before" -clock_only $opt(-clock_only) -quiet $opt(-quiet)]
  } elseif {!$opt(-quiet)} {
    puts "INFO(OR): cross-tier snapshot ${opt(-label)} before [_cross_tier_stats_brief $before_stats]"
  }
  set after_stats  [report_cross_tier_snapshot $after_report  -label "${opt(-label)} after"  -clock_only $opt(-clock_only) -quiet $opt(-quiet)]

  if {!$opt(-quiet)} {
    set before_all [dict get $before_stats cross_tier_all]
    set after_all [dict get $after_stats cross_tier_all]
    puts "INFO(OR): cross-tier transition $opt(-label) before=$before_all after=$after_all delta=[expr {$after_all - $before_all}]"
  }

  if {$summary_path ne ""} {
    set fh [open $summary_path w]
    puts $fh [format "label %s" $opt(-label)]
    puts $fh [format "clock_only %d" $opt(-clock_only)]
    foreach {tag stats} [list before $before_stats after $after_stats] {
      puts $fh "$tag [_cross_tier_stats_brief $stats]"
      puts $fh [format "%s_cross_tier_all %d" $tag [dict get $stats cross_tier_all]]
      puts $fh [format "%s_upper_bottom %d" $tag [dict get $stats upper_bottom]]
      puts $fh [format "%s_upper_io %d" $tag [dict get $stats upper_io]]
      puts $fh [format "%s_bottom_io %d" $tag [dict get $stats bottom_io]]
      puts $fh [format "%s_upper_bottom_io %d" $tag [dict get $stats upper_bottom_io]]
      puts $fh [format "%s_unknown %d" $tag [dict get $stats unknown]]
    }
    puts $fh [format "delta_cross_tier_all %d" [expr {[dict get $after_stats cross_tier_all] - [dict get $before_stats cross_tier_all]}]]
    close $fh
  }

  return [dict create before $before_stats after $after_stats]
}

proc report_mixed_fanout_transition {summary_path before_report after_report args} {
  array set opt {
    -label ""
    -clock_only 0
    -quiet 0
  }
  if {([llength $args] % 2) != 0} {
    error "report_mixed_fanout_transition: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "report_mixed_fanout_transition: unknown option $k"
    }
    set opt($k) $v
  }

  set before_stats [_read_mixed_fanout_report_stats $before_report]
  if {$before_stats eq ""} {
    set before_stats [report_mixed_fanout_snapshot $before_report -label "${opt(-label)} before" -clock_only $opt(-clock_only) -quiet $opt(-quiet)]
  } elseif {!$opt(-quiet)} {
    puts "INFO(OR): mixed-fanout snapshot ${opt(-label)} before [_mixed_fanout_stats_brief $before_stats]"
  }
  set after_stats [report_mixed_fanout_snapshot $after_report -label "${opt(-label)} after" -clock_only $opt(-clock_only) -quiet $opt(-quiet)]

  if {!$opt(-quiet)} {
    set before_all [dict get $before_stats mixed_fanout_all]
    set after_all [dict get $after_stats mixed_fanout_all]
    puts "INFO(OR): mixed-fanout transition $opt(-label) before=$before_all after=$after_all delta=[expr {$after_all - $before_all}]"
  }

  if {$summary_path ne ""} {
    set fh [open $summary_path w]
    puts $fh [format "label %s" $opt(-label)]
    puts $fh [format "clock_only %d" $opt(-clock_only)]
    foreach {tag stats} [list before $before_stats after $after_stats] {
      puts $fh "$tag [_mixed_fanout_stats_brief $stats]"
      puts $fh [format "%s_mixed_fanout_all %d" $tag [dict get $stats mixed_fanout_all]]
      puts $fh [format "%s_upper_bottom %d" $tag [dict get $stats upper_bottom]]
      puts $fh [format "%s_upper_bottom_io %d" $tag [dict get $stats upper_bottom_io]]
      puts $fh [format "%s_unknown %d" $tag [dict get $stats unknown]]
    }
    puts $fh [format "delta_mixed_fanout_all %d" [expr {[dict get $after_stats mixed_fanout_all] - [dict get $before_stats mixed_fanout_all]}]]
    close $fh
  }

  return [dict create before $before_stats after $after_stats]
}

proc _read_cross_tier_list_entries {report_path} {
  set entries [dict create]
  if {$report_path eq "" || ![file exists $report_path]} {
    return $entries
  }
  set cached_snapshot [_pin3d_metric_report_cache_get $report_path cross_tier]
  if {$cached_snapshot ne ""} {
    return [dict get $cached_snapshot cross_entries]
  }

  set fh [open $report_path r]
  while {[gets $fh line] >= 0} {
    if {[regexp {^\s*Net Name\s+\|\s+Type} $line]} {
      continue
    }
    if {[regexp {^-+} $line]} {
      continue
    }
    if {[regexp {^(.+?)\s+\|\s+(\S+)\s*$} $line -> net_name net_type]} {
      set trimmed_name [string trim $net_name]
      if {$trimmed_name ne "" && $trimmed_name ne "# Cross-Tier Net Report"} {
        dict set entries $trimmed_name $net_type
      }
    }
  }
  close $fh
  return $entries
}

proc _current_split_related_net_lookup {} {
  array set split_related {}
  set block [ord::get_db_block]
  foreach net [$block getNets] {
    set net_name [$net getName]
    if {[_split_branch_name_match $net_name] || [_net_touches_split_buffer_inst $net]} {
      set split_related($net_name) 1
    }
  }
  return [array get split_related]
}

proc report_cross_tier_delta_attribution {summary_path before_report after_report args} {
  array set opt {
    -label ""
    -quiet 0
  }
  if {([llength $args] % 2) != 0} {
    error "report_cross_tier_delta_attribution: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "report_cross_tier_delta_attribution: unknown option $k"
    }
    set opt($k) $v
  }

  set before_entries [_read_cross_tier_list_entries $before_report]
  set after_entries [_read_cross_tier_list_entries $after_report]
  set before_names [lsort [dict keys $before_entries]]
  set after_names [lsort [dict keys $after_entries]]
  set added_names [_list_minus $after_names $before_names]
  set removed_names [_list_minus $before_names $after_names]

  array set split_related_lookup [_current_split_related_net_lookup]
  array set clock_net_lookup {}
  foreach clock_net_name [_clock_net_name_set] {
    set clock_net_lookup($clock_net_name) 1
  }
  set after_split_related 0
  set after_non_split_related 0
  set after_clock_related 0
  set after_data_related 0
  foreach net_name $after_names {
    if {[info exists split_related_lookup($net_name)]} {
      incr after_split_related
    } else {
      incr after_non_split_related
    }
    if {[info exists clock_net_lookup($net_name)]} {
      incr after_clock_related
    } else {
      incr after_data_related
    }
  }

  set added_split_related 0
  set added_non_split_related 0
  set added_clock_split_related 0
  set added_clock_non_split_related 0
  set added_data_split_related 0
  set added_data_non_split_related 0
  set added_non_split_related_sample {}
  foreach net_name $added_names {
    set is_clock [info exists clock_net_lookup($net_name)]
    if {[info exists split_related_lookup($net_name)]} {
      incr added_split_related
      if {$is_clock} {
        incr added_clock_split_related
      } else {
        incr added_data_split_related
      }
    } else {
      incr added_non_split_related
      if {$is_clock} {
        incr added_clock_non_split_related
      } else {
        incr added_data_non_split_related
      }
      if {[llength $added_non_split_related_sample] < 20} {
        lappend added_non_split_related_sample $net_name
      }
    }
  }

  if {$summary_path ne ""} {
    set fh [open $summary_path w]
    puts $fh "label $opt(-label)"
    puts $fh [format "before_cross_tier_nets %d" [llength $before_names]]
    puts $fh [format "after_cross_tier_nets %d" [llength $after_names]]
    puts $fh [format "added_cross_tier_nets %d" [llength $added_names]]
    puts $fh [format "removed_cross_tier_nets %d" [llength $removed_names]]
    puts $fh [format "after_split_related_cross_tier_nets %d" $after_split_related]
    puts $fh [format "after_non_split_related_cross_tier_nets %d" $after_non_split_related]
    puts $fh [format "after_clock_cross_tier_nets %d" $after_clock_related]
    puts $fh [format "after_data_cross_tier_nets %d" $after_data_related]
    puts $fh [format "added_split_related_cross_tier_nets %d" $added_split_related]
    puts $fh [format "added_non_split_related_cross_tier_nets %d" $added_non_split_related]
    puts $fh [format "added_clock_split_related_cross_tier_nets %d" $added_clock_split_related]
    puts $fh [format "added_clock_non_split_related_cross_tier_nets %d" $added_clock_non_split_related]
    puts $fh [format "added_data_split_related_cross_tier_nets %d" $added_data_split_related]
    puts $fh [format "added_data_non_split_related_cross_tier_nets %d" $added_data_non_split_related]
    foreach net_name $added_non_split_related_sample {
      puts $fh "added_non_split_related_sample $net_name"
    }
    close $fh
  }

  if {!$opt(-quiet)} {
    puts "INFO(OR): cross-tier attribution $opt(-label) added=[llength $added_names] added_clock=[expr {$added_clock_split_related + $added_clock_non_split_related}] added_data=[expr {$added_data_split_related + $added_data_non_split_related}] added_split_related=$added_split_related added_non_split_related=$added_non_split_related after_split_related=$after_split_related"
  }

  return [dict create \
    before_cross_tier_nets [llength $before_names] \
    after_cross_tier_nets [llength $after_names] \
    added_cross_tier_nets [llength $added_names] \
    removed_cross_tier_nets [llength $removed_names] \
    after_split_related_cross_tier_nets $after_split_related \
    added_split_related_cross_tier_nets $added_split_related \
    added_non_split_related_cross_tier_nets $added_non_split_related \
    after_clock_cross_tier_nets $after_clock_related \
    after_data_cross_tier_nets $after_data_related \
    added_clock_split_related_cross_tier_nets $added_clock_split_related \
    added_clock_non_split_related_cross_tier_nets $added_clock_non_split_related \
    added_data_split_related_cross_tier_nets $added_data_split_related \
    added_data_non_split_related_cross_tier_nets $added_data_non_split_related]
}

proc _net_optimization_class {net_ptr} {
  lassign [tier_net_presence_detail_counts $net_ptr] upper_count bottom_count io_count unknown_count
  set has_upper [expr {$upper_count > 0}]
  set has_bottom [expr {$bottom_count > 0}]
  set has_unknown [expr {$unknown_count > 0}]

  if {$has_unknown} {
    return "unknown"
  }
  if {$has_upper && $has_bottom} {
    return "mixed"
  }
  if {$has_upper} {
    return "upper_only"
  }
  if {$has_bottom} {
    return "bottom_only"
  }
  if {$io_count > 0} {
    return "ignore"
  }
  return "ignore"
}

proc _net_class_is_unlocked {allow_net klass} {
  switch -- $allow_net {
    all {
      return [expr {$klass ne "unknown"}]
    }
    upper_only {
      return [expr {$klass eq "upper_only" || $klass eq "mixed"}]
    }
    bottom_only {
      return [expr {$klass eq "bottom_only" || $klass eq "mixed"}]
    }
    default {
      error "Unexpected allow_net class '$allow_net'"
    }
  }
}

proc _set_net_dont_touch_flag {net_name flag quiet} {
  set net_obj [get_nets -quiet $net_name]
  if {$net_obj eq ""} {
    if {!$quiet} {
      puts "WARN(OR): cannot resolve net object for $net_name"
    }
    return 0
  }

  if {[catch {rsz::set_dont_touch_net $net_obj $flag} err]} {
    if {!$quiet} {
      if {$flag} {
        puts "WARN(OR): failed to lock net $net_name : $err"
      } else {
        puts "WARN(OR): failed to unlock net $net_name : $err"
      }
    }
    return 0
  }
  return 1
}

proc _pin3d_elapsed_ms {start_ms} {
  return [expr {[clock milliseconds] - $start_ms}]
}

proc _set_net_dont_touch_flag_batch {net_names flag quiet} {
  set total [llength $net_names]
  if {$total == 0} {
    return 0
  }

  set failures 0
  set chunk_size 256
  for {set idx 0} {$idx < $total} {incr idx $chunk_size} {
    set chunk [lrange $net_names $idx [expr {$idx + $chunk_size - 1}]]
    if {[llength $chunk] == 0} {
      continue
    }

    foreach net_name $chunk {
      if {![_set_net_dont_touch_flag $net_name $flag 1]} {
        incr failures
      }
    }
  }

  return $failures
}

proc _clock_port_name_candidates {{sdc_path ""}} {
  array set seen {}
  set out {}

  foreach var_name {::clk_port_name clk_port_name} {
    if {[uplevel #0 [list info exists $var_name]]} {
      set port_name [uplevel #0 [list set $var_name]]
      if {$port_name ne "" && $port_name ne "NULL" && ![info exists seen($port_name)]} {
        set seen($port_name) 1
        lappend out $port_name
      }
    }
  }

  foreach env_name {CLOCK_PORT CLK_PORT_NAME CLK_PORT} {
    if {[info exists ::env($env_name)] && $::env($env_name) ne ""} {
      foreach port_name $::env($env_name) {
        if {$port_name ne "" && $port_name ne "NULL" && ![info exists seen($port_name)]} {
          set seen($port_name) 1
          lappend out $port_name
        }
      }
    }
  }

  if {$sdc_path ne "" && [file exists $sdc_path]} {
    set fp [open $sdc_path r]
    while {[gets $fp line] >= 0} {
      if {[regexp {^\s*set\s+clk_port_name\s+([^\s#;]+)} $line -> port_name]} {
        if {$port_name ne "" && $port_name ne "NULL" && ![info exists seen($port_name)]} {
          set seen($port_name) 1
          lappend out $port_name
        }
      }
      if {[regexp {create_clock.*\[get_ports\s+([^\]\s]+)\]} $line -> port_name]} {
        if {[string index $port_name 0] eq "$"} {
          continue
        }
        if {$port_name ne "" && $port_name ne "NULL" && ![info exists seen($port_name)]} {
          set seen($port_name) 1
          lappend out $port_name
        }
      }
    }
    close $fp
  }

  return $out
}

proc _collect_db_clock_net_names {} {
  array set clock_names {}
  set block [ord::get_db_block]
  foreach net [$block getNets] {
    if {[catch {set sig_type [$net getSigType]}]} {
      set sig_type "SIGNAL"
    }
    if {$sig_type eq "CLOCK"} {
      set clock_names([$net getName]) 1
    }
  }
  return [array names clock_names]
}

proc _pin3d_clock_propagation_graph_cache_key {} {
  if {![info exists ::pin3d_metric_snapshot_epoch]} {
    set ::pin3d_metric_snapshot_epoch 0
  }
  return $::pin3d_metric_snapshot_epoch
}

proc _pin3d_is_seq_like_master_name {master_name} {
  return [expr {[regexp -nocase -- {(^|_)(async_dff|dff|sdff|dlh|dll|tlat|sdf|latch|sdlatch)} $master_name]}]
}

proc _pin3d_inst_signal_output_iterms {inst} {
  set outputs {}
  foreach iterm [$inst getITerms] {
    set mterm [$iterm getMTerm]
    set sig_type [_pin3d_safe_sigtype_from_mterm $mterm]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
      continue
    }
    if {[_pin3d_safe_iotype_from_mterm $mterm] eq "OUTPUT"} {
      lappend outputs $iterm
    }
  }
  return $outputs
}

proc _pin3d_is_clock_propagation_inst {inst} {
  if {$inst eq "" || $inst eq "NULL"} {
    return 0
  }
  if {[_or_inst_tier $inst] eq "split_buffer"} {
    return 1
  }

  set master [$inst getMaster]
  if {$master eq "" || $master eq "NULL"} {
    return 0
  }
  set master_name [$master getName]
  if {[_pin3d_is_seq_like_master_name $master_name]} {
    return 0
  }

  lassign [_pin3d_master_signal_io_summary $master] input_count output_count input_name output_name
  if {$input_count < 1 || $output_count < 1} {
    return 0
  }
  return 1
}

proc _pin3d_clock_propagation_graph {} {
  set cache_key [_pin3d_clock_propagation_graph_cache_key]
  if {[info exists ::pin3d_clock_propagation_graph_cache($cache_key)]} {
    return $::pin3d_clock_propagation_graph_cache($cache_key)
  }

  set graph [dict create]
  set block [ord::get_db_block]
  foreach inst [$block getInsts] {
    if {![_pin3d_is_clock_propagation_inst $inst]} {
      continue
    }

    set input_net_names {}
    set output_net_names {}
    foreach iterm [$inst getITerms] {
      set mterm [$iterm getMTerm]
      set sig_type [_pin3d_safe_sigtype_from_mterm $mterm]
      if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
        continue
      }
      set net [_pin3d_iterm_net $iterm]
      if {$net eq "" || $net eq "NULL"} {
        continue
      }
      set net_name [$net getName]
      if {$net_name eq ""} {
        continue
      }
      switch -- [_pin3d_safe_iotype_from_mterm $mterm] {
        INPUT {
          lappend input_net_names $net_name
        }
        OUTPUT {
          lappend output_net_names $net_name
        }
      }
    }

    if {[llength $input_net_names] == 0 || [llength $output_net_names] == 0} {
      continue
    }

    set input_net_names [lsort -unique $input_net_names]
    set output_net_names [lsort -unique $output_net_names]
    foreach input_net_name $input_net_names {
      foreach output_net_name $output_net_names {
        if {$input_net_name eq $output_net_name} {
          continue
        }
        dict lappend graph $input_net_name $output_net_name
      }
    }
  }

  foreach input_net_name [dict keys $graph] {
    dict set graph $input_net_name [lsort -unique [dict get $graph $input_net_name]]
  }

  set ::pin3d_clock_propagation_graph_cache($cache_key) $graph
  return $graph
}

proc _expand_clock_nets_via_propagation_graph {seed_clock_names} {
  array set known {}
  set queue {}
  foreach net_name $seed_clock_names {
    if {$net_name eq "" || [info exists known($net_name)]} {
      continue
    }
    set known($net_name) 1
    lappend queue $net_name
  }

  set graph [_pin3d_clock_propagation_graph]
  while {[llength $queue] > 0} {
    set net_name [lindex $queue 0]
    set queue [lrange $queue 1 end]
    if {![dict exists $graph $net_name]} {
      continue
    }
    foreach out_net_name [dict get $graph $net_name] {
      if {$out_net_name eq "" || [info exists known($out_net_name)]} {
        continue
      }
      set known($out_net_name) 1
      lappend queue $out_net_name
    }
  }

  return [array names known]
}

proc _clock_net_name_set {{sdc_path ""}} {
  set cache_key [_pin3d_metric_snapshot_cache_key 2 $sdc_path]
  if {[info exists ::pin3d_clock_net_name_cache($cache_key)]} {
    return $::pin3d_clock_net_name_cache($cache_key)
  }

  array set clock_names {}
  foreach net_name [_collect_db_clock_net_names] {
    set clock_names($net_name) 1
  }
  foreach port_name [_clock_port_name_candidates $sdc_path] {
    set nets {}
    if {![catch {set nets [get_nets -quiet $port_name]}] && [llength $nets] > 0} {
      # prefer direct net lookup because some OpenROAD builds reject Port objects
    } elseif {![catch {set port_obj [get_ports $port_name]}] && [llength $port_obj] > 0} {
      catch {set nets [get_nets -quiet -of_objects $port_obj]}
    }
    if {[llength $nets] == 0} {
      continue
    }
    foreach net_obj $nets {
      if {[catch {set net_name [get_name $net_obj]}] || $net_name eq "" || $net_name eq "NULL"} {
        continue
      }
      set clock_names($net_name) 1
    }
  }

  if {[array size clock_names] == 0} {
    foreach clock [all_clocks] {
      if {$clock eq "" || $clock eq "NULL"} {
        continue
      }
      if {[catch {set sources [get_property $clock sources]}] || [llength $sources] == 0} {
        continue
      }
      set clean_sources {}
      foreach src $sources {
        if {$src eq "" || $src eq "NULL"} {
          continue
        }
        lappend clean_sources $src
      }
      if {[llength $clean_sources] == 0} {
        continue
      }
      if {[catch {set nets [get_nets -quiet -of_objects $clean_sources]}]} {
        continue
      }
      foreach net_obj $nets {
        if {[catch {set net_name [get_name $net_obj]}] || $net_name eq ""} {
          continue
        }
        set clock_names($net_name) 1
      }
    }
  }
  set clock_net_names [_expand_clock_nets_via_propagation_graph [array names clock_names]]
  set ::pin3d_clock_net_name_cache($cache_key) $clock_net_names
  return $clock_net_names
}

proc _apply_net_class_optimization_mask {active_class quiet {skip_clock_nets 0}} {
  array set stats {
    upper_only_locked 0
    upper_only_unlocked 0
    bottom_only_locked 0
    bottom_only_unlocked 0
    mixed_locked 0
    mixed_unlocked 0
    unknown_locked 0
    unknown_unlocked 0
  }
  set ignore_cnt 0
  set fail_cnt 0
  set clock_skip_cnt 0
  set unlock_net_names {}
  set lock_net_names {}

  array set clock_net_lookup {}
  if {$skip_clock_nets} {
    foreach clock_net_name [_clock_net_name_set] {
      set clock_net_lookup($clock_net_name) 1
    }
  }

  set block [ord::get_db_block]
  foreach net [$block getNets] {
    set sig_type [$net getSigType]
    if {$sig_type eq "POWER" || $sig_type eq "GROUND"} {
      continue
    }

    set net_name [$net getName]
    if {$skip_clock_nets && [info exists clock_net_lookup($net_name)]} {
      lappend unlock_net_names $net_name
      incr clock_skip_cnt
      continue
    }

    set klass [_net_optimization_class $net]
    if {$klass eq "ignore"} {
      incr ignore_cnt
      continue
    }
    set unlock_net [_net_class_is_unlocked $active_class $klass]
    set lock_net [expr {!$unlock_net}]
    if {$lock_net} {
      lappend lock_net_names $net_name
    } else {
      lappend unlock_net_names $net_name
    }

    if {$lock_net} {
      incr stats(${klass}_locked)
    } else {
      incr stats(${klass}_unlocked)
    }
  }

  incr fail_cnt [_set_net_dont_touch_flag_batch $unlock_net_names 0 $quiet]
  incr fail_cnt [_set_net_dont_touch_flag_batch $lock_net_names 1 $quiet]

  if {!$quiet} {
    puts "INFO(OR): Applied staged net-class mask for active_class=$active_class"
    puts "INFO(OR):   upper_only unlocked=$stats(upper_only_unlocked) locked=$stats(upper_only_locked)"
    puts "INFO(OR):   bottom_only unlocked=$stats(bottom_only_unlocked) locked=$stats(bottom_only_locked)"
    puts "INFO(OR):   mixed unlocked=$stats(mixed_unlocked) locked=$stats(mixed_locked)"
    puts "INFO(OR):   unknown unlocked=$stats(unknown_unlocked) locked=$stats(unknown_locked)"
    puts "INFO(OR):   ignored=$ignore_cnt clock_skipped=$clock_skip_cnt failures=$fail_cnt"
  }
}

proc _pin3d_boolean_env {name default_value} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    return $default_value
  }
  set value [string tolower [string trim $::env($name)]]
  return [expr {$value ni {0 false off no}}]
}

proc _set_cell_dont_touch_flag_batch {cell_names protect quiet} {
  set touched 0
  set failures 0
  set chunk_size 256
  set total [llength $cell_names]
  for {set idx 0} {$idx < $total} {incr idx $chunk_size} {
    set chunk [lrange $cell_names $idx [expr {$idx + $chunk_size - 1}]]
    if {[llength $chunk] == 0} {
      continue
    }
    set cells [get_cells -hierarchical -quiet $chunk]
    if {$cells eq ""} {
      continue
    }
    if {$protect} {
      set failed [catch {set_dont_touch $cells} err]
    } else {
      set failed [catch {unset_dont_touch $cells} err]
    }
    if {$failed} {
      incr failures [llength $chunk]
      if {!$quiet} {
        puts "WARN(OR): failed cell dont_touch batch protect=$protect : $err"
      }
      continue
    }
    incr touched [llength $chunk]
  }
  return [dict create touched $touched failures $failures]
}

proc _apply_inactive_tier_cell_dont_touch {active_tier quiet} {
  if {![_pin3d_boolean_env PIN3D_INACTIVE_TIER_DONT_TOUCH 1]} {
    if {!$quiet} {
      puts "INFO(OR): PIN3D_INACTIVE_TIER_DONT_TOUCH=off; cell mask skipped"
    }
    return
  }

  set active_cells {}
  set inactive_cells {}
  foreach inst [[ord::get_db_block] getInsts] {
    set inst_tier [_or_inst_tier $inst]
    if {$inst_tier eq "split_buffer"} {
      continue
    }
    if {$inst_tier ni {upper bottom}} {
      continue
    }
    if {$inst_tier eq $active_tier} {
      lappend active_cells [$inst getName]
    } else {
      lappend inactive_cells [$inst getName]
    }
  }

  set active_result [_set_cell_dont_touch_flag_batch $active_cells 0 $quiet]
  set inactive_result [_set_cell_dont_touch_flag_batch $inactive_cells 1 $quiet]
  if {!$quiet} {
    puts "INFO(OR): Tier cell mask active=$active_tier active_unlocked=[dict get $active_result touched] inactive_locked=[dict get $inactive_result touched] failures=[expr {[dict get $active_result failures] + [dict get $inactive_result failures]}]"
  }
}

proc _release_tier_cell_dont_touch {quiet} {
  if {![_pin3d_boolean_env PIN3D_INACTIVE_TIER_DONT_TOUCH 1]} {
    return
  }
  set tier_cells {}
  foreach inst [[ord::get_db_block] getInsts] {
    set inst_tier [_or_inst_tier $inst]
    if {$inst_tier eq "split_buffer" || $inst_tier ni {upper bottom}} {
      continue
    }
    lappend tier_cells [$inst getName]
  }
  set result [_set_cell_dont_touch_flag_batch $tier_cells 0 $quiet]
  if {!$quiet} {
    puts "INFO(OR): Released tier cell mask touched=[dict get $result touched] failures=[dict get $result failures]"
  }
}

proc _protect_pin3d_bridge_nets {quiet {protect 1}} {
  set records [pin3d_read_split_manifest]
  set bridge_names [_pin3d_manifest_name_set $records bridge_net]
  set touched 0
  set failures 0
  foreach net_name $bridge_names {
    if {[_set_net_dont_touch_flag $net_name $protect 1]} {
      incr touched
    } else {
      incr failures
      if {!$quiet} {
        puts "WARN(OR): failed to set bridge dont_touch=$protect for $net_name"
      }
    }
  }
  if {!$quiet} {
    puts "INFO(OR): PIN3D bridge protection protect=$protect touched=$touched failures=$failures"
  }
  return $touched
}

# ------------------------------------------------------------
# Apply tier policy
# Options:
#   -quiet 0/1 (default 0)
# ------------------------------------------------------------
proc apply_tier_policy {tier args} {
  set tier [string tolower $tier]
  if {$tier ne "upper" && $tier ne "bottom"} {
    error "apply_tier_policy: tier must be 'upper' or 'bottom'"
  }

  array set opt {
    -quiet    0
    -fixlib   0
    -allow_net all
    -rebuild_rows 1
    -skip_clock_nets 0
    -protect_split_buffers 1
    -inactive_cell_mask 1
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
  set requested_allow_net [_requested_allow_net_class_with_default $opt(-allow_net) $opt(-quiet)]
  set effective_allow_net [_effective_allow_net_class $requested_allow_net $opt(-quiet)]
  _report_allow_net_resolution "tier_policy/${tier}" $requested_allow_net $effective_allow_net
  set total_start_ms [clock milliseconds]
  set fixlib_start_ms $total_start_ms

  if {$tier eq "upper"} {
    # dont_use for synthesis/placement choices
    if {$opt(-fixlib)} { 
      _set_dont_use [_expand_libcells $dnu_up] 
    }

    set ::env(TIEHI_CELL_AND_PORT) $::env(UPPER_TIEHI_CELL_AND_PORT)
    set ::env(TIELO_CELL_AND_PORT) $::env(UPPER_TIELO_CELL_AND_PORT)
    if {[info exists ::env(UPPER_SITE)]} { set ::env(PLACE_SITE) $::env(UPPER_SITE) }

    if {!$opt(-quiet)} {
      puts "INFO(OR): Tier=UPPER applied."
    }
  } else {
    if {$opt(-fixlib)} { 
      _set_dont_use [_expand_libcells $dnu_bot] 
    }

    set ::env(TIEHI_CELL_AND_PORT) $::env(BOTTOM_TIEHI_CELL_AND_PORT)
    set ::env(TIELO_CELL_AND_PORT) $::env(BOTTOM_TIELO_CELL_AND_PORT)
    if {[info exists ::env(BOTTOM_SITE)]} { set ::env(PLACE_SITE) $::env(BOTTOM_SITE) }

    if {!$opt(-quiet)} {
      puts "INFO(OR): Tier=BOTTOM applied."
    }
  }

  if {[info exists ::env(DONT_USE_CELLS)] && $::env(DONT_USE_CELLS) ne ""} {
    _set_dont_use [_expand_libcells $::env(DONT_USE_CELLS)]
    if {!$opt(-quiet)} { puts "INFO(OR): Applied DONT_USE_CELLS = '$::env(DONT_USE_CELLS)'." }
  }
  set fixlib_elapsed_ms [_pin3d_elapsed_ms $fixlib_start_ms]

  set netmask_start_ms [clock milliseconds]
  _apply_net_class_optimization_mask $effective_allow_net $opt(-quiet) $opt(-skip_clock_nets)
  if {$effective_allow_net eq "upper_only" || $effective_allow_net eq "bottom_only"} {
    if {$opt(-inactive_cell_mask)} {
      _apply_inactive_tier_cell_dont_touch $tier $opt(-quiet)
    } else {
      _release_tier_cell_dont_touch $opt(-quiet)
    }
  }
  # Protect split topology only in stages that perform one-tier netlist
  # optimization.  Infrastructure stages use allow_net=all and must leave the
  # cells mutable long enough for global_connect to attach their PG pins.
  set protect_split_topology [expr {
    $opt(-protect_split_buffers) &&
    ($effective_allow_net eq "upper_only" || $effective_allow_net eq "bottom_only")}]
  _protect_pin3d_split_buffers $opt(-quiet) $protect_split_topology
  _protect_pin3d_bridge_nets $opt(-quiet) $protect_split_topology
  set netmask_elapsed_ms [_pin3d_elapsed_ms $netmask_start_ms]
  set rebuild_elapsed_ms 0
  if {$opt(-rebuild_rows)} {
    set rebuild_start_ms [clock milliseconds]
    or_rebuild_rows_for_site $::env(PLACE_SITE) $tier
    set rebuild_elapsed_ms [_pin3d_elapsed_ms $rebuild_start_ms]
  }
  if {!$opt(-quiet)} {
    puts "INFO(OR): apply_tier_policy/$tier timing fixlib_ms=$fixlib_elapsed_ms netmask_ms=$netmask_elapsed_ms rebuild_rows_ms=$rebuild_elapsed_ms total_ms=[_pin3d_elapsed_ms $total_start_ms]"
  }
}
