###############################################################
#  Design:            CoupledL2
###############################################################
set_units -time ns -capacitance fF -resistance kOhm -voltage V -current mA -power nW
current_design CoupledL2
set_clock_gating_check -rise -setup 0
set_clock_gating_check -fall -setup 0
create_clock [get_ports {clock}] -name core_clock -period 2.003000 -waveform {0.000000 1.001500}
