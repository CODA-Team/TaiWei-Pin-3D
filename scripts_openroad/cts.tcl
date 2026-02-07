utl::set_metrics_stage "cts__{}"
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl

load_design 3_place.def 3_place.sdc "Starting CTS..."

source $::env(OPENROAD_SCRIPTS_DIR)/placement_utils.tcl

set cts_layer "bottom"
set fix_layer "upper"
if {[info exists ::env(CTS_LAYER)]} {
  set cts_layer $::env(CTS_LAYER)
  if { $cts_layer == "bottom" } {
    set fix_layer "upper"
  } else {
    set fix_layer "bottom"
  }
  puts "CTS LAYER: $cts_layer"
}

mark_insts_by_master "*${fix_layer}*" FIRM
puts "Marked ${fix_layer} instances as FIRM"

apply_tier_policy $cts_layer -cts_safe 1 -fixlib 1

# Clone clock tree inverters next to register loads
# so cts does not try to buffer the inverted clocks.
repair_clock_inverters

proc save_progress { stage } {
  puts "Run 'make gui_$stage.odb' to load progress snapshot"
  write_db $::env(RESULTS_DIR)/$stage.odb
  write_sdc -no_timestamp $::env(RESULTS_DIR)/$stage.sdc
}

# Run CTS
set cts_args [list \
  -sink_clustering_enable \
  -repair_clock_nets \
  -root_buf $::env(CTS_BUF_CELL) \
  -buf_list $::env(CTS_BUF_CELL)
  ]

append_env_var cts_args CTS_BUF_DISTANCE -distance_between_buffers 1
append_env_var cts_args CTS_CLUSTER_SIZE -sink_clustering_size 1
append_env_var cts_args CTS_CLUSTER_DIAMETER -sink_clustering_max_diameter 1
append_env_var cts_args CTS_BUF_LIST -buf_list 1
append_env_var cts_args CTS_LIB_NAME -library 1


if { [env_var_exists_and_non_empty CTS_ARGS] } {
  set cts_args $::env(CTS_ARGS)
}

log_cmd clock_tree_synthesis {*}$cts_args

utl::push_metrics_stage "cts__{}__pre_repair_timing"
estimate_parasitics -placement
utl::pop_metrics_stage

set_placement_padding -global \
  -left $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT) \
  -right $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT)

# CTS leaves a long wire from the pad to the clock tree root.
log_cmd repair_clock_nets

# place clock buffers
log_cmd detailed_placement 

estimate_parasitics -placement

# if { $::env(CTS_SNAPSHOTS) } {
#   save_progress 4_1_pre_repair_hold_setup
# }
if { ![info exists ::env(SKIP_CTS_REPAIR_TIMING)] } {
  set ::env(SKIP_CTS_REPAIR_TIMING) 0
}
if { $::env(SKIP_CTS_REPAIR_TIMING) } {

  repair_timing_helper

  set result [catch { detailed_placement } msg]
  if { $result != 0 } {
    save_progress 4_1_error
    puts "Detailed placement failed in CTS: $msg"
    exit $result
  }

  check_placement -verbose
}

source_env_var_if_exists POST_CTS_TCL

mark_insts_by_master "*${fix_layer}*" PLACED
puts "Marked ${fix_layer} instances as PLACED"
source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 4 "cts" false false

write_def $::env(RESULTS_DIR)/4_cts.def
write_verilog $::env(RESULTS_DIR)/4_cts.v
write_sdc $::env(RESULTS_DIR)/4_cts.sdc
save_image -resolution 0.1 $::env(LOG_DIR)/4_cts.webp 

exit