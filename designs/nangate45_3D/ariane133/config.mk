export DESIGN_NAME = ariane
export DESIGN_NICKNAME = ariane133
export PLATFORM    = nangate45_3D

export SC_LEF_UPPER_COVER = $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.lef \
                            $(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.cover.lef 
export SC_LEF_BOTTOM_COVER = $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.cover.lef \
                             $(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.lef 

export ADDITIONAL_LEFS = $(sort $(wildcard $(PLATFORM_DIR)/lef_bottom/fakeram_block/*.lef)) \
                         $(sort $(wildcard $(PLATFORM_DIR)/lef_upper/fakeram_block/*.lef))
export ADDITIONAL_LEFS_UPPER_COVER = $(sort $(wildcard $(PLATFORM_DIR)/lef_bottom/fakeram_block/*.lef)) \
                                     $(sort $(wildcard $(PLATFORM_DIR)/lef_upper/fakeram_cover/*.lef))
export ADDITIONAL_LEFS_BOTTOM_COVER = $(sort $(wildcard $(PLATFORM_DIR)/lef_bottom/fakeram_cover/*.lef)) \
                                      $(sort $(wildcard $(PLATFORM_DIR)/lef_upper/fakeram_block/*.lef))
export ADDITIONAL_LIBS = $(sort $(wildcard $(PLATFORM_DIR)/lib_bottom/fakeram/*.lib)) \
                         $(sort $(wildcard $(PLATFORM_DIR)/lib_upper/fakeram/*.lib))

export CORE_UTILIZATION = 50
export CORE_ASPECT_RATIO = 1
export CORE_MARGIN = 5
export PLACE_DENSITY_LB_ADDON = 0.08
export TNS_END_PERCENT        = 100
export DETAILED_ROUTE_END_ITERATION = 20
export GLOBAL_ROUTE_ARGS = -verbose -congestion_iterations 30

export MACRO_PLACE_HALO    = 8 8
export RTLMP_MAX_LEVEL = 1
export RTLMP_MAX_MACRO = 10
export RTLMP_MIN_MACRO = 1
export RTLMP_MAX_INST = 80000
export RTLMP_MIN_INST = 8000

export NUM_CORES   ?= 32
