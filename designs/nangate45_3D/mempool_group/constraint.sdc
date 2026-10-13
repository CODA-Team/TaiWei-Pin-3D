###############################################################
#  Design:            mempool_group
###############################################################
set_units -time ns -capacitance fF -resistance kOhm -voltage V -current mA -power nW
current_design mempool_group
set_clock_gating_check -rise -setup 0
set_clock_gating_check -fall -setup 0
create_clock [get_ports {clk_i}] -name clk_i -period 2.575800 -waveform {0.000000 1.287900}
