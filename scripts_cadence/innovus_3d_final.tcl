# This script was written and developed by Zhiyu Zheng at Fudan University; however, the underlying
# commands and reports are copyrighted by Cadence. We thank Cadence for
# granting permission to share our research to help promote and foster the next
# generation of innovators.
# ============================================================
# innovus_3d_final.tcl
# Final metric extraction from the routed handoff.
# ============================================================

# Core setup
source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/handoff_manager.tcl

# Environment directories
set LOG_DIR       [_get LOG_DIR]
set RESULTS_DIR   [_get RESULTS_DIR]
set REPORTS_DIR   [_get REPORTS_DIR]
set OBJECTS_DIR   [_get OBJECTS_DIR]

# Stage handoff
set stage_name "final"
# Inputs : 5_route.def / 5_route.v / 5_route.sdc
# Outputs: 6_final.png / final_metrics.csv / final_summary.txt / handoffs/final.tcl
set stage_paths [handoff_stage_paths $stage_name $RESULTS_DIR $OBJECTS_DIR $LOG_DIR]
handoff_bind_stage_io $stage_paths
set sdc $SDC_IN

# Additional setup
handoff_log_paths $stage_paths

if {![file exists $V_IN]}  { puts "ERROR: Missing netlist: $V_IN";  exit 1 }
if {![file exists $SDC_IN]} { puts "ERROR: Missing SDC:     $SDC_IN";  exit 1 }

# init_* globals required by some Innovus builds even for restoreDesign
if {![info exists lefs] || $lefs eq ""} {
  puts "WARN: 'lefs' was not exported by lib_setup.tcl; continue with netlist/SDC only."
}

source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl

set init_lef_file $lefs
set init_mmmc_file ""
set init_design_settop 1
set init_top_cell $DESIGN
set init_verilog   $V_IN
set init_design_netlisttype "Verilog"

# ---- Restore routed DB (no DEF fallback) ----
# set ENC_PRIMARY   [file join $OBJECTS_DIR "_postRoute.enc"]
# set ENC_FILE [file join $OBJECTS_DIR "${DESIGN}_postRoute.enc.dat"]
# if {[file exists $ENC_FILE]} {
#   puts "INFO: restoreDesign $ENC_FILE $DESIGN"
#   restoreDesign $ENC_FILE $DESIGN
# } else {
#   puts "Missing routed ENC file: $ENC_FILE"
puts "INFO: restoreDesign $DESIGN from def, verilog"

init_design -setup {WC_VIEW} -hold {BC_VIEW}
_common_setup

defIn $DEF_IN
# }
puts "READ DEF: $DEF_IN"

# Explicit final extraction/analysis policy; no hidden native-RC fallback.
set final_rc_mode [string tolower [_get CDS_FINAL_RC_MODE native]]
set si_aware [_get CDS_SI_AWARE 1]
if {$si_aware ni {0 1}} { error "CDS_SI_AWARE must be 0 or 1" }
setDelayCalMode -siAware [expr {$si_aware ? "true" : "false"}]
if {$final_rc_mode eq "spef"} {
  set final_spef [_get CDS_FINAL_SPEF [file join $RESULTS_DIR 6_final.spef]]
  if {![file isfile $final_spef]} {
    error "Final SPEF is missing: $final_spef; run ord-final first or explicitly select CDS_FINAL_RC_MODE=native."
  }
  foreach source_file [list $DEF_IN $V_IN] {
    if {[file mtime $final_spef] < [file mtime $source_file]} {
      error "Final SPEF predates routed input $source_file; regenerate it before evaluation."
    }
  }
  spefIn -rc_corner Cmax $final_spef
  spefIn -rc_corner Cmin $final_spef
} elseif {$final_rc_mode ne "native"} {
  error "CDS_FINAL_RC_MODE must be spef or native"
}
file mkdir $LOG_DIR
set rc_meta [open [file join $LOG_DIR extraction_config.txt] w]
puts $rc_meta "final_rc_mode=$final_rc_mode"
puts $rc_meta "corner_initialization=$cds_rc_mode"
puts $rc_meta "si_aware=$si_aware"
puts $rc_meta "qrc_file=$QRC_FILE"
if {$final_rc_mode eq "spef"} { puts $rc_meta "spef=$final_spef" }
puts $rc_meta "model_scope=research; physical 3D calibration is not certified"
close $rc_meta
puts "INFO(RC): final_rc_mode=$final_rc_mode si_aware=$si_aware"

set_default_switching_activity -seq_activity 0.2

dumpToGIF $LOG_DIR/6_final.png
# Newer Voltus API hint (do not error if views absent)

# Run unified extractor directly into LOG_DIR
file mkdir [file join $LOG_DIR timingReports]

set EXTRACT_TCL [file join $::env(CADENCE_SCRIPTS_DIR) extract_report.tcl]
if {![file exists $EXTRACT_TCL]} { puts "ERROR: Cannot find $EXTRACT_TCL"; exit 1 }
source $EXTRACT_TCL

set csv_line [extract_report -postRoute \
                            -outdir $LOG_DIR \
                            -write_csv $CSV_OUT \
                            -write_summary $SUMMARY_OUT]

catch { file mkdir [file join $LOG_DIR final] }
catch { dumpPictures -dir [file join $LOG_DIR final] -prefix final }

puts "INFO: Final metrics CSV -> $CSV_OUT"
puts "INFO: Final summary     -> $SUMMARY_OUT"
puts "INFO: timingReports/, power_Final.rpt, drc.rpt, fep.rpt are under $LOG_DIR."
handoff_write_manifest $stage_paths -extra_kv [list csv_out $CSV_OUT summary_out $SUMMARY_OUT mode postRoute]

set VISUALIZE_FINAL [_get VISUALIZE_FINAL "0"]
if {$VISUALIZE_FINAL eq "1"} {
  puts "INFO: Pausing for Final Design Visualization. Type 'resume' to continue or exit manually."
  win
  suspend
}

exit
