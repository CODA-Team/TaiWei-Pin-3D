export DESIGN_NAME = black_parrot
export DESIGN_NICKNAME = blackparrot_2
export PLATFORM = nangate45

RTL_ROOT := $(DESIGN_HOME)/src/blackparrot_2/nangate45
RTL_FILELIST := $(DESIGN_HOME)/src/blackparrot_2/nangate45/rtl_files.f
export VERILOG_FILES = $(addprefix $(RTL_ROOT)/,$(shell awk 'NF' $(RTL_FILELIST)))
RTL_INCLUDE_LIST := $(DESIGN_HOME)/src/blackparrot_2/nangate45/include_dirs.f
export VERILOG_INCLUDE_DIRS = $(addprefix $(RTL_ROOT)/,$(shell awk 'NF' $(RTL_INCLUDE_LIST)))
export SYNTH_HDL_FRONTEND = slang
export SDC_FILE = $(DESIGN_HOME)/nangate45_3D/blackparrot_2/constraint.sdc
export ADDITIONAL_LEFS = \
  $(PLATFORM_DIR)/lef/fakeram/blackparrot_2/ht45_blackparrot_256x95.lef \
  $(PLATFORM_DIR)/lef/fakeram/blackparrot_2/ht45_blackparrot_512x64.lef \
  $(PLATFORM_DIR)/lef/fakeram/blackparrot_2/ht45_blackparrot_64x15.lef \
  $(PLATFORM_DIR)/lef/fakeram/blackparrot_2/ht45_blackparrot_64x7.lef \
  $(PLATFORM_DIR)/lef/fakeram/blackparrot_2/ht45_blackparrot_64x96.lef
export ADDITIONAL_LIBS = \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/blackparrot_2/ht45_blackparrot_256x95.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/blackparrot_2/ht45_blackparrot_512x64.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/blackparrot_2/ht45_blackparrot_64x15.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/blackparrot_2/ht45_blackparrot_64x7.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/blackparrot_2/ht45_blackparrot_64x96.lib
export CORE_MARGIN = 1
export CORE_UTILIZATION ?= 60
export NUM_CORES ?= 32
