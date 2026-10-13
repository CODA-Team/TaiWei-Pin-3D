#!/usr/bin/env bash
set -euo pipefail

required_vars=(
  DESIGN_NAME
  D3D_PARTITION_CONFIG
  D3D_PARTITION_DRIVER
  D3D_PARTITION_CHECK
  D3D_PARTITION_CASE_NAME
  D3D_PARTITION_LEFS
  D3D_PARTITION_NUM_THREADS
  D3D_PARTITION_PREFIX
  D3D_PARTITION_PYTHON
  D3D_PARTITION_RUNTIME_ROOT
  D3D_PARTITION_DEF
  D3D_PARTITION_VERILOG
  D3D_PARTITION_SDC
  D3D_PARTITION_OUTPUT
  D3D_PARTITION_SUMMARY
  D3D_PARTITION_DEFERRED_TIES
  D3D_PARTITION_SCRIPTS_DIR
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "[ERROR][D3D-PARTITION] required environment variable is empty: ${var_name}" >&2
    exit 2
  fi
done

defer_ties="${D3D_PARTITION_DEFER_TIE_CELLS:-1}"
case "${defer_ties,,}" in
  1|on|true|yes|enabled) defer_ties=1 ;;
  0|off|false|no|disabled) defer_ties=0 ;;
  *)
    echo "[ERROR][D3D-PARTITION] invalid D3D_PARTITION_DEFER_TIE_CELLS='$defer_ties'" >&2
    exit 2
    ;;
esac

tie_defer_script="$D3D_PARTITION_SCRIPTS_DIR/defer_tie_cells.py"
if [[ "$defer_ties" == 1 ]]; then
  for var_name in TIEHI_CELL_AND_PORT TIELO_CELL_AND_PORT; do
    if [[ -z "${!var_name:-}" ]]; then
      echo "[ERROR][D3D-PARTITION] tie deferral requires ${var_name}" >&2
      exit 2
    fi
  done
  if [[ ! -f "$tie_defer_script" ]]; then
    echo "[ERROR][D3D-PARTITION] tie defer script is not a file: $tie_defer_script" >&2
    exit 2
  fi
fi

for input_path in \
  "$D3D_PARTITION_DRIVER" \
  "$D3D_PARTITION_CHECK" \
  "$D3D_PARTITION_CONFIG" \
  "$D3D_PARTITION_DEF" \
  "$D3D_PARTITION_VERILOG" \
  "$D3D_PARTITION_SDC"; do
  if [[ ! -f "$input_path" ]]; then
    echo "[ERROR][D3D-PARTITION] required input is not a file: $input_path" >&2
    exit 2
  fi
done

