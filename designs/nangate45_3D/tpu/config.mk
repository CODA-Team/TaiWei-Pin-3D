export DESIGN_NAME = tpu
export DESIGN_NICKNAME = tpu
export PLATFORM = nangate45_3D

export PIN3D_SPLIT_PORT_DRIVEN_NETS ?= 1

export SC_LEF_UPPER_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.cover.lef
export SC_LEF_BOTTOM_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.lef

export CORE_UTILIZATION = 60
export CORE_ASPECT_RATIO = 1
export CORE_MARGIN = 1
export PLACE_DENSITY_LB_ADDON = 0.08
export TNS_END_PERCENT = 100
export DETAILED_ROUTE_END_ITERATION = 20
export GLOBAL_ROUTE_ARGS = -verbose -congestion_iterations 30

export NUM_CORES ?= 32
