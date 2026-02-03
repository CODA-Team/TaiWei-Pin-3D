export DESIGN_NICKNAME = ibex
export DESIGN_NAME = ibex_core
export PLATFORM    = nangate45_3D

export SC_LEF ?= \
$(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.cover.lef \
$(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.lef 

export PLACE_DENSITY_LB_ADDON = 0.10
export TNS_END_PERCENT        = 100
export SKIP_GATE_CLONING   = 1
export CORE_MARGIN = 2

export CORE_UTILIZATION ?= 60

export NUM_CORES  ?= 32
