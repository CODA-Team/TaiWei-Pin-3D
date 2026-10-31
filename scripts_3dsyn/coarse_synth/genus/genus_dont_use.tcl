proc configure_genus_dont_use {patterns exception_names report_path} {
  if {[string trim $patterns] eq ""} {
    error "Genus dont-use patterns are empty; refusing to run synthesis without a cell-use policy"
  }

  set matched_cells {}
  set pattern_rows {}
  foreach pattern $patterns {
    set hits [get_db lib_cells */$pattern]
    set hit_count [llength $hits]
    puts "INFO: GENUS_DONT_USE_PATTERN pattern=$pattern matched=$hit_count"
    lappend pattern_rows [list $pattern $hit_count]
    foreach hit $hits {
      lappend matched_cells $hit
    }
  }

  set matched_cells [lsort -unique $matched_cells]
  if {[llength $matched_cells] > 0} {
    set_dont_use $matched_cells
  } else {
    puts "INFO: Genus dont-use patterns matched no loaded library cells; no cells need to be avoided"
  }

  set exception_cells {}
  foreach cell_name $exception_names {
    if {[regexp {[\[\]*?]} $cell_name]} {
      error "Genus dont-use exceptions must contain exact cell names; invalid value '$cell_name'"
    }
    set hits [get_db lib_cells */$cell_name]
    if {[llength $hits] != 1} {
      error "Genus dont-use exception '$cell_name' must match exactly one loaded library cell; matches=$hits"
    }
    set exception_cell [lindex $hits 0]
    if {[lsearch -exact $matched_cells $exception_cell] < 0} {
      error "Genus dont-use exception '$cell_name' is not selected by the dont-use patterns"
    }
    lappend exception_cells $exception_cell
  }
  set exception_cells [lsort -unique $exception_cells]

  foreach exception_cell $exception_cells {
    set_db $exception_cell .avoid false
  }

  set verification_failures {}
  foreach cell $matched_cells {
    set cell_name [get_db $cell .name]
    set avoid_value [get_db $cell .avoid]
    if {[lsearch -exact $exception_cells $cell] >= 0} {
      if {$avoid_value ni {false 0}} {
        lappend verification_failures "$cell_name expected=allowed actual=$avoid_value"
      }
    } elseif {$avoid_value ni {true 1}} {
      lappend verification_failures "$cell_name expected=avoided actual=$avoid_value"
    }
  }
  if {[llength $verification_failures] > 0} {
    error "Genus dont-use verification failed: $verification_failures"
  }

  set report_dir [file dirname $report_path]
  if {![file exists $report_dir]} {
    file mkdir $report_dir
  }
  set report_file [open $report_path w]
  puts $report_file "patterns=$patterns"
  puts $report_file "exceptions=$exception_names"
  foreach row $pattern_rows {
    puts $report_file "pattern=[lindex $row 0] matched=[lindex $row 1]"
  }
  puts $report_file "unique_matched_cells=[llength $matched_cells]"
  puts $report_file "unique_exception_cells=[llength $exception_cells]"
  foreach cell $matched_cells {
    set is_exception [expr {[lsearch -exact $exception_cells $cell] >= 0}]
    puts $report_file "cell=[get_db $cell .name] exception=$is_exception avoid=[get_db $cell .avoid]"
  }
  puts $report_file "verification=PASS"
  close $report_file

  puts "INFO: GENUS_DONT_USE_APPLIED matched=[llength $matched_cells] exceptions=[llength $exception_cells] verification=PASS report=$report_path"
  return [dict create \
    matched_cells $matched_cells \
    exception_cells $exception_cells \
    report_path $report_path]
}
