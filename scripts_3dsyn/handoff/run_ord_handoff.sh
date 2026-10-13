#!/usr/bin/env bash
set -euo pipefail

required_variables=(
  FLOW_HOME
  DESIGN_NAME
  FLOW_VARIANT
  RESULTS_DIR
  OBJECTS_DIR
  REPORTS_DIR
  LOG_DIR
  SYN3D_HANDOFF_DIR
  SYN3D_PLATFORM
  SYN3D_PLATFORM_DIR
  OPENROAD_EXE
  PYTHON_EXE
  YOSYS_EXE
)

for name in "${required_variables[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "[3D-Syn] Required variable is not set: ${name}" >&2
    exit 1
  fi
done

require_file() {
  local label="$1"
  local path="$2"
  if [[ ! -s "${path}" ]]; then
    echo "[3D-Syn] Missing or empty ${label}: ${path}" >&2
    exit 1
  fi
}

run_logged() {
  local log_file="$1"
  shift
  local tmp_log="${log_file}.tmp"
  rm -f -- "${tmp_log}"
  set +e
  "$@" 2>&1 | tee "${tmp_log}"
  local command_status=${PIPESTATUS[0]}
  set -e
  mv -f -- "${tmp_log}" "${log_file}"
  return "${command_status}"
}

preplace_opt="${SYN3D_BACKEND_PREPLACE_OPT:-0}"
if [[ "${preplace_opt}" != "0" && "${preplace_opt}" != "1" ]]; then
  echo "[3D-Syn] SYN3D_BACKEND_PREPLACE_OPT must be 0 or 1: ${preplace_opt}" >&2
  exit 1
fi

for tool in "${OPENROAD_EXE}" "${PYTHON_EXE}" "${YOSYS_EXE}"; do
  if [[ ! -x "${tool}" ]]; then
    echo "[3D-Syn] Tool is not executable: ${tool}" >&2
    exit 1
  fi
done

require_file "per-tier base netlist" "${RESULTS_DIR}/base.v"
require_file "per-tier partition" "${RESULTS_DIR}/partition_from_flow.txt"
require_file "synthesis constraints" "${RESULTS_DIR}/1_synth.sdc"

stage_log_dir="${LOG_DIR}/3dsyn/handoff"
stage_report_dir="${REPORTS_DIR}/3dsyn/handoff"
mkdir -p "${RESULTS_DIR}" "${SYN3D_HANDOFF_DIR}" "${stage_log_dir}" "${stage_report_dir}"

backend_floorplan_def="${RESULTS_DIR}/2_1_floorplan.backend.def"
backend_floorplan_odb="${RESULTS_DIR}/2_1_floorplan.backend.odb"
backend_v="${RESULTS_DIR}/2_2_floorplan_io.backend.v"
backend_def="${RESULTS_DIR}/2_2_floorplan_io.backend.def"
backend_odb="${RESULTS_DIR}/2_2_floorplan_io.backend.odb"
backend_partition="${RESULTS_DIR}/partition.backend.txt"
fp_v="${RESULTS_DIR}/${DESIGN_NAME}_3D.fp.v"
fp_def="${RESULTS_DIR}/${DESIGN_NAME}_3D.fp.def"
manifest="${RESULTS_DIR}/backend_handoff_manifest.json"

rm -f -- \
  "${backend_floorplan_def}" \
  "${backend_floorplan_odb}" \
  "${RESULTS_DIR}/2_floorplan.backend.sdc" \
  "${backend_v}" "${backend_def}" "${backend_odb}" \
  "${backend_partition}" "${fp_v}" "${fp_def}" "${manifest}"

openroad_args=(-no_init -threads "${NUM_CORES:-1}" -exit)

echo "[3D-Syn][ORD] Backend handoff: floorplan"
run_logged "${stage_log_dir}/01_backend_preplace_floorplan.log" \
  "${OPENROAD_EXE}" "${openroad_args[@]}" \
  "${FLOW_HOME}/scripts_3dsyn/handoff/ord/01_backend_preplace_floorplan.tcl"
require_file "backend floorplan database" "${backend_floorplan_odb}"
require_file "backend floorplan DEF" "${backend_floorplan_def}"

echo "[3D-Syn][ORD] Backend handoff: IO placement"
run_logged "${stage_log_dir}/01_backend_preplace_io.log" \
  "${OPENROAD_EXE}" "${openroad_args[@]}" \
  "${FLOW_HOME}/scripts_3dsyn/handoff/ord/01_backend_preplace_io.tcl"
