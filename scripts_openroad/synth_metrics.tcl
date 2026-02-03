utl::set_metrics_stage "synth__{}"
source $::env(OPENROAD_SCRIPTS_DIR)/load.tcl
load_design 1_1_yosys.v 1_synth.sdc "Post synthesis"

source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics "Post synthesis" false false
