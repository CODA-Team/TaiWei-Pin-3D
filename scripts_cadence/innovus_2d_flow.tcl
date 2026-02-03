# ===============================
# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# innovus_preplace.tcl
# Floorplan init + Pin placement (editPin)
# ===============================

source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl
# Directories and key files
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR  [_get OBJECTS_DIR]
set netlist     [file join $RESULTS_DIR "2_2_floorplan_io.v"]
set sdc        [file join $RESULTS_DIR "1_synth.sdc"]
source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl

setMultiCpuUsage -localCpu [_get NUM_CORES 16]
set util [_get CORE_UTILIZATION 60]

# default settings
set init_pwr_net VDD
set init_gnd_net VSS
set init_verilog "$netlist"
set init_design_netlisttype "Verilog"
set init_design_settop 1
set init_top_cell "$DESIGN"
set init_lef_file "$lefs"

# MCMM setup
init_design -setup {WC_VIEW} -hold {BC_VIEW}

defIn [file join $RESULTS_DIR "2_2_floorplan_io.def"]

set_power_analysis_mode -leakage_power_view WC_VIEW -dynamic_power_view WC_VIEW

set_interactive_constraint_modes {CON}
setAnalysisMode -reset
setAnalysisMode -analysisType onChipVariation -cppr both

clearGlobalNets
globalNetConnect VDD -type pgpin -pin VDD -inst * -override
globalNetConnect VSS -type pgpin -pin VSS -inst * -override
globalNetConnect VDD -type tiehi -inst * -override
globalNetConnect VSS -type tielo -inst * -override


setOptMode -powerEffort low -leakageToDynamicRatio 0.5
setGenerateViaMode -auto true
generateVias

# ===== Place pins evenly on four sides (with explicit layer settings) =====
# error "INTENTIONAL_ABORT: PDN stage completed; failing at user request"
source $::env(PLATFORM_DIR)/util/pdn_config.tcl
source $::env(CADENCE_SCRIPTS_DIR)/pdn_util.tcl
source $::env(CADENCE_SCRIPTS_DIR)/place_common.tcl

if {[info exists ::env(MAX_ROUTING_LAYER)]} { setDesignMode -topRoutingLayer    $::env(MAX_ROUTING_LAYER) }
if {[info exists ::env(MIN_ROUTING_LAYER)]} { setDesignMode -bottomRoutingLayer $::env(MIN_ROUTING_LAYER) }

pc::setup_basic
pc::run_place

setPlaceMode -place_detail_legalization_inst_gap 1
setFillerMode -fitGap true
place_opt_design -out_dir $REPORTS_DIR -prefix legalize

checkPlace



set_ccopt_property post_conditioning_enable_routing_eco 1
set_ccopt_property -cts_def_lock_clock_sinks_after_routing true
setOptMode -unfixClkInstForOpt false
create_ccopt_clock_tree_spec
ccopt_design

set_interactive_constraint_modes [all_constraint_modes -active]
set_propagated_clock [all_clocks]
set_clock_propagation propagated
# ---------- Router Settings (Robust) ----------
# GR: Disable timing if too slow; enable advanced node fix
setNanoRouteMode -grouteExpWithTimingDriven false
if {![info exists ::env(DETAILED_ROUTE_END_ITERATION)]} {
    set ::env(DETAILED_ROUTE_END_ITERATION) 20
}
setNanoRouteMode -drouteEndIteration $::env(DETAILED_ROUTE_END_ITERATION)

# SI/Timing-driven, auto VIA, avoid vias inside SC pins
setNanoRouteMode -routeWithSiDriven true
setNanoRouteMode -routeWithTimingDriven true
setNanoRouteMode -routeUseAutoVia true
setNanoRouteMode -routeWithViaInPin "1:1"
setNanoRouteMode -routeWithViaOnlyForStandardCellPin "1:1"

# VIA1 on-grid only, advanced node routing switches
setNanoRouteMode -drouteOnGridOnly "via 1:1"
setNanoRouteMode -drouteAutoStop true
setNanoRouteMode -drouteExpAdvancedMarFix true
setNanoRouteMode -routeExpAdvancedTechnology true

# ---------- Route + Post-Route Optimization ----------
routeDesign

optDesign -postRoute

# ---------- Export ----------
set DEF_OUT  [file join $RESULTS_DIR "5_route.def"]
set V_OUT    [file join $RESULTS_DIR "5_route.v"]
set ENC_OUT  [file join $OBJECTS_DIR  "${DESIGN}_postRoute.enc"]
defOut -netlist -floorplan -routing $DEF_OUT
saveNetlist $V_OUT
saveDesign $ENC_OUT
fit
dumpToGIF $LOG_DIR/5_route.png
puts "INFO: Routing done. DEF: $DEF_OUT  V: $V_OUT  ENC: $ENC_OUT"

# # Run unified extractor directly into LOG_DIR
# file mkdir [file join $LOG_DIR timingReports]

# set EXTRACT_TCL [file join $::env(CADENCE_SCRIPTS_DIR) extract_report.tcl]
# if {![file exists $EXTRACT_TCL]} { puts "ERROR: Cannot find $EXTRACT_TCL"; exit 1 }
# source $EXTRACT_TCL

# set CSV_PATH [file join $LOG_DIR "final_metrics.csv"]
# set SUMMARY  [file join $LOG_DIR "final_summary.txt"]

# set csv_line [extract_report -postRoute \
#                             -outdir $LOG_DIR \
#                             -write_csv $CSV_PATH \
#                             -write_summary $SUMMARY]

# catch { file mkdir [file join $LOG_DIR final] }
# catch { dumpPictures -dir [file join $LOG_DIR final] -prefix final }

# puts "INFO: Final metrics CSV -> $CSV_PATH"
# puts "INFO: Final summary     -> $SUMMARY"
# puts "INFO: timingReports/, power_Final.rpt, drc.rpt, fep.rpt are under $LOG_DIR."

# set VISUALIZE_FINAL [_get VISUALIZE_FINAL "0"]
# if {$VISUALIZE_FINAL eq "1"} {
#   puts "INFO: Pausing for Final Design Visualization. Type 'resume' to continue or exit manually."
#   win
#   suspend
# }

exit