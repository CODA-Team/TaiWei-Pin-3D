export DESIGN_NAME = d3d_tie_smoke
export PLATFORM = asap7_3D

export CORE_MARGIN = 2
export ASPECT_RATIO = 1.0
export CORE_UTILIZATION = 50
export PLACE_DENSITY_LB_ADDON = 0.10
export SKIP_GATE_CLONING = 1
export NUM_CORES ?= 8

export SC_LEF_UPPER_COVER = \
  $(PLATFORM_DIR)/lef_bottom/asap7sc7p5t_28_R_1x_220121a.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.cover.lef
export SC_LEF_BOTTOM_COVER = \
  $(PLATFORM_DIR)/lef_bottom/asap7sc7p5t_28_R_1x_220121a.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.lef
