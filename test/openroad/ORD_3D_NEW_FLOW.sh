#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  cat >&2 <<'EOF'
Usage: test/openroad/ORD_3D_NEW_FLOW.sh <enablement> <flow_variant> <use_flow> <design_nickname>

Arguments:
  enablement      Platform / enablement directory under designs/, such as asap7_3D or nangate45_3D
  flow_variant    Flow variant name used for logs/results/objects/reports
  use_flow        Flow selector. This launcher currently supports openroad only
  design_nickname Design nickname under designs/<enablement>/

Optional environment variables:
  SKIP_2D_PART=1          Skip clean_all and ord-3d-flow-2dpart
  REUSE_2DPART_FROM_VARIANT=<variant>
                          Copy 1_synth.sdc, 2_2_floorplan_io.def/.v, and
                          partition artifacts from an existing result variant,
                          then continue from ord-pre
  START_FROM=<stage>      Resume from a later stage
  OUTER_ITERATIONS=N      Number of staged preCTS outer-loop iterations (default: 1)
  NUM_CORES=N             Exported before sourcing the flow environment
  PIN3D_ALLOW_NET_FLOW    on/off, default on
  PIN3D_SPLIT_NET_FLOW    on/off, default on
EOF
  exit 1
fi

ENABLEMENT="$1"
FLOW_VARIANT="$2"
USE_FLOW="$3"
DESIGN_NICKNAME="$4"

case "${USE_FLOW}" in
  openroad|OpenROAD)
    USE_FLOW="openroad"
    ;;
  *)
    echo "ERROR: ${BASH_SOURCE[0]} currently supports use_flow=openroad/OpenROAD only." >&2
    exit 1
    ;;
esac

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

OUTER_ITERATIONS="${OUTER_ITERATIONS:-1}"
export OUTER_ITERATIONS
export OUTER_ITERATIONS="${OUTER_ITERATIONS}"
START_FROM="${START_FROM:-}"

stage_order_index() {
  case "$1" in
    ord-pre) echo 10 ;;
    ord-3d-floorplan) echo 20 ;;
    ord-3d-io) echo 30 ;;
    ord-3d-split-net) echo 40 ;;
    ord-place-macro-upper) echo 50 ;;
    ord-place-macro-bottom) echo 60 ;;
    ord-3d-pdn-only) echo 70 ;;
    ord-place-init) echo 80 ;;
    ord-place-init-upper) echo 90 ;;
    ord-place-init-bottom) echo 100 ;;
    staged-prects) echo 110 ;;
    ord-gp2lg) echo 120 ;;
    ord-legalize-upper) echo 130 ;;
    ord-legalize-bottom) echo 140 ;;
    ord-cts) echo 150 ;;
    ord-cts-post) echo 160 ;;
    ord-route) echo 170 ;;
    ord-final) echo 180 ;;
    *)
      echo "ERROR: unsupported START_FROM stage '$1'" >&2
      exit 1
      ;;
  esac
}

if [[ -n "${START_FROM}" ]]; then
  START_FROM_INDEX="$(stage_order_index "${START_FROM}")"
else
  START_FROM_INDEX=0
fi

should_run_stage() {
  local stage="$1"
  local stage_index
  stage_index="$(stage_order_index "${stage}")"
  [[ "${stage_index}" -ge "${START_FROM_INDEX}" ]]
}

run_make() {
  local target="$1"
  local design_config="${2:-${DESIGN_CONFIG_3D}}"
  echo "[run] make ${target}"
  make DESIGN_CONFIG="${design_config}" "${target}"
}

run_make_with_allow_net() {
  local allow_net="$1"
  local target="$2"
  echo "[run] make ${target} (allow_net=${allow_net})"
  TIER_ALLOW_NET="${allow_net}" make DESIGN_CONFIG="${DESIGN_CONFIG_3D}" "${target}"
}

