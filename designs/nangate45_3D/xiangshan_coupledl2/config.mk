export DESIGN_NAME = CoupledL2
export DESIGN_NICKNAME = xiangshan_coupledl2
export PLATFORM = nangate45_3D

export SC_LEF_UPPER_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.cover.lef
export SC_LEF_BOTTOM_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.lef
export ADDITIONAL_LEFS = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/xiangshan_coupledl2/array_2048x137_bk.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/xiangshan_coupledl2/array_256x104.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/xiangshan_coupledl2/array_256x13.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/xiangshan_coupledl2/array_256x16.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/xiangshan_coupledl2/array_256x164.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/xiangshan_coupledl2/array_256x8_0.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/xiangshan_coupledl2/array_2048x137_bk.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/xiangshan_coupledl2/array_256x104.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/xiangshan_coupledl2/array_256x13.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/xiangshan_coupledl2/array_256x16.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/xiangshan_coupledl2/array_256x164.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/xiangshan_coupledl2/array_256x8_0.upper.lef
export ADDITIONAL_LEFS_UPPER_COVER = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/xiangshan_coupledl2/array_2048x137_bk.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/xiangshan_coupledl2/array_256x104.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/xiangshan_coupledl2/array_256x13.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/xiangshan_coupledl2/array_256x16.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/xiangshan_coupledl2/array_256x164.bottom.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/xiangshan_coupledl2/array_256x8_0.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/xiangshan_coupledl2/array_2048x137_bk.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/xiangshan_coupledl2/array_256x104.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/xiangshan_coupledl2/array_256x13.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/xiangshan_coupledl2/array_256x16.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/xiangshan_coupledl2/array_256x164.upper.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/xiangshan_coupledl2/array_256x8_0.upper.cover.lef
export ADDITIONAL_LEFS_BOTTOM_COVER = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/xiangshan_coupledl2/array_2048x137_bk.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/xiangshan_coupledl2/array_256x104.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/xiangshan_coupledl2/array_256x13.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/xiangshan_coupledl2/array_256x16.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/xiangshan_coupledl2/array_256x164.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/xiangshan_coupledl2/array_256x8_0.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/xiangshan_coupledl2/array_2048x137_bk.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/xiangshan_coupledl2/array_256x104.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/xiangshan_coupledl2/array_256x13.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/xiangshan_coupledl2/array_256x16.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/xiangshan_coupledl2/array_256x164.upper.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/xiangshan_coupledl2/array_256x8_0.upper.lef
export ADDITIONAL_LIBS = \
  $(PLATFORM_DIR)/lib_bottom/fakeram/xiangshan_coupledl2/array_2048x137_bk.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/fakeram/xiangshan_coupledl2/array_256x104.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/fakeram/xiangshan_coupledl2/array_256x13.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/fakeram/xiangshan_coupledl2/array_256x16.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/fakeram/xiangshan_coupledl2/array_256x164.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/fakeram/xiangshan_coupledl2/array_256x8_0.bottom.lib \
  $(PLATFORM_DIR)/lib_upper/fakeram/xiangshan_coupledl2/array_2048x137_bk.upper.lib \
  $(PLATFORM_DIR)/lib_upper/fakeram/xiangshan_coupledl2/array_256x104.upper.lib \
  $(PLATFORM_DIR)/lib_upper/fakeram/xiangshan_coupledl2/array_256x13.upper.lib \
  $(PLATFORM_DIR)/lib_upper/fakeram/xiangshan_coupledl2/array_256x16.upper.lib \
  $(PLATFORM_DIR)/lib_upper/fakeram/xiangshan_coupledl2/array_256x164.upper.lib \
  $(PLATFORM_DIR)/lib_upper/fakeram/xiangshan_coupledl2/array_256x8_0.upper.lib

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
