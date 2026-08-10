# ============================================================
# cds_partition_handoff.tcl
# Build the OpenDB snapshot required by TritonPart from the
# Cadence pre-place handoff (Verilog connectivity + Innovus DEF).
# ============================================================

source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl

set results_dir $::env(RESULTS_DIR)
set netlist_file [file join $results_dir 2_2_floorplan_io.v]
set floorplan_def [file join $results_dir 2_2_floorplan_io.def]
set sdc_file [file join $results_dir 1_synth.sdc]
set odb_file [file join $results_dir 2_2_floorplan_io.odb]

foreach {label path} [list \
    "Cadence pre-place netlist" $netlist_file \
    "Cadence pre-place DEF" $floorplan_def \
    "synthesis constraints" $sdc_file] {
  if {![file exists $path]} {
    utl::error CDS 100 "$label does not exist: $path"
  }
}

puts "INFO: Building TritonPart OpenDB handoff from Cadence pre-place outputs."
puts "INFO:   connectivity: $netlist_file"
puts "INFO:   floorplan   : $floorplan_def"

# The Innovus DEF is intentionally written with `defOut -floorplan`, so it
# does not contain the logical NETS section.  Load and link the Verilog first
# to retain connectivity, then overlay the DEF floorplan, placement, and pins.
load_design $netlist_file $sdc_file "Build Cadence-to-TritonPart handoff"
read_def -floorplan_initialize $floorplan_def

set db [ord::get_db]
set block [ord::get_db_block]
if {$db eq "NULL" || $block eq "NULL"} {
  utl::error CDS 101 "OpenROAD database was not initialized from the Cadence handoff."
}

set inst_count [llength [$block getInsts]]
set net_count [llength [$block getNets]]
if {$inst_count == 0} {
  utl::error CDS 102 "Cadence handoff contains no instances."
}
if {$net_count == 0} {
  utl::error CDS 103 "Cadence handoff contains no nets; Verilog connectivity was not imported."
}

write_db $odb_file
puts "INFO: Cadence-to-TritonPart handoff complete: $odb_file"
puts "INFO:   instances=$inst_count nets=$net_count"

exit
