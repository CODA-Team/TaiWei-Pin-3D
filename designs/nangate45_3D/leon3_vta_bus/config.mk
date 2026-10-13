export DESIGN_NAME = leon3_vta_soc
export DESIGN_NICKNAME = leon3_vta_bus
export PLATFORM = nangate45_3D

export PIN3D_SPLIT_PORT_DRIVEN_NETS ?= 1
export PIN3D_INACTIVE_TIER_DONT_TOUCH ?= 1
export SKIP_INCREMENTAL_REPAIR = 0
export SKIP_GATE_CLONING = 0

export SC_LEF_UPPER_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.cover.lef
export SC_LEF_BOTTOM_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.lef
export ADDITIONAL_LEFS = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_256x16_1r1w.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_256x16_1rw.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_mem_0_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_0_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_1_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_2_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_vta_q_512x128.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_256x16_1r1w.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_256x16_1rw.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_mem_0_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_0_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_1_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_2_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_vta_q_512x128.upper.lef
export ADDITIONAL_LEFS_UPPER_COVER = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_256x16_1r1w.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_256x16_1rw.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_mem_0_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_0_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_1_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_2_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_vta_q_512x128.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_256x16_1r1w.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_256x16_1rw.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_mem_0_ext.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_0_ext.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_1_ext.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_2_ext.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_ext.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_vta_q_512x128.upper.cover.lef
export ADDITIONAL_LEFS_BOTTOM_COVER = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_256x16_1r1w.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_256x16_1rw.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_mem_0_ext.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_0_ext.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_1_ext.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_2_ext.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_ext.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht45_leon3vtabus_vta_q_512x128.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_256x16_1r1w.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_256x16_1rw.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_mem_0_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_0_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_1_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_2_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht45_leon3vtabus_vta_q_512x128.upper.lef
export ADDITIONAL_LIBS = \
  $(PLATFORM_DIR)/lib_bottom/fakeram/leon3_vta_bus/ht45_leon3vtabus_256x16_1r1w.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/fakeram/leon3_vta_bus/ht45_leon3vtabus_256x16_1rw.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/fakeram/leon3_vta_bus/ht45_leon3vtabus_mem_0_ext.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/fakeram/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_0_ext.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/fakeram/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_1_ext.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/fakeram/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_2_ext.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/fakeram/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_ext.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/fakeram/leon3_vta_bus/ht45_leon3vtabus_vta_q_512x128.bottom.lib \
  $(PLATFORM_DIR)/lib_upper/fakeram/leon3_vta_bus/ht45_leon3vtabus_256x16_1r1w.upper.lib \
  $(PLATFORM_DIR)/lib_upper/fakeram/leon3_vta_bus/ht45_leon3vtabus_256x16_1rw.upper.lib \
  $(PLATFORM_DIR)/lib_upper/fakeram/leon3_vta_bus/ht45_leon3vtabus_mem_0_ext.upper.lib \
  $(PLATFORM_DIR)/lib_upper/fakeram/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_0_ext.upper.lib \
  $(PLATFORM_DIR)/lib_upper/fakeram/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_1_ext.upper.lib \
  $(PLATFORM_DIR)/lib_upper/fakeram/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_2_ext.upper.lib \
  $(PLATFORM_DIR)/lib_upper/fakeram/leon3_vta_bus/ht45_leon3vtabus_tensorFile_0_ext.upper.lib \
  $(PLATFORM_DIR)/lib_upper/fakeram/leon3_vta_bus/ht45_leon3vtabus_vta_q_512x128.upper.lib

export MACRO_PLACE_HALO = 5 5
export MACRO_PLACE_HALO_UPPER = 5 5
export MACRO_PLACE_HALO_BOTTOM = 5 5

export CORE_UTILIZATION = 50
export CORE_ASPECT_RATIO = 1
export CORE_MARGIN = 5
export PLACE_DENSITY_LB_ADDON = 0.08
export TNS_END_PERCENT = 100
export DETAILED_ROUTE_END_ITERATION = 20
export GLOBAL_ROUTE_ARGS = -verbose -congestion_iterations 30

export NUM_CORES ?= 32
