# =====================================================
# Platform / Process
# =====================================================
export PLATFORM                  = asap7
export PROCESS                   ?= 7

# =====================================================
# Tech / LEF / LIB (aggregation-friendly)
# =====================================================
# Tech LEF
export TECH_LEF                  ?= $(PLATFORM_DIR)/lef/asap7_tech_1x_201209.lef
# Standard-cell LEF (fixed RVT -> tag "R")
export SC_LEF                    ?= $(PLATFORM_DIR)/lef/asap7sc7p5t_28_R_1x_220121a.lef

# Library root (fixed NLDM)
export LIB_DIR                   = $(PLATFORM_DIR)/lib/NLDM

# Liberty set (fixed BC/FF, NLDM, RVT)
export LIB_FILES                ?= \
  $(LIB_DIR)/asap7sc7p5t_AO_RVT_FF_nldm_211120.lib \
  $(LIB_DIR)/asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.lib \
  $(LIB_DIR)/asap7sc7p5t_OA_RVT_FF_nldm_211120.lib \
  $(LIB_DIR)/asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.lib \
  $(LIB_DIR)/asap7sc7p5t_SEQ_RVT_FF_nldm_220123.lib \
  $(ADDITIONAL_LIBS)

# Aggregate LEF list
export LEF_FILES                ?= $(TECH_LEF) $(SC_LEF) $(ADDITIONAL_LEFS)

# Convenience dirs
export LEF_DIR                  ?= $(dir $(TECH_LEF))

# Optional QRC
export QRC_FILE                 ?= $(PLATFORM_DIR)/qrc/ASAP7.tch
export SET_RC_TCL               ?= $(PLATFORM_DIR)/setRC.tcl
# =====================================================
# GDS
# =====================================================
# GDS uses RVT tag "R"
export GDS_FILES                 = $(PLATFORM_DIR)/gds/asap7sc7p5t_28_R_220121a.gds
export GDS_FILES                += $(ADDITIONAL_GDS)
export GDS_ALLOW_EMPTY          ?= fakeram.*

# =====================================================
# Synthesis / Yosys
# =====================================================
export RTL_SEARCH_DIRS          ?= $(dir $(firstword $(VERILOG_FILES)))
export MAX_UNGROUP_SIZE         ?= 10000

# Constant cells
export TIEHI_CELL_AND_PORT       = TIEHIx1_ASAP7_75t_R H
export TIELO_CELL_AND_PORT       = TIELOx1_ASAP7_75t_R L

# Buffer cells
export MIN_BUF_CELL_AND_PORTS    = BUFx2_ASAP7_75t_R A Y
export ABC_DRIVER_CELL           = BUFx2_ASAP7_75t_R
export ABC_LOAD_IN_FF            = 3.898

# Mapping files
export LATCH_MAP_FILE           ?= $(PLATFORM_DIR)/yoSys/cells_latch_R.v
export CLKGATE_MAP_FILE         ?= $(PLATFORM_DIR)/yoSys/cells_clkgate_R.v
export ADDER_MAP_FILE           ?= $(PLATFORM_DIR)/yoSys/cells_adders_R.v

# Do-not-use and filler cells
export DONT_USE_CELLS            = *x1p*_ASAP7* *xp*_ASAP7* SDF* ICG*
export FILL_CELLS                = \
  FILLERxp5_ASAP7_75t_R \
  FILLER_ASAP7_75t_R \
  DECAPx1_ASAP7_75t_R \
  DECAPx2_ASAP7_75t_R \
  DECAPx4_ASAP7_75t_R \
  DECAPx6_ASAP7_75t_R \
  DECAPx10_ASAP7_75t_R

# TAP cell
export TAP_CELL_NAME            ?= TAPCELL_ASAP7_75t_R

# =====================================================
# Floorplan
# =====================================================
export PLACE_SITE                = asap7sc7p5t
export IO_PLACER_H               = M4
export IO_PLACER_V               = M5
export PAR_BAL_LO ?= 1.0
export PAR_BAL_HI ?= 6.0
export PAR_BAL_ITERATION ?= 11
# PDN (fixed default strategy)
export PDN_TCL                  ?= $(PLATFORM_DIR)/openRoad/pdn/grid_strategy-M1-M2-M5-M6.tcl
export TAPCELL_TCL              ?= $(PLATFORM_DIR)/openRoad/tapcell.tcl
export MAKE_TRACKS             ?= $(PLATFORM_DIR)/openRoad/make_tracks.tcl
export SET_RC_TCL               ?= $(PLATFORM_DIR)/setRC.tcl

# =====================================================
# Place
# =====================================================
export PLACE_DENSITY            ?= 0.60
export CELL_PAD_IN_SITES_GLOBAL_PLACEMENT ?= 0
export CELL_PAD_IN_SITES_DETAIL_PLACEMENT ?= 0

# =====================================================
# CTS
# =====================================================
export CTS_BUF_CELL             ?= BUFx8_ASAP7_75t_R
export MIN_CLK_ROUTING_LAYER = M2
# =====================================================
# Route
# =====================================================
export MIN_ROUTING_LAYER         = M2
export MAX_ROUTING_LAYER         = M7
export FASTROUTE_TCL            ?= $(PLATFORM_DIR)/fastroute.tcl

# =====================================================
# KLayout (tech/DRC/LVS)
# =====================================================
export KLAYOUT_TECH_FILE         = $(PLATFORM_DIR)/KLayout/asap7.lyt
export KLAYOUT_DRC_FILE          = $(PLATFORM_DIR)/drc/asap7.lydrc
export KLAYOUT_LVS_FILE         ?=

# =====================================================
# Netlist / PG analysis (optional)
# =====================================================
export CDL_FILE                 ?=
export TEMPLATE_PGA_CFG         ?= $(PLATFORM_DIR)/template_pga.cfg

# =====================================================
# RC / Extraction
# =====================================================
export RCX_RULES                 = $(PLATFORM_DIR)/rcx_patterns.rules

# =====================================================
# IR Drop
# =====================================================
# Fixed BC supply (0.77V); edit if your testcase uses a different VDD.
export PWR_NETS_VOLTAGES        ?= "VDD 0.77"
export GND_NETS_VOLTAGES        ?= "VSS 0.0"
export IR_DROP_LAYER            ?= M1

# =====================================================
# Optional: Multi-bit FF support
# =====================================================
ifeq ($(CLUSTER_FLOPS),1)
  export ADDITIONAL_LIBS        += \
    $(LIB_DIR)/asap7sc7p5t_DFFHQNH2V2X_RVT_TT_nldm_FAKE.lib \
    $(LIB_DIR)/asap7sc7p5t_DFFHQNV2X_RVT_TT_nldm_FAKE.lib
  export ADDITIONAL_LEFS        += \
    $(PLATFORM_DIR)/lef/asap7sc7p5t_DFFHQNH2V2X.lef \
    $(PLATFORM_DIR)/lef/asap7sc7p5t_DFFHQNV2X.lef
  export ADDITIONAL_SITES       += asap7sc7p5t_pg
  export GDS_ALLOW_EMPTY        += DFFHQN[VH][24].*
endif
