#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: experiment_scripts/ORD_CI_REGRESSION.sh <pass|all>

Modes:
  pass   Run the OpenROAD smoke regression on the common cases:
         asap7_3D/{ibex,swerv_wrapper}
         nangate45_3D/{ibex,swerv_wrapper}
         asap7_nangate45_3D/{ibex,swerv_wrapper}

  all    Run all discovered OpenROAD cases.

Behavior:
  - Only runs OpenROAD.
  - Forces FLOW_VARIANT=ORD_CI by default.
  - Runs from scratch by default (SKIP_2D_PART=0, no START_FROM, no reuse).
  - Writes per-case console logs and a regression summary under:
      run_logs/regression/ord_ci_<mode>_<timestamp>/

Useful environment variables:
  FLOW_VARIANT=ORD_CI          Regression output variant (default: ORD_CI)
  BASELINE_VARIANT=openroad    Baseline variant used for timing comparison
  NUM_CORES=16                 Passed through to the OpenROAD launcher
  OUTER_ITERATIONS=1           Passed through to the OpenROAD launcher
  PIN3D_ALLOW_NET_FLOW=on      Passed through to the OpenROAD launcher
  PIN3D_SPLIT_NET_FLOW=on      Passed through to the OpenROAD launcher
EOF
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

MODE="$1"
case "${MODE}" in
  pass|all)
    ;;
  *)
    usage
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

FLOW_VARIANT="${FLOW_VARIANT:-ORD_CI}"
BASELINE_VARIANT="${BASELINE_VARIANT:-openroad}"
NUM_CORES="${NUM_CORES:-16}"
OUTER_ITERATIONS="${OUTER_ITERATIONS:-1}"
PIN3D_ALLOW_NET_FLOW="${PIN3D_ALLOW_NET_FLOW:-on}"
PIN3D_SPLIT_NET_FLOW="${PIN3D_SPLIT_NET_FLOW:-on}"

# Regression is intended to be a clean end-to-end check before push.
export FLOW_VARIANT
export USE_FLOW="openroad"
export NUM_CORES
export OUTER_ITERATIONS
export PIN3D_ALLOW_NET_FLOW
export PIN3D_SPLIT_NET_FLOW
export SKIP_2D_PART=0
unset REUSE_2DPART_FROM_VARIANT || true
unset START_FROM || true

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RUN_ROOT="${REPO_ROOT}/run_logs/regression/ord_ci_${MODE}_${TIMESTAMP}"
SUMMARY_TSV="${RUN_ROOT}/summary.tsv"
SUMMARY_TXT="${RUN_ROOT}/summary.txt"
mkdir -p "${RUN_ROOT}"

extract_metric() {
  local file="$1"
  local pattern="$2"
  local value=""
  if [[ ! -f "${file}" ]]; then
    return 0
  fi
  value="$(rg -m1 "${pattern}" "${file}" 2>/dev/null | awk '{print $NF}' || true)"
  printf '%s\n' "${value}"
}

timing_delta() {
  local new_value="$1"
  local base_value="$2"
  python3 - "$new_value" "$base_value" <<'PY'
import sys

new_raw = sys.argv[1].strip()
base_raw = sys.argv[2].strip()
if not new_raw or not base_raw:
    print("")
    raise SystemExit(0)

try:
    new_val = float(new_raw)
    base_val = float(base_raw)
except ValueError:
    print("")
    raise SystemExit(0)

print(f"{new_val - base_val:.3f}")
PY
}

timing_check() {
  local new_wns="$1"
  local base_wns="$2"
  local new_tns="$3"
  local base_tns="$4"
  python3 - "$new_wns" "$base_wns" "$new_tns" "$base_tns" <<'PY'
import sys

def parse(text):
    text = text.strip()
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None

new_wns = parse(sys.argv[1])
base_wns = parse(sys.argv[2])
new_tns = parse(sys.argv[3])
base_tns = parse(sys.argv[4])

if new_wns is None or base_wns is None:
    print("unknown")
    raise SystemExit(0)

if new_tns is None or base_tns is None:
    print("improved" if new_wns >= base_wns else "regressed")
    raise SystemExit(0)

if new_wns >= base_wns and new_tns >= base_tns:
    print("improved")
else:
    print("regressed")
PY
}

build_task_list() {
  local mode="$1"
  if [[ "${mode}" == "pass" ]]; then
    local tech
    local case_name
    for tech in asap7_3D nangate45_3D asap7_nangate45_3D; do
      for case_name in ibex swerv_wrapper; do
        printf '%s %s\n' "${tech}" "${case_name}"
      done
    done
    return 0
  fi

  find test -path '*/ord/run.sh' \
    | sed -E 's#^test/([^/]+)/([^/]+)/ord/run\.sh$#\1 \2#' \
    | sort
}

