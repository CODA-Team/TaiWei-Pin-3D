export DESIGN_NICKNAME = ibex
export DESIGN_NAME = ibex_core
export PLATFORM    = asap7_nangate45

export VERILOG_FILES = $(sort $(wildcard $(DESIGN_HOME)/src/ibex_sv/*.sv)) \
    $(DESIGN_HOME)/src/ibex_sv/syn/rtl/prim_clock_gating.v

export VERILOG_INCLUDE_DIRS = \
    $(DESIGN_HOME)/src/ibex_sv/vendor/lowrisc_ip/prim/rtl/

export SDC_FILE      = $(DESIGN_HOME)/asap7_nangate45_3D/$(DESIGN_NICKNAME)/constraint.sdc

export SYNTH_HDL_FRONTEND = slang

export ABC_AREA      = 1
export CORE_MARGIN = 2
export ASPECT_RATIO = 1.0
export CORE_UTILIZATION ?= 60
export PLACE_DENSITY_LB_ADDON = 0.10
export TNS_END_PERCENT        = 100
export REMOVE_CELLS_FOR_EQY   = TAPCELL*
export GEN_EFF medium
export MAP_EFF high


export NUM_CORES   ?= 32
