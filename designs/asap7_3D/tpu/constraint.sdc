###############################################################
#  Design:            tpu
###############################################################
set_units -time ps -capacitance fF -resistance kOhm -voltage V -current mA -power pW
current_design tpu
set_clock_gating_check -rise -setup 0
set_clock_gating_check -fall -setup 0
#create_clock [get_ports {clk}] -name core_clock -period 1000.000000 -waveform {0.000000 500.000000}
create_clock [get_ports {clk}] -name core_clock -period 200.000000 -waveform {0.000000 100.000000}