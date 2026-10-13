export DESIGN_NAME = syn3d_macro_smoke
export PLATFORM = asap7

export VERILOG_FILES = $(DESIGN_HOME)/src/syn3d_macro_smoke/syn3d_macro_smoke.v \
                       $(DESIGN_HOME)/asap7_3D/syn3d_macro_smoke/macros.v
export SDC_FILE = $(DESIGN_HOME)/asap7_3D/syn3d_macro_smoke/constraint.sdc
override export CLKGATE_MAP_FILE :=

export ADDITIONAL_LEFS = $(PLATFORM_DIR)/lef/fakeram/fakeram7_64x21.lef
export ADDITIONAL_LIBS = $(PLATFORM_DIR)/lib/NLDM/fakeram/fakeram7_64x21.lib

export CORE_MARGIN = 2
export ASPECT_RATIO = 1.0
export CORE_UTILIZATION = 50
export PLACE_DENSITY_LB_ADDON = 0.08

export GEN_EFF = medium
export MAP_EFF = high
export SWAP_ARITH_OPERATORS = 1