mapfile -t TASKS < <(build_task_list "${MODE}")

{
  printf "tech\tcase\tstatus\twns\ttns\tbaseline_wns\tbaseline_tns\tdelta_wns\tdelta_tns\ttiming_check\tcase_log\n"
} > "${SUMMARY_TSV}"

{
  echo "[regression] mode=${MODE}"
  echo "[regression] flow=openroad"
  echo "[regression] flow_variant=${FLOW_VARIANT}"
  echo "[regression] baseline_variant=${BASELINE_VARIANT}"
  echo "[regression] num_cores=${NUM_CORES}"
  echo "[regression] outer_iterations=${OUTER_ITERATIONS}"
  echo "[regression] pin3d_allow_net_flow=${PIN3D_ALLOW_NET_FLOW}"
  echo "[regression] pin3d_split_net_flow=${PIN3D_SPLIT_NET_FLOW}"
  echo "[regression] clean_run=1"
  echo "[regression] task_count=${#TASKS[@]}"
  printf "[regression] tasks:"
  for task in "${TASKS[@]}"; do
    printf " %s/%s" "${task%% *}" "${task##* }"
  done
  printf "\n"
} | tee "${SUMMARY_TXT}"

failure_count=0
regressed_count=0
case_index=0

for task in "${TASKS[@]}"; do
  tech="${task%% *}"
  case_name="${task##* }"
  case_index=$((case_index + 1))
  case_log="${RUN_ROOT}/${tech}__${case_name}.log"
  current_summary="logs/${tech}/${case_name}/${FLOW_VARIANT}/final_summary.txt"
  baseline_summary="logs/${tech}/${case_name}/${BASELINE_VARIANT}/final_summary.txt"

  {
    echo
    echo "[regression] (${case_index}/${#TASKS[@]}) start ${tech}/${case_name}"
    echo "[regression] case_log=${case_log}"
    echo "[regression] current_summary=${current_summary}"
    echo "[regression] baseline_summary=${baseline_summary}"
  } | tee -a "${SUMMARY_TXT}"

  if bash "test/${tech}/${case_name}/ord/run.sh" > >(tee "${case_log}") 2>&1; then
    status="ok"
    wns="$(extract_metric "${current_summary}" '^WNS \(ns\)')"
    tns="$(extract_metric "${current_summary}" '^TNS \(ns\)')"
    baseline_wns="$(extract_metric "${baseline_summary}" '^WNS \(ns\)')"
    baseline_tns="$(extract_metric "${baseline_summary}" '^TNS \(ns\)')"
    delta_wns="$(timing_delta "${wns}" "${baseline_wns}")"
    delta_tns="$(timing_delta "${tns}" "${baseline_tns}")"
    timing_status="$(timing_check "${wns}" "${baseline_wns}" "${tns}" "${baseline_tns}")"

    if [[ "${timing_status}" == "regressed" ]]; then
      regressed_count=$((regressed_count + 1))
    fi
  else
    status="failed"
    wns=""
    tns=""
    baseline_wns="$(extract_metric "${baseline_summary}" '^WNS \(ns\)')"
    baseline_tns="$(extract_metric "${baseline_summary}" '^TNS \(ns\)')"
    delta_wns=""
    delta_tns=""
    timing_status="not_run"
    failure_count=$((failure_count + 1))
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${tech}" "${case_name}" "${status}" "${wns}" "${tns}" \
    "${baseline_wns}" "${baseline_tns}" "${delta_wns}" "${delta_tns}" \
    "${timing_status}" "${case_log}" >> "${SUMMARY_TSV}"

  {
    echo "[regression] done ${tech}/${case_name} status=${status} wns=${wns:-N/A} tns=${tns:-N/A} baseline_wns=${baseline_wns:-N/A} baseline_tns=${baseline_tns:-N/A} timing_check=${timing_status}"
  } | tee -a "${SUMMARY_TXT}"
done

{
  echo
  echo "[regression] summary_tsv=${SUMMARY_TSV}"
  echo "[regression] summary_txt=${SUMMARY_TXT}"
  echo "[regression] failures=${failure_count}"
  echo "[regression] timing_regressions=${regressed_count}"
} | tee -a "${SUMMARY_TXT}"

cat "${SUMMARY_TSV}"

if [[ ${failure_count} -gt 0 || ${regressed_count} -gt 0 ]]; then
  exit 1
fi
