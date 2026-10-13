#!/usr/bin/env bash
# Usage: ./scripts_3dsyn/run_3d_syn.sh <platform_3d> <design> [flow_variant]
# Example: ./scripts_3dsyn/run_3d_syn.sh asap7_3D gcd 0826_3dsyn_gcd

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <platform_3d> <design> [flow_variant]" >&2
  exit 2
fi

# Target case and output variant.
PLATFORM_3D="$1"
DESIGN="$2"
FLOW_VARIANT="${3:-3dsyn}"

# Parallel worker count.
NUM_CORES="${NUM_CORES:-16}"

# Physical backend: cds or ord.
SYN3D_BACKEND="${SYN3D_BACKEND:-cds}"

# Coarse-unit recognition: all, arithmetic, multibit_ff, or none.
SYN3D_COARSE_UNIT_KEEP_MODE="${SYN3D_COARSE_UNIT_KEEP_MODE:-all}"

# HBT model: scale or direct.
SYN3D_HBT_MODEL_MODE="${SYN3D_HBT_MODEL_MODE:-scale}"

# Scale-mode HBT parameters.
SYN3D_HBT_R_SCALE="${SYN3D_HBT_R_SCALE:-0}"
SYN3D_HBT_C_SCALE="${SYN3D_HBT_C_SCALE:-0.25}"

# Direct-mode HBT parameters.
SYN3D_HBT_R_OHM="${SYN3D_HBT_R_OHM:-}"
SYN3D_HBT_C_FF="${SYN3D_HBT_C_FF:-}"

# Backend preplace optimization: 0 disables it; 1 enables it.
SYN3D_BACKEND_PREPLACE_OPT="${SYN3D_BACKEND_PREPLACE_OPT:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DESIGN_CONFIG="designs/${PLATFORM_3D}/${DESIGN}/config2d.mk"

fail() {
  echo "[3D-Syn] ERROR: $*" >&2
  exit 1
}

require_safe_token() {
  local name="$1"
  local value="$2"
  [[ -n "${value}" && "${value}" =~ ^[A-Za-z0-9_.-]+$ ]] || \
    fail "${name} contains unsupported characters: ${value}"
}

require_positive_integer() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || fail "${name} must be a positive integer: ${value}"
}

require_nonnegative_number() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] || \
    fail "${name} must be a non-negative number: ${value}"
}

require_safe_token PLATFORM_3D "${PLATFORM_3D}"
require_safe_token DESIGN "${DESIGN}"
require_safe_token FLOW_VARIANT "${FLOW_VARIANT}"
require_positive_integer NUM_CORES "${NUM_CORES}"

[[ "${PLATFORM_3D}" == *_3D ]] || fail "platform must use a *_3D name: ${PLATFORM_3D}"
[[ -f "${FLOW_ROOT}/${DESIGN_CONFIG}" ]] || fail "design config is unavailable: ${DESIGN_CONFIG}"

case "${SYN3D_BACKEND}" in
  cds)
    USE_FLOW="cadence"
    ;;
  ord)
    USE_FLOW="openroad"
    ;;
  *) fail "SYN3D_BACKEND must be cds or ord: ${SYN3D_BACKEND}" ;;
esac

case "${SYN3D_COARSE_UNIT_KEEP_MODE}" in
  all|arithmetic|multibit_ff|none) ;;
  *) fail "unsupported coarse-unit recognition mode: ${SYN3D_COARSE_UNIT_KEEP_MODE}" ;;
esac

case "${SYN3D_HBT_MODEL_MODE}" in
  scale)
    [[ -z "${SYN3D_HBT_R_OHM}" && -z "${SYN3D_HBT_C_FF}" ]] || \
      fail "direct R/C values require SYN3D_HBT_MODEL_MODE=direct"
    require_nonnegative_number SYN3D_HBT_R_SCALE "${SYN3D_HBT_R_SCALE}"
    require_nonnegative_number SYN3D_HBT_C_SCALE "${SYN3D_HBT_C_SCALE}"
    ;;
  direct)
    [[ -n "${SYN3D_HBT_R_OHM}" && -n "${SYN3D_HBT_C_FF}" ]] || \
      fail "direct mode requires SYN3D_HBT_R_OHM and SYN3D_HBT_C_FF"
    require_nonnegative_number SYN3D_HBT_R_OHM "${SYN3D_HBT_R_OHM}"
    require_nonnegative_number SYN3D_HBT_C_FF "${SYN3D_HBT_C_FF}"
    ;;
  *) fail "unsupported HBT model mode: ${SYN3D_HBT_MODEL_MODE}" ;;
esac

case "${SYN3D_BACKEND_PREPLACE_OPT}" in
  0|1) ;;
  *) fail "SYN3D_BACKEND_PREPLACE_OPT must be 0 or 1" ;;
esac

cd "${FLOW_ROOT}"
export USE_FLOW
# shellcheck source=/dev/null
source "${FLOW_ROOT}/env.sh"

export PLATFORM_3D DESIGN FLOW_VARIANT DESIGN_CONFIG NUM_CORES SYN3D_BACKEND
export SYN3D_COARSE_UNIT_KEEP_MODE
export SYN3D_HBT_MODEL_MODE SYN3D_HBT_R_SCALE SYN3D_HBT_C_SCALE
export SYN3D_HBT_R_OHM SYN3D_HBT_C_FF SYN3D_BACKEND_PREPLACE_OPT

run_stage() {
  local index="$1"
  local target="$2"
  echo "[3D-Syn] [${index}/4] ${target}"
  make DESIGN_CONFIG="${DESIGN_CONFIG}" FLOW_VARIANT="${FLOW_VARIANT}" "${target}"
}

echo "[3D-Syn] platform=${PLATFORM_3D} design=${DESIGN} variant=${FLOW_VARIANT} backend=${SYN3D_BACKEND}"
echo "[3D-Syn] HBT mode=${SYN3D_HBT_MODEL_MODE} preplace_opt=${SYN3D_BACKEND_PREPLACE_OPT}"

run_stage 1 cds-coarse-synth
run_stage 2 "${SYN3D_BACKEND}-coarse-partition"
run_stage 3 cds-per-tier-synth
run_stage 4 "${SYN3D_BACKEND}-3dsyn-handoff"

echo "[3D-Syn] Completed ${PLATFORM_3D}/${DESIGN} (${FLOW_VARIANT})"
