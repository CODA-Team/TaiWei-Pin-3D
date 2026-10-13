###############################################################
#  Design:            leon3_vta_soc
###############################################################
set_units -time ns -capacitance fF -resistance kOhm -voltage V -current mA -power nW
current_design leon3_vta_soc
set_clock_gating_check -rise -setup 0
set_clock_gating_check -fall -setup 0
set clk_name clk
set clk_port_name clk
set clk_period 1.300000
set clk_io_pct 0.2
set clk_port [get_ports $clk_port_name]
if {[llength $clk_port] != 1} { error "Expected one clock port: $clk_port_name" }
create_clock -name $clk_name -period $clk_period -waveform {0.000000 0.650000} $clk_port
set non_clock_inputs [all_inputs -no_clocks]
set_input_delay [expr {$clk_period * $clk_io_pct}] -clock $clk_name $non_clock_inputs
set_output_delay [expr {$clk_period * $clk_io_pct}] -clock $clk_name [all_outputs]
