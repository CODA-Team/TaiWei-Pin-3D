export DESIGN_NAME = black_parrot
export DESIGN_NICKNAME = blackparrot_2
export PLATFORM = asap7_3D

export PIN3D_SPLIT_PORT_DRIVEN_NETS ?= 1
export PIN3D_INACTIVE_TIER_DONT_TOUCH ?= 1
export SKIP_INCREMENTAL_REPAIR = 0
export SKIP_GATE_CLONING = 0

export SC_LEF_UPPER_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/asap7sc7p5t_28_R_1x_220121a.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.cover.lef
export SC_LEF_BOTTOM_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/asap7sc7p5t_28_R_1x_220121a.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.lef
export ADDITIONAL_LEFS = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/blackparrot_2/ht_asap7_blackparrot_256x95.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/blackparrot_2/ht_asap7_blackparrot_512x64.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/blackparrot_2/ht_asap7_blackparrot_64x15.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/blackparrot_2/ht_asap7_blackparrot_64x7.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/blackparrot_2/ht_asap7_blackparrot_64x96.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/blackparrot_2/ht_asap7_blackparrot_256x95.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/blackparrot_2/ht_asap7_blackparrot_512x64.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/blackparrot_2/ht_asap7_blackparrot_64x15.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/blackparrot_2/ht_asap7_blackparrot_64x7.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/blackparrot_2/ht_asap7_blackparrot_64x96.upper.lef
export ADDITIONAL_LEFS_UPPER_COVER = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/blackparrot_2/ht_asap7_blackparrot_256x95.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/blackparrot_2/ht_asap7_blackparrot_512x64.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/blackparrot_2/ht_asap7_blackparrot_64x15.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/blackparrot_2/ht_asap7_blackparrot_64x7.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/blackparrot_2/ht_asap7_blackparrot_64x96.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/blackparrot_2/ht_asap7_blackparrot_256x95.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/blackparrot_2/ht_asap7_blackparrot_512x64.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/blackparrot_2/ht_asap7_blackparrot_64x15.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/blackparrot_2/ht_asap7_blackparrot_64x7.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/blackparrot_2/ht_asap7_blackparrot_64x96.upper.cover.lef
export ADDITIONAL_LEFS_BOTTOM_COVER = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/blackparrot_2/ht_asap7_blackparrot_256x95.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/blackparrot_2/ht_asap7_blackparrot_512x64.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/blackparrot_2/ht_asap7_blackparrot_64x15.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/blackparrot_2/ht_asap7_blackparrot_64x7.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/blackparrot_2/ht_asap7_blackparrot_64x96.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/blackparrot_2/ht_asap7_blackparrot_256x95.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/blackparrot_2/ht_asap7_blackparrot_512x64.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/blackparrot_2/ht_asap7_blackparrot_64x15.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/blackparrot_2/ht_asap7_blackparrot_64x7.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/blackparrot_2/ht_asap7_blackparrot_64x96.upper.lef
export ADDITIONAL_LIBS = \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/blackparrot_2/ht_asap7_blackparrot_256x95.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/blackparrot_2/ht_asap7_blackparrot_512x64.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/blackparrot_2/ht_asap7_blackparrot_64x15.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/blackparrot_2/ht_asap7_blackparrot_64x7.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/blackparrot_2/ht_asap7_blackparrot_64x96.bottom.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/blackparrot_2/ht_asap7_blackparrot_256x95.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/blackparrot_2/ht_asap7_blackparrot_512x64.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/blackparrot_2/ht_asap7_blackparrot_64x15.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/blackparrot_2/ht_asap7_blackparrot_64x7.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/blackparrot_2/ht_asap7_blackparrot_64x96.upper.lib

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
