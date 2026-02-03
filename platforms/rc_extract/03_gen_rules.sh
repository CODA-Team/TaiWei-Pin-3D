#!/usr/bin/env bash
# ============================================================
# 03_gen_rules.sh
# ------------------------------------------------------------
# Step 3: Use OpenROAD/OpenRCX to:
#   - read TECH_LEF + patterns.def
#   - read golden SPEF
#   - generate RCX rules file (*.rules)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/env.sh"

mkdir -p "${ORD_OUT_DIR}" "${LOG_DIR}"

if [[ ! -x "${OPENROAD_BIN}" ]]; then
  echo "[ERROR] OPENROAD_BIN is not executable: ${OPENROAD_BIN}" >&2
  exit 1
fi

if [[ ! -f "${TCL_GEN_RULES}" ]]; then
  echo "[ERROR] TCL_GEN_RULES not found: ${TCL_GEN_RULES}" >&2
  exit 1
fi

if [[ ! -f "${TECH_LEF}" ]]; then
  echo "[ERROR] TECH_LEF not found: ${TECH_LEF}" >&2
  exit 1
fi

if [[ ! -f "${PATTERN_DEF}" ]]; then
  echo "[ERROR] PATTERN_DEF not found: ${PATTERN_DEF}" >&2
  echo "[ERROR] Please run ./01_gen_patterns.sh first." >&2
  exit 1
fi

if [[ ! -f "${PATTERN_SPEF}" ]]; then
  echo "[ERROR] PATTERN_SPEF not found: ${PATTERN_SPEF}" >&2
  echo "[ERROR] Please run ./02_cds_extract.sh first." >&2
  exit 1
fi

LOG_FILE="${LOG_DIR}/03_gen_rules.log"

echo "[INFO] =================================================="
echo "[INFO] Step 3: OpenROAD / OpenRCX generate RCX rules"
echo "[INFO]   TECH_LEF     = ${TECH_LEF}"
echo "[INFO]   PATTERN_DEF  = ${PATTERN_DEF}"
echo "[INFO]   PATTERN_SPEF = ${PATTERN_SPEF}"
echo "[INFO]   RCX_RULES    = ${RCX_RULES}"
echo "[INFO]   LOG_FILE     = ${LOG_FILE}"
echo "[INFO] =================================================="

"${OPENROAD_BIN}" -threads $NUM_CORES "${TCL_GEN_RULES}" 2>&1 | tee "${LOG_FILE}"

EXT_RULES_SRC="${ORD_OUT_DIR}/extRules"
if [[ -f "${EXT_RULES_SRC}" ]]; then
  mv "${EXT_RULES_SRC}" "${RCX_RULES}"
else 
  echo "[ERROR] External rules file not found: ${EXT_RULES_SRC}" >&2
  echo "[ERROR] Please check log: ${LOG_FILE}" >&2
  exit 1
fi

if [[ ! -f "${RCX_RULES}" ]]; then
  echo "[ERROR] RCX rules file not found: ${RCX_RULES}" >&2
  echo "[ERROR] Please check log: ${LOG_FILE}" >&2
  exit 1
fi

echo "[INFO] Step 3 finished: RCX rules generated"
echo "[INFO]   RCX_RULES = ${RCX_RULES}"