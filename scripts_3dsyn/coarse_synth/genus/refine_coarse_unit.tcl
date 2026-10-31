set design_name $::env(SYN3D_UNIT_NAME)
set input_netlist $::env(SYN3D_UNIT_INPUT_NETLIST)
set output_netlist $::env(SYN3D_UNIT_OUTPUT_NETLIST)
set area_report $::env(SYN3D_UNIT_AREA_REPORT)
set area_value $::env(SYN3D_UNIT_AREA_VALUE)
set lib_files $::env(SYN3D_UNIT_LIB_FILES)
set dont_use_patterns $::env(SYN3D_UNIT_DONT_USE_CELLS)
set dont_use_exceptions {}
if {[info exists ::env(SYN3D_UNIT_GENUS_DONT_USE_EXCEPTIONS)]} {
  set dont_use_exceptions $::env(SYN3D_UNIT_GENUS_DONT_USE_EXCEPTIONS)
}
set dont_use_report $::env(SYN3D_UNIT_DONT_USE_REPORT)
source $::env(SYN3D_GENUS_DONT_USE_TCL)

proc run_configured_syn_opt {} {
  set mode normal
  if {[info exists ::env(SYN3D_GENUS_OPT_MODE)] && $::env(SYN3D_GENUS_OPT_MODE) ne ""} {
    set mode $::env(SYN3D_GENUS_OPT_MODE)
  }

  puts "INFO: SYN3D_GENUS_OPT_MODE = $mode"
  switch -- $mode {
    normal {
      syn_opt
    }
    low_effort {
      syn_opt -incr -effort low
    }
    default {
      error "SYN3D_GENUS_OPT_MODE must be normal or low_effort: '$mode'"
    }
  }
}

proc read_cell_area {report_path design_name} {
  set fp [open $report_path r]
  set text [read $fp]
  close $fp
  regsub -all {[][(){}.+*?^$\\|]} $design_name {\\&} escaped_name
  set row_pattern [format {^\s*%s\s+\d+\s+([-+]?[0-9]*\.?[0-9]+)\s+} $escaped_name]
  foreach line [split $text "\n"] {
    if {[regexp $row_pattern $line -> area]} {
      return $area
    }
  }
  foreach line [split $text "\n"] {
    if {[regexp {^\s*Cell Area\s+([-+]?[0-9]*\.?[0-9]+)\s*$} $line -> area]} {
      return $area
    }
  }
  error "Cannot read cell area for $design_name from $report_path"
}

set_db max_cpus_per_server 1
set_db super_thread_servers "localhost"
set_db hdl_flatten_complex_port true
set_db hdl_record_naming_style %s_%s
catch {set_db hdl_resolve_instance_with_libcell true}
set link_library $lib_files
set target_library $lib_files
set_db library $lib_files

read_hdl -sv $input_netlist
elaborate $design_name
init_design

configure_genus_dont_use $dont_use_patterns $dont_use_exceptions $dont_use_report

# This characterization step intentionally has no SDC and only optimizes an
# already technology-mapped netlist.
run_configured_syn_opt
report_area > $area_report
write_hdl > $output_netlist

set fp [open $area_value w]
puts $fp [read_cell_area $area_report $design_name]
close $fp
exit
