export DESIGN_NAME = bsg_chip
export DESIGN_NICKNAME = bp_quad
export PLATFORM    = nangate45_3D

export PIN3D_SPLIT_PORT_DRIVEN_NETS ?= 1
export PIN3D_INACTIVE_TIER_DONT_TOUCH ?= 1
export SKIP_INCREMENTAL_REPAIR = 0
export SKIP_GATE_CLONING = 0

export SC_LEF_UPPER_COVER = $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.lef \
                            $(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.cover.lef 
export SC_LEF_BOTTOM_COVER = $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.cover.lef \
                             $(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.lef 

export ADDITIONAL_LEFS = $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_128x116.bottom.lef \
                         $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_256x48.bottom.lef \
                         $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_32x32.bottom.lef \
                         $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_512x64.bottom.lef \
                         $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_64x124.bottom.lef \
                         $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_64x62.bottom.lef \
                         $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram45_128x116.upper.lef \
                         $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram45_256x48.upper.lef \
                         $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram45_32x32.upper.lef \
                         $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram45_512x64.upper.lef \
                         $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram45_64x124.upper.lef \
                         $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram45_64x62.upper.lef
export ADDITIONAL_LEFS_UPPER_COVER = $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_128x116.bottom.lef \
                                     $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_256x48.bottom.lef \
                                     $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_32x32.bottom.lef \
                                     $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_512x64.bottom.lef \
                                     $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_64x124.bottom.lef \
                                     $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_64x62.bottom.lef \
                                     $(PLATFORM_DIR)/lef_upper/fakeram_cover/fakeram45_128x116.upper.cover.lef \
                                     $(PLATFORM_DIR)/lef_upper/fakeram_cover/fakeram45_256x48.upper.cover.lef \
                                     $(PLATFORM_DIR)/lef_upper/fakeram_cover/fakeram45_32x32.upper.cover.lef \
                                     $(PLATFORM_DIR)/lef_upper/fakeram_cover/fakeram45_512x64.upper.cover.lef \
                                     $(PLATFORM_DIR)/lef_upper/fakeram_cover/fakeram45_64x124.upper.cover.lef \
                                     $(PLATFORM_DIR)/lef_upper/fakeram_cover/fakeram45_64x62.upper.cover.lef
export ADDITIONAL_LEFS_BOTTOM_COVER = $(PLATFORM_DIR)/lef_bottom/fakeram_cover/fakeram45_128x116.bottom.cover.lef \
                                      $(PLATFORM_DIR)/lef_bottom/fakeram_cover/fakeram45_256x48.bottom.cover.lef \
                                      $(PLATFORM_DIR)/lef_bottom/fakeram_cover/fakeram45_32x32.bottom.cover.lef \
                                      $(PLATFORM_DIR)/lef_bottom/fakeram_cover/fakeram45_512x64.bottom.cover.lef \
                                      $(PLATFORM_DIR)/lef_bottom/fakeram_cover/fakeram45_64x124.bottom.cover.lef \
                                      $(PLATFORM_DIR)/lef_bottom/fakeram_cover/fakeram45_64x62.bottom.cover.lef \
                                      $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram45_128x116.upper.lef \
                                      $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram45_256x48.upper.lef \
                                      $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram45_32x32.upper.lef \
                                      $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram45_512x64.upper.lef \
                                      $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram45_64x124.upper.lef \
                                      $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram45_64x62.upper.lef
export ADDITIONAL_LIBS = $(PLATFORM_DIR)/lib_bottom/fakeram/fakeram45_128x116.bottom.lib \
                         $(PLATFORM_DIR)/lib_bottom/fakeram/fakeram45_256x48.bottom.lib \
                         $(PLATFORM_DIR)/lib_bottom/fakeram/fakeram45_32x32.bottom.lib \
                         $(PLATFORM_DIR)/lib_bottom/fakeram/fakeram45_512x64.bottom.lib \
                         $(PLATFORM_DIR)/lib_bottom/fakeram/fakeram45_64x124.bottom.lib \
                         $(PLATFORM_DIR)/lib_bottom/fakeram/fakeram45_64x62.bottom.lib \
                         $(PLATFORM_DIR)/lib_upper/fakeram/fakeram45_128x116.upper.lib \
                         $(PLATFORM_DIR)/lib_upper/fakeram/fakeram45_256x48.upper.lib \
                         $(PLATFORM_DIR)/lib_upper/fakeram/fakeram45_32x32.upper.lib \
                         $(PLATFORM_DIR)/lib_upper/fakeram/fakeram45_512x64.upper.lib \
                         $(PLATFORM_DIR)/lib_upper/fakeram/fakeram45_64x124.upper.lib \
                         $(PLATFORM_DIR)/lib_upper/fakeram/fakeram45_64x62.upper.lib

export CORE_UTILIZATION = 50
export CORE_ASPECT_RATIO = 1
export CORE_MARGIN = 5
export PLACE_DENSITY_LB_ADDON = 0.08
export TNS_END_PERCENT        = 100
export DETAILED_ROUTE_END_ITERATION = 20
export GLOBAL_ROUTE_ARGS = -verbose -congestion_iterations 30

export MACRO_PLACE_HALO = 5 5
export MACRO_PLACE_HALO_UPPER = 5 5
export MACRO_PLACE_HALO_BOTTOM = 5 5

export NUM_CORES   ?= 32
