namespace eval genus_synthesis_max_fanout {
  variable active false
  variable design_name ""
  variable limit ""
  variable original_limit ""
  variable report_path ""
}

proc genus_synthesis_max_fanout_limit {} {
  if {![info exists ::env(GENUS_SYNTHESIS_MAX_FANOUT)]} {
    return 64
  }

  set value [string trim $::env(GENUS_SYNTHESIS_MAX_FANOUT)]
  if {![string is double -strict $value] || $value <= 0.0} {
    error "GENUS_SYNTHESIS_MAX_FANOUT must be a positive number: '$value'"
  }
  return $value
}

proc configure_genus_synthesis_max_fanout {limit output_report} {
  if {$::genus_synthesis_max_fanout::active} {
    error "Genus synthesis max-fanout constraint is already active"
  }
  if {![string is double -strict $limit] || $limit <= 0.0} {
    error "The Genus synthesis max-fanout limit must be positive: '$limit'"
  }

  set design [current_design]
  if {$design eq ""} {
    error "A current design is required before setting max_fanout"
  }
  set design_name [get_db $design .name]
  set original_limit [get_db $design .max_fanout]

  set_max_fanout $limit $design
  set effective_limit [get_db $design .max_fanout]
  if {![string is double -strict $effective_limit] \
      || abs($effective_limit - $limit) > 1.0e-6} {
    error "Genus max_fanout verification failed: expected=$limit actual=$effective_limit"
  }

  set report_dir [file dirname $output_report]
  if {![file exists $report_dir]} {
    file mkdir $report_dir
  }
  set report_file [open $output_report w]
  puts $report_file "design=$design_name"
  puts $report_file "original_max_fanout=$original_limit"
  puts $report_file "synthesis_max_fanout=$effective_limit"
  puts $report_file "apply_verification=PASS"
  close $report_file

  set ::genus_synthesis_max_fanout::design_name $design_name
  set ::genus_synthesis_max_fanout::limit $effective_limit
  set ::genus_synthesis_max_fanout::original_limit $original_limit
  set ::genus_synthesis_max_fanout::report_path $output_report
  set ::genus_synthesis_max_fanout::active true
  puts "INFO: GENUS_SYNTHESIS_MAX_FANOUT design=$design_name original=$original_limit value=$effective_limit verification=PASS"
}

proc report_genus_synthesis_max_fanout {} {
  if {!$::genus_synthesis_max_fanout::active} {
    error "Genus synthesis max-fanout constraint is not active"
  }

  set design [current_design]
  if {$design eq ""} {
    error "A current design is required when reporting max_fanout"
  }
  set effective_limit [get_db $design .max_fanout]
  if {![string is double -strict $effective_limit] \
      || abs($effective_limit - $::genus_synthesis_max_fanout::limit) > 1.0e-6} {
    error "Genus max_fanout changed during synthesis: expected=$::genus_synthesis_max_fanout::limit actual=$effective_limit"
  }

  set max_load_count 0
  set nets_at_or_above_limit 0
  set nets_above_limit 0
  set max_net ""
  foreach net [get_db nets] {
    set load_count [get_db $net .num_loads]
    if {$load_count > $max_load_count} {
      set max_load_count $load_count
      set max_net [get_db $net .name]
    }
    if {$load_count >= $effective_limit} {
      incr nets_at_or_above_limit
    }
    if {$load_count > $effective_limit} {
      incr nets_above_limit
    }
  }

  set max_fanout_cost [get_db $design .max_fanout_cost]
  set report_file [open $::genus_synthesis_max_fanout::report_path a]
  puts $report_file "post_synthesis_effective_max_fanout=$effective_limit"
  puts $report_file "post_synthesis_max_fanout_cost=$max_fanout_cost"
  puts $report_file "post_synthesis_max_num_loads=$max_load_count"
  puts $report_file "post_synthesis_max_num_loads_net=$max_net"
  puts $report_file "post_synthesis_nets_num_loads_ge_limit=$nets_at_or_above_limit"
  puts $report_file "post_synthesis_nets_num_loads_gt_limit=$nets_above_limit"
  puts $report_file "post_synthesis_verification=PASS"
  close $report_file

  set violation_report "$::genus_synthesis_max_fanout::report_path.violators"
  report_constraint -drv_violation_type max_fanout -all_violators > $violation_report
  puts "INFO: GENUS_SYNTHESIS_MAX_FANOUT_POST value=$effective_limit max_fanout_cost=$max_fanout_cost max_num_loads=$max_load_count max_net=$max_net nets_num_loads_gt_limit=$nets_above_limit"
}

proc restore_genus_synthesis_max_fanout {} {
  if {!$::genus_synthesis_max_fanout::active} {
    error "Genus synthesis max-fanout constraint is not active"
  }

  set design [current_design]
  if {$design eq "" || [get_db $design .name] ne $::genus_synthesis_max_fanout::design_name} {
    error "The current design changed before restoring max_fanout"
  }

  set original_limit $::genus_synthesis_max_fanout::original_limit
  if {$original_limit eq "" || $original_limit eq "no_value"} {
    set_db $design .max_fanout no_value
  } else {
    if {![string is double -strict $original_limit] || $original_limit <= 0.0} {
      error "Cannot restore invalid original max_fanout value: '$original_limit'"
    }
    set_max_fanout $original_limit $design
  }

  set restored_limit [get_db $design .max_fanout]
  if {$original_limit eq "" || $original_limit eq "no_value"} {
    if {$restored_limit ne "" && $restored_limit ne "no_value"} {
      error "Genus max_fanout restore failed: expected=no_value actual=$restored_limit"
    }
  } elseif {![string is double -strict $restored_limit] \
      || abs($restored_limit - $original_limit) > 1.0e-6} {
    error "Genus max_fanout restore failed: expected=$original_limit actual=$restored_limit"
  }

  set report_file [open $::genus_synthesis_max_fanout::report_path a]
  puts $report_file "restored_max_fanout=$restored_limit"
  puts $report_file "restore_verification=PASS"
  close $report_file

  set ::genus_synthesis_max_fanout::active false
  puts "INFO: GENUS_SYNTHESIS_MAX_FANOUT_RESTORED value=$restored_limit verification=PASS"
}
