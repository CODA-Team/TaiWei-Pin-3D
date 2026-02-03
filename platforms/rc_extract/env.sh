#!/usr/bin/env bash
# ============================================================
# env.sh  - Common environment for 3D RC calibration flow
# ------------------------------------------------------------
# Usage:
#   # 方法1：设置FLOW_VARIANT后source
#   export FLOW_VARIANT="NangateOpenCellLibrary.tech21"
#   source env.sh
#   
#   # 方法2：source时传入参数
#   source env.sh NangateOpenCellLibrary.tech21
# ============================================================

# Project root = directory where this env.sh lives
export PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 支持命令行参数
if [ $# -eq 1 ]; then
    export FLOW_VARIANT="$1"
fi

# 检查FLOW_VARIANT是否设置
if [[ -z "${FLOW_VARIANT:-}" ]]; then
    echo "Error: FLOW_VARIANT is not set. Please set it or pass it as an argument." >&2
    echo "Usage: export FLOW_VARIANT=<tech> && source env.sh" >&2
    echo "   or: source env.sh <tech>" >&2
    return 1 2>/dev/null || exit 1
fi

# ----------------- Tool binaries -----------------------------
export OPENROAD_BIN=/scripts/ORFS-Research/tools/install/OpenROAD/bin/openroad
export CDS_BIN=$(which innovus)
export NUM_CORES=16
export CDS_RC_SETUP_TCL=""

# ----------------- Tcl scripts -------------------------------
export TCL_GEN_PATTERNS="$PROJ_ROOT/script/01_gen_patterns.tcl"
export TCL_CDS_EXTRACT="$PROJ_ROOT/script/02_cds_extract.tcl"
export TCL_GEN_RULES="$PROJ_ROOT/script/03_ord_gen_rules.tcl"

# ----------------- 基于FLOW_VARIANT的路径 -----------------------
export TECH_LEF="$PROJ_ROOT/input/${FLOW_VARIANT}.lef"
export RCX_RULES="$PROJ_ROOT/output/${FLOW_VARIANT}.rcx_patterns.rules"

# ----------------- Work / output paths -----------------------
export WORK_DIR="$PROJ_ROOT/work/$FLOW_VARIANT"
export CDS_OUT_DIR="$WORK_DIR/cds"
export ORD_OUT_DIR="$WORK_DIR/ord"
export LOG_DIR="$WORK_DIR/log"

export PATTERN_DEF="$WORK_DIR/patterns.def"
export PATTERN_V="$WORK_DIR/patterns.v"
export PATTERN_SPEF="$CDS_OUT_DIR/patterns.spef"

# 创建目录
mkdir -p "$WORK_DIR" "$CDS_OUT_DIR" "$ORD_OUT_DIR" "$LOG_DIR"

# 打印配置信息（可选）
echo "[ENV] Config loaded: FLOW_VARIANT=$FLOW_VARIANT" >&2