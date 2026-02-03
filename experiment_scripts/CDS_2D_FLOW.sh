#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_ROOT="${SCRIPT_DIR}"
while [[ "${FLOW_ROOT}" != "/" && ! -f "${FLOW_ROOT}/env.sh" ]]; do
  FLOW_ROOT="$(dirname "${FLOW_ROOT}")"
done
if [[ ! -f "${FLOW_ROOT}/env.sh" ]]; then
  echo "ERROR: env.sh not found for ${SCRIPT_DIR}" >&2
  exit 1
fi
source "${FLOW_ROOT}/env.sh"
export NUM_CORES=20

export DESIGN_DIMENSION="2D"
export DESIGN_NICKNAME="aes" 
export FLOW_VARIANT="cadence"
export USE_FLOW="cadence"

make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config2d.mk cds-2d_flow &

export DESIGN_DIMENSION="2D"
export DESIGN_NICKNAME="ibex" 
export FLOW_VARIANT="cadence"
export USE_FLOW="cadence"

make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config2d.mk cds-2d_flow &

export DESIGN_DIMENSION="2D"
export DESIGN_NICKNAME="jpeg" 
export FLOW_VARIANT="cadence"
export USE_FLOW="cadence"

make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config2d.mk cds-2d_flow &

export DESIGN_DIMENSION="2D"
export DESIGN_NICKNAME="jpeg" 
export FLOW_VARIANT="cadence"
export USE_FLOW="cadence"

make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config2d.mk cds-2d_flow &

export DESIGN_DIMENSION="2D"
export DESIGN_NICKNAME="aes" 
export FLOW_VARIANT="cadence"
export USE_FLOW="cadence"

make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config2d.mk cds-2d_flow & 

export DESIGN_DIMENSION="2D"
export DESIGN_NICKNAME="ibex" 
export FLOW_VARIANT="cadence"
export USE_FLOW="cadence"

make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config2d.mk cds-2d_flow &

wait
