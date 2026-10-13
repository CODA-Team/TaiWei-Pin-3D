export DESIGN_NAME = mempool_group
export DESIGN_NICKNAME = mempool_group
export PLATFORM = asap7_3D

export SC_LEF_UPPER_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/asap7sc7p5t_28_R_1x_220121a.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.cover.lef
export SC_LEF_BOTTOM_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/asap7sc7p5t_28_R_1x_220121a.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.lef
export ADDITIONAL_LEFS = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/mempool_group/ht_asap7_mempoolgroup_23x64.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/mempool_group/ht_asap7_mempoolgroup_256x128.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/mempool_group/ht_asap7_mempoolgroup_32x128.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/mempool_group/ht_asap7_mempoolgroup_32x256.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/mempool_group/ht_asap7_mempoolgroup_512x16384.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/mempool_group/ht_asap7_mempoolgroup_512x64.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/mempool_group/ht_asap7_mempoolgroup_64x64.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/mempool_group/ht_asap7_mempoolgroup_23x64.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/mempool_group/ht_asap7_mempoolgroup_256x128.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/mempool_group/ht_asap7_mempoolgroup_32x128.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/mempool_group/ht_asap7_mempoolgroup_32x256.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/mempool_group/ht_asap7_mempoolgroup_512x16384.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/mempool_group/ht_asap7_mempoolgroup_512x64.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/mempool_group/ht_asap7_mempoolgroup_64x64.upper.lef
export ADDITIONAL_LEFS_UPPER_COVER = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/mempool_group/ht_asap7_mempoolgroup_23x64.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/mempool_group/ht_asap7_mempoolgroup_256x128.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/mempool_group/ht_asap7_mempoolgroup_32x128.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/mempool_group/ht_asap7_mempoolgroup_32x256.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/mempool_group/ht_asap7_mempoolgroup_512x16384.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/mempool_group/ht_asap7_mempoolgroup_512x64.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/mempool_group/ht_asap7_mempoolgroup_64x64.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/mempool_group/ht_asap7_mempoolgroup_23x64.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/mempool_group/ht_asap7_mempoolgroup_256x128.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/mempool_group/ht_asap7_mempoolgroup_32x128.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/mempool_group/ht_asap7_mempoolgroup_32x256.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/mempool_group/ht_asap7_mempoolgroup_512x16384.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/mempool_group/ht_asap7_mempoolgroup_512x64.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/mempool_group/ht_asap7_mempoolgroup_64x64.upper.cover.lef
export ADDITIONAL_LEFS_BOTTOM_COVER = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/mempool_group/ht_asap7_mempoolgroup_23x64.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/mempool_group/ht_asap7_mempoolgroup_256x128.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/mempool_group/ht_asap7_mempoolgroup_32x128.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/mempool_group/ht_asap7_mempoolgroup_32x256.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/mempool_group/ht_asap7_mempoolgroup_512x16384.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/mempool_group/ht_asap7_mempoolgroup_512x64.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/mempool_group/ht_asap7_mempoolgroup_64x64.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/mempool_group/ht_asap7_mempoolgroup_23x64.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/mempool_group/ht_asap7_mempoolgroup_256x128.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/mempool_group/ht_asap7_mempoolgroup_32x128.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/mempool_group/ht_asap7_mempoolgroup_32x256.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/mempool_group/ht_asap7_mempoolgroup_512x16384.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/mempool_group/ht_asap7_mempoolgroup_512x64.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/mempool_group/ht_asap7_mempoolgroup_64x64.upper.lef
export ADDITIONAL_LIBS = \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/mempool_group/ht_asap7_mempoolgroup_23x64.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/mempool_group/ht_asap7_mempoolgroup_256x128.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/mempool_group/ht_asap7_mempoolgroup_32x128.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/mempool_group/ht_asap7_mempoolgroup_32x256.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/mempool_group/ht_asap7_mempoolgroup_512x16384.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/mempool_group/ht_asap7_mempoolgroup_512x64.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/mempool_group/ht_asap7_mempoolgroup_64x64.bottom.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/mempool_group/ht_asap7_mempoolgroup_23x64.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/mempool_group/ht_asap7_mempoolgroup_256x128.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/mempool_group/ht_asap7_mempoolgroup_32x128.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/mempool_group/ht_asap7_mempoolgroup_32x256.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/mempool_group/ht_asap7_mempoolgroup_512x16384.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/mempool_group/ht_asap7_mempoolgroup_512x64.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/mempool_group/ht_asap7_mempoolgroup_64x64.upper.lib

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
