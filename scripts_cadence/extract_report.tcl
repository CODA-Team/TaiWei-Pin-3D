# ============================================================
# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# extract_report.tcl — Unified reporting (Cadence Innovus)
#   extract_report -postRoute -outdir <DIR> \
#                   [-write_csv <csvpath>] [-write_summary <txtpath>]
#
# Metrics:
#   timing/power/area/wl/cong + drc/fep + hb_via_count + cross_tier_nets
#   connectivity (verifyConnectivity): IMPVFC-92/94/total
#   ERC (electrical) via report_constraint: max_tran/max_cap/max_fanout
# ============================================================
proc _open_any {path} {
  if {![file exists $path]} { return "" }
  set fp [open $path r]
  if {[string match *.gz $path]} { zlib push gunzip $fp }
  return $fp
}

proc _ensure_dir {d} { if {![file exists $d]} { file mkdir $d } }

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
      return "off"
    }
  }
}

# --------------------------
# Timing / Power / Area / WL
# --------------------------
proc extract_from_timing_rpt {timing_rpt} {
  set wns ""; set tns ""; set hc ""; set vc ""; set flag 0
  set fp [_open_any $timing_rpt]
  if {$fp eq ""} {
    set fp [_open_any [file rootname $timing_rpt]]
    if {$fp eq ""} { return [list $wns $tns $hc $vc] }
  }
  while {[gets $fp line] >= 0} {
    if {$flag == 0} { set words [split $line "|"] } else { set words [split $line] }
    if {[llength $words] < 2} { continue }
    if {[string map {" " ""} [lindex $words 1]] eq "WNS(ns):"} {
      set wns [string map {" " ""} [lindex $words 2]]
    } elseif {[string map {" " ""} [lindex $words 1]] eq "TNS(ns):"} {
      set tns [string map {" " ""} [lindex $words 2]]
      set flag 1
    } elseif {[llength $words] == 7 && [lindex $words 0] eq "Routing"} {
      set hc [lindex $words 2]; set vc [lindex $words 5]; break
    }
  }
  close $fp
  return [list $wns $tns $hc $vc]
}

proc extract_from_power_rpt {power_rpt} {
  if {![file exists $power_rpt]} { return "" }
  set power ""
  set fp [open $power_rpt r]
  while {[gets $fp line] >= 0} {
    if {[llength $line] == 3 && [lindex $line 0] eq "Total"} {
      set power [lindex $line 2]; break
    }
  }
  close $fp
  return $power
}

proc extract_cell_area {} {
  set macro_area 0
  set std_cell_area 0
  catch {
    set macro_area [expr [join [dbget [dbget top.insts.cell.subClass block -p2 ].area ] +]]
  }
  catch {
    set std_cell_area [expr [join [dbget [dbget top.insts.cell.subClass block -v -p2 ].area ] +]]
  }
  if {$macro_area eq ""} { set macro_area 0 }
  if {$std_cell_area eq ""} { set std_cell_area 0 }
  return [list $macro_area $std_cell_area]
}

proc extract_wire_length {} {
  set val 0
  catch { set val [expr [join [dbget top.nets.wires.length] +]] }
  if {$val eq ""} { set val 0 }
  return $val
}

