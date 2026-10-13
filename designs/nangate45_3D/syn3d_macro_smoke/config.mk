export DESIGN_NAME = syn3d_macro_smoke
export PLATFORM = nangate45_3D

export SC_LEF_UPPER_COVER = \
  $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.cover.lef
export SC_LEF_BOTTOM_COVER = \
  $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.lef

export ADDITIONAL_LEFS = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_64x21.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram45_64x21.upper.lef
export ADDITIONAL_LEFS_UPPER_COVER = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_64x21.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/fakeram45_64x21.upper.cover.lef
export ADDITIONAL_LEFS_BOTTOM_COVER = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/fakeram45_64x21.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram45_64x21.upper.lef
export ADDITIONAL_LIBS = \
  $(PLATFORM_DIR)/lib_bottom/fakeram/fakeram45_64x21.bottom.lib \
  $(PLATFORM_DIR)/lib_upper/fakeram/fakeram45_64x21.upper.lib

export CORE_MARGIN = 2
export ASPECT_RATIO = 1.0
export CORE_UTILIZATION = 50
export MACRO_PLACE_HALO = 5 5
export MACRO_PLACE_HALO_UPPER = 5 5
export MACRO_PLACE_HALO_BOTTOM = 5 5
