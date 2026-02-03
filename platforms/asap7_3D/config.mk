# =========================================
# tech config.mk  (asap7_3D, fixed RVT / NLDM / BC)
# =========================================

# -------- Process --------
export PROCESS ?= 7

# -------- Tech / Libs --------
ifeq ($(USE_FLOW),openroad)
  export TECH_LEF  ?= $(PLATFORM_DIR)/lef/asap7_tech_1x_2A6M7M.lef
  export RCX_RULES         ?= $(PLATFORM_DIR)/asap7_tech_1x_2A6M7M.rcx_patterns.rules
  export MIN_ROUTING_LAYER ?= M2
  export MAX_ROUTING_LAYER ?= M3_add
  export SET_RC_TCL               ?= $(PLATFORM_DIR)/setRC_2A6M7M.tcl
endif
export MIN_CLK_ROUTING_LAYER ?= M2
export TECH_LEF  ?= $(PLATFORM_DIR)/lef/asap7_tech_1x_6M7M.lef
export RCX_RULES         ?= $(PLATFORM_DIR)/asap7_tech_1x_6M7M.rcx_patterns.rules
export SET_RC_TCL               ?= $(PLATFORM_DIR)/setRC_6M7M.tcl
# export MAKE_TRACKS       ?= $(PLATFORM_DIR)/make_tracks_cds.tcl
# 标准单元 LEF（分层）
export SC_LEF    ?= \
  $(PLATFORM_DIR)/lef_bottom/asap7sc7p5t_28_R_1x_220121a.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.lef

# NLDM/FF/RVT 库（bottom 层；可按需在 lib_upper 下放置同名 upper 库）
export SC_LIB_UPPER ?= \
  $(PLATFORM_DIR)/lib_upper/NLDM/asap7sc7p5t_AO_RVT_FF_nldm_211120.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/asap7sc7p5t_OA_RVT_FF_nldm_211120.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/asap7sc7p5t_SEQ_RVT_FF_nldm_220123.upper.lib
export SC_LIB_BOTTOM ?= \
  $(PLATFORM_DIR)/lib_bottom/NLDM/asap7sc7p5t_AO_RVT_FF_nldm_211120.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/asap7sc7p5t_OA_RVT_FF_nldm_211120.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/asap7sc7p5t_SEQ_RVT_FF_nldm_220123.bottom.lib

export SC_LIB    ?= $(SC_LIB_BOTTOM) $(SC_LIB_UPPER)

# Unified LEF/LIB list
export LEF_FILES = $(TECH_LEF) \
                   $(SC_LEF) \
                   $(ADDITIONAL_LEFS)
export LIB_FILES = $(SC_LIB) \
                   $(ADDITIONAL_LIBS)

# 目录/抽取（保持与 45_3D 模板一致）
export LIB_DIR  ?= $(dir $(SC_LIB))
export LEF_DIR  ?= $(dir $(TECH_LEF))
export QRC_FILE ?= $(PLATFORM_DIR)/qrc/ASAP7.tch

