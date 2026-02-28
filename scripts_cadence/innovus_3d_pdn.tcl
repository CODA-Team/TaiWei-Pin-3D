# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ==========================================
# innovus_3d_pdn.tcl - 3D PDN design flow script
# Goal:
# General Interface for different technologys PDN design
# ==========================================
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl
# Directories and key files
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR  [_get OBJECTS_DIR]
set DEF_IO    $RESULTS_DIR/${DESIGN}_3D.fp.def
set VERILOG_IO $RESULTS_DIR/${DESIGN}_3D.fp.v
set sdc        [file join $RESULTS_DIR "1_synth.sdc"]
source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl

setMultiCpuUsage -localCpu [_get NUM_CORES 16]

# --- 3D place init: import gp DEF, create groups, initial fixing ---
set init_lef_file          $lefs
set init_mmmc_file         ""
set init_design_settop     1
set init_top_cell          $DESIGN
set init_verilog           $VERILOG_IO
set init_design_netlisttype "Verilog"

set init_pwr_net  {BOT_VDD TOP_VDD}
set init_gnd_net  {BOT_VSS TOP_VSS}

init_design -setup {WC_VIEW} -hold {BC_VIEW}
set_power_analysis_mode -leakage_power_view WC_VIEW -dynamic_power_view WC_VIEW
set_interactive_constraint_modes {CON}
setAnalysisMode -reset
setAnalysisMode -analysisType onChipVariation -cppr both
setOptMode -powerEffort low -leakageToDynamicRatio 0.5

defIn $DEF_IO

# Floorplan parameters 
set CORE_UTIL [_get CORE_UTILIZATION 60] 
set ASPECT_RATIO [_get CORE_ASPECT_RATIO 1.0] 
set CORE_MARGIN [_get CORE_MARGIN 0.2] 
set PLACE_SITE [_get PLACE_SITE ""]
# --- Floorplan Initialization (tier-aware) ---
set U_target [expr {double($CORE_UTIL) / 100.0}]
set mL $CORE_MARGIN; set mR $CORE_MARGIN; set mT $CORE_MARGIN; set mB $CORE_MARGIN
source $::env(CADENCE_SCRIPTS_DIR)/floorplan_utils.tcl
lassign [tier::core_wh_for_max_tier_util $U_target $ASPECT_RATIO] CORE_W CORE_H A_up A_bot A_max

puts "INFO: Tier areas: upper=$A_up bottom=$A_bot (max=$A_max)"
puts "INFO: Core W/H = $CORE_W / $CORE_H (max-tier util target=$U_target)"
floorPlan -s [list $CORE_W $CORE_H $mL $mB $mR $mT] -siteOnly $PLACE_SITE

deleteTrack

# if {[file exists $::env(MAKE_TRACKS)]} {
#     source $::env(MAKE_TRACKS)
# } else {
generateTracks 
# }

# --- Place pins evenly on four sides (with explicit layer settings) ---
source $::env(CADENCE_SCRIPTS_DIR)/place_pin.tcl 

source $::env(PLATFORM_DIR)/util/pdn_config.tcl

fit
dumpToGIF $LOG_DIR/2_pdn.png
defOut -floorplan $RESULTS_DIR/2_floorplan.def
saveNetlist $RESULTS_DIR/2_floorplan.v

exit
