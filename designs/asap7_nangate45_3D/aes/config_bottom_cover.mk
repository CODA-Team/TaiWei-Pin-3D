export DESIGN_NICKNAME = aes
export DESIGN_NAME = aes_cipher_top
export PLATFORM    = asap7_nangate45_3D

export SC_LEF ?= \
$(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.cover.processed.lef \
$(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.processed.lef 

export PLACE_DENSITY_LB_ADDON = 0.10
export TNS_END_PERCENT        = 100
export SKIP_GATE_CLONING   = 1
export CORE_MARGIN = 3

export CORE_UTILIZATION ?= 60

export NUM_CORES  ?= 32
