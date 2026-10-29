export DESIGN_NAME = ariane
export DESIGN_NICKNAME = ariane133
export PLATFORM    = asap7_3D

export PIN3D_SPLIT_PORT_DRIVEN_NETS ?= 1
export PIN3D_INACTIVE_TIER_DONT_TOUCH ?= 1
export SKIP_INCREMENTAL_REPAIR = 0
export SKIP_GATE_CLONING = 0

export SC_LEF_UPPER_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/asap7sc7p5t_28_R_1x_220121a.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.cover.lef
export SC_LEF_BOTTOM_COVER ?= \
  $(PLATFORM_DIR)/lef_bottom/asap7sc7p5t_28_R_1x_220121a.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.lef

export ADDITIONAL_LEFS = $(PLATFORM_DIR)/lef_bottom/fakeram_block/sram_asap7_16x256_1rw.bottom.lef \
                         $(PLATFORM_DIR)/lef_upper/fakeram_block/sram_asap7_16x256_1rw.upper.lef
export ADDITIONAL_LEFS_UPPER_COVER = $(PLATFORM_DIR)/lef_bottom/fakeram_block/sram_asap7_16x256_1rw.bottom.lef \
                                     $(PLATFORM_DIR)/lef_upper/fakeram_cover/sram_asap7_16x256_1rw.upper.cover.lef
export ADDITIONAL_LEFS_BOTTOM_COVER = $(PLATFORM_DIR)/lef_bottom/fakeram_cover/sram_asap7_16x256_1rw.bottom.cover.lef \
                                      $(PLATFORM_DIR)/lef_upper/fakeram_block/sram_asap7_16x256_1rw.upper.lef
export ADDITIONAL_LIBS = $(PLATFORM_DIR)/lib_bottom/NLDM/fakeram/sram_asap7_16x256_1rw.bottom.lib \
                         $(PLATFORM_DIR)/lib_upper/NLDM/fakeram/sram_asap7_16x256_1rw.upper.lib

export CORE_UTILIZATION = 50
export CORE_ASPECT_RATIO = 1
export CORE_MARGIN = 5
export PLACE_DENSITY_LB_ADDON = 0.08
export TNS_END_PERCENT        = 100
export DETAILED_ROUTE_END_ITERATION = 20
export GLOBAL_ROUTE_ARGS = -verbose -congestion_iterations 30

export MACRO_PLACE_HALO = 1 1
export MACRO_PLACE_HALO_UPPER = 1 1
export MACRO_PLACE_HALO_BOTTOM = 1 1

export NUM_CORES   ?= 32
