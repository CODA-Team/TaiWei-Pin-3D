export DESIGN_NAME = bsg_chip
export DESIGN_NICKNAME = bp_quad
export PLATFORM    = asap7

export SYNTH_HIERARCHICAL = 1

export VERILOG_FILES = $(DESIGN_HOME)/asap7_3D/$(DESIGN_NICKNAME)/bsg_chip_block.sv2v.v \
                       $(DESIGN_HOME)/asap7_3D/$(DESIGN_NICKNAME)/fakeram45_32x32_dp.v

export SDC_FILE      = $(DESIGN_HOME)/asap7_3D/$(DESIGN_NICKNAME)/bsg_chip.sdc

export ADDITIONAL_LEFS = $(sort $(wildcard $(PLATFORM_DIR)/lef/fakeram/*.lef))
export ADDITIONAL_LIBS = $(sort $(wildcard $(PLATFORM_DIR)/lib/NLDM/fakeram/*.lib))

export CORE_UTILIZATION ?= 60
export CORE_ASPECT_RATIO = 1
export CORE_MARGIN = 5
export GEN_EFF medium
export MAP_EFF high

export NUM_CORES   ?= 32
export PIN3D_SPLIT_PORT_DRIVEN_NETS ?= 1
export GLOBAL_ROUTE_ARGS ?= -verbose -congestion_iterations 30
