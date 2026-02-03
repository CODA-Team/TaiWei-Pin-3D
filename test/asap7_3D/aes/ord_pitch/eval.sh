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
export TECH_LEF="platforms/asap7_3D/lef/ord_pitch_variant/asap7_tech_1x_2A6M7M.${hbPitch}.lef"
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk cds-final
