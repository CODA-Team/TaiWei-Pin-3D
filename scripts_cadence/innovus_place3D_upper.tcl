# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ===============================
# innovus_place3D_upper.tcl — fix bottom, place upper
# ===============================
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/place_common.tcl

set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]

set GPDEF     [file join $RESULTS_DIR "${DESIGN}_3D.tmp.def"]
set GPVERILOG [file join $RESULTS_DIR "${DESIGN}_3D.tmp.v"]
set sdc       [file join $RESULTS_DIR "1_synth.sdc"]

source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl

set init_lef_file $lefs
set init_mmmc_file ""
set init_design_settop 1
set init_top_cell $DESIGN
set init_verilog $GPVERILOG
set init_design_netlisttype "Verilog"
setGenerateViaMode -auto true
init_design -setup {WC_VIEW} -hold {BC_VIEW}
set_power_analysis_mode -leakage_power_view WC_VIEW -dynamic_power_view WC_VIEW
defIn $GPDEF

source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl

set_tier_placement_status bottom fixed
apply_tier_policy upper

pc::setup_basic
pc::run_place

set_tier_placement_status bottom placed

# Export
saveDesign [file join $::env(OBJECTS_DIR) "${DESIGN}_3d_after_upper.enc"]
defOut -floorplan $GPDEF
saveNetlist [file join $RESULTS_DIR "${DESIGN}_3D.tmp.v"]
fit
dumpToGIF $LOG_DIR/upper_place.png
puts "INFO: 3D upper placement done."
exit
