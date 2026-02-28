# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ===============================
# innovus_place3D_init.tcl — 3D place init with stable modes
# ===============================
# Source utility and setup scripts
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/place_common.tcl

# Get directory paths from the environment/setup
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]

# Define input file paths based on the results directory
set FPDEF      [file join $RESULTS_DIR "2_floorplan.def"]
set FPVERILOG  [file join $RESULTS_DIR "2_floorplan.v"]
set sdc        [file join $RESULTS_DIR "1_synth.sdc"]

# Source the multi-mode multi-corner (MMMC) setup script
source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl

# Set up initial design parameters
set init_lef_file $lefs
set init_mmmc_file ""
set init_design_settop 1
set init_top_cell $DESIGN
set init_verilog $FPVERILOG
set init_design_netlisttype "Verilog"
# Initialize the design with specified setup and hold views
init_design -setup {WC_VIEW} -hold {BC_VIEW}
# Set the power analysis mode for leakage and dynamic power
set_power_analysis_mode -leakage_power_view WC_VIEW -dynamic_power_view WC_VIEW
# Read in the floorplan DEF file
defIn $FPDEF

setPlaceMode -place_design_refine_place false
place_design

# Define output file paths for the placed design
set GPDEFOUT [file join $RESULTS_DIR "${DESIGN}_3D.tmp.def"]
set GPVOUT   [file join $RESULTS_DIR "${DESIGN}_3D.tmp.v"]
# Write out the placed DEF file
defOut -floorplan $GPDEFOUT
# Save the netlist
saveNetlist $GPVOUT
# Fit the design view to the window
fit
# Dump a screenshot of the layout
dumpToGIF $LOG_DIR/init_place.png
# Print completion message
puts "INFO: 3D place init done. DEF: $GPDEFOUT  V: $GPVOUT"

# Exit the tool
exit
