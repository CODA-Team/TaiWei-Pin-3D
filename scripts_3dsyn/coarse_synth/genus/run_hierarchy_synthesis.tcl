# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# Genus synthesis on an existing gate-level netlist with stitched coarse-unit
# internals preserved as hierarchy.
# ==========================================

source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl

proc normalize_sdc_for_openroad {sdc_path} {
  if {![file exists $sdc_path]} {
    error "SDC output does not exist for normalization: $sdc_path"
  }

  set in_fp [open $sdc_path r]
  set text [read $in_fp]
  close $in_fp

  set changed 0
  set out_lines {}
  foreach line [split $text "\n"] {
    if {[regexp {^(\s*)set_dont_use\s+true\s+(.+?)\s*$} $line -> indent target]} {
      lappend out_lines "${indent}set_dont_use ${target}"
      set changed 1
      continue
    }
    lappend out_lines $line
  }

  if {!$changed} {
    return
  }

  set out_fp [open $sdc_path w]
  puts -nonewline $out_fp [join $out_lines "\n"]
  close $out_fp
}

proc read_module_name_list {path} {
  set names {}
  if {$path eq ""} {
    return $names
  }
  if {![file exists $path]} {
    error "coarse-unit type list does not exist: $path"
  }

  set fp [open $path r]
  while {[gets $fp line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string match "#*" $line]} {
      continue
    }
    lappend names $line
  }
  close $fp
  return $names
}

proc collect_named_modules {module_names} {
  set mods {}
  foreach name $module_names {
    set q [format {.name == "%s"} $name]
    set found [get_db modules -if $q]
    if {[llength $found] == 0} {
      puts "WARN: coarse-unit module not found after elaborate/init_design: $name"
      continue
    }
    foreach item $found { lappend mods $item }
  }
  return $mods
}

proc collect_named_hinsts {module_names} {
  set hinsts {}
  foreach name $module_names {
    set q [format {.module.name == "%s"} $name]
    set found [get_db hinsts -if $q]
    foreach item $found { lappend hinsts $item }
  }
  return $hinsts
}

set LOG_DIR      [_get LOG_DIR]
set RESULTS_DIR  [_get RESULTS_DIR]
set REPORTS_DIR  [_get REPORTS_DIR]
set OBJECTS_DIR  [_get OBJECTS_DIR]
set NETLIST_IN   [_get GENUS_INPUT_NETLIST [file join $RESULTS_DIR "1_synth.v"]]
set OUT_V        [_get GENUS_OUTPUT_NETLIST [file join $RESULTS_DIR "1_genus_netlist.v"]]
set OUT_SDC      [_get GENUS_OUTPUT_SDC [file join $RESULTS_DIR "1_genus_netlist.sdc"]]
set COARSE_UNIT_LIST_FILE [_get SYN3D_COARSE_UNIT_LIST_FILE]

foreach d [list $RESULTS_DIR $REPORTS_DIR $LOG_DIR $OBJECTS_DIR] {
  if {$d ne "" && ![file exists $d]} { file mkdir $d }
}

if {![file exists $NETLIST_IN]} {
  error "Input netlist does not exist: $NETLIST_IN"
}

set_db max_cpus_per_server [_get NUM_CORES 16]
set_db super_thread_servers "localhost"

set list_lib [_get GENUS_LIB_FILES "$libworst"]
set link_library $list_lib
set target_library $list_lib
set_db library $list_lib

set_db hdl_flatten_complex_port true
set_db hdl_record_naming_style %s_%s

puts "INFO: Netlist input            = $NETLIST_IN"
puts "INFO: Design                   = $DESIGN"
puts "INFO: Library list             = $list_lib"
puts "INFO: Coarse-unit list file     = $COARSE_UNIT_LIST_FILE"

read_hdl -sv $NETLIST_IN
elaborate $DESIGN
time_info Elaboration

read_sdc $sdc
init_design

set coarse_unit_names [read_module_name_list $COARSE_UNIT_LIST_FILE]
puts "INFO: Requested coarse-unit count = [llength $coarse_unit_names]"
set coarse_mods [collect_named_modules $coarse_unit_names]
set coarse_hinsts [collect_named_hinsts $coarse_unit_names]
puts "INFO: Resolved coarse-unit type count     = [llength $coarse_mods]"
puts "INFO: Resolved coarse-unit instance count = [llength $coarse_hinsts]"

set_db / .auto_ungroup none
if {[llength $coarse_mods] > 0} {
  catch { set_db $coarse_mods .ungroup_ok false }
}
if {[llength $coarse_hinsts] > 0} {
  catch { set_db $coarse_hinsts .ungroup_ok false }
}

set genus_dont_use {}
if {[info exists ::env(DONT_USE_CELLS)] && $::env(DONT_USE_CELLS) ne ""} {
  set genus_dont_use [concat $genus_dont_use $::env(DONT_USE_CELLS)]
}
set genus_dont_use_file [_get GENUS_DONT_USE_FILE]
if {$genus_dont_use_file ne "" && [file exists $genus_dont_use_file]} {
  set fp [open $genus_dont_use_file r]
  while {[gets $fp line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string match "#*" $line]} {
      continue
    }
    lappend genus_dont_use $line
  }
  close $fp
}
set genus_extra_dont_use [_get GENUS_EXTRA_DONT_USE_CELLS]
if {$genus_extra_dont_use ne ""} {
  set genus_dont_use [concat $genus_dont_use $genus_extra_dont_use]
}
set genus_dont_use [_uniq $genus_dont_use]
if {[llength $genus_dont_use]} {
  puts "INFO: Applying Genus dont_use cell count = [llength $genus_dont_use]"
  foreach c $genus_dont_use {
    catch { set_dont_use $c true }
  }
}

check_design -unresolved
check_timing_intent
report_ple > ${REPORTS_DIR}/ple.rpt

# 2026-07-09: preserve stitched coarse hierarchy and keep whole-netlist Genus
# intervention minimal by using only low-effort incremental syn_opt.
syn_opt -incr -effort low
time_info OPT
write_db ${OBJECTS_DIR}/${DESIGN}_opt.db

report_messages > ${REPORTS_DIR}/${DESIGN}_messages.rpt
report_gates > ${REPORTS_DIR}/${DESIGN}_gates.rpt
report_power > ${REPORTS_DIR}/${DESIGN}_power.rpt
report_area > ${REPORTS_DIR}/${DESIGN}_area.rpt
write_reports -directory ${REPORTS_DIR} -tag final

write_hdl > $OUT_V
write_sdc > $OUT_SDC
normalize_sdc_for_openroad $OUT_SDC

puts "INFO: Wrote $OUT_V"
puts "INFO: Wrote $OUT_SDC"
exit
