# ============== CTS on 3_place.{def,v,sdc} ==============
# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl

set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

set DEF_IN   [file join $RESULTS_DIR "3_place.def"]
set V_IN     [file join $RESULTS_DIR "3_place.v"]
set sdc   [file join $RESULTS_DIR "3_place.sdc"]

source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl

setMultiCpuUsage -localCpu [_get NUM_CORES 16]

# --- init design ---
set init_lef_file $lefs
set init_mmmc_file ""
set init_design_settop 1
set init_top_cell $DESIGN
set init_verilog $V_IN
setGenerateViaMode -auto true
init_design -setup {WC_VIEW} -hold {BC_VIEW}
set_power_analysis_mode -leakage_power_view WC_VIEW -dynamic_power_view WC_VIEW
set_interactive_constraint_modes {CON}
setAnalysisMode -reset
setAnalysisMode -analysisType onChipVariation -cppr both
defIn $DEF_IN

if {[info exists ::env(MAX_ROUTING_LAYER)]} { setDesignMode -topRoutingLayer    $::env(MAX_ROUTING_LAYER) }
if {[info exists ::env(MIN_ROUTING_LAYER)]} { setDesignMode -bottomRoutingLayer $::env(MIN_ROUTING_LAYER) }

# --- CTS properties ---
set_ccopt_property post_conditioning_enable_routing_eco 1
set_ccopt_property -cts_def_lock_clock_sinks_after_routing true
setOptMode -unfixClkInstForOpt false

source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl

set cts_layer "bottom"
set fix_layer "upper"
if {[info exists ::env(CTS_LAYER)]} {
  set cts_layer $::env(CTS_LAYER)
  if { $cts_layer == "bottom" } {
    set fix_layer "upper"
  } else {
    set fix_layer "bottom"
  }
}

set_tier_placement_status $fix_layer fixed
apply_tier_policy $cts_layer -fixlib 1 

# --- run ccopt ---
create_ccopt_clock_tree_spec
if { !([info exists ::env(UPPER_SITE)] && [info exists ::env(BOTTOM_SITE)]) } {
  ccopt_design
}

set_tier_placement_status $fix_layer placed

# --- 写出 DEF + Netlist（CTS 视图）---
defOut -floorplan -routing [file join $RESULTS_DIR "4_1_cts.def"]
saveNetlist [file join $RESULTS_DIR "4_1_cts.v"]
fit
dumpToGIF $LOG_DIR/4_1_cts.png
puts "INFO: CTS done. DEF -> [file join $RESULTS_DIR "4_1_cts.def"]  V -> [file join $RESULTS_DIR "4_1_cts.v"]"
exit
