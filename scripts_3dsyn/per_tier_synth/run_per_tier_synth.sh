#!/usr/bin/env bash
set -euo pipefail

required_variables=(
  FLOW_HOME
  PYTHON_EXE
  YOSYS_EXE
  GENUS_EXE
  SYN3D_GENUS_OPT_MODE
  SCRIPTS_3DSYN_DIR
  DESIGN_NAME
  FLOW_VARIANT
  SYN3D_PLATFORM
  SYN3D_COARSE_SYNTH_DIR
  SYN3D_PER_TIER_SYNTH_DIR
  SDC_FILE
  RESULTS_DIR
  OBJECTS_DIR
  LOG_DIR
  REPORTS_DIR
  DONT_USE_CELLS
  SYN3D_DONT_USE_CELLS_UPPER
  SYN3D_DONT_USE_CELLS_BOTTOM
  SYN3D_DNU_FOR_UPPER
  SYN3D_DNU_FOR_BOTTOM
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

for tool in "${PYTHON_EXE}" "${YOSYS_EXE}" "${GENUS_EXE}"; do
  if [[ ! -x "${tool}" ]]; then
    echo "[3D-Syn] Tool is not executable: ${tool}" >&2
    exit 1
  fi
done

case "${SYN3D_PLATFORM}" in
  asap7_3D|nangate45_3D|asap7_nangate45_3D) ;;
  *)
    echo "[3D-Syn] Unsupported platform: ${SYN3D_PLATFORM}" >&2
    exit 1
    ;;
esac

case "${SYN3D_GENUS_OPT_MODE}" in
  normal|low_effort) ;;
  *)
    echo "[3D-Syn] Unsupported SYN3D_GENUS_OPT_MODE: ${SYN3D_GENUS_OPT_MODE}" >&2
    exit 1
    ;;
esac

stage_script_dir="${SCRIPTS_3DSYN_DIR}/per_tier_synth"
genus_dont_use_script="${SCRIPTS_3DSYN_DIR}/coarse_synth/genus/genus_dont_use.tcl"
coarse_handoff_dir="${SYN3D_COARSE_SYNTH_DIR}/handoff"
require_file "stage driver" "${stage_script_dir}/run_flow.py"
require_file "Genus dont-use helper" "${genus_dont_use_script}"
require_file "coarse-partition netlist" "${RESULTS_DIR}/2_2_floorplan_io.v"
require_file "coarse-partition floorplan" "${RESULTS_DIR}/2_2_floorplan_io.def"
require_file "coarse partition" "${RESULTS_DIR}/partition.coarse.txt"
require_file "design SDC" "${SDC_FILE}"
require_file "2D coarse-unit LEF" "${coarse_handoff_dir}/lef/2d/coarse_units.lef"
require_file "bottom coarse-unit LEF" "${coarse_handoff_dir}/lef/bottom/coarse_units.lef"
require_file "upper coarse-unit LEF" "${coarse_handoff_dir}/lef/upper/coarse_units.lef"

objects_root="$(realpath -m "${OBJECTS_DIR}")"
stage_dir="$(realpath -m "${SYN3D_PER_TIER_SYNTH_DIR}")"
case "${stage_dir}" in
  "${objects_root}"/3dsyn/per_tier_synth) ;;
  *)
    echo "[3D-Syn] Stage directory must be OBJECTS_DIR/3dsyn/per_tier_synth: ${stage_dir}" >&2
    exit 1
    ;;
esac

work_dir="${stage_dir}/work"
if [[ -d "${work_dir}" ]]; then
  rm -rf -- "${work_dir}"
fi
rm -f -- \
  "${RESULTS_DIR}/base.v" \
  "${RESULTS_DIR}/partition_from_flow.txt" \
  "${RESULTS_DIR}/per_tier_synth_manifest.json"
mkdir -p "${SYN3D_PER_TIER_SYNTH_DIR}" "${RESULTS_DIR}" "${LOG_DIR}" "${REPORTS_DIR}"
export SYN3D_GENUS_DONT_USE_TCL="${genus_dont_use_script}"

echo "[3D-Syn] Starting per-tier synthesis"
echo "[3D-Syn] Platform : ${SYN3D_PLATFORM}"
echo "[3D-Syn] Variant  : ${FLOW_VARIANT}"
echo "[3D-Syn] HBT mode : ${SYN3D_HBT_MODEL_MODE:-direct}"
"${PYTHON_EXE}" "${stage_script_dir}/run_flow.py"

require_file "per-tier base netlist" "${RESULTS_DIR}/base.v"
require_file "per-tier partition" "${RESULTS_DIR}/partition_from_flow.txt"
require_file "per-tier manifest" "${RESULTS_DIR}/per_tier_synth_manifest.json"

if grep -Eq '\(\*[[:space:]]*src[[:space:]]*=' "${RESULTS_DIR}/base.v"; then
  echo "[3D-Syn] Published base.v contains a source attribute" >&2
  exit 1
fi

echo "[3D-Syn] Per-tier synthesis netlist : ${RESULTS_DIR}/base.v"
echo "[3D-Syn] Per-tier partition result : ${RESULTS_DIR}/partition_from_flow.txt"
echo "[3D-Syn] Per-tier synthesis manifest: ${RESULTS_DIR}/per_tier_synth_manifest.json"
