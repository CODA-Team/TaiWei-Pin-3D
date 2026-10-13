export DESIGN_NAME = syn3d_macro_smoke
export PLATFORM = asap7_nangate45_3D

export SC_LEF_UPPER_COVER = \
  $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.processed.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.cover.processed.lef
export SC_LEF_BOTTOM_COVER = \
  $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.cover.processed.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.processed.lef

export ADDITIONAL_LEFS = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_64x21.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram7_64x21.upper.lef
export ADDITIONAL_LEFS_UPPER_COVER = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_block/fakeram45_64x21.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_cover/fakeram7_64x21.upper.cover.lef
export ADDITIONAL_LEFS_BOTTOM_COVER = \
  $(PLATFORM_DIR)/lef_bottom/fakeram_cover/fakeram45_64x21.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/fakeram_block/fakeram7_64x21.upper.lef
export ADDITIONAL_LIBS = \
  $(PLATFORM_DIR)/lib_bottom/fakeram/fakeram45_64x21.bottom.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/fakeram7_64x21.upper.lib

export CORE_MARGIN = 2
export ASPECT_RATIO = 1.0
export CORE_UTILIZATION = 50
export MACRO_PLACE_HALO = 1 1
export MACRO_PLACE_HALO_UPPER = 1 1
export MACRO_PLACE_HALO_BOTTOM = 5 5
