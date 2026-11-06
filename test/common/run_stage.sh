#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  cat >&2 <<'EOF'
Usage: test/common/run_stage.sh <enablement> <flow_variant> <use_flow> <design_nickname> <make_target>

Arguments:
  enablement      Platform / enablement directory under designs/.
  flow_variant    Flow variant name used for logs/results/objects/reports.
  use_flow        Flow selector: openroad or cadence.
  design_nickname Design nickname under designs/<enablement>/.
  make_target     Single make target to run, such as ord-pre or cds-final.

Notes:
  - This wrapper runs exactly one make target.
  - 3D-Syn and *-3d-flow-2dpart targets automatically use config2d.mk.
  - All other targets use config.mk.
EOF
  exit 1
fi

ENABLEMENT="$1"
FLOW_VARIANT="$2"
USE_FLOW="$3"
DESIGN_NICKNAME="$4"
MAKE_TARGET="$5"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_ROOT="${SCRIPT_DIR}"
while [[ "${FLOW_ROOT}" != "/" && ! -f "${FLOW_ROOT}/env.sh" ]]; do
  FLOW_ROOT="$(dirname "${FLOW_ROOT}")"
done

if [[ ! -f "${FLOW_ROOT}/env.sh" ]]; then
  echo "ERROR: env.sh not found for ${SCRIPT_DIR}" >&2
  exit 1
fi

cd "${FLOW_ROOT}"

DESIGN_CONFIG_3D="designs/${ENABLEMENT}/${DESIGN_NICKNAME}/config.mk"
DESIGN_CONFIG_2D="designs/${ENABLEMENT}/${DESIGN_NICKNAME}/config2d.mk"

if [[ ! -f "${FLOW_ROOT}/${DESIGN_CONFIG_3D}" ]]; then
  echo "ERROR: missing design config ${DESIGN_CONFIG_3D}" >&2
  exit 1
fi

if [[ ! -f "${FLOW_ROOT}/${DESIGN_CONFIG_2D}" ]]; then
  echo "ERROR: missing design config ${DESIGN_CONFIG_2D}" >&2
  exit 1
fi

export NUM_CORES="${NUM_CORES:-16}"
source "${FLOW_ROOT}/env.sh"

export DESIGN_DIMENSION="3D"
export DESIGN_NICKNAME
export FLOW_VARIANT
export USE_FLOW
export LOG_DIR="./logs/${ENABLEMENT}/${DESIGN_NICKNAME}/${FLOW_VARIANT}"
export OBJECTS_DIR="./objects/${ENABLEMENT}/${DESIGN_NICKNAME}/${FLOW_VARIANT}"
export REPORTS_DIR="./reports/${ENABLEMENT}/${DESIGN_NICKNAME}/${FLOW_VARIANT}"
export RESULTS_DIR="./results/${ENABLEMENT}/${DESIGN_NICKNAME}/${FLOW_VARIANT}"

select_design_config() {
  case "$1" in
    ord-3d-synth|cds-coarse-synth|ord-coarse-partition|cds-coarse-partition|cds-per-tier-synth|ord-3dsyn-handoff|cds-3dsyn-handoff|ord-3d-flow-2dpart|cds-3d-flow-2dpart|ord-tier-partition|cds-tier-partition)
      echo "${DESIGN_CONFIG_2D}"
      ;;
    *)
      echo "${DESIGN_CONFIG_3D}"
      ;;
  esac
}

DESIGN_CONFIG_SELECTED="$(select_design_config "${MAKE_TARGET}")"

echo "[run] enablement=${ENABLEMENT}"
echo "[run] design=${DESIGN_NICKNAME}"
echo "[run] use_flow=${USE_FLOW}"
echo "[run] flow_variant=${FLOW_VARIANT}"
echo "[run] make_target=${MAKE_TARGET}"
echo "[run] design_config=${DESIGN_CONFIG_SELECTED}"
echo "[run] PIN3D_ALLOW_NET_FLOW=${PIN3D_ALLOW_NET_FLOW:-on}"
echo "[run] PIN3D_SPLIT_NET_FLOW=${PIN3D_SPLIT_NET_FLOW:-on}"

exec make DESIGN_CONFIG="${DESIGN_CONFIG_SELECTED}" "${MAKE_TARGET}"
