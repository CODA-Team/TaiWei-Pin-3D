export DESIGN_NICKNAME = aes
export DESIGN_NAME = aes_cipher_top
export PLATFORM    = asap7

export VERILOG_FILES = $(sort $(wildcard $(DESIGN_HOME)/src/$(DESIGN_NICKNAME)/*.v))
export SDC_FILE      = $(DESIGN_HOME)/asap7_3D/$(DESIGN_NICKNAME)/constraint.sdc

export ABC_AREA      = 1
export CORE_MARGIN = 0.2
export ASPECT_RATIO = 1.0
export CORE_UTILIZATION ?= 60
export PLACE_DENSITY_LB_ADDON = 0.10
export TNS_END_PERCENT        = 100
export REMOVE_CELLS_FOR_EQY   = TAPCELL*
export GEN_EFF medium
export MAP_EFF high


export NUM_CORES   ?= 32
