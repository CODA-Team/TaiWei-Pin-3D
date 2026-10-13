export DESIGN_NAME = leon3_vta_soc
export DESIGN_NICKNAME = leon3_vta_bus
export PLATFORM = asap7

RTL_ROOT := $(DESIGN_HOME)/src/leon3_vta_bus/asap7
RTL_FILELIST := $(DESIGN_HOME)/src/leon3_vta_bus/asap7/rtl_files.f
export VERILOG_FILES = $(addprefix $(RTL_ROOT)/,$(shell awk 'NF' $(RTL_FILELIST)))
export SYNTH_HDL_FRONTEND = slang
export SDC_FILE = $(DESIGN_HOME)/asap7_3D/leon3_vta_bus/constraint.sdc
export ADDITIONAL_LEFS = \
  $(PLATFORM_DIR)/lef/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1r1w.lef \
  $(PLATFORM_DIR)/lef/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1rw.lef \
  $(PLATFORM_DIR)/lef/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_mem_0_ext.lef \
  $(PLATFORM_DIR)/lef/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_0_ext.lef \
  $(PLATFORM_DIR)/lef/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_1_ext.lef \
  $(PLATFORM_DIR)/lef/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_2_ext.lef \
  $(PLATFORM_DIR)/lef/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_ext.lef \
  $(PLATFORM_DIR)/lef/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_vta_q_512x128.lef
export ADDITIONAL_LIBS = \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1r1w.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1rw.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_mem_0_ext.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_0_ext.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_1_ext.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_2_ext.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_ext.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_vta_q_512x128.lib
export CORE_MARGIN = 0.2
export CORE_UTILIZATION ?= 60
export NUM_CORES ?= 32
export PIN3D_SPLIT_PORT_DRIVEN_NETS ?= 1
export GLOBAL_ROUTE_ARGS ?= -verbose -congestion_iterations 30
