# Adapted from scripts_cadence/innovus_preplace.tcl for the 3D-Syn handoff.

source $::env(CADENCE_SCRIPTS_DIR)/utils.tcl
source $::env(CADENCE_SCRIPTS_DIR)/lib_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/design_setup.tcl
source $::env(CADENCE_SCRIPTS_DIR)/handoff_manager.tcl

set results_dir [_get RESULTS_DIR]
set objects_dir [_get OBJECTS_DIR]
set log_dir [_get LOG_DIR]
set stage_dir [_get SYN3D_HANDOFF_DIR]
file mkdir $results_dir $stage_dir [file join $log_dir 3dsyn handoff]

set stage_paths [handoff_stage_paths "preplace" $results_dir $objects_dir $log_dir]
dict set stage_paths stage "3dsyn-backend-preplace"
dict set stage_paths stage_label "cds-3dsyn-handoff"
dict set stage_paths v_in [file join $results_dir "base.v"]
dict set stage_paths def_out [file join $results_dir "2_2_floorplan_io.backend.def"]
dict set stage_paths v_out [file join $results_dir "2_2_floorplan_io.backend.v"]
dict set stage_paths enc_out [file join $stage_dir "2_2_floorplan_io.backend.enc"]
dict set stage_paths png_out [file join $log_dir "3dsyn" "handoff" "01_backend_preplace.png"]
dict set stage_paths manifest_out [file join $stage_dir "backend_preplace.tcl"]
handoff_bind_stage_io $stage_paths
handoff_require_inputs $stage_paths {v_in sdc_in}

source $::env(CADENCE_SCRIPTS_DIR)/mmmc_setup.tcl
handoff_log_paths $stage_paths

set init_verilog $V_IN
set init_design_netlisttype "Verilog"
set init_design_settop 1
set init_top_cell $DESIGN
set init_lef_file $lefs

setGenerateViaMode -auto true
init_design -setup {WC_VIEW} -hold {BC_VIEW}
set_power_analysis_mode -leakage_power_view WC_VIEW -dynamic_power_view WC_VIEW
set_interactive_constraint_modes {CON}
setAnalysisMode -reset
setAnalysisMode -analysisType onChipVariation -cppr both
setOptMode -powerEffort low -leakageToDynamicRatio 0.5
setGenerateViaMode -auto true
generateVias
createBasicPathGroups -expanded

set core_util [_get CORE_UTILIZATION 60]
set aspect_ratio [_get CORE_ASPECT_RATIO 1.0]
set core_margin [_get CORE_MARGIN 0]
set util [expr {double($core_util) / 100.0}]
floorPlan -r $aspect_ratio $util $core_margin $core_margin $core_margin $core_margin
generateTracks
source $::env(CADENCE_SCRIPTS_DIR)/place_pin.tcl

set enable_opt [_get SYN3D_BACKEND_PREPLACE_OPT 1]
if {$enable_opt eq "0"} {
  puts "INFO: 3D-Syn backend preplace uses place_design -noPrePlaceOpt"
  place_design -noPrePlaceOpt
} elseif {$enable_opt eq "1"} {
  puts "INFO: 3D-Syn backend preplace uses place_design"
  place_design
} else {
  error "SYN3D_BACKEND_PREPLACE_OPT must be 0 or 1: $enable_opt"
}

handoff_write_stage_outputs $stage_paths \
  -def_args {-floorplan} \
  -copy_sdc 0 \
  -save_design 1 \
  -write_png 1 \
  -write_manifest 1 \
  -extra_manifest [list backend_preplace_optimization $enable_opt]

puts "INFO: 3D-Syn backend preplace completed."
puts "INFO:   DEF     : [handoff_get $stage_paths def_out]"
puts "INFO:   Verilog: [handoff_get $stage_paths v_out]"
exit
