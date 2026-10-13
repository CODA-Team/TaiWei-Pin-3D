export DESIGN_NAME = DigitalTop
export DESIGN_NICKNAME = rocket_gemmini
export PLATFORM = nangate45

RTL_ROOT := $(DESIGN_HOME)/src/rocket_gemmini/nangate45
RTL_FILELIST := $(DESIGN_HOME)/src/rocket_gemmini/nangate45/rtl_files.f
export VERILOG_FILES = $(addprefix $(RTL_ROOT)/,$(shell awk 'NF' $(RTL_FILELIST)))
export SYNTH_HDL_FRONTEND = slang
export SDC_FILE = $(DESIGN_HOME)/nangate45_3D/rocket_gemmini/constraint.sdc
export ADDITIONAL_LEFS = \
  $(PLATFORM_DIR)/lef/fakeram/rocket_gemmini/ht45_rocketgemmini_cc_banks_0_ext.lef \
  $(PLATFORM_DIR)/lef/fakeram/rocket_gemmini/ht45_rocketgemmini_cc_dir_ext.lef \
  $(PLATFORM_DIR)/lef/fakeram/rocket_gemmini/ht45_rocketgemmini_mem_0_ext.lef \
  $(PLATFORM_DIR)/lef/fakeram/rocket_gemmini/ht45_rocketgemmini_mem_1_ext.lef \
  $(PLATFORM_DIR)/lef/fakeram/rocket_gemmini/ht45_rocketgemmini_mem_ext.lef \
  $(PLATFORM_DIR)/lef/fakeram/rocket_gemmini/ht45_rocketgemmini_rockettile_dcache_data_arrays_0_ext.lef \
  $(PLATFORM_DIR)/lef/fakeram/rocket_gemmini/ht45_rocketgemmini_rockettile_dcache_tag_array_ext.lef \
  $(PLATFORM_DIR)/lef/fakeram/rocket_gemmini/ht45_rocketgemmini_rockettile_icache_data_arrays_0_ext.lef \
  $(PLATFORM_DIR)/lef/fakeram/rocket_gemmini/ht45_rocketgemmini_rockettile_icache_tag_array_ext.lef
export ADDITIONAL_LIBS = \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/rocket_gemmini/ht45_rocketgemmini_cc_banks_0_ext.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/rocket_gemmini/ht45_rocketgemmini_cc_dir_ext.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/rocket_gemmini/ht45_rocketgemmini_mem_0_ext.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/rocket_gemmini/ht45_rocketgemmini_mem_1_ext.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/rocket_gemmini/ht45_rocketgemmini_mem_ext.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/rocket_gemmini/ht45_rocketgemmini_rockettile_dcache_data_arrays_0_ext.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/rocket_gemmini/ht45_rocketgemmini_rockettile_dcache_tag_array_ext.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/rocket_gemmini/ht45_rocketgemmini_rockettile_icache_data_arrays_0_ext.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/rocket_gemmini/ht45_rocketgemmini_rockettile_icache_tag_array_ext.lib
export CORE_MARGIN = 1
export CORE_UTILIZATION ?= 60
export NUM_CORES ?= 32
