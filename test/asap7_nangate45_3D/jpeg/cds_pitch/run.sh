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
export DESIGN_NICKNAME="jpeg"
export USE_FLOW="cadence"
export FLOW_VARIANT="cadence_${hbPitch}"
mkdir -p results/asap7_nangate45_3D/${DESIGN_NICKNAME}/${FLOW_VARIANT}
cp -r results/asap7_nangate45_3D/${DESIGN_NICKNAME}/${USE_FLOW}/partition.txt results/asap7_nangate45_3D/${DESIGN_NICKNAME}/${FLOW_VARIANT} 
cp -r results/asap7_nangate45/${DESIGN_NICKNAME}/${USE_FLOW}/* results/asap7_nangate45_3D/${DESIGN_NICKNAME}/${FLOW_VARIANT} 
export TECH_LEF="platforms/asap7_nangate45_3D/lef/cds_pitch_variant/asap7_nangate45_8M10M.${hbPitch}.lef"
make DESIGN_CONFIG=designs/asap7_nangate45_3D/${DESIGN_NICKNAME}/config.mk ord-pre
make DESIGN_CONFIG=designs/asap7_nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-3d-pdn
make DESIGN_CONFIG=designs/asap7_nangate45_3D/${DESIGN_NICKNAME}/config_upper_cover.mk cds-place-init
make DESIGN_CONFIG=designs/asap7_nangate45_3D/${DESIGN_NICKNAME}/config_bottom_cover.mk cds-place-init-upper
make DESIGN_CONFIG=designs/asap7_nangate45_3D/${DESIGN_NICKNAME}/config_upper_cover.mk cds-place-init-bottom
iteration=1
for ((i=1;i<=iteration;i++))
do
    echo "Iteration: $i"
    make DESIGN_CONFIG=designs/asap7_nangate45_3D/${DESIGN_NICKNAME}/config_bottom_cover.mk cds-place-upper
    make DESIGN_CONFIG=designs/asap7_nangate45_3D/${DESIGN_NICKNAME}/config_upper_cover.mk cds-place-bottom
done
make DESIGN_CONFIG=designs/asap7_nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-place-finish
make DESIGN_CONFIG=designs/asap7_nangate45_3D/${DESIGN_NICKNAME}/config_upper_cover.mk cds-legalize-bottom
make DESIGN_CONFIG=designs/asap7_nangate45_3D/${DESIGN_NICKNAME}/config_bottom_cover.mk cds-legalize-upper
make DESIGN_CONFIG=designs/asap7_nangate45_3D/${DESIGN_NICKNAME}/config_upper_cover.mk cds-cts 
make DESIGN_CONFIG=designs/asap7_nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-route 
make DESIGN_CONFIG=designs/asap7_nangate45_3D/${DESIGN_NICKNAME}/config.mk cds-final 
