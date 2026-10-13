#!/usr/bin/env python3
"""Adapt the legacy generate_3d_views_our.py wrapper to current TaiWei."""

import argparse
import os
import sys


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FLOW_HOME = os.path.dirname(os.path.dirname(os.path.dirname(SCRIPT_DIR)))
OPENROAD_SCRIPTS_DIR = os.path.join(FLOW_HOME, "scripts_openroad")
sys.path.insert(0, OPENROAD_SCRIPTS_DIR)

from generate_3d_views import (  # noqa: E402
    parse_cell_map_json,
    parse_partition_file,
    rewrite_def,
    rewrite_verilog,
    swap_partition_labels,
)


def require_file(label, path):
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        raise RuntimeError("{} not found or empty: {}".format(label, path))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--def-in", required=True)
    parser.add_argument("--v-in", required=True)
    parser.add_argument("--partition", required=True)
    parser.add_argument("--cell-map", default="")
    parser.add_argument("--def-out", required=True)
    parser.add_argument("--v-out", required=True)
    args = parser.parse_args()

    require_file("backend preplace DEF", args.def_in)
    require_file("backend preplace netlist", args.v_in)
    require_file("backend partition", args.partition)

    canonical_partition = parse_partition_file(args.partition)
    if not canonical_partition:
        raise RuntimeError("backend partition is empty: {}".format(args.partition))

    # Shared TaiWei rewrite helpers use 0=upper and 1=bottom. 3D-Syn publishes
    # 0=bottom and 1=upper, so convert exactly once and skip orientation inference.
    internal_partition = swap_partition_labels(canonical_partition)
    (
        base_to_bottom,
        base_to_upper,
        base_to_bottom_pin_map,
        base_to_upper_pin_map,
        base_to_bottom_const_pins,
        base_to_upper_const_pins,
        _base_to_tier_areas,
        _has_heterogeneous_area_map,
        has_cell_map,
    ) = parse_cell_map_json(args.cell_map)

    rewrite_def(
        args.def_in,
        args.def_out,
        internal_partition,
        base_to_bottom,
        base_to_upper,
        base_to_bottom_pin_map,
        base_to_upper_pin_map,
        has_cell_map,
    )
    rewrite_verilog(
        args.v_in,
        args.v_out,
        internal_partition,
        base_to_bottom,
        base_to_upper,
        base_to_bottom_pin_map,
        base_to_upper_pin_map,
        base_to_bottom_const_pins,
        base_to_upper_const_pins,
        has_cell_map,
    )

    require_file("3D backend DEF", args.def_out)
    require_file("3D backend netlist", args.v_out)
    print("[3D-Syn] Published 3D DEF     : {}".format(args.def_out))
    print("[3D-Syn] Published 3D netlist : {}".format(args.v_out))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print("[3D-Syn] {}".format(error), file=sys.stderr)
        raise SystemExit(1)
