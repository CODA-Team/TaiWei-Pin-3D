export DESIGN_NICKNAME = jpeg
export DESIGN_NAME = jpeg_encoder
export PLATFORM    = nangate45_3D

export SC_LEF ?= \
$(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.lef \
$(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.cover.lef

export PLACE_DENSITY_LB_ADDON = 0.10
export TNS_END_PERCENT        = 100
export SKIP_GATE_CLONING   = 1
export CORE_MARGIN = 1

export NUM_CORES   ?= 32
