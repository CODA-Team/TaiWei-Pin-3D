utl::set_metrics_stage "detailedroute__{}"
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/util.tcl
load_design 5_1_grt.odb 5_1_grt.sdc "Start detailed route"
if { ![grt::have_routes] } {
  error "Global routing failed, run `make gui_grt` and load $::global_route_congestion_report \
        in DRC viewer to view congestion"
}

set_propagated_clock [all_clocks]

set additional_args ""
if { ![info exists ::env(OR_K)] } {
  set ::env(OR_K) 1.0
}
# if { ![info exists ::env(REPAIR_PDN_VIA_LAYER)] } {
#   set ::env(REPAIR_PDN_VIA_LAYER) 1
# }
if { ![info exists ::env(DETAILED_ROUTE_END_ITERATION)] } {
  set ::env(DETAILED_ROUTE_END_ITERATION) 20
}
append_env_var additional_args DB_PROCESS_NODE -db_process_node 1
append_env_var additional_args OR_K -or_k 1
# append_env_var additional_args REPAIR_PDN_VIA_LAYER -repair_pdn_vias 1
append_env_var additional_args DETAILED_ROUTE_END_ITERATION -droute_end_iter 1
append additional_args " -verbose 1 -no_pin_access"

# DETAILED_ROUTE_ARGS is used when debugging detailed, route, e.g. append
# "-droute_end_iter 5" to look at routing violations after only 5 iterations,
# speeding up iterations on a problem where detailed routing doesn't converge
# or converges slower than expected.
#
# If DETAILED_ROUTE_ARGS is not specified, save out progress report a
# few iterations after the first two iterations. The first couple of
# iterations would produce very large .drc reports without interesting
# information for the user.
#
# The idea is to have a policy that gives progress information soon without
# having to go spelunking in Tcl or modify configuration scripts, while
# not having to wait too long or generating large useless reports.

set arguments [expr {
  [env_var_exists_and_non_empty DETAILED_ROUTE_ARGS] ? $::env(DETAILED_ROUTE_ARGS) :
  [concat $additional_args {-drc_report_iter_step 5}]
}]

puts "Detailed route arguments: $arguments"

set all_args [concat [list \
  -output_drc $::env(REPORTS_DIR)/5_route_drc.rpt \
  -output_maze $::env(RESULTS_DIR)/maze.log] \
  $arguments]

log_cmd detailed_route {*}$all_args

if {
  ![env_var_equals SKIP_ANTENNA_REPAIR_POST_DRT 1] &&
  [env_var_exists_and_non_empty MAX_REPAIR_ANTENNAS_ITER_DRT]
} {
  set repair_antennas_iters 1
  if { [repair_antennas] } {
    detailed_route {*}$all_args
  }
  while { [check_antennas] && $repair_antennas_iters < $::env(MAX_REPAIR_ANTENNAS_ITER_DRT) } {
    repair_antennas
    detailed_route {*}$all_args
    incr repair_antennas_iters
  }
} else {
  utl::metric_int "antenna_diodes_count" -1
}

source_env_var_if_exists POST_DETAIL_ROUTE_TCL

check_antennas -report_file $env(REPORTS_DIR)/drt_antennas.log

if { ![design_is_routed] } {
  error "Design has unrouted nets."
}

# report_metrics 5 "detailed route"
write_db $::env(RESULTS_DIR)/5_2_route.odb
write_def $::env(RESULTS_DIR)/5_route.def
write_verilog $::env(RESULTS_DIR)/5_route.v

exit
