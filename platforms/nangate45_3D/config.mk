# =========================================
# tech config.mk
# =========================================

# -------- Process --------
export PROCESS = 45

# -------- Tech / Libs --------
ifeq ($(USE_FLOW),openroad)
  export TECH_LEF ?= $(PLATFORM_DIR)/lef/NangateOpenCellLibrary.tech21.lef
  export RCX_RULES         ?= $(PLATFORM_DIR)/NangateOpenCellLibrary.tech21.rcx_patterns.rules
  export SET_RC_TCL  ?= $(PLATFORM_DIR)/setRC.tech21.tcl
  export MIN_ROUTING_LAYER ?= M2
  export MAX_ROUTING_LAYER ?= M3_add
  export MAKE_TRACKS ?= $(PLATFORM_DIR)/make_tracks.tech21.tcl
endif
export MIN_CLK_ROUTING_LAYER ?= M2
export TECH_LEF ?= $(PLATFORM_DIR)/lef/NangateOpenCellLibrary.tech.lef
export RCX_RULES         ?= $(PLATFORM_DIR)/NangateOpenCellLibrary.tech.rcx_patterns.rules
export SET_RC_TCL  ?= $(PLATFORM_DIR)/setRC.tech.tcl

export SC_LEF  ?= \
$(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.lef \
$(PLATFORM_DIR)/lef_upper/NangateOpenCellLibrary.macro.mod.upper.lef 

export SC_LIB_UPPER  ?= \
$(PLATFORM_DIR)/lib_upper/NangateOpenCellLibrary_typical.upper.lib
export SC_LIB_BOTTOM  ?= \
$(PLATFORM_DIR)/lib_bottom/NangateOpenCellLibrary_typical.bottom.lib

export SC_LIB  ?= $(SC_LIB_BOTTOM) $(SC_LIB_UPPER)

# Unified LEF/LIB list (following Cadence order/naming convention)
export LEF_FILES = $(TECH_LEF) \
                   $(SC_LEF) \
                   $(ADDITIONAL_LEFS)
export LIB_FILES = $(SC_LIB) \
                   $(ADDITIONAL_LIBS)

# Directory/Extracted files (Cadence)
export LIB_DIR ?= $(dir $(SC_LIB))
export LEF_DIR ?= $(dir $(TECH_LEF))
export QRC_FILE ?= $(PLATFORM_DIR)/qrc/NG45.tch

# Layout/GDS (supplement for OpenROAD)
export GDS_FILES = $(sort $(wildcard $(PLATFORM_DIR)/gds/*.gds)) \
                   $(ADDITIONAL_GDS)

# -------- Synthesis / Mapping --------
# Cadence: RTL search path (for Genus); OpenROAD: Yosys/ABC related switches
export RTL_SEARCH_DIRS ?= $(dir $(firstword $(VERILOG_FILES)))

# Yosys/ABC (OpenROAD specific, kept for mixed-flow convenience)
export MAX_UNGROUP_SIZE ?= 10000
export BOTTOM_TIEHI_CELL_AND_PORT = LOGIC1_X1_bottom Z
export BOTTOM_TIELO_CELL_AND_PORT = LOGIC0_X1_bottom Z
export UPPER_TIEHI_CELL_AND_PORT = LOGIC1_X1_upper Z
export UPPER_TIELO_CELL_AND_PORT = LOGIC0_X1_upper Z

export MIN_BUF_CELL_AND_PORTS = BUF_X1_bottom A Z
export LATCH_MAP_FILE    = $(PLATFORM_DIR)/cells_latch.v
export CLKGATE_MAP_FILE  = $(PLATFORM_DIR)/cells_clkgate.v
export ADDER_MAP_FILE   ?= $(PLATFORM_DIR)/cells_adders.v
export ABC_DRIVER_CELL   = BUF_X1_bottom
export ABC_LOAD_IN_FF    = 3.898

# -------- Floorplan --------
export PLACE_SITE   = FreePDK45_38x28_10R_NP_162NW_34O
export IO_PLACER_H ?= M5
export IO_PLACER_V ?= M6
export MAKE_TRACKS ?= $(PLATFORM_DIR)/make_tracks.tcl
# PDN / Endcap / Welltie (based on Cadence)
export PDN_TCL      ?= $(PLATFORM_DIR)/grid_strategy-M1-M4-M7.tcl
export TAPCELL_TCL  ?= $(PLATFORM_DIR)/tapcell.tcl
export TAP_CELL_NAME = TAPCELL_X1_bottom

# -------- Placement --------
export CELL_PAD_IN_SITES_GLOBAL_PLACEMENT ?= 0
export CELL_PAD_IN_SITES_DETAIL_PLACEMENT ?= 0
export PLACE_DENSITY ?= 0.30

# 3D tier-related (based on Cadence structured variables)
export FILL_CELLS_UPPER  ?= FILLCELL_X1_upper  FILLCELL_X2_upper  FILLCELL_X4_upper  \
                             FILLCELL_X8_upper  FILLCELL_X16_upper  FILLCELL_X32_upper
export FILL_CELLS_BOTTOM ?= FILLCELL_X1_bottom FILLCELL_X2_bottom FILLCELL_X4_bottom \
                             FILLCELL_X8_bottom FILLCELL_X16_bottom FILLCELL_X32_bottom
export DONT_USE_CELLS_UPPER  ?= TAPCELL_X1_upper  FILLCELL_X1_upper  AOI211_X1_upper  OAI211_X1_upper
export DONT_USE_CELLS_BOTTOM ?= TAPCELL_X1_bottom FILLCELL_X1_bottom AOI211_X1_bottom OAI211_X1_bottom
export DONT_USE_CELLS = $(DONT_USE_CELLS_UPPER) $(DONT_USE_CELLS_BOTTOM)

# Unified/Derived for Tcl usage
export FILL_CELLS ?= $(FILL_CELLS_BOTTOM)     # For non-tiered/fallback usage
export DNU_FOR_UPPER   := $(DONT_USE_CELLS_UPPER) *_bottom
export DNU_FOR_BOTTOM  := $(DONT_USE_CELLS_BOTTOM)  *_upper

# -------- CTS --------
export CTS_BUF_CELL ?= BUF_X4_bottom

# -------- Route --------
export MIN_ROUTING_LAYER ?= M2
export MAX_ROUTING_LAYER ?= M2_m

# OpenROAD specific script (kept for mixed-flow)
export FASTROUTE_TCL ?= $(PLATFORM_DIR)/fastroute.tcl

# Allow empty GDS cell (Cadence)
export GDS_ALLOW_EMPTY ?= fakeram.*

# -------- Signoff / RCX / IR --------
export CDL_FILE           = $(PLATFORM_DIR)/cdl/NangateOpenCellLibrary.cdl
export TEMPLATE_PGA_CFG  ?= $(PLATFORM_DIR)/template_pga.cfg
export RCX_RULES          = $(PLATFORM_DIR)/NangateOpenCellLibrary.tech21.rcx_patterns.rules

# IR drop settings (consistent for both tiers)
export PWR_NETS_VOLTAGES ?= "VDD 1.1"
export GND_NETS_VOLTAGES ?= "VSS 0.0"
export IR_DROP_LAYER     ?= M1