# Layout/GDS
export GDS_FILES = $(sort $(wildcard $(PLATFORM_DIR)/gds/*.gds)) \
                   $(ADDITIONAL_GDS)
export GDS_ALLOW_EMPTY ?= fakeram.*

# -------- Synthesis / Mapping --------
# RTL 搜索路径（OpenROAD/Yosys & Cadence/Genus 通用）
export RTL_SEARCH_DIRS ?= $(dir $(firstword $(VERILOG_FILES)))

# Yosys/ABC（便于混合流程）
export MAX_UNGROUP_SIZE ?= 10000

# 分层常量单元（upper / bottom）
export BOTTOM_TIEHI_CELL_AND_PORT = TIEHIx1_ASAP7_75t_R_bottom H
export BOTTOM_TIELO_CELL_AND_PORT = TIELOx1_ASAP7_75t_R_bottom L
export UPPER_TIEHI_CELL_AND_PORT  = TIEHIx1_ASAP7_75t_R_upper  H
export UPPER_TIELO_CELL_AND_PORT  = TIELOx1_ASAP7_75t_R_upper  L

# Yosys 驱动/缓冲（以 bottom 为主跑一个 tier 的场景）
export MIN_BUF_CELL_AND_PORTS = BUFx2_ASAP7_75t_R_bottom A Y
export ABC_DRIVER_CELL        = BUFx2_ASAP7_75t_R_bottom
export ABC_LOAD_IN_FF         = 3.898

# 映射文件（可复用 2D 的 RTL 映射，或准备分层版）
export LATCH_MAP_FILE   = $(PLATFORM_DIR)/yoSys/cells_latch_R.v
export CLKGATE_MAP_FILE = $(PLATFORM_DIR)/yoSys/cells_clkgate_R.v
export ADDER_MAP_FILE  ?= $(PLATFORM_DIR)/yoSys/cells_adders_R.v

# -------- Floorplan --------
export PLACE_SITE   = asap7sc7p5t
# export IO_PLACER_H ?= M4
# export IO_PLACER_V ?= M5
export IO_PLACER_H ?= M4
export IO_PLACER_V ?= M3
# PDN / Endcap / Welltie（3D 策略）
export PDN_TCL      ?= $(PLATFORM_DIR)/openRoad/pdn/grid_strategy-M1-M2-M5-M6.tcl
export TAPCELL_TCL  ?= $(PLATFORM_DIR)/tapcell.tcl
export TAP_CELL_NAME = TAPCELL_ASAP7_75t_R_bottom
export MAKE_TRACKS       ?= $(PLATFORM_DIR)/openRoad/make_tracks.tcl

# -------- Placement --------
export CELL_PAD_IN_SITES_GLOBAL_PLACEMENT ?= 0
export CELL_PAD_IN_SITES_DETAIL_PLACEMENT ?= 0
export PLACE_DENSITY ?= 0.60

# 3D 分层填充/屏蔽
export FILL_CELLS_UPPER  ?= FILLERxp5_ASAP7_75t_R_upper FILLER_ASAP7_75t_R_upper \
                            DECAPx1_ASAP7_75t_R_upper   DECAPx2_ASAP7_75t_R_upper \
                            DECAPx4_ASAP7_75t_R_upper   DECAPx6_ASAP7_75t_R_upper \
                            DECAPx10_ASAP7_75t_R_upper
export FILL_CELLS_BOTTOM ?= FILLERxp5_ASAP7_75t_R_bottom FILLER_ASAP7_75t_R_bottom \
                            DECAPx1_ASAP7_75t_R_bottom   DECAPx2_ASAP7_75t_R_bottom \
                            DECAPx4_ASAP7_75t_R_bottom   DECAPx6_ASAP7_75t_R_bottom \
                            DECAPx10_ASAP7_75t_R_bottom

export DONT_USE_CELLS_UPPER  ?= *x1p*_ASAP7*_upper *xp*_ASAP7*_upper SDF*_upper ICG*_upper
export DONT_USE_CELLS_BOTTOM ?= *x1p*_ASAP7*_bottom *xp*_ASAP7*_bottom SDF*_bottom ICG*_bottom
export DONT_USE_CELLS = $(DONT_USE_CELLS_UPPER) $(DONT_USE_CELLS_BOTTOM)

# Tcl 统一/派生
export FILL_CELLS ?= $(FILL_CELLS_BOTTOM)   # 非分层/回退场景
export DNU_FOR_UPPER   := $(DONT_USE_CELLS_UPPER) *_bottom
export DNU_FOR_BOTTOM  := $(DONT_USE_CELLS_BOTTOM)  *_upper

# -------- CTS --------
export CTS_BUF_CELL ?= BUFx8_ASAP7_75t_R_bottom

# -------- Route --------
export MIN_ROUTING_LAYER ?= M2
export MAX_ROUTING_LAYER ?= M2_m
export FASTROUTE_TCL     ?= $(PLATFORM_DIR)/fastroute.tcl

# -------- Signoff / RCX / IR --------
export CDL_FILE           ?=
export TEMPLATE_PGA_CFG  ?= $(PLATFORM_DIR)/template_pga.cfg
export RCX_RULES          = $(PLATFORM_DIR)/asap7_tech_1x_9M10M.rcx_patterns.rules

# IR drop（两层同电压；如需区分 T1/T2，可改为 "VDD_T1 0.77 VDD_T2 0.77"）
export PWR_NETS_VOLTAGES ?= "VDD 0.77"
export GND_NETS_VOLTAGES ?= "VSS 0.0"
export IR_DROP_LAYER     ?= M1
