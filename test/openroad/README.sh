#!/usr/bin/env bash
# Example: the default OpenROAD pipeline on native-3d.
# Requires Genus, 3D-Syn-enabled Yosys, and TDP/3DCTS-enabled OpenROAD.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/ORD_3D_NEW_FLOW.sh" \
  "${ENABLEMENT:-nangate45_3D}" "${FLOW_VARIANT:-example}" \
  openroad "${DESIGN_NICKNAME:-gcd}"
