export DESIGN_NAME = CoupledL2
export DESIGN_NICKNAME = xiangshan_coupledl2
export PLATFORM = asap7

RTL_ROOT := $(DESIGN_HOME)/src/xiangshan_coupledl2/asap7
RTL_FILELIST := $(DESIGN_HOME)/src/xiangshan_coupledl2/asap7/rtl_files.f
export VERILOG_FILES = $(addprefix $(RTL_ROOT)/,$(shell awk 'NF' $(RTL_FILELIST)))
export SYNTH_HDL_FRONTEND = slang
export SDC_FILE = $(DESIGN_HOME)/asap7_3D/xiangshan_coupledl2/constraint.sdc
export ADDITIONAL_LEFS = \
  $(PLATFORM_DIR)/lef/fakeram/xiangshan_coupledl2/array_2048x137_bk.lef \
  $(PLATFORM_DIR)/lef/fakeram/xiangshan_coupledl2/array_256x104.lef \
  $(PLATFORM_DIR)/lef/fakeram/xiangshan_coupledl2/array_256x13.lef \
  $(PLATFORM_DIR)/lef/fakeram/xiangshan_coupledl2/array_256x16.lef \
  $(PLATFORM_DIR)/lef/fakeram/xiangshan_coupledl2/array_256x164.lef \
  $(PLATFORM_DIR)/lef/fakeram/xiangshan_coupledl2/array_256x8_0.lef
export ADDITIONAL_LIBS = \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/xiangshan_coupledl2/array_2048x137_bk.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/xiangshan_coupledl2/array_256x104.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/xiangshan_coupledl2/array_256x13.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/xiangshan_coupledl2/array_256x16.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/xiangshan_coupledl2/array_256x164.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/xiangshan_coupledl2/array_256x8_0.lib
export CORE_MARGIN = 0.2
export CORE_UTILIZATION ?= 60
export NUM_CORES ?= 32
export PIN3D_SPLIT_PORT_DRIVEN_NETS ?= 1
export GLOBAL_ROUTE_ARGS ?= -verbose -congestion_iterations 30