seed_reused_2dpart_artifacts() {
  local source_variant="$1"
  local source_results="./results/${ENABLEMENT}/${DESIGN_NICKNAME}/${source_variant}"
  local required_files=(
    "1_synth.sdc"
    "2_2_floorplan_io.def"
    "2_2_floorplan_io.v"
    "partition.txt"
  )
  local optional_files=(
    "1_synth.v"
    "partition.result.tcl"
    "partition.simple_plan.txt"
  )

  if [[ ! -d "${source_results}" ]]; then
    echo "ERROR: missing reuse source directory ${source_results}" >&2
    exit 1
  fi

  for file_name in "${required_files[@]}"; do
    if [[ ! -f "${source_results}/${file_name}" ]]; then
      echo "ERROR: missing required reuse artifact ${source_results}/${file_name}" >&2
      exit 1
    fi
  done

  mkdir -p "${RESULTS_DIR}" "${LOG_DIR}" "${OBJECTS_DIR}" "${REPORTS_DIR}"

  echo "[run] reuse 2D-part artifacts from ${source_results}"
  for file_name in "${required_files[@]}" "${optional_files[@]}"; do
    if [[ -f "${source_results}/${file_name}" ]]; then
      cp -f "${source_results}/${file_name}" "${RESULTS_DIR}/${file_name}"
      echo "[run] copied ${file_name}"
    fi
  done
}

echo "[run] enablement=${ENABLEMENT} design=${DESIGN_NICKNAME} use_flow=${USE_FLOW} flow_variant=${FLOW_VARIANT}"
echo "[run] design_config_3d=${DESIGN_CONFIG_3D}"
echo "[run] design_config_2d=${DESIGN_CONFIG_2D}"
echo "[run] outer_iterations=${OUTER_ITERATIONS}"
echo "[run] PIN3D_ALLOW_NET_FLOW=${PIN3D_ALLOW_NET_FLOW:-on}"
echo "[run] PIN3D_SPLIT_NET_FLOW=${PIN3D_SPLIT_NET_FLOW:-on}"
echo "[run] REUSE_2DPART_FROM_VARIANT=${REUSE_2DPART_FROM_VARIANT:-}"
echo "[run] START_FROM=${START_FROM:-}"

if [[ -n "${START_FROM}" ]]; then
  echo "[run] resume mode enabled, skip clean_all/reuse/ord-3d-flow-2dpart bootstrap"
elif [[ -n "${REUSE_2DPART_FROM_VARIANT:-}" ]]; then
  rm -rf "${LOG_DIR}" "${OBJECTS_DIR}" "${REPORTS_DIR}" "${RESULTS_DIR}"
  seed_reused_2dpart_artifacts "${REUSE_2DPART_FROM_VARIANT}"
  echo "[run] reuse mode enabled, skip clean_all and ord-3d-flow-2dpart"
elif [[ "${SKIP_2D_PART:-0}" != "1" ]]; then
  run_make clean_all "${DESIGN_CONFIG_3D}"
  run_make ord-3d-flow-2dpart "${DESIGN_CONFIG_2D}"
else
  echo "[run] SKIP_2D_PART=1, skip clean_all and ord-3d-flow-2dpart"
fi

if should_run_stage ord-pre; then
  run_make ord-pre
fi
if should_run_stage ord-3d-floorplan; then
  run_make ord-3d-floorplan
fi
if should_run_stage ord-3d-io; then
  run_make ord-3d-io
fi
if should_run_stage ord-3d-split-net; then
  run_make ord-3d-split-net
fi
if should_run_stage ord-place-macro-upper; then
  run_make ord-place-macro-upper
fi
if should_run_stage ord-place-macro-bottom; then
  run_make ord-place-macro-bottom
fi
if should_run_stage ord-3d-pdn-only; then
  run_make ord-3d-pdn-only
fi
if should_run_stage ord-place-init; then
  run_make ord-place-init
fi
if should_run_stage ord-place-init-upper; then
  run_make ord-place-init-upper
fi
if should_run_stage ord-place-init-bottom; then
  run_make ord-place-init-bottom
fi
if should_run_stage staged-prects; then
  for ((i = 1; i <= OUTER_ITERATIONS; i++)); do
    echo "[run] staged preCTS iteration ${i}/${OUTER_ITERATIONS}"
    run_make_with_allow_net "upper-only" ord-place-upper
    run_make_with_allow_net "bottom-only" ord-place-bottom
  done
fi
if should_run_stage ord-gp2lg; then
  run_make ord-gp2lg
fi
if should_run_stage ord-legalize-upper; then
  run_make ord-legalize-upper
fi
if should_run_stage ord-legalize-bottom; then
  run_make ord-legalize-bottom
fi
if should_run_stage ord-cts; then
  run_make ord-cts
fi
if should_run_stage ord-cts-post; then
  run_make ord-cts-post
fi
if should_run_stage ord-route; then
  run_make ord-route
fi
if should_run_stage ord-final; then
  run_make ord-final
fi

echo "[run] flow completed for ${ENABLEMENT}/${DESIGN_NICKNAME} (${FLOW_VARIANT})"
