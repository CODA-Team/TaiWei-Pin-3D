###############################################################
#  Design:            picorv32
###############################################################
set_units -time ns -capacitance fF -resistance kOhm -voltage V -current mA -power nW
current_design picorv32
set_clock_gating_check -rise -setup 0
set_clock_gating_check -fall -setup 0
create_clock [get_ports {clk}] -name core_clock -period 0.900000 -waveform {0.000000 0.450000}
