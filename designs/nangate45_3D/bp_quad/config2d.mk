export DESIGN_NAME = bsg_chip
export DESIGN_NICKNAME = bp_quad
export PLATFORM    = nangate45

export SYNTH_HIERARCHICAL = 1

export VERILOG_FILES = $(DESIGN_HOME)/nangate45_3D/$(DESIGN_NICKNAME)/bsg_chip_block.sv2v.v \
                       $(DESIGN_HOME)/nangate45_3D/$(DESIGN_NICKNAME)/fakeram45_32x32_dp.v

export SDC_FILE      = $(DESIGN_HOME)/nangate45_3D/$(DESIGN_NICKNAME)/bsg_chip.sdc

export ADDITIONAL_LEFS = $(sort $(wildcard $(PLATFORM_DIR)/lef/fakeram/*.lef))
export ADDITIONAL_LIBS = $(sort $(wildcard $(PLATFORM_DIR)/lib/fakeram/*.lib))

export CORE_UTILIZATION = 50
export CORE_ASPECT_RATIO = 1
export CORE_MARGIN = 5
export GEN_EFF medium
export MAP_EFF high

export NUM_CORES   ?= 32
