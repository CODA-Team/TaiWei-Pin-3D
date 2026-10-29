export DESIGN_NAME = picorv32
export PLATFORM    = nangate45_3D

export PIN3D_SPLIT_PORT_DRIVEN_NETS ?= 1
export PIN3D_INACTIVE_TIER_DONT_TOUCH ?= 1
export SKIP_INCREMENTAL_REPAIR = 0

export PLACE_DENSITY_LB_ADDON = 0.10
export TNS_END_PERCENT        = 100
export SKIP_GATE_CLONING      = 0
export CORE_MARGIN = 1
export CORE_ASPECT_RATIO = 1.0
export CORE_UTILIZATION ?= 50
export DETAILED_ROUTE_END_ITERATION = 5
export GLOBAL_ROUTE_ARGS = -verbose -congestion_iterations 30

export SC_LEF_UPPER_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.cover.lef
export SC_LEF_BOTTOM_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.lef

export NUM_CORES ?= 32
