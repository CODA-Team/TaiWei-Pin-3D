namespace eval genus_synthesis_timing_margin {
  variable active false
  variable clock_rows {}
  variable original_tns_critical_range ""
  variable report_path ""
}

proc genus_synthesis_timing_margin_is_enabled {} {
  set variable_name GENUS_SYNTHESIS_TIMING_MARGIN_ENABLE
  if {![info exists ::env($variable_name)]} {
    return 1
  }

  set value [string trim $::env($variable_name)]
  if {$value ni {0 1}} {
    error "$variable_name must be 0 or 1: '$value'"
  }
  return $value
}

proc configure_genus_synthesis_timing_margin {setup_uncertainty_ratio tns_critical_range_ratio output_report} {
  if {$::genus_synthesis_timing_margin::active} {
    error "Genus synthesis timing margin is already active"
  }
  foreach {name value} [list \
      setup_uncertainty_ratio $setup_uncertainty_ratio \
      tns_critical_range_ratio $tns_critical_range_ratio] {
    if {![string is double -strict $value] || $value <= 0.0 || $value >= 1.0} {
      error "$name must be greater than 0 and less than 1: '$value'"
    }
  }

  set clock_objects [get_db clocks]
  if {[llength $clock_objects] == 0} {
    error "Genus synthesis timing margin requires at least one clock"
  }

  set shortest_period_ps ""
  set clock_rows {}
  foreach clock $clock_objects {
    set clock_name [get_db $clock .name]
    set period_ps [get_db $clock .period]
    set original_uncertainty_ps [get_db $clock .setup_uncertainty]
    if {![string is double -strict $period_ps] || $period_ps <= 0.0} {
      error "Clock '$clock_name' has an invalid period in ps: '$period_ps'"
    }
    if {![string is double -strict $original_uncertainty_ps] || $original_uncertainty_ps < 0.0} {
      error "Clock '$clock_name' has an invalid setup uncertainty in ps: '$original_uncertainty_ps'"
    }

    set target_uncertainty_ps [expr {$period_ps * $setup_uncertainty_ratio}]
    set_db $clock .setup_uncertainty $target_uncertainty_ps
    set effective_uncertainty_ps [get_db $clock .setup_uncertainty]
    if {![string is double -strict $effective_uncertainty_ps] \
        || abs($effective_uncertainty_ps - $target_uncertainty_ps) > 1.0e-6} {
      error "Clock '$clock_name' setup uncertainty verification failed in ps: expected=$target_uncertainty_ps actual=$effective_uncertainty_ps"
    }

    if {$shortest_period_ps eq "" || $period_ps < $shortest_period_ps} {
      set shortest_period_ps $period_ps
    }
    lappend clock_rows [list \
      $clock_name \
      $period_ps \
      $original_uncertainty_ps \
      $effective_uncertainty_ps]
    puts "INFO: GENUS_SYNTHESIS_TIMING_MARGIN clock=$clock_name period_ps=$period_ps original_setup_uncertainty_ps=$original_uncertainty_ps synthesis_setup_uncertainty_ps=$effective_uncertainty_ps"
  }

  set original_tns_critical_range_ps [get_db / .tns_critical_range]
  if {![string is double -strict $original_tns_critical_range_ps] || $original_tns_critical_range_ps < 0.0} {
    error "The original tns_critical_range is invalid in ps: '$original_tns_critical_range_ps'"
  }
  set target_tns_critical_range_ps [expr {$shortest_period_ps * $tns_critical_range_ratio}]
  set_db / .tns_critical_range $target_tns_critical_range_ps
  set effective_tns_critical_range_ps [get_db / .tns_critical_range]
  if {![string is double -strict $effective_tns_critical_range_ps] \
      || abs($effective_tns_critical_range_ps - $target_tns_critical_range_ps) > 1.0e-6} {
    error "tns_critical_range verification failed in ps: expected=$target_tns_critical_range_ps actual=$effective_tns_critical_range_ps"
  }

  set report_dir [file dirname $output_report]
  if {![file exists $report_dir]} {
    file mkdir $report_dir
  }
  set report_file [open $output_report w]
  puts $report_file "unit_domain=genus_database_ps"
  puts $report_file "setup_uncertainty_ratio=$setup_uncertainty_ratio"
  puts $report_file "tns_critical_range_ratio=$tns_critical_range_ratio"
  puts $report_file "shortest_clock_period_ps=$shortest_period_ps"
  puts $report_file "original_tns_critical_range_ps=$original_tns_critical_range_ps"
  puts $report_file "synthesis_tns_critical_range_ps=$effective_tns_critical_range_ps"
  foreach row $clock_rows {
    puts $report_file "clock=[lindex $row 0] period_ps=[lindex $row 1] original_setup_uncertainty_ps=[lindex $row 2] synthesis_setup_uncertainty_ps=[lindex $row 3]"
  }
  puts $report_file "apply_verification=PASS"
  close $report_file

  set ::genus_synthesis_timing_margin::clock_rows $clock_rows
  set ::genus_synthesis_timing_margin::original_tns_critical_range $original_tns_critical_range_ps
  set ::genus_synthesis_timing_margin::report_path $output_report
  set ::genus_synthesis_timing_margin::active true
  puts "INFO: GENUS_SYNTHESIS_TNS_CRITICAL_RANGE shortest_period_ps=$shortest_period_ps value_ps=$effective_tns_critical_range_ps"
}

