#!/usr/bin/env bash
###
 # @Author: JeanneWillis hi@jeannewillis.cn 
 # @Date: 2026-01-17 18:31:45
 # @LastEditors: JeanneWillis hi@jeannewillis.cn
 # @LastEditTime: 2026-01-18 00:33:57
 # @FilePath: /test/repo/TaiWei/3DEval/env.sh
 # @Description: 3D Evaluation Environment Setup
### 

# ------------------------------------------------------------------------------
# Toolchain paths (override in your shell if needed)
# ------------------------------------------------------------------------------
export FLOW_HOME=$(pwd)
export NUM_CORES="${NUM_CORES:-16}"

# OpenROAD toolchain
export ORFS_DIR="${ORFS_DIR:-../ORFS-Research}"
export OPENROAD_EXE="${OPENROAD_EXE:-${ORFS_DIR}/tools/install/OpenROAD/bin/openroad}"
export YOSYS_EXE="${YOSYS_EXE:-${ORFS_DIR}/tools/install/yosys/bin/yosys}"
export STA_EXE="${STA_EXE:-${ORFS_DIR}/tools/install/OpenROAD/bin/sta}"

# Cadence toolchain
export GENUS_EXE="${GENUS_EXE:-$(which genus)}"
export INNOVUS_EXE="${INNOVUS_EXE:-$(which innovus)}"
GENUS_CMD="${GENUS_EXE} -64 -abort_on_error"
INNOVUS_CMD="${INNOVUS_EXE} -64 -abort_on_error"