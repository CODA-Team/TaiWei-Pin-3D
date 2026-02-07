export DESIGN_NICKNAME = jpeg
export DESIGN_NAME = jpeg_encoder
export PLATFORM    = nangate45_3D

export PLACE_DENSITY_LB_ADDON = 0.10
export TNS_END_PERCENT        = 100
export SKIP_GATE_CLONING   = 1
export CORE_MARGIN = 1
export CORE_ASPECT_RATIO = 1.0
export CORE_UTILIZATION ?= 60
export PLACE_DENSITY_LB_ADDON = 0.10
export GLOBAL_ROUTE_ARGS = -verbose -congestion_iterations 30


export NUM_CORES   ?= 32

export SC_LEF_UPPER_COVER ?= \
$(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.lef \
$(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.cover.lef 
export SC_LEF_BOTTOM_COVER ?= \
$(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.lef \
$(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.cover.lef
