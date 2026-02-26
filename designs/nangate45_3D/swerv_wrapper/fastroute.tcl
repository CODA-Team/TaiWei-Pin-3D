set_global_routing_layer_adjustment M2-M3 0.20
set_global_routing_layer_adjustment M3_m-M2_m 0.20
set_global_routing_layer_adjustment M4-M4_m 0.10

set_routing_layers -signal $::env(MIN_ROUTING_LAYER)-$::env(MAX_ROUTING_LAYER)
