set design_name $::env(SYN3D_UNIT_NAME)
set input_netlist $::env(SYN3D_UNIT_INPUT_NETLIST)
set output_netlist $::env(SYN3D_UNIT_OUTPUT_NETLIST)
set area_report $::env(SYN3D_UNIT_AREA_REPORT)
set area_value $::env(SYN3D_UNIT_AREA_VALUE)
set lib_files $::env(SYN3D_UNIT_LIB_FILES)

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

# This characterization step intentionally has no SDC. It matches the old
# coarse-unit flow and only refines an already technology-mapped netlist.
syn_opt -incr -effort low
report_area > $area_report
write_hdl > $output_netlist

set fp [open $area_value w]
puts $fp [read_cell_area $area_report $design_name]
close $fp
exit
