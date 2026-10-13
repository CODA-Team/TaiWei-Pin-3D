export DESIGN_NAME = mempool_group
export DESIGN_NICKNAME = mempool_group
export PLATFORM = nangate45

RTL_ROOT := $(DESIGN_HOME)/src/mempool_group/nangate45
RTL_FILELIST := $(DESIGN_HOME)/src/mempool_group/nangate45/rtl_files.f
export VERILOG_FILES = $(addprefix $(RTL_ROOT)/,$(shell awk 'NF' $(RTL_FILELIST)))
RTL_INCLUDE_LIST := $(DESIGN_HOME)/src/mempool_group/nangate45/include_dirs.f
export VERILOG_INCLUDE_DIRS = $(addprefix $(RTL_ROOT)/,$(shell awk 'NF' $(RTL_INCLUDE_LIST)))
export VERILOG_DEFINES = \
  -D \
  TARGET_SYNTHESIS \
  -D \
  XPULPIMG=1 \
  -D \
  AXI_DATA_WIDTH=512 \
  -D \
  NUM_CORES=256 \
  -D \
  NUM_CORES_PER_TILE=4 \
  -D \
  NUM_GROUPS=4 \
  -D \
  BANKING_FACTOR=4 \
  -D \
  AXI_HIER_RADIX=17 \
  -D \
  AXI_MASTERS_PER_GROUP=1 \
  -D \
  DMAS_PER_GROUP=1 \
  -D \
  L2_SIZE=4194304 \
  -D \
  L2_BANKS=4 \
  -D \
  RO_LINE_WIDTH=512 \
  -D \
  SEQ_MEM_SIZE=512 \
  -D \
  XQUEUE_SIZE=0
export SYNTH_HDL_FRONTEND = slang
export SDC_FILE = $(DESIGN_HOME)/nangate45_3D/mempool_group/constraint.sdc
export ADDITIONAL_LEFS = \
  $(PLATFORM_DIR)/lef/fakeram/mempool_group/ht45_mempoolgroup_23x64.lef \
  $(PLATFORM_DIR)/lef/fakeram/mempool_group/ht45_mempoolgroup_256x128.lef \
  $(PLATFORM_DIR)/lef/fakeram/mempool_group/ht45_mempoolgroup_32x128.lef \
  $(PLATFORM_DIR)/lef/fakeram/mempool_group/ht45_mempoolgroup_32x256.lef \
  $(PLATFORM_DIR)/lef/fakeram/mempool_group/ht45_mempoolgroup_512x16384.lef \
  $(PLATFORM_DIR)/lef/fakeram/mempool_group/ht45_mempoolgroup_512x64.lef \
  $(PLATFORM_DIR)/lef/fakeram/mempool_group/ht45_mempoolgroup_64x64.lef
export ADDITIONAL_LIBS = \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/mempool_group/ht45_mempoolgroup_23x64.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/mempool_group/ht45_mempoolgroup_256x128.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/mempool_group/ht45_mempoolgroup_32x128.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/mempool_group/ht45_mempoolgroup_32x256.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/mempool_group/ht45_mempoolgroup_512x16384.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/mempool_group/ht45_mempoolgroup_512x64.lib \
  $(PLATFORM_DIR)/lib/NLDM/fakeram/mempool_group/ht45_mempoolgroup_64x64.lib
export CORE_MARGIN = 1
export CORE_UTILIZATION ?= 60
export NUM_CORES ?= 32
export PIN3D_SPLIT_PORT_DRIVEN_NETS ?= 1
