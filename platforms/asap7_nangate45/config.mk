# =====================================================
# Platform / Process
# =====================================================
export PROCESS                  = 45

# =====================================================
# Tech / LEF / LIB (aggregation-friendly)
# =====================================================
export TECH_LEF                 = $(PLATFORM_DIR)/lef/NangateOpenCellLibrary.tech.lef
export SC_LEF                   = $(PLATFORM_DIR)/lef/NangateOpenCellLibrary.macro.mod.processed.lef

export LIB_FILES               ?= $(PLATFORM_DIR)/lib/NangateOpenCellLibrary_typical.processed.lib $(ADDITIONAL_LIBS)
export LEF_FILES               ?= $(TECH_LEF) $(SC_LEF) $(ADDITIONAL_LEFS)

# 目录便捷变量
export LIB_DIR                 ?= $(PLATFORM_DIR)/lib
export LEF_DIR                 ?= $(dir $(TECH_LEF))

# QRC（可选）
export QRC_FILE                ?= $(PLATFORM_DIR)/qrc/NG45.tch
export SET_RC_TCL               ?= $(PLATFORM_DIR)/setRC.tcl
# =====================================================
# GDS
# =====================================================
export GDS_FILES                = $(sort $(wildcard $(PLATFORM_DIR)/gds/*.gds))
export GDS_FILES               += $(ADDITIONAL_GDS)
export GDS_ALLOW_EMPTY         ?= fakeram.*

# =====================================================
# Synthesis / Yosys
# =====================================================
export RTL_SEARCH_DIRS         ?= $(dir $(firstword $(VERILOG_FILES)))
export MAX_UNGROUP_SIZE        ?= 10000

# 常量单元
export TIEHI_CELL_AND_PORT      = LOGIC1_X1 Z
export TIELO_CELL_AND_PORT      = LOGIC0_X1 Z

# 缓冲单元
export MIN_BUF_CELL_AND_PORTS   = BUF_X1 A Z
export ABC_DRIVER_CELL          = BUF_X1
export ABC_LOAD_IN_FF           = 3.898

# 映射文件
export LATCH_MAP_FILE           = $(PLATFORM_DIR)/cells_latch.v
export CLKGATE_MAP_FILE         = $(PLATFORM_DIR)/cells_clkgate.v
export ADDER_MAP_FILE          ?= $(PLATFORM_DIR)/cells_adders.v

# 不使用的单元 & 填充单元
export DONT_USE_CELLS           = TAPCELL_X1 FILLCELL_X1 AOI211_X1 OAI211_X1
export FILL_CELLS               = FILLCELL_X1 FILLCELL_X2 FILLCELL_X4 FILLCELL_X8 FILLCELL_X16 FILLCELL_X32

# =====================================================
# Floorplan
# =====================================================
export PLACE_SITE               = FreePDK45_38x28_10R_NP_162NW_34O
export IO_PLACER_H              = M5
export IO_PLACER_V              = M6
export PAR_BAL_LO ?= 1.0
export PAR_BAL_HI ?= 6.0
export PAR_SCALE_FACTOR ?= 0.06 0.94
export PAR_BAL_ITERATION ?= 11
# PDN
export PDN_TCL                 ?= $(PLATFORM_DIR)/grid_strategy-M1-M4-M7.tcl
export TAPCELL_TCL              = $(PLATFORM_DIR)/tapcell.tcl

# 宏块留白
export MACRO_PLACE_HALO        ?= 22.4 15.12
export MACRO_PLACE_CHANNEL     ?= 18.8 19.95

# =====================================================
# Place
# =====================================================
export PLACE_DENSITY           ?= 0.30
export CELL_PAD_IN_SITES_GLOBAL_PLACEMENT ?= 0
export CELL_PAD_IN_SITES_DETAIL_PLACEMENT ?= 0

# =====================================================
# CTS
# =====================================================
export CTS_BUF_CELL            ?= BUF_X4

# =====================================================
# Route
# =====================================================
export MIN_ROUTING_LAYER        = M2
export MAX_ROUTING_LAYER        = M10
export FASTROUTE_TCL           ?= $(PLATFORM_DIR)/fastroute.tcl

# =====================================================
# KLayout (tech/DRC/LVS)
# =====================================================
export KLAYOUT_TECH_FILE        = $(PLATFORM_DIR)/FreePDK45.lyt
export KLAYOUT_DRC_FILE         = $(PLATFORM_DIR)/drc/FreePDK45.lydrc
export KLAYOUT_LVS_FILE         = $(PLATFORM_DIR)/lvs/FreePDK45.lylvs

# =====================================================
# Netlist / PG analysis (optional)
# =====================================================
export CDL_FILE                 = $(PLATFORM_DIR)/cdl/NangateOpenCellLibrary.cdl
export TEMPLATE_PGA_CFG        ?= $(PLATFORM_DIR)/template_pga.cfg

# =====================================================
# RC / Extraction
# =====================================================
export RCX_RULES                = $(PLATFORM_DIR)/rcx_patterns.rules

# =====================================================
# IR Drop
# =====================================================
# 多电源示例："VDD1 1.8 VDD2 1.2"
export PWR_NETS_VOLTAGES       ?= "VDD 1.1"
export GND_NETS_VOLTAGES       ?= "VSS 0.0"
export IR_DROP_LAYER           ?= M1
