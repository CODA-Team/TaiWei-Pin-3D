###############################################################
#  Design:            leon3_vta_soc
###############################################################
set_units -time ns -capacitance fF -resistance kOhm -voltage V -current mA -power nW
current_design leon3_vta_soc
set_clock_gating_check -rise -setup 0
set_clock_gating_check -fall -setup 0
create_clock [get_ports {clk}] -name clk -period 1.300000 -waveform {0.000000 0.650000}
