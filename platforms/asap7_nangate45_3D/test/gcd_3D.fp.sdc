# 1_synth.sdc
create_clock -name CLK -period 2.0 [get_ports CLK]
set_input_delay 0.1 -clock CLK [all_inputs]
set_output_delay 0.1 -clock CLK [all_outputs]