# --------------------------
# Cross-tier reporting helpers
# --------------------------
proc _report_net_tier_presence {net_ptr} {
  set has_upper 0
  set has_bottom 0
  set has_io 0
  set has_unknown 0

  # Top-level IO terms are first classified by their actual routed pin layers.
  # Only ambiguous terms with no resolvable tier stay in the IO bucket.
  foreach term [dbGet -e $net_ptr.terms] {
    switch -- [tier_classify_term_ptr $term] {
      upper {
        set has_upper 1
      }
      bottom {
        set has_bottom 1
      }
      default {
        set has_io 1
      }
    }
  }

  foreach inst_term [dbGet -e $net_ptr.instTerms] {
    switch -- [tier_classify_inst_term_ptr $inst_term] {
      upper {
        set has_upper 1
      }
      bottom {
        set has_bottom 1
      }
      split_buffer {
        continue
      }
      default {
        set has_unknown 1
      }
    }
  }

  return [list $has_upper $has_bottom $has_io $has_unknown]
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

proc _report_clock_names {} {
  global extract_report_clock_names_cache
  if {[info exists extract_report_clock_names_cache]} {
    return $extract_report_clock_names_cache
  }
  set names {}
  if {![catch {set names [get_object_name [all_clocks]]} err]} {
    set extract_report_clock_names_cache [lsort -unique $names]
    return $extract_report_clock_names_cache
  }
  set extract_report_clock_names_cache {}
  return {}
}

proc _report_build_clock_name_lookup {} {
  global extract_report_clock_name_lookup_ready
  global extract_report_clock_name_lookup_cache

  if {[info exists extract_report_clock_name_lookup_ready] && $extract_report_clock_name_lookup_ready} {
    return
  }

  catch {array unset extract_report_clock_name_lookup_cache}
  foreach clock_name [_report_clock_names] {
    if {$clock_name ne ""} {
      set extract_report_clock_name_lookup_cache($clock_name) 1
    }
  }
  set extract_report_clock_name_lookup_ready 1
}

proc _report_is_clock_name {name} {
  global extract_report_clock_name_lookup_cache
  if {$name eq ""} {
    return 0
  }
  _report_build_clock_name_lookup
  return [info exists extract_report_clock_name_lookup_cache($name)]
}

proc _report_is_clock_pin_name {pin_name} {
  set short_name $pin_name
  if {[string first "/" $pin_name] >= 0} {
    set short_name [lindex [split $pin_name "/"] end]
  }

  foreach pattern {CLK CK CLKB CKB CLKN CKN CP GCLK SCLK} {
    if {[string match "${pattern}*" $short_name]} {
      return 1
    }
  }
  return 0
}

proc _report_is_clock_inst_term {inst_term} {
  if {![catch {set inst_term_name [dbGet $inst_term.name]}]} {
    if {[_report_is_clock_pin_name $inst_term_name]} {
      return 1
    }
  }
  return 0
}

proc _report_is_clock_net_ptr {net_ptr} {
  set net_name [dbGet $net_ptr.name]
  if {[_report_is_clock_name $net_name]} {
    return 1
  }

  foreach inst_term [dbGet -e $net_ptr.instTerms] {
    if {[_report_is_clock_inst_term $inst_term]} {
      return 1
    }
  }

  foreach term [dbGet -e $net_ptr.terms] {
    set term_name [dbGet $term.name]
    if {[_report_is_clock_name $term_name]} {
      return 1
    }
  }

  return 0
}

# --------------------------
# Cross Tier Net Count
# Rule:
#   - Top-level IO terms inherit upper/bottom tier when their placed pin layers
#     resolve cleanly to one tier.
#   - cross_tier_all is reserved for nets that truly span both tiers:
#       1) upper + bottom
#       2) upper + bottom + ambiguous IO
#   - upper/bottom + ambiguous IO are still reported in the category breakdown,
#     but they are not counted in cross_tier_all because they do not imply an
#     upper-bottom bridge and therefore should not be compared against HBT count.
# Options:
#   -clock_only 1 : report only clock-related cross-tier nets
# --------------------------
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

  set report_mode [_pin3d_metric_report_mode]
  set emit_detail [expr {$report_mode eq "full"}]
  set emit_report [expr {$report_mode ne "off"}]

  set total_cross_tier 0
  array set category_counts {
    Upper_Bottom    0
    Upper_IO        0
    Bottom_IO       0
    Upper_Bottom_IO 0
    Unknown_Tier    0
  }

  set report_lines [list]
  if {$opt(-clock_only)} {
    lappend report_lines "# Clock-Only Cross-Tier Net Report"
  } else {
    lappend report_lines "# Cross-Tier Net Report"
  }
  if {$emit_detail} {
    lappend report_lines [format "%-40s | %s" "Net Name" "Type"]
    lappend report_lines "-----------------------------------------|------------------"
  } else {
    lappend report_lines "# detail_omitted 1"
    lappend report_lines [format "# report_mode %s" [expr {$report_mode eq "off" ? "off" : "summary"}]]
  }

  foreach net [dbGet top.nets] {
    if {$opt(-clock_only) && ![_report_is_clock_net_ptr $net]} {
      continue
    }

    lassign [_report_net_tier_presence $net] has_upper has_bottom has_io has_unknown
    set net_type [_cross_tier_category_from_presence $has_upper $has_bottom $has_io $has_unknown]

    if {$net_type ne ""} {
      if {$net_type in {"Upper_Bottom" "Upper_Bottom_IO"}} {
        incr total_cross_tier
      }
      incr category_counts($net_type)
      if {$emit_detail} {
        lappend report_lines [format "%-40s | %s" [dbGet $net.name] $net_type]
      }
    }
  }

  lappend report_lines ""
  lappend report_lines [format "Total Cross-Tier Nets: %d" $total_cross_tier]
  lappend report_lines "Category Totals:"
  foreach key {Upper_Bottom Upper_IO Bottom_IO Upper_Bottom_IO Unknown_Tier} {
    lappend report_lines [format "  %-18s %d" $key $category_counts($key)]
  }

  if {$list_rpt_path ne "" && $emit_report} {
    set fh [open $list_rpt_path w]
    foreach line $report_lines {
      puts $fh $line
    }
    close $fh
  }

  return [dict create \
    cross_tier_all $total_cross_tier \
    upper_bottom $category_counts(Upper_Bottom) \
    upper_io $category_counts(Upper_IO) \
    bottom_io $category_counts(Bottom_IO) \
    upper_bottom_io $category_counts(Upper_Bottom_IO) \
    unknown $category_counts(Unknown_Tier)]
}

