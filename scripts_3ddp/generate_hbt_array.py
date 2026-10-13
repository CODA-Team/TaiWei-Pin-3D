#!/usr/bin/env python3
"""Generate the per-run HBT array consumed by OpenROAD 3D DP.

Die geometry is sourced from the active DEF, HBT width/resistance from the
platform technology LEF, and the boundary offset from CORE_MARGIN.  The HBT
spacing is an explicit model parameter with a 0.6 um default.
"""

import argparse
import json
import math
import re
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-def", type=Path, required=True,
                        help="DEF supplying DIEAREA and DBU units")
    parser.add_argument("--source-lef", type=Path, required=True,
                        help="2A technology LEF supplying hb_layer rules")
    parser.add_argument("--design-config", type=Path, required=True,
                        help="Design config.mk supplying CORE_MARGIN")
    parser.add_argument("--hbt-spacing", type=float, default=0.6,
                        help="HBT model edge-to-edge spacing in microns "
                             "(default: 0.6)")
    parser.add_argument("--max-core-utilization", type=float, required=True)
    parser.add_argument("--required-connections", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def snap(value, dbu_per_micron):
    return round(value * dbu_per_micron) / dbu_per_micron


def require_match(pattern, text, description, flags=0):
    match = re.search(pattern, text, flags)
    if not match:
        raise SystemExit(f"unable to find {description}")
    return match


def parse_def(path):
    """Return die bounds in microns and the DBU scale from a DEF file."""
    text = path.read_text(encoding="utf-8", errors="replace")
    dbu = int(require_match(
        r"\bUNITS\s+DISTANCE\s+MICRONS\s+(\d+)\s*;", text,
        f"UNITS DISTANCE MICRONS in DEF '{path}'", re.IGNORECASE).group(1))
    die = require_match(
        r"\bDIEAREA\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*"
        r"\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*;", text,
        f"DIEAREA in DEF '{path}'", re.IGNORECASE)
    die_dbu = tuple(int(value) for value in die.groups())
    return tuple(value / dbu for value in die_dbu), dbu


def parse_hbt_layer(path):
    """Read the HBT CUT-layer geometry directly from the selected 2A LEF."""
    text = path.read_text(encoding="utf-8", errors="replace")
    block = require_match(
        r"\bLAYER\s+(hb_layer)\s*(.*?)\bEND\s+\1\s*;?", text,
        f"hb_layer definition in LEF '{path}'", re.IGNORECASE | re.DOTALL)
    layer, body = block.group(1), block.group(2)
    layer_type = require_match(r"\bTYPE\s+(\S+)\s*;", body,
                               f"TYPE for layer '{layer}'").group(1)
    if layer_type.upper() != "CUT":
        raise SystemExit(f"HBT layer '{layer}' in '{path}' must be TYPE CUT")
    width = float(require_match(r"\bWIDTH\s+([0-9.eE+-]+)\s*;", body,
                                f"WIDTH for layer '{layer}'").group(1))
    spacing = float(require_match(r"\bSPACING\s+([0-9.eE+-]+)\s*;", body,
                                  f"SPACING for layer '{layer}'").group(1))
    resistance = float(require_match(
        r"\bRESISTANCE\s+([0-9.eE+-]+)\s*;", body,
        f"RESISTANCE for layer '{layer}'").group(1))
    return layer, width, spacing, resistance


def parse_core_margin(path):
    """Read the numeric CORE_MARGIN assigned by the design/case config."""
    text = path.read_text(encoding="utf-8", errors="replace")
    match = require_match(
        r"^\s*(?:export\s+)?CORE_MARGIN\s*(?:\?|\+|:)?=\s*"
        r"([0-9.eE+-]+)\b", text,
        f"numeric CORE_MARGIN in design config '{path}'", re.MULTILINE)
    return float(match.group(1))


def main():
    args = parse_args()
    (die_lx, die_ly, die_ux, die_uy), dbu_per_micron = parse_def(args.source_def)
    layer, hbt_width, _lef_min_spacing, resistance = parse_hbt_layer(
        args.source_lef)
    # The array uses an explicit experiment-model spacing.  Keep reading the
    # LEF to validate hb_layer and obtain its width/resistance, but do not
    # modify the technology rule itself.
    min_spacing = args.hbt_spacing
    boundary_offset = parse_core_margin(args.design_config)
    width = die_ux - die_lx
    height = die_uy - die_ly
    min_pitch = hbt_width + min_spacing
    available_width = width - 2.0 * boundary_offset
    available_height = height - 2.0 * boundary_offset

    if width <= 0.0 or height <= 0.0:
        raise SystemExit("invalid die area")
    if hbt_width <= 0.0 or min_spacing < 0.0:
        raise SystemExit("HBT width must be positive and spacing non-negative")
    if available_width < hbt_width or available_height < hbt_width:
        raise SystemExit("HBT boundary offset leaves no usable array area")
    if not 0.0 < args.max_core_utilization <= 1.0:
        raise SystemExit("HBT max core utilization must be in (0, 1]")
    if args.required_connections < 0:
        raise SystemExit("required HBT connection count cannot be negative")

    # gen_hbt.py uses the shorter side to make an n x n array, then expands
    # the X/Y pitches to span the allowed region without violating min_pitch.
    min_available = min(available_width, available_height)
    dimension = int(math.floor((min_available - hbt_width) / min_pitch)) + 1
    if dimension < 2:
        raise SystemExit("chip is too small for at least a 2x2 HBT array")
    pitch_x = (available_width - hbt_width) / (dimension - 1)
    pitch_y = (available_height - hbt_width) / (dimension - 1)
    if pitch_x + 1e-9 < min_pitch or pitch_y + 1e-9 < min_pitch:
        raise SystemExit("generated HBT pitch is below the requested minimum")
    rows = dimension
    columns = dimension
    required_sites = int(math.ceil(
        args.required_connections / args.max_core_utilization))
    if rows * columns < required_sites:
        raise SystemExit(
            f"HBT capacity is insufficient: {rows * columns} sites for "
            f"{args.required_connections} cross-tier nets at "
            f"{args.max_core_utilization:.3f} maximum utilization")
    first_x = snap(die_lx + boundary_offset + hbt_width / 2.0, dbu_per_micron)
    first_y = snap(die_ly + boundary_offset + hbt_width / 2.0, dbu_per_micron)

    positions = []
    for row in range(rows):
        for column in range(columns):
            x = snap(first_x + column * pitch_x, dbu_per_micron)
            y = snap(first_y + row * pitch_y, dbu_per_micron)
            positions.append({
                "id": f"hbt_{row}_{column}",
                "row": row,
                "col": column,
                "x_um": x,
                "y_um": y,
                "width_um": hbt_width,
                "layer": layer,
                "bbox_um": {
                    "x_min": round(x - hbt_width / 2.0, 4),
                    "x_max": round(x + hbt_width / 2.0, 4),
                    "y_min": round(y - hbt_width / 2.0, 4),
                    "y_max": round(y + hbt_width / 2.0, 4),
                },
            })

    payload = {
        "chip_info": {
            "width_um": width,
            "height_um": height,
            "origin_um": [die_lx, die_ly],
            "units": "microns",
            "source_def": str(args.source_def),
            "diearea_dbu": [
                round(die_lx * dbu_per_micron),
                round(die_ly * dbu_per_micron),
                round(die_ux * dbu_per_micron),
                round(die_uy * dbu_per_micron),
            ],
            "dbu_per_micron": dbu_per_micron,
        },
        "hbt_constraints": {
            "width_um": hbt_width,
            "spacing_um": min_spacing,
            "center_to_center_um": min_pitch,
            "boundary_offset_um": boundary_offset,
            "source_lef": str(args.source_lef),
            "layer": layer,
            "layer_type": "CUT",
            "resistance_ohm": resistance,
            "max_core_utilization": args.max_core_utilization,
            "required_connections": args.required_connections,
            "required_sites": required_sites,
        },
        "hbt_array": {
            "rows": rows,
            "columns": columns,
            "pitch_um": round(pitch_x, 4),
            "total_count": len(positions),
            "available_region_um": {
                "x_min": die_lx + boundary_offset,
                "x_max": die_ux - boundary_offset,
                "y_min": die_ly + boundary_offset,
                "y_max": die_uy - boundary_offset,
            },
            "first_center_um": {"x": first_x, "y": first_y},
        },
        "hbt_positions": positions,
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2) + "\n", encoding="ascii")
    print(f"Generated {rows}x{columns} HBT array ({len(positions)} sites): {args.output}")


if __name__ == "__main__":
    main()
