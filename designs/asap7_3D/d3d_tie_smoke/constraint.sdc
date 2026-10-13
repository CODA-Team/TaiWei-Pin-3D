current_design d3d_tie_smoke

set clk_name core_clock
set clk_period 310
create_clock -name $clk_name -period $clk_period [get_ports clk]

set_input_delay [expr $clk_period * 0.2] -clock $clk_name [all_inputs -no_clocks]
set_output_delay [expr $clk_period * 0.2] -clock $clk_name [all_outputs]
