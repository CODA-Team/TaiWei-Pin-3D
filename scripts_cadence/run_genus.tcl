# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# run_genus.tcl — Genus synthesis
# Outputs: $::env(RESULTS_DIR)/1_synth.v and 1_synth.sdc
# ==========================================

source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl

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
# Directories and key files
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR  [_get OBJECTS_DIR]
foreach d [list $RESULTS_DIR $REPORTS_DIR $LOG_DIR] {
  if {$d ne "" && ![file exists $d]} { file mkdir $d }
}

set OUT_V   [file join $RESULTS_DIR "1_synth.v"]
set OUT_SDC [file join $RESULTS_DIR "1_synth.sdc"]

# Threads
set_db max_cpus_per_server [_get NUM_CORES 16] 
set_db super_thread_servers "localhost" 

set list_lib "$libworst"

# Target library
set link_library $list_lib
set target_library $list_lib

# Expand and deduplicate include directories (wildcards accepted)
set vi_all {}
foreach d $VERILOG_INCLUDE_DIRS {
  set hits [glob -nocomplain -- $d]
  if {[llength $hits]} {
    foreach x $hits { lappend vi_all $x }
  } elseif {[file isdirectory $d]} {
    lappend vi_all $d
  }
}
set vi_all [_uniq $vi_all]

# Key: Tell Genus to search for `include` files in these directories
if {[llength $vi_all]} {
  puts "init_hdl_search_path = $vi_all"
  set_db init_hdl_search_path $vi_all
}

# set path
set_db hdl_flatten_complex_port true
set_db hdl_record_naming_style  %s_%s

set_db library $list_lib

# Dedup RTL list first (rtl_all comes from design_setup.tcl)
set rtl_all_uniq [_uniq $rtl_all]

# Partition: package files first (common pattern: *_pkg.sv or *pkg.sv)
set rtl_pkg   {}
set rtl_other {}
foreach f $rtl_all_uniq {
  if {[regexp -nocase {(^|/).*(^|_)(pkg|_pkg)\.sv$} $f] || [regexp -nocase {(^|/).*_pkg\.sv$} $f]} {
    lappend rtl_pkg $f
  } else {
    lappend rtl_other $f
  }
}

if {[llength $rtl_pkg] == 0 && [info exists vi_all] && [llength $vi_all]} {
  set found_pkgs {}
  foreach d $vi_all {
    foreach pat [list "*_pkg.sv" "*pkg.sv"] {
      set hits [glob -nocomplain -- [file join $d $pat]]
      if {[llength $hits]} { foreach x $hits { lappend found_pkgs $x } }
    }
  }
  set found_pkgs [_uniq $found_pkgs]
  if {[llength $found_pkgs]} {
    puts "INFO: Auto-discovered package files in include dirs: $found_pkgs"
    set rtl_pkg $found_pkgs
  }
}

# Final ordered list: packages first, then the rest
set rtl_ordered [_uniq [concat $rtl_pkg $rtl_other]]

puts "INFO: read_hdl (SV) file count = [llength $rtl_ordered]"
if {[llength $rtl_pkg]} {
  puts "INFO: package files first = [llength $rtl_pkg]"
  puts "INFO: first package file  = [lindex $rtl_pkg 0]"
} else {
  puts "WARN: no package (*.sv) detected; if you still see ibex_pkg::* errors, ensure ibex_pkg.sv is in rtl_all or include dirs."
}

# Read all RTL in one shot to preserve compilation-unit ordering
read_hdl -sv $rtl_ordered

# Elaborate & Constraints & Initialization
elaborate $DESIGN
time_info Elaboration

read_sdc $sdc
init_design

configure_constant_tie_cells

# --- apply global dont-use from env (safe; no TAP/FILL/CLKBUF here) ---
# if {[info exists ::env(DONT_USE_CELLS)] && $::env(DONT_USE_CELLS) ne ""} {
#   foreach c $::env(DONT_USE_CELLS) { catch { set_dont_use $c true } }
# }

check_design -unresolved

check_timing_intent

# reports the physical layout estimation report from lef and QRC tech file
report_ple > ${REPORTS_DIR}/ple.rpt 

# keep hierarchy during synthesis

syn_generic
time_info GENERIC

write_reports -directory ${REPORTS_DIR} -tag generic
write_db  ${OBJECTS_DIR}/${DESIGN}_generic.db

syn_map
time_info MAPPED

# generate a summary for the current stage of synthesis
write_reports -directory ${REPORTS_DIR} -tag map
write_db  ${OBJECTS_DIR}/${DESIGN}_map.db

syn_opt
time_info OPT
write_db ${OBJECTS_DIR}/${DESIGN}_opt.db

# Flatten all modules except for macros/black boxes unless hierarchy retention is requested.
# ungroup -all -flatten
##############################################################################
# Write reports
##############################################################################

# summarizes the information, warnings and errors
report_messages > ${REPORTS_DIR}/${DESIGN}_messages.rpt

# generate PPA reports
report_gates > ${REPORTS_DIR}/${DESIGN}_gates.rpt
report_power > ${REPORTS_DIR}/${DESIGN}_power.rpt
report_area > ${REPORTS_DIR}/${DESIGN}_power.rpt
write_reports -directory ${REPORTS_DIR} -tag final 

write_hdl > $OUT_V
write_sdc > $OUT_SDC

puts "INFO: Wrote $OUT_V"
puts "INFO: Wrote $OUT_SDC"
exit
