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

export DESIGN_DIMENSION="3D"
export DESIGN_NICKNAME="aes"
export USE_FLOW="openroad"
export FLOW_VARIANT="openroad_${hbPitch}"

rm -rf results/asap7_3D/${DESIGN_NICKNAME}/${FLOW_VARIANT}
cp -r results/asap7/${DESIGN_NICKNAME}/${USE_FLOW} results/asap7_3D/${DESIGN_NICKNAME}/${FLOW_VARIANT} 
export TECH_LEF="platforms/asap7_3D/lef/ord_pitch_variant/asap7_tech_1x_2A6M7M.${hbPitch}.lef"
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-pre
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-3d-pdn
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-place-init
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-place-init-upper
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-place-init-bottom
iteration=1
for ((i=1;i<=iteration;i++))
do
    echo "Iteration: $i"
    make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-place-upper
    make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-place-bottom
done
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-pre-opt
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-legalize-bottom
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-legalize-upper
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-cts 
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-route  
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-final
