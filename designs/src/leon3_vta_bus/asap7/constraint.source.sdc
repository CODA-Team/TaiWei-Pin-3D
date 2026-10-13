###############################################################
#  Design:            leon3_vta_soc
###############################################################
set_units -time ps -capacitance fF -resistance kOhm -voltage V -current mA -power pW
current_design leon3_vta_soc
set_clock_gating_check -rise -setup 0
set_clock_gating_check -fall -setup 0
create_clock [get_ports {clk}] -name clk -period 900.000000 -waveform {0.000000 450.000000}
