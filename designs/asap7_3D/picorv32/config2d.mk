export DESIGN_NAME = picorv32
export PLATFORM    = asap7

export VERILOG_FILES = $(DESIGN_HOME)/src/picorv32/asap7/rtl/picorv32.sv
export SDC_FILE      = $(DESIGN_HOME)/asap7_3D/picorv32/constraint.sdc

export ABC_AREA      = 1
export CORE_MARGIN = 0.2
export ASPECT_RATIO = 1.0
export CORE_UTILIZATION ?= 60
export PLACE_DENSITY_LB_ADDON = 0.10
export TNS_END_PERCENT        = 100
export GEN_EFF medium
export MAP_EFF high

export NUM_CORES ?= 32
export PIN3D_SPLIT_PORT_DRIVEN_NETS ?= 1
