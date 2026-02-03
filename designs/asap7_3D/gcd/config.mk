export DESIGN_NAME = gcd
export PLATFORM    = asap7_3D

export PLACE_DENSITY_LB_ADDON = 0.10
export TNS_END_PERCENT        = 100
export SKIP_GATE_CLONING   = 1
export CORE_MARGIN = 0.2
export GLOBAL_ROUTE_ARGS = -verbose -congestion_iterations 30
export DETAILED_ROUTE_END_ITERATION = 5
export CORE_UTILIZATION ?= 60

export NUM_CORES   ?= 32
