utl::set_metrics_stage "finish__{}"
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
load_design 5_route.def 5_route.sdc "Starting final report"

set_propagated_clock [all_clocks]

puts "Starting global connection cleanup"

global_connect

# Delete routing obstructions for final DEF
source $::env(OPENROAD_SCRIPTS_DIR)/deleteRoutingObstructions.tcl
deleteRoutingObstructions

puts "Writing final design files"

write_db $::env(RESULTS_DIR)/6_final.odb
write_def $::env(RESULTS_DIR)/6_final.def
write_verilog $::env(RESULTS_DIR)/6_final.v
write_sdc $::env(RESULTS_DIR)/6_final.sdc
puts "Starting extraction"
# Run extraction and STA
if {[info exist ::env(RCX_RULES)]} {

  # Set RC corner for RCX
  # Set in config.mk
  if {[info exist ::env(RCX_RC_CORNER)]} {
    set rc_corner $::env(RCX_RC_CORNER)
  }

  # RCX section
  define_process_corner -ext_model_index 0 X
  extract_parasitics -ext_model_file $::env(RCX_RULES)

  # Write Spef
  write_spef $::env(RESULTS_DIR)/6_final.spef
  file delete $::env(DESIGN_NAME).totCap

  # Read Spef for OpenSTA
  read_spef $::env(RESULTS_DIR)/6_final.spef

  # Static IR drop analysis
  # if {[info exist ::env(PWR_NETS_VOLTAGES)]} {
  #   dict for {pwrNetName pwrNetVoltage}  {*}$::env(PWR_NETS_VOLTAGES) {
  #       set_pdnsim_net_voltage -net ${pwrNetName} -voltage ${pwrNetVoltage}
  #       analyze_power_grid -net ${pwrNetName} \
  #           -error_file $::env(REPORTS_DIR)/${pwrNetName}.rpt
  #   }
  # } else {
  #   puts "IR drop analysis for power nets is skipped because PWR_NETS_VOLTAGES is undefined"
  # }
  # if {[info exist ::env(GND_NETS_VOLTAGES)]} {
  #   dict for {gndNetName gndNetVoltage}  {*}$::env(GND_NETS_VOLTAGES) {
  #       set_pdnsim_net_voltage -net ${gndNetName} -voltage ${gndNetVoltage}
  #       analyze_power_grid -net ${gndNetName} \
  #           -error_file $::env(REPORTS_DIR)/${gndNetName}.rpt
  #   }
  # } else {
  #   puts "IR drop analysis for ground nets is skipped because GND_NETS_VOLTAGES is undefined"
  # }

} else {
  puts "OpenRCX is not enabled for this platform."
}

source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics "finish" "finish"
puts "Final report metrics written to $::env(REPORTS_DIR)/finish_finish.rpt"
# Save a final image if openroad is compiled with the gui
set VISUALIZE_FINAL [_get VISUALIZE_FINAL "0"]
if {$VISUALIZE_FINAL eq "1"} {
  puts "gui::pause"
  gui::show
  gui::pause
  return -code 0
}
source $::env(OPENROAD_SCRIPTS_DIR)/save_images.tcl


exit
