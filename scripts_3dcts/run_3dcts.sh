#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
flow_root=$(cd "$script_dir/.." && pwd)

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <design-config> [flow-variant]" >&2
  exit 2
fi

design_config=$1
flow_variant=${2:-3dcts}

if [[ "$design_config" = /* ]]; then
  resolved_config=$design_config
else
  resolved_config=$flow_root/$design_config
fi

if [[ ! -f "$resolved_config" ]]; then
  echo "ERROR: design config not found: $resolved_config" >&2
  exit 1
fi

exec make -C "$flow_root" \
  DESIGN_CONFIG="$resolved_config" \
  FLOW_VARIANT="$flow_variant" \
  ord-cts-3d
