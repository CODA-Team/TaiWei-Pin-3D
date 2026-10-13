###############################################################
#  Design:            picorv32
###############################################################
set_units -time ps -capacitance fF -resistance kOhm -voltage V -current mA -power pW
current_design picorv32
set_clock_gating_check -rise -setup 0
set_clock_gating_check -fall -setup 0
create_clock [get_ports {clk}] -name core_clock -period 300.000000 -waveform {0.000000 150.000000}
