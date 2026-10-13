export DESIGN_NAME = swerv_wrapper
export PLATFORM    = nangate45

export VERILOG_FILES = $(DESIGN_HOME)/src/swerv/swerv_wrapper.sv2v.v \
                       $(DESIGN_HOME)/nangate45_3D/swerv_wrapper/macros.v
export SDC_FILE      = $(DESIGN_HOME)/nangate45_3D/swerv_wrapper/constraint.sdc
# This design already defines OPENROAD_CLKGATE in macros.v.
# Skip the platform clock-gate stub to avoid Yosys redefinition.
override export CLKGATE_MAP_FILE :=

export ADDITIONAL_LEFS = $(sort $(wildcard $(PLATFORM_DIR)/lef/fakeram/*.lef))
export ADDITIONAL_LIBS = $(sort $(wildcard $(PLATFORM_DIR)/lib/fakeram/*.lib))

export CORE_MARGIN = 2
export ASPECT_RATIO = 1.0
export CORE_UTILIZATION ?= 60

export PLACE_DENSITY_LB_ADDON = 0.08
export TNS_END_PERCENT        = 100

export GEN_EFF medium
export MAP_EFF high
export SWAP_ARITH_OPERATORS = 1

export NUM_CORES   ?= 32
export PIN3D_SPLIT_PORT_DRIVEN_NETS ?= 1