read -r -a d3d_partition_lefs <<< "$D3D_PARTITION_LEFS"
if [[ ${#d3d_partition_lefs[@]} -eq 0 ]]; then
  echo "[ERROR][D3D-PARTITION] no LEF inputs were provided" >&2
  exit 2
fi
for lef_path in "${d3d_partition_lefs[@]}"; do
  if [[ ! -f "$lef_path" ]]; then
    echo "[ERROR][D3D-PARTITION] required LEF is not a file: $lef_path" >&2
    exit 2
  fi
done

if [[ ! "$D3D_PARTITION_NUM_THREADS" =~ ^[1-9][0-9]*$ ]]; then
  echo "[ERROR][D3D-PARTITION] D3D_PARTITION_NUM_THREADS must be positive" >&2
  exit 2
fi

if [[ "$D3D_PARTITION_PYTHON" == */* ]]; then
  if [[ ! -x "$D3D_PARTITION_PYTHON" ]]; then
    echo "[ERROR][D3D-PARTITION] Python is not executable: $D3D_PARTITION_PYTHON" >&2
    exit 2
  fi
elif ! command -v "$D3D_PARTITION_PYTHON" >/dev/null 2>&1; then
  echo "[ERROR][D3D-PARTITION] Python is not on PATH: $D3D_PARTITION_PYTHON" >&2
  exit 2
fi

if [[ ! -d "$D3D_PARTITION_PREFIX" ]]; then
  echo "[ERROR][D3D-PARTITION] installed tool prefix not found: $D3D_PARTITION_PREFIX" >&2
  exit 2
fi

d3d_environment_prefix="${D3D_PARTITION_ENV_PREFIX:-}"
if [[ -z "$d3d_environment_prefix" ]]; then
  d3d_environment_prefix="$("$D3D_PARTITION_PYTHON" -c 'import sys; print(sys.prefix)')"
fi
if [[ ! -d "$d3d_environment_prefix/lib" ]]; then
  echo "[ERROR][D3D-PARTITION] environment library directory not found: $d3d_environment_prefix/lib" >&2
  exit 2
fi

export LD_LIBRARY_PATH="$d3d_environment_prefix/lib:$D3D_PARTITION_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$D3D_PARTITION_PREFIX:$D3D_PARTITION_PREFIX/placer"

"$D3D_PARTITION_PYTHON" "$D3D_PARTITION_CHECK" \
  --prefix "$D3D_PARTITION_PREFIX" \
  --require-manifest

mkdir -p \
  "$D3D_PARTITION_RUNTIME_ROOT" \
  "$(dirname "$D3D_PARTITION_OUTPUT")" \
  "$(dirname "$D3D_PARTITION_SUMMARY")" \
  "$(dirname "$D3D_PARTITION_DEFERRED_TIES")"

# Remove every formal artifact owned by this stage before launch so a failed
# run cannot leave a stale partition or deferred-tie handoff consumable.
rm -f -- \
  "$D3D_PARTITION_OUTPUT" \
  "$D3D_PARTITION_SUMMARY" \
  "$D3D_PARTITION_DEFERRED_TIES"

run_dir="$(mktemp -d "$D3D_PARTITION_RUNTIME_ROOT/run.XXXXXX")"
assignment_json="$run_dir/assignment.json"
candidate_partition="$run_dir/partition.txt"
candidate_summary="$run_dir/d3d_partition_summary.json"
candidate_deferred_ties="$run_dir/deferred_ties.json"
partition_def="$D3D_PARTITION_DEF"

export D2D_RUNTIME_ROOT="$run_dir"
export OMP_NUM_THREADS="$D3D_PARTITION_NUM_THREADS"

driver_lef_args=()
for lef_path in "${d3d_partition_lefs[@]}"; do
  driver_lef_args+=(--lef "$lef_path")
done

export_deferred_args=()
if [[ "$defer_ties" == 1 ]]; then
  read -r tiehi_cell tiehi_port tiehi_extra <<< "$TIEHI_CELL_AND_PORT"
  read -r tielo_cell tielo_port tielo_extra <<< "$TIELO_CELL_AND_PORT"
  if [[ -z "${tiehi_cell:-}" || -z "${tiehi_port:-}" || -n "${tiehi_extra:-}" || \
        -z "${tielo_cell:-}" || -z "${tielo_port:-}" || -n "${tielo_extra:-}" ]]; then
    echo "[ERROR][D3D-PARTITION] TIEHI/TIELO_CELL_AND_PORT must each contain exactly 'cell pin'" >&2
    exit 2
  fi

  partition_def="$run_dir/partition_input.def"
  "$D3D_PARTITION_PYTHON" "$tie_defer_script" prepare \
    --def "$D3D_PARTITION_DEF" \
    --output-def "$partition_def" \
    --manifest "$candidate_deferred_ties" \
    --tiehi-cell "$tiehi_cell" \
    --tiehi-port "$tiehi_port" \
    --tielo-cell "$tielo_cell" \
    --tielo-port "$tielo_port"
  export_deferred_args+=(--deferred-ties "$candidate_deferred_ties")
fi

"$D3D_PARTITION_PYTHON" "$D3D_PARTITION_DRIVER" \
  --config "$D3D_PARTITION_CONFIG" \
  --case-name "$D3D_PARTITION_CASE_NAME" \
  --def "$partition_def" \
  --verilog "$D3D_PARTITION_VERILOG" \
  --sdc "$D3D_PARTITION_SDC" \
  "${driver_lef_args[@]}" \
  --num-threads "$D3D_PARTITION_NUM_THREADS" \
  --runtime-root "$run_dir" \
  --output "$assignment_json"

"$D3D_PARTITION_PYTHON" \
  "$D3D_PARTITION_SCRIPTS_DIR/export_partition.py" \
  --def "$D3D_PARTITION_DEF" \
  --assignment "$assignment_json" \
  "${export_deferred_args[@]}" \
  --output "$candidate_partition" \
  --summary "$candidate_summary"

# Publish the report first and the downstream handoff last.  Both candidates
# have already been fully written and validated in the private work directory.
mv -f -- "$candidate_summary" "$D3D_PARTITION_SUMMARY"
if [[ "$defer_ties" == 1 ]]; then
  mv -f -- "$candidate_deferred_ties" "$D3D_PARTITION_DEFERRED_TIES"
fi
mv -f -- "$candidate_partition" "$D3D_PARTITION_OUTPUT"

echo "[INFO][D3D-PARTITION] published $D3D_PARTITION_OUTPUT"
echo "[INFO][D3D-PARTITION] summary $D3D_PARTITION_SUMMARY"
if [[ "$defer_ties" == 1 ]]; then
  echo "[INFO][D3D-PARTITION] deferred ties $D3D_PARTITION_DEFERRED_TIES"
fi
echo "[INFO][D3D-PARTITION] private runtime $run_dir"
