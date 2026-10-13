#!/usr/bin/env bash
set -euo pipefail

required_variables=(
  FLOW_HOME
  DESIGN_CONFIG
  SYN3D_COARSE_SYNTH_DIR
  RESULTS_DIR
  LEF_FILES
  LIB_FILES
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

append_unique_path() {
  local list="$1"
  local path="$2"
  local item
  for item in ${list}; do
    if [[ "${item}" == "${path}" ]]; then
      printf '%s' "${list}"
      return
    fi
  done
  if [[ -n "${list}" ]]; then
    printf '%s %s' "${list}" "${path}"
  else
    printf '%s' "${path}"
  fi
}

coarse_handoff_dir="${SYN3D_COARSE_SYNTH_DIR}/handoff"
coarse_2d_lef="${coarse_handoff_dir}/lef/2d/coarse_units.lef"
coarse_2d_lib="${coarse_handoff_dir}/lib/2d/coarse_units.lib"

require_file "coarse synthesis netlist" "${RESULTS_DIR}/1_synth.v"
require_file "coarse synthesis constraints" "${RESULTS_DIR}/1_synth.sdc"
require_file "2D coarse-unit LEF" "${coarse_2d_lef}"
require_file "aggregate 2D coarse-unit Liberty" "${coarse_2d_lib}"

additional_lefs="$(append_unique_path "${ADDITIONAL_LEFS:-}" "${coarse_2d_lef}")"
additional_libs="${ADDITIONAL_LIBS:-}"
partition_lefs="$(append_unique_path "${LEF_FILES}" "${coarse_2d_lef}")"
partition_libs="$(append_unique_path "${LIB_FILES}" "${coarse_2d_lib}")"

echo "[3D-Syn][ORD] Starting coarse-grained tier partitioning"
echo "[3D-Syn] 2D coarse-unit LEF : ${coarse_2d_lef}"
echo "[3D-Syn] 2D coarse-unit LIB : ${coarse_2d_lib}"

make_args=(
  --no-print-directory
  -C "${FLOW_HOME}"
  "DESIGN_CONFIG=${DESIGN_CONFIG}"
  "ADDITIONAL_LEFS=${additional_lefs}"
  "ADDITIONAL_LIBS=${additional_libs}"
  "LEF_FILES=${partition_lefs}"
  "LIB_FILES=${partition_libs}"
)

make "${make_args[@]}" ord-preplace
make "${make_args[@]}" ord-tier-partition

for output in \
  2_2_floorplan_io.def \
  2_2_floorplan_io.v \
  2_2_floorplan_io.odb \
  partition.txt \
  partition.result.tcl \
  partition.simple_plan.txt; do
  require_file "coarse partition output" "${RESULTS_DIR}/${output}"
done

mv -f -- \
  "${RESULTS_DIR}/partition.txt" \
  "${RESULTS_DIR}/partition.coarse.txt"
require_file "coarse partition output" "${RESULTS_DIR}/partition.coarse.txt"

echo "[3D-Syn] Coarse partition netlist : ${RESULTS_DIR}/2_2_floorplan_io.v"
echo "[3D-Syn] Coarse partition floorplan: ${RESULTS_DIR}/2_2_floorplan_io.def"
echo "[3D-Syn] Coarse partition result  : ${RESULTS_DIR}/partition.coarse.txt"
