# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# --- Legalize ONLY BOTTOM tier ---
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl


set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

set DEF_IN   [file join $RESULTS_DIR "${DESIGN}_3D.lg.def"]
set V_IN     [file join $RESULTS_DIR "${DESIGN}_3D.lg.v"]
set SDC_IN   [file join $RESULTS_DIR "2_floorplan.sdc"]
set sdc $SDC_IN

source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl

setMultiCpuUsage -localCpu [_get NUM_CORES 16]

# --- init design ---
set init_lef_file $lefs
set init_mmmc_file ""
set init_design_settop 1
set init_top_cell $DESIGN
set init_verilog $V_IN
set init_design_netlisttype "Verilog"
init_design -setup {WC_VIEW} -hold {BC_VIEW}
defIn $DEF_IN

# --- incremental legalization on remaining (bottom) ---
checkPlace
setPlaceMode -place_detail_legalization_inst_gap 1
setFillerMode -fitGap true
source $::env(CADENCE_SCRIPTS_DIR)/tier_cell_policy.tcl

set_tier_placement_status upper fixed
apply_tier_policy bottom -fixlib 1
# apply_tier_policy bottom
catch { place_opt_design -out_dir $REPORTS_DIR -prefix legalize_bottom }
checkPlace

set_tier_placement_status upper placed

fit
dumpToGIF $LOG_DIR/4_2_lg_bottom.png
# --- write out only-bottom DEF ---
set DEF_OUT  [file join $RESULTS_DIR "${DESIGN}_3D.lg.def"]
set V_OUT [file join $RESULTS_DIR "${DESIGN}_3D.lg.v"]
defOut -floorplan $DEF_OUT
saveNetlist $V_OUT 
puts "INFO: Bottom-only legalized DEF -> $DEF_OUT"
puts "INFO: Bottom-only legalized Verilog -> $V_OUT"
exit