require_file "backend preplace netlist" "${backend_v}"
require_file "backend preplace floorplan" "${backend_def}"
require_file "backend preplace database" "${backend_odb}"

echo "[3D-Syn][ORD] Backend handoff: partition preparation"
partition_work_dir="${SYN3D_HANDOFF_DIR}/partition_workspace"
mkdir -p "${partition_work_dir}"
rm -f -- \
  "${partition_work_dir}/base.v" \
  "${partition_work_dir}/2_2_floorplan_io.v" \
  "${partition_work_dir}/partition.txt" \
  "${partition_work_dir}/partition.before_preplace_update.txt"
cp -f -- "${RESULTS_DIR}/base.v" "${partition_work_dir}/base.v"
cp -f -- "${backend_v}" "${partition_work_dir}/2_2_floorplan_io.v"
cp -f -- "${RESULTS_DIR}/partition_from_flow.txt" "${partition_work_dir}/partition.txt"

partition_args=(
  "${PYTHON_EXE}"
  "${FLOW_HOME}/scripts_3dsyn/handoff/ord/02_prepare_backend_partition.py"
  --results-dir "${partition_work_dir}"
  --enablement "${SYN3D_PLATFORM}"
  --design-nickname "${DESIGN_NAME}"
  --flow-root "${FLOW_HOME}"
  --objects-dir "${SYN3D_HANDOFF_DIR}"
  --log-dir "${stage_report_dir}"
  --yosys "${YOSYS_EXE}"
)
if [[ "${preplace_opt}" == "0" ]]; then
  partition_args+=(--expect-unchanged)
fi
run_logged "${stage_log_dir}/02_prepare_backend_partition.log" "${partition_args[@]}"
cp -f -- "${partition_work_dir}/partition.txt" "${backend_partition}"
require_file "backend partition" "${backend_partition}"

echo "[3D-Syn][ORD] Backend handoff: canonical 3D views"
run_logged "${stage_log_dir}/03_generate_backend_views.log" \
  "${PYTHON_EXE}" "${FLOW_HOME}/scripts_3dsyn/handoff/ord/03_generate_backend_views.py" \
  --def-in "${backend_def}" \
  --v-in "${backend_v}" \
  --partition "${backend_partition}" \
  --cell-map "${SYN3D_PLATFORM_DIR}/map.json" \
  --def-out "${fp_def}" \
  --v-out "${fp_v}"

require_file "3D backend netlist" "${fp_v}"
require_file "3D backend floorplan" "${fp_def}"

"${PYTHON_EXE}" - "${manifest}" "${DESIGN_NAME}" "${SYN3D_PLATFORM}" \
  "${FLOW_VARIANT}" "${preplace_opt}" "${RESULTS_DIR}" <<'PY'
import json
import os
import sys

path, design, platform, variant, preplace_opt, results_dir = sys.argv[1:]
payload = {
    "stage": "3dsyn_backend_handoff",
    "backend": "ord",
    "design": design,
    "platform": platform,
    "flow_variant": variant,
    "backend_preplace_optimization": preplace_opt == "1",
    "inputs": {
        "base_netlist": os.path.join(results_dir, "base.v"),
        "partition": os.path.join(results_dir, "partition_from_flow.txt"),
        "sdc": os.path.join(results_dir, "1_synth.sdc"),
    },
    "intermediate_outputs": {
        "preplace_netlist": os.path.join(results_dir, "2_2_floorplan_io.backend.v"),
        "preplace_def": os.path.join(results_dir, "2_2_floorplan_io.backend.def"),
        "preplace_odb": os.path.join(results_dir, "2_2_floorplan_io.backend.odb"),
        "partition": os.path.join(results_dir, "partition.backend.txt"),
    },
    "backend_outputs": {
        "netlist": os.path.join(results_dir, design + "_3D.fp.v"),
        "def": os.path.join(results_dir, design + "_3D.fp.def"),
    },
}
with open(path, "w", encoding="utf-8") as fp:
    json.dump(payload, fp, indent=2, sort_keys=True)
    fp.write("\n")
PY
require_file "backend handoff manifest" "${manifest}"

echo "[3D-Syn] Backend preplace netlist : ${backend_v}"
echo "[3D-Syn] Backend partition        : ${backend_partition}"
echo "[3D-Syn] Backend 3D netlist       : ${fp_v}"
echo "[3D-Syn] Backend 3D floorplan     : ${fp_def}"
