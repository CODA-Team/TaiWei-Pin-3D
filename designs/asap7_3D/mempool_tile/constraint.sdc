# mempool_tile timing constraints, ASAP7.
# UNITS: PICOSECONDS (ASAP7 liberty time_unit = 1ps).
#
# Adapted from TILOS MacroPlacement
#   Flows/ASAP7/mempool_tile/constraints/mempool_tile.sdc
# (clock 4 ns -> 4000 ps; uncertainty 80 ps, max_transition 40 ps, max_fanout 16,
#  pre-CTS clock latency 70 ps; TCDM io fractions 0.85/0.65 from that source).
#
# The TILOS source selects ports with filter_collection / "is_on_clock_network",
# neither of which exists in Aprisa's Tcl set. Port groups are therefore selected
# with direct get_ports globs (same approach as the mempool_group twin): the
# mempool_tile port names carry direction as their own _i/_o suffix
# (tcdm_master_req_o/_valid_o vs tcdm_master_req_ready_i, etc.), so the glob
# reproduces the [all_inputs]/[all_outputs]-plus-name-match intent.
set sdc_version 2.0
set_units -time ps -capacitance fF -resistance kOhm -voltage V -current mA -power pW
current_design mempool_tile

set clock_cycle 4000
set uncertainty 80
set io_delay 0
set maxFanout 16
set maxTransition 40
set pre_cts_clock_latency_estimate 70
set clock_port_mempool_tile clk_i

create_clock -name clk_i -period $clock_cycle [get_ports $clock_port_mempool_tile]
set_clock_uncertainty $uncertainty [all_clocks]
set clk_port [get_ports $clock_port_mempool_tile]
set non_clock_inputs [all_inputs]
set clk_port_idx [lsearch $non_clock_inputs $clk_port]
if {$clk_port_idx >= 0} {
    set non_clock_inputs [lreplace $non_clock_inputs $clk_port_idx $clk_port_idx]
}
set_input_delay -clock [get_clocks clk_i] -add_delay -max $io_delay $non_clock_inputs
set_output_delay -clock [get_clocks clk_i] -add_delay -max $io_delay [all_outputs]
set_max_transition $maxTransition -clock_path [get_clocks clk_i]
set_clock_latency $pre_cts_clock_latency_estimate [get_clocks clk_i]

# Create virtual clock.
create_clock -name "vclk_i" -period $clock_cycle
set_clock_uncertainty $uncertainty [get_clocks vclk_i]
set_clock_latency $pre_cts_clock_latency_estimate [get_clocks vclk_i]
set_max_transition $maxTransition -clock_path [get_clocks vclk_i]

set_case_analysis 0 [get_ports scan_enable_i]
set_max_fanout $maxFanout [current_design]

# False path the quasi-static tile id (a real mempool_tile boundary port).
set_false_path -from [get_ports {tile_id_i*}]

# TCDM Master
set_input_delay  [expr 0.85*$clock_cycle] -clock vclk_i [get_ports {tcdm_master_*req_*_i*}]
set_output_delay [expr 0.85*$clock_cycle] -clock vclk_i [get_ports {tcdm_master_*req_*_o*}]

set_input_delay  [expr 0.65*$clock_cycle] -clock vclk_i [get_ports {tcdm_master_*resp_*_i*}]
set_output_delay [expr 0.85*$clock_cycle] -clock vclk_i [get_ports {tcdm_master_*resp_*_o*}]

# TCDM Slave
set_output_delay [expr 0.85*$clock_cycle] -clock vclk_i [get_ports {tcdm_slave_*req_*_o*}]

set_input_delay  [expr 0.85*$clock_cycle] -clock vclk_i [get_ports {tcdm_slave_*resp_*_i*}]
set_output_delay [expr 0.85*$clock_cycle] -clock vclk_i [get_ports {tcdm_slave_*resp_*_o*}]

# Reset
set_input_delay  [expr 0.30*$clock_cycle] -clock vclk_i rst_ni
