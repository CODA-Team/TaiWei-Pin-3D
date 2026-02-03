#!/usr/bin/env bash
# ============================================================
# 01_gen_patterns.sh
# ------------------------------------------------------------
# Step 1: Use OpenROAD/OpenRCX to generate:
#   - patterns.def
#   - patterns.v
# based on the 3D tech LEF.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/env.sh"

if [[ ! -x "${OPENROAD_BIN}" ]]; then
  echo "[ERROR] OPENROAD_BIN is not executable: ${OPENROAD_BIN}" >&2
  exit 1
fi

if [[ ! -f "${TCL_GEN_PATTERNS}" ]]; then
  echo "[ERROR] TCL_GEN_PATTERNS not found: ${TCL_GEN_PATTERNS}" >&2
  exit 1
fi

if [[ ! -f "${TECH_LEF}" ]]; then
  echo "[ERROR] TECH_LEF not found: ${TECH_LEF}" >&2
  exit 1
fi

LOG_FILE="${LOG_DIR}/01_gen_patterns.log"

echo "[INFO] =================================================="
echo "[INFO] Step 1: Generate bench patterns (DEF + Verilog)"
echo "[INFO]   TECH_LEF    = ${TECH_LEF}"
echo "[INFO]   PATTERN_DEF = ${PATTERN_DEF}"
echo "[INFO]   PATTERN_V   = ${PATTERN_V}"
echo "[INFO]   LOG_FILE    = ${LOG_FILE}"
echo "[INFO] =================================================="

"${OPENROAD_BIN}" -threads $NUM_CORES "${TCL_GEN_PATTERNS}" 2>&1 | tee "${LOG_FILE}"

if [[ ! -f "${PATTERN_DEF}" || ! -f "${PATTERN_V}" ]]; then
  echo "[ERROR] Pattern generation failed. Check log: ${LOG_FILE}" >&2
  exit 1
fi

echo "[INFO] Step 1 finished: patterns generated successfully."
echo "[INFO]   DEF = ${PATTERN_DEF}"
echo "[INFO]   V   = ${PATTERN_V}"
