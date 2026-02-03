#!/usr/bin/env bash
# ============================================================
# 02_cds_extract.sh
# ------------------------------------------------------------
# Step 2: Run commercial RC extraction (Cadence / Synopsys /
# Siemens, etc.) on the generated patterns to produce:
#   - patterns.spef (golden SPEF)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/env.sh"

mkdir -p "${CDS_OUT_DIR}" "${LOG_DIR}"

# Ensure patterns from Step 1 exist
if [[ ! -f "${PATTERN_DEF}" || ! -f "${PATTERN_V}" ]]; then
  echo "[ERROR] PATTERN_DEF or PATTERN_V not found." >&2
  echo "[ERROR] Please run ./01_gen_patterns.sh first." >&2
  exit 1
fi

if [[ ! -x "${CDS_BIN}" ]]; then
  echo "[ERROR] CDS_BIN is not executable: ${CDS_BIN}" >&2
  exit 1
fi

if [[ ! -f "${TCL_CDS_EXTRACT}" ]]; then
  echo "[ERROR] TCL_CDS_EXTRACT not found: ${TCL_CDS_EXTRACT}" >&2
  exit 1
fi

LOG_FILE="${LOG_DIR}/02_cds_extract.log"

echo "[INFO] =================================================="
echo "[INFO] Step 2: Commercial RC extraction"
echo "[INFO]   PATTERN_DEF  = ${PATTERN_DEF}"
echo "[INFO]   PATTERN_V    = ${PATTERN_V}"
echo "[INFO]   PATTERN_SPEF = ${PATTERN_SPEF}"
echo "[INFO]   LOG_FILE     = ${LOG_FILE}"
echo "[INFO] =================================================="

# Example command line for a Cadence tool (Innovus/Quantus):
#   ${CDS_BIN} -no_gui -init ${TCL_CDS_EXTRACT} -log ${LOG_FILE}
#
# For other tools (StarRC, Calibre xRC), adjust the CLI below.

"${CDS_BIN}" -64 -overwrite -no_gui -init "${TCL_CDS_EXTRACT}" -log "${LOG_FILE}"

if [[ ! -f "${PATTERN_SPEF}" ]]; then
  echo "[ERROR] Expected SPEF not found: ${PATTERN_SPEF}" >&2
  echo "[ERROR] Please check log file: ${LOG_FILE}" >&2
  exit 1
fi

echo "[INFO] Step 2 finished: golden SPEF generated."
echo "[INFO]   SPEF = ${PATTERN_SPEF}"
