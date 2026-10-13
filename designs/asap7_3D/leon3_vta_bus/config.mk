export DESIGN_NAME = leon3_vta_soc
export DESIGN_NICKNAME = leon3_vta_bus
export PLATFORM = asap7_3D

export PIN3D_SPLIT_PORT_DRIVEN_NETS ?= 1

export SC_LEF_UPPER_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/asap7sc7p5t_28_R_1x_220121a.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.cover.lef
export SC_LEF_BOTTOM_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/asap7sc7p5t_28_R_1x_220121a.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.lef
export ADDITIONAL_LEFS = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1r1w.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1rw.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_mem_0_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_0_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_1_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_2_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_vta_q_512x128.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1r1w.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1rw.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_mem_0_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_0_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_1_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_2_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_vta_q_512x128.upper.lef
export ADDITIONAL_LEFS_UPPER_COVER = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1r1w.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1rw.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_mem_0_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_0_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_1_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_2_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_ext.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_vta_q_512x128.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1r1w.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1rw.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_mem_0_ext.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_0_ext.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_1_ext.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_2_ext.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_ext.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_vta_q_512x128.upper.cover.lef
export ADDITIONAL_LEFS_BOTTOM_COVER = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1r1w.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1rw.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_mem_0_ext.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_0_ext.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_1_ext.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_2_ext.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_ext.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/leon3_vta_bus/ht_asap7_leon3vtabus_vta_q_512x128.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1r1w.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1rw.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_mem_0_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_0_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_1_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_2_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_ext.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/leon3_vta_bus/ht_asap7_leon3vtabus_vta_q_512x128.upper.lef
export ADDITIONAL_LIBS = \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1r1w.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1rw.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_mem_0_ext.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_0_ext.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_1_ext.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_2_ext.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_ext.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_vta_q_512x128.bottom.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1r1w.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_256x16_1rw.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_mem_0_ext.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_0_ext.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_1_ext.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_2_ext.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_tensorFile_0_ext.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/leon3_vta_bus/ht_asap7_leon3vtabus_vta_q_512x128.upper.lib

export MACRO_PLACE_HALO = 1 1
export MACRO_PLACE_HALO_UPPER = 1 1
export MACRO_PLACE_HALO_BOTTOM = 1 1

export CORE_UTILIZATION = 50
export CORE_ASPECT_RATIO = 1
export CORE_MARGIN = 5
export PLACE_DENSITY_LB_ADDON = 0.08
export TNS_END_PERCENT = 100
export DETAILED_ROUTE_END_ITERATION = 20
export GLOBAL_ROUTE_ARGS = -verbose -congestion_iterations 30

export NUM_CORES ?= 32
