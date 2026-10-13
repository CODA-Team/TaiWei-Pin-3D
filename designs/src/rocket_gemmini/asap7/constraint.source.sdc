###############################################################
#  Design:            DigitalTop
###############################################################
set_units -time ps -capacitance fF -resistance kOhm -voltage V -current mA -power pW
current_design DigitalTop
set_clock_gating_check -rise -setup 0
set_clock_gating_check -fall -setup 0
create_clock [get_ports {auto_chipyard_prcictrl_domain_reset_setter_clock_in_member_allClocks_uncore_clock}] -name core_clock -period 2000.000000 -waveform {0.000000 1000.000000}
