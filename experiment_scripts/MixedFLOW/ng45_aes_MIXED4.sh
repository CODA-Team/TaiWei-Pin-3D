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
export NUM_CORES=16
export DESIGN_DIMENSION="3D"
export DESIGN_NICKNAME="aes" 
export FLOW_VARIANT="mixed4"
export USE_FLOW="openroad"

rm -rf results/nangate45_3D/aes/mixed4
cp -r results/nangate45_3D/aes/openroad results/nangate45_3D/aes/mixed4

make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk ord-3d-pdn
ssh -Y zhiyuzheng@hnode33 "
    cd ~/Projects/3DIC/scripts/ORFS-Research/flow-Pin3D || exit
    source env.sh
    export NUM_CORES=16
    export DESIGN_DIMENSION="3D"
    export DESIGN_NICKNAME="aes" 
    export FLOW_VARIANT="mixed4"
    export USE_FLOW="openroad"
    make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config_upper_cover.mk cds-place-init
    make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config_bottom_cover.mk cds-place-upper
    make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config_upper_cover.mk cds-place-bottom
    make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config.mk cds-place-finish
    make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config_upper_cover.mk cds-legalize-bottom
    make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config_bottom_cover.mk cds-legalize-upper
"
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config_upper_cover.mk ord-re-cts 
make DESIGN_CONFIG=designs/nangate45_3D/${DESIGN_NICKNAME}/config.mk ord-route 
ssh -Y zhiyuzheng@hnode33 "
    cd ~/Projects/3DIC/scripts/ORFS-Research/flow-Pin3D || exit
    source env.sh
    export NUM_CORES=16
    export DESIGN_DIMENSION="3D"
    export DESIGN_NICKNAME="aes" 
    export FLOW_VARIANT="mixed4"
    export USE_FLOW="openroad"
    make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config.mk cds-final 
"