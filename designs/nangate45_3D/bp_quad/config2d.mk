export DESIGN_NAME = bsg_chip
export DESIGN_NICKNAME = bp_quad
export PLATFORM    = nangate45

export SYNTH_HIERARCHICAL = 1

export VERILOG_FILES = $(DESIGN_HOME)/nangate45_3D/$(DESIGN_NICKNAME)/bsg_chip_block.sv2v.v \
                       $(DESIGN_HOME)/nangate45_3D/$(DESIGN_NICKNAME)/fakeram45_32x32_dp.v

export SDC_FILE      = $(DESIGN_HOME)/nangate45_3D/$(DESIGN_NICKNAME)/bsg_chip.sdc

export ADDITIONAL_LEFS = $(PLATFORM_DIR)/lef/fakeram/fakeram45_128x116.lef \
                         $(PLATFORM_DIR)/lef/fakeram/fakeram45_256x48.lef \
                         $(PLATFORM_DIR)/lef/fakeram/fakeram45_32x32.lef \
                         $(PLATFORM_DIR)/lef/fakeram/fakeram45_512x64.lef \
                         $(PLATFORM_DIR)/lef/fakeram/fakeram45_64x124.lef \
                         $(PLATFORM_DIR)/lef/fakeram/fakeram45_64x62.lef
export ADDITIONAL_LIBS = $(PLATFORM_DIR)/lib/fakeram/fakeram45_128x116.lib \
                         $(PLATFORM_DIR)/lib/fakeram/fakeram45_256x48.lib \
                         $(PLATFORM_DIR)/lib/fakeram/fakeram45_32x32.lib \
                         $(PLATFORM_DIR)/lib/fakeram/fakeram45_512x64.lib \
                         $(PLATFORM_DIR)/lib/fakeram/fakeram45_64x124.lib \
                         $(PLATFORM_DIR)/lib/fakeram/fakeram45_64x62.lib

export CORE_UTILIZATION = 50
export CORE_ASPECT_RATIO = 1
export CORE_MARGIN = 5
export GEN_EFF medium
export MAP_EFF high

export NUM_CORES   ?= 32
export PIN3D_SPLIT_PORT_DRIVEN_NETS ?= 1
export GLOBAL_ROUTE_ARGS ?= -verbose -congestion_iterations 30
