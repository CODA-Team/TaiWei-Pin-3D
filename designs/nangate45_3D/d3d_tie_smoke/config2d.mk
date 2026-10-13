export DESIGN_NAME = d3d_tie_smoke
export PLATFORM = nangate45

export VERILOG_FILES = \
  $(DESIGN_HOME)/src/d3d_tie_smoke/d3d_tie_smoke.v \
  $(DESIGN_HOME)/nangate45_3D/d3d_tie_smoke/constant_loads.v
export SDC_FILE = $(DESIGN_HOME)/nangate45_3D/d3d_tie_smoke/constraint.sdc

export ABC_AREA = 1
export CORE_MARGIN = 2
export ASPECT_RATIO = 1.0
export CORE_UTILIZATION = 50
export PLACE_DENSITY_LB_ADDON = 0.10
export NUM_CORES ?= 8
