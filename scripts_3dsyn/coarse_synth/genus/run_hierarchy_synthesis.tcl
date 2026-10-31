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
source $::env(SYN3D_GENUS_DONT_USE_TCL)

proc run_configured_syn_opt {} {
  set mode [_get SYN3D_GENUS_OPT_MODE normal]
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

proc configure_constant_tie_cells {} {
  set tie_cells {}
  foreach variable_name {TIELO_CELL_AND_PORT TIEHI_CELL_AND_PORT} {
    if {![info exists ::env($variable_name)]} {
      error "$variable_name is not set"
    }

    set tie_spec $::env($variable_name)
    if {[llength $tie_spec] != 2 || [lindex $tie_spec 0] eq "" || [lindex $tie_spec 1] eq ""} {
      error "$variable_name must contain exactly one cell name and one output port: '$tie_spec'"
    }

    set cell_name [lindex $tie_spec 0]
    if {[regexp {[\[\]*?]} $cell_name]} {
      error "$variable_name cell name must not contain glob metacharacters: '$cell_name'"
    }
    set matches [get_db lib_cells */$cell_name]
    if {[llength $matches] != 1} {
      error "$variable_name cell '$cell_name' must match exactly one loaded library cell; matches=$matches"
    }
    set tie_cell [lindex $matches 0]
    set port_name [lindex $tie_spec 1]
    set port_matches {}
    foreach lib_pin [get_db $tie_cell .lib_pins] {
      if {[get_db $lib_pin .base_name] eq $port_name} {
        lappend port_matches $lib_pin
      }
    }
    if {[llength $port_matches] != 1 || [get_db [lindex $port_matches 0] .direction] ne "out"} {
      error "$variable_name port '$port_name' must match exactly one output pin on '$cell_name'"
    }
    lappend tie_cells $tie_cell
  }

  if {[lindex $tie_cells 0] eq [lindex $tie_cells 1]} {
    error "TIELO_CELL_AND_PORT and TIEHI_CELL_AND_PORT resolve to the same library cell"
  }

  foreach tie_cell $tie_cells {
    set_db $tie_cell .avoid false
    set_db $tie_cell .preserve false
  }
  set_db use_tiehilo_for_const duplicate
  if {[get_db / .use_tiehilo_for_const] ne "duplicate"} {
    error "Failed to enable duplicate constant tie-cell mapping"
  }
  puts "INFO: Constant tie-cell mapping = duplicate"
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
set genus_dont_use_exceptions {}
if {[info exists ::env(GENUS_DONT_USE_EXCEPTIONS)]} {
  set genus_dont_use_exceptions $::env(GENUS_DONT_USE_EXCEPTIONS)
}

configure_constant_tie_cells
configure_genus_dont_use \
  $genus_dont_use \
  $genus_dont_use_exceptions \
  [file join $REPORTS_DIR genus_dont_use_coarse_hierarchy.rpt]

check_design -unresolved
check_timing_intent
report_ple > ${REPORTS_DIR}/ple.rpt

run_configured_syn_opt
time_info OPT
write_db ${OBJECTS_DIR}/${DESIGN}_opt.db

report_messages > ${REPORTS_DIR}/${DESIGN}_messages.rpt
report_gates > ${REPORTS_DIR}/${DESIGN}_gates.rpt
report_power > ${REPORTS_DIR}/${DESIGN}_power.rpt
report_area > ${REPORTS_DIR}/${DESIGN}_area.rpt
write_reports -directory ${REPORTS_DIR} -tag final

write_hdl > $OUT_V
write_sdc > $OUT_SDC

puts "INFO: Wrote $OUT_V"
puts "INFO: Wrote $OUT_SDC"
exit