proc extract_cross_tier_nets {list_rpt_path args} {
  set stats [extract_cross_tier_net_stats $list_rpt_path {*}$args]
  return [dict get $stats cross_tier_all]
}

# --------------------------
# Cross Tier Net Count (Eval / Final Summary)
# Rule:
#   - Preserve top-level IO presence as its own dimension even when a term's
#     routed pin layers resolve cleanly to upper/bottom. This mirrors the
#     OpenROAD final evaluation view and is used only for post-route metrics,
#     not for stage-time HBT estimation.
#   - cross_tier_all counts every non-unknown cross-tier category:
#       1) upper + bottom
#       2) upper + IO
#       3) bottom + IO
#       4) upper + bottom + IO
# Options:
#   -clock_only 1 : report only clock-related cross-tier nets
# --------------------------
proc _report_eval_net_tier_presence {net_ptr} {
  set has_upper 0
  set has_bottom 0
  set has_io 0
  set has_unknown 0

  foreach term [dbGet -e $net_ptr.terms] {
    set has_io 1
    switch -- [tier_classify_term_ptr $term] {
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

  foreach inst_term [dbGet -e $net_ptr.instTerms] {
    switch -- [tier_classify_inst_term_ptr $inst_term] {
      upper {
        set has_upper 1
      }
      bottom {
        set has_bottom 1
      }
      split_buffer {
        continue
      }
      default {
        set has_unknown 1
      }
    }
  }

  return [list $has_upper $has_bottom $has_io $has_unknown]
}

proc extract_cross_tier_net_stats_eval {list_rpt_path args} {
  array set opt {
    -clock_only 0
  }
  if {([llength $args] % 2) != 0} {
    error "extract_cross_tier_net_stats_eval: args must be key-value pairs, got: $args"
  }
  foreach {k v} $args {
    if {![info exists opt($k)]} {
      error "extract_cross_tier_net_stats_eval: unknown option $k"
    }
    set opt($k) $v
  }

  set report_mode [_pin3d_metric_report_mode]
  set emit_detail [expr {$report_mode eq "full"}]
  set emit_report [expr {$report_mode ne "off"}]

  set total_cross_tier 0
  array set category_counts {
    Upper_Bottom    0
    Upper_IO        0
    Bottom_IO       0
    Upper_Bottom_IO 0
    Unknown_Tier    0
  }

  set report_lines [list]
  if {$opt(-clock_only)} {
    lappend report_lines "# Clock-Only Cross-Tier Net Report (Eval)"
  } else {
    lappend report_lines "# Cross-Tier Net Report (Eval)"
  }
  if {$emit_detail} {
    lappend report_lines [format "%-40s | %s" "Net Name" "Type"]
    lappend report_lines "-----------------------------------------|------------------"
  } else {
    lappend report_lines "# detail_omitted 1"
    lappend report_lines [format "# report_mode %s" [expr {$report_mode eq "off" ? "off" : "summary"}]]
  }

  foreach net [dbGet top.nets] {
    if {$opt(-clock_only) && ![_report_is_clock_net_ptr $net]} {
      continue
    }

    lassign [_report_eval_net_tier_presence $net] has_upper has_bottom has_io has_unknown
    set net_type [_cross_tier_category_from_presence $has_upper $has_bottom $has_io $has_unknown]

    if {$net_type ne ""} {
      if {$net_type ne "Unknown_Tier"} {
        incr total_cross_tier
      }
      incr category_counts($net_type)
      if {$emit_detail} {
        lappend report_lines [format "%-40s | %s" [dbGet $net.name] $net_type]
      }
    }
  }

  lappend report_lines ""
  lappend report_lines [format "Total Cross-Tier Nets: %d" $total_cross_tier]
  lappend report_lines "Category Totals:"
  foreach key {Upper_Bottom Upper_IO Bottom_IO Upper_Bottom_IO Unknown_Tier} {
    lappend report_lines [format "  %-18s %d" $key $category_counts($key)]
  }

  if {$list_rpt_path ne "" && $emit_report} {
    set fh [open $list_rpt_path w]
    foreach line $report_lines {
      puts $fh $line
    }
    close $fh
  }

  return [dict create \
    cross_tier_all $total_cross_tier \
    upper_bottom $category_counts(Upper_Bottom) \
    upper_io $category_counts(Upper_IO) \
    bottom_io $category_counts(Bottom_IO) \
    upper_bottom_io $category_counts(Upper_Bottom_IO) \
    unknown $category_counts(Unknown_Tier)]
}

# --------------------------
# FEP
# --------------------------
proc extract_fep {report_file_path} {
  set paths [report_timing -check_type setup -begin_end_pair -collection]
  set ep2min [dict create]
  foreach_in_collection p $paths {
    set slack [get_property $p slack]
    if {$slack < 0} {
      set ep [get_object_name [get_property $p capturing_point]]
      if {![dict exists $ep2min $ep]} {
        dict set ep2min $ep $slack
      } else {
        set cur [dict get $ep2min $ep]
        if {$slack < $cur} { dict set ep2min $ep $slack }
      }
    }
  }
  set FEP_vios [dict size $ep2min]
  set FEP_TNS 0.0
  set FEP_WNS 0.0
  if {$FEP_vios > 0} {
    set FEP_WNS 1e9
    dict for {ep s} $ep2min {
      set FEP_TNS [expr {$FEP_TNS + $s}]
      set FEP_WNS [expr {min($FEP_WNS, $s)}]
    }
  }
  set fid [open $report_file_path w]
  puts $fid "Total FEP Violations: $FEP_vios"
  puts $fid "Total FEP TNS: $FEP_TNS"
  puts $fid "Total FEP WNS: $FEP_WNS"
  close $fid
  return $FEP_vios
}

# --------------------------
# DRC
# --------------------------
proc extract_drc {drc_rpt} {
  set node_map {
    7  N7
    45 {}
  }
  set proc $::env(PROCESS)
  set node [dict get $node_map $proc]
  set design_mode_args [list -process $proc]
  if {$node ne ""} {
    lappend design_mode_args -node $node
  }
  setDesignMode {*}$design_mode_args
  verify_drc -exclude_pg_net -limit 0 -report $drc_rpt
  # verify_drc -limit 0 -report $drc_rpt
  set v ""
  set fp [open $drc_rpt r]
  while {[gets $fp line] >= 0} {
    if {[string match "  Total Violations : * Viols." $line]} {
      regexp {Total Violations : (\d+) Viols.} $line _ v
      set v [string trim $v]
      break
    }
  }
  close $fp
  if {$v eq ""} { set v 0 }
  setDesignMode -process 45
  return $v
}

# --------------------------
# HB via count (Physical Total)
# --------------------------
proc count_hb_viaInst {cutlayer} {
  # Verified command for accurate counting
  set sig [dbGet -e -u -p3 top.nets.vias.via.cutLayer.name $cutlayer]
  if {$sig eq "" || $sig eq "0x0"} { set sig {} }
  set pg {}
  if {![catch {dbGet -e -u -p3 top.pgNets.vias.via.cutLayer.name $cutlayer} pg_res]} {
    set pg $pg_res
    if {$pg eq "" || $pg eq "0x0"} { set pg {} }
  }
  set all [concat $sig $pg]
  if {$all eq ""} { return 0 }
  return [llength [lsort -unique $all]]
}

# ============================================================
# Helpers
# ============================================================
proc _write_failed_report {rpt err} {
  set fh [open $rpt w]
  puts $fh "REPORT_FAILED: $err"
  close $fh
}

proc _capture_cmd_to_file {rpt script_body} {
  if {![catch {
    if {[llength [info commands redirect]] > 0} {
      redirect -file $rpt $script_body
    } else {
      set txt [uplevel 1 $script_body]
      set fh [open $rpt w]
      puts $fh $txt
      close $fh
    }
  } err]} {
    return 1
  }
  _write_failed_report $rpt $err
  return 0
}

# ============================================================
# Connectivity & ERC
# ============================================================
proc _parse_verifyConnectivity {rpt} {
  set c92 0; set c94 0; set total ""
  if {![file exists $rpt]} { return [list $c92 $c94 0] }
  set fp [open $rpt r]
  while {[gets $fp line] >= 0} {
    if {[regexp {^\s*([0-9]+)\s+Problem\(s\)\s+\((IMPVFC-92)\):} $line _ cnt]} { set c92 [expr {int($cnt)}]; continue }
    if {[regexp {^\s*([0-9]+)\s+Problem\(s\)\s+\((IMPVFC-94)\):} $line _ cnt]} { set c94 [expr {int($cnt)}]; continue }
    if {$total eq "" && [regexp {^\s*([0-9]+)\s+total\s+info\(s\)\s+created\.} $line _ cnt3]} { set total [expr {int($cnt3)}]; continue }
  }
  close $fp
  if {$total eq ""} { set total [expr {$c92 + $c94}] }
  return [list $c92 $c94 $total]
}

proc run_connectivity_report {rpt} {
  if {![catch {verify_connectivity -error 0 -geom_connect -no_antenna -report $rpt} err]} { return 1 }
  _write_failed_report $rpt $err
  return 0
}

proc run_erc_report_check_types {rpt} {
  set body { report_constraint -all_violators -max_transition -max_capacitance -max_fanout }
  return [_capture_cmd_to_file $rpt $body]
}

proc _parse_erc_check_types {rpt} {
  set ms 0; set mc 0; set mf 0
  if {![file exists $rpt]} { return [list 0 0 0 0] }
  set fp [open $rpt r]
  set mode "none"
  while {[gets $fp line] >= 0} {
    set l [string trim $line]
    if {$l eq ""} { continue }
    if {[regexp -nocase {Check\s*type\s*:\s*max_transition} $l]} { set mode "slew"; continue }
    if {[regexp -nocase {Check\s*type\s*:\s*max_capacitance} $l]} { set mode "cap"; continue }
    if {[regexp -nocase {Check\s*type\s*:\s*max_fanout} $l]} { set mode "fanout"; continue }
    if {[string match "*No Violations found*" $l]} { continue }
    if {[string match "-*" $l] || [string match "+*" $l]} { continue }
    if {[string first "Pin Name" $l] != -1} { continue }
    switch -- $mode {
      "slew"   { incr ms }
      "cap"    { incr mc }
      "fanout" { incr mf }
    }
  }
  close $fp
  set total [expr {$ms + $mc + $mf}]
  return [list $ms $mc $mf $total]
}

# ============================================================
# Main Extraction Logic
# ============================================================
proc _extract_postRoute {outdir} {
  set stage "Final"
  _ensure_dir $outdir
  
  set tr_out [file join $outdir timingReports]
  _ensure_dir $tr_out
  
  # 1) Timing
  timeDesign -postRoute -prefix ${stage} -outDir $tr_out
  
  # 2) Power
  set power_rpt [file join $outdir power_${stage}.rpt]
  report_power > $power_rpt
  
  # 3) Parse timing summary
  set tpath_gz [file join $tr_out ${stage}.summary.gz]
  set tpath    [file join $tr_out ${stage}.summary]
  set timing_path [expr {[file exists $tpath_gz] ? $tpath_gz : $tpath}]
  set rpt1  [extract_from_timing_rpt $timing_path]
  set rpt2  [extract_from_power_rpt  $power_rpt]
  set rpt3  [extract_cell_area]
  set rpt4  [extract_wire_length]
  
  # 4) DRC & FEP
  set drc_v [extract_drc [file join $outdir drc.rpt]]
  set fep_v [extract_fep [file join $outdir fep.rpt]]
  
  # 5) HB Metrics (Updated Logic)
  set hb_via_cnt [count_hb_viaInst "hb_layer"]
  
  # Generate report inside outdir
  set cross_tier_rpt [file join $outdir "cross_tier_nets.list"]
  set cross_tier_stats [extract_cross_tier_net_stats_eval $cross_tier_rpt]
  set cross_tier_cnt [dict get $cross_tier_stats cross_tier_all]
  set cross_tier_upper_bottom [dict get $cross_tier_stats upper_bottom]
  set cross_tier_upper_io [dict get $cross_tier_stats upper_io]
  set cross_tier_bottom_io [dict get $cross_tier_stats bottom_io]
  set cross_tier_upper_bottom_io [dict get $cross_tier_stats upper_bottom_io]
  set cross_tier_unknown [dict get $cross_tier_stats unknown]
  
  # 6) Connectivity
  set conn_rpt [file join $outdir erc_connectivity.rpt]
  run_connectivity_report $conn_rpt
  lassign [_parse_verifyConnectivity $conn_rpt] conn92 conn94 conn_total
  
  # 7) ERC
  set erc_rpt [file join $outdir erc_check_types.rpt]
  run_erc_report_check_types $erc_rpt
  lassign [_parse_erc_check_types $erc_rpt] erc_ms erc_mc erc_mf erc_total
  
  # 8) Assemble
  set core_area 0
  catch { set core_area [dbget top.fplan.coreBox_area] }
  
  set std_area  [lindex $rpt3 1]
  set mac_area  [lindex $rpt3 0]
  set wns       [lindex $rpt1 0]; if {$wns eq ""} { set wns 0 }
  set tns       [lindex $rpt1 1]; if {$tns eq ""} { set tns 0 }
  set hc        [lindex $rpt1 2]
  set vc        [lindex $rpt1 3]
  
  return "$stage,$core_area,$std_area,$mac_area,$rpt2,$rpt4,$wns,$tns,$hc,$vc,$drc_v,$fep_v,$hb_via_cnt,$cross_tier_cnt,$cross_tier_upper_bottom,$cross_tier_upper_io,$cross_tier_bottom_io,$cross_tier_upper_bottom_io,$cross_tier_unknown,$conn92,$conn94,$conn_total,$erc_ms,$erc_mc,$erc_mf,$erc_total"
}

# ---- Public entrypoint ----
proc extract_report {args} {
  set mode ""; set outdir "."; set write_csv ""; set write_sum ""
  set i 0
  while {$i < [llength $args]} {
    set a [lindex $args $i]
    switch -- $a {
      -postRoute      { set mode "postRoute" }
      -outdir         { incr i; set outdir    [lindex $args $i] }
      -write_csv      { incr i; set write_csv [lindex $args $i] }
      -write_summary  { incr i; set write_sum [lindex $args $i] }
      default         { error "extract_report: unknown option '$a'" }
    }
    incr i
  }
  
  if {$mode eq ""} { error "extract_report: specify -postRoute" }
  
  set csv_line ""
  if {$mode eq "postRoute"} {
    set csv_line [_extract_postRoute $outdir]
  }
  
  if {$write_csv ne ""} {
    set fid [open $write_csv w]
    puts $fid "stage,core_area,std_cell_area,macro_area,total_power,wire_length,wns,tns,h_cong,v_cong,drc_violations,fep_violations,hb_via_count,cross_tier_nets,cross_tier_upper_bottom,cross_tier_upper_io,cross_tier_bottom_io,cross_tier_upper_bottom_io,cross_tier_unknown,connectivity_improvfc92,connectivity_improvfc94,connectivity_total,erc_max_slew,erc_max_cap,erc_max_fanout,erc_total_elec"
    puts $fid $csv_line
    close $fid
  }
  
  if {$write_sum ne ""} {
    set fh [open $write_sum w]
    puts $fh "=== Cadence Pin3DFlow – Final Metrics (postRoute) ==="
    puts $fh "Out dir     : $outdir"
    if {$write_csv ne ""} { puts $fh "CSV         : $write_csv" }
    puts $fh ""
    set f [split $csv_line ","]
    
    puts $fh [format "%-26s %s" "Core Area"              [lindex $f 1]]
    puts $fh [format "%-26s %s" "StdCell Area"           [lindex $f 2]]
    puts $fh [format "%-26s %s" "Macro Area"             [lindex $f 3]]
    puts $fh [format "%-26s %s" "Total Power"            [lindex $f 4]]
    puts $fh [format "%-26s %s" "Wire Length"            [lindex $f 5]]
    puts $fh [format "%-26s %s" "WNS (ns)"               [lindex $f 6]]
    puts $fh [format "%-26s %s" "TNS (ns)"               [lindex $f 7]]
    puts $fh [format "%-26s %s" "H Congestion"           [lindex $f 8]]
    puts $fh [format "%-26s %s" "V Congestion"           [lindex $f 9]]
    puts $fh [format "%-26s %s" "DRC Violations"         [lindex $f 10]]
    puts $fh [format "%-26s %s" "FEP Violations"         [lindex $f 11]]
    puts $fh [format "%-26s %s" "HB VIA Count (Phys)"         [lindex $f 12]]
    set cross_tier_bridge [expr {int([lindex $f 14]) + int([lindex $f 17])}]
    puts $fh [format "%-26s %s" "Cross-Tier Nets (All)"      [lindex $f 13]]
    puts $fh [format "%-26s %s" "Cross-Tier Nets (U/B bridge)" $cross_tier_bridge]
    puts $fh ""
    puts $fh "=== Cross-Tier Breakdown ==="
    puts $fh [format "%-26s %s" "Upper_Bottom"           [lindex $f 14]]
    puts $fh [format "%-26s %s" "Upper_IO"               [lindex $f 15]]
    puts $fh [format "%-26s %s" "Bottom_IO"              [lindex $f 16]]
    puts $fh [format "%-26s %s" "Upper_Bottom_IO"        [lindex $f 17]]
    puts $fh [format "%-26s %s" "Unknown_Tier"           [lindex $f 18]]
    puts $fh ""
    puts $fh "=== Connectivity (verifyConnectivity) ==="
    puts $fh [format "%-26s %s" "IMPVFC-92 (Disconnected)" [lindex $f 19]]
    puts $fh [format "%-26s %s" "IMPVFC-94 (Dangling)"     [lindex $f 20]]
    puts $fh [format "%-26s %s" "Total (info created)"     [lindex $f 21]]
    puts $fh ""
    puts $fh "=== ERC (Electrical: report_constraint) ==="
    puts $fh [format "%-26s %s" "Max Slew Violations"      [lindex $f 22]]
    puts $fh [format "%-26s %s" "Max Cap Violations"       [lindex $f 23]]
    puts $fh [format "%-26s %s" "Max Fanout Violations"    [lindex $f 24]]
    puts $fh [format "%-26s %s" "ERC Total (sum)"          [lindex $f 25]]
    close $fh
  }
  return $csv_line
}
# Shared tier classification
source $::env(CADENCE_SCRIPTS_DIR)/tier_classification.tcl