proc restore_genus_synthesis_timing_margin {} {
  if {!$::genus_synthesis_timing_margin::active} {
    error "Genus synthesis timing margin is not active"
  }

  foreach row $::genus_synthesis_timing_margin::clock_rows {
    set clock_name [lindex $row 0]
    set original_uncertainty [lindex $row 2]
    set clock_objects [get_db clocks $clock_name]
    if {[llength $clock_objects] != 1} {
      error "Clock '$clock_name' must resolve to exactly one database clock during restore: '$clock_objects'"
    }
    set clock [lindex $clock_objects 0]
    set_db $clock .setup_uncertainty $original_uncertainty
    set restored_uncertainty [get_db $clock .setup_uncertainty]
    if {![string is double -strict $restored_uncertainty] \
        || abs($restored_uncertainty - $original_uncertainty) > 1.0e-6} {
      error "Clock '$clock_name' setup uncertainty restore failed: expected=$original_uncertainty actual=$restored_uncertainty"
    }
    puts "INFO: GENUS_SYNTHESIS_TIMING_MARGIN_RESTORED clock=$clock_name setup_uncertainty_ps=$restored_uncertainty"
  }

  set_db / .tns_critical_range $::genus_synthesis_timing_margin::original_tns_critical_range
  set restored_tns_critical_range [get_db / .tns_critical_range]
  if {![string is double -strict $restored_tns_critical_range] \
      || abs($restored_tns_critical_range - $::genus_synthesis_timing_margin::original_tns_critical_range) > 1.0e-6} {
    error "tns_critical_range restore failed: expected=$::genus_synthesis_timing_margin::original_tns_critical_range actual=$restored_tns_critical_range"
  }

  set report_file [open $::genus_synthesis_timing_margin::report_path a]
  puts $report_file "restored_tns_critical_range_ps=$restored_tns_critical_range"
  foreach row $::genus_synthesis_timing_margin::clock_rows {
    set clock_name [lindex $row 0]
    set clock_objects [get_db clocks $clock_name]
    if {[llength $clock_objects] != 1} {
      error "Clock '$clock_name' must resolve to exactly one database clock for reporting: '$clock_objects'"
    }
    set clock [lindex $clock_objects 0]
    puts $report_file "restored_clock=$clock_name setup_uncertainty_ps=[get_db $clock .setup_uncertainty]"
  }
  puts $report_file "restore_verification=PASS"
  close $report_file

  set ::genus_synthesis_timing_margin::active false
}
