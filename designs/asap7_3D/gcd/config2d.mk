export DESIGN_NAME = gcd
export PLATFORM    = asap7

export VERILOG_FILES = $(sort $(wildcard $(DESIGN_HOME)/src/$(DESIGN_NAME)/*.v))
export SDC_FILE      = $(DESIGN_HOME)/asap7_3D/$(DESIGN_NAME)/constraint.sdc

# Adders degrade GCD
export ABC_AREA      = 1
export CORE_MARGIN = 0.2
export ASPECT_RATIO = 1.0
export CORE_UTILIZATION ?= 60
export PLACE_DENSITY_LB_ADDON = 0.10
export TNS_END_PERCENT        = 100
export GEN_EFF medium
export MAP_EFF high


export NUM_CORES   ?= 32
