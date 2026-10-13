#!/usr/bin/env python3
"""Append canonical coarse-unit definitions to the wrapped top netlist."""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FLOW_HOME = os.path.dirname(os.path.dirname(SCRIPT_DIR))
sys.path.insert(0, os.path.join(SCRIPT_DIR, "common"))

from yosys_json_toolkit import dump_design, load_design, validate_design


HETERO_PLATFORM = "asap7_nangate45_3D"


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--top-netlist", required=True)
    parser.add_argument("--coarse-unit-source-dir", required=True)
    parser.add_argument("--output-netlist", required=True)
    parser.add_argument("--coarse-unit-list-out", required=True)
    parser.add_argument("--manifest-out", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--yosys", required=True)
    parser.add_argument("--work-dir", required=True)
    return parser.parse_args()


def list_coarse_units(coarse_source_dir):
    coarse_dir = Path(coarse_source_dir)
    if not coarse_dir.is_dir():
        return []
    return sorted(path for path in coarse_dir.glob("*.v") if path.is_file())


def resolve_yosys_exe(requested_path):
    if requested_path:
        return requested_path
    by_path = shutil.which("yosys")
    if by_path:
        return by_path
    fallback = Path(FLOW_HOME).parent / "ORFS-Research" / "tools" / "install" / "yosys" / "bin" / "yosys"
    return str(fallback)


def run_yosys_script(yosys_exe, body_tcl, label):
    if not os.path.exists(yosys_exe):
        raise RuntimeError("Yosys not found: {}".format(yosys_exe))
    with tempfile.NamedTemporaryFile(mode="w", suffix=".ys", delete=False) as fp:
        fp.write(body_tcl)
        script_path = fp.name
    try:
        result = subprocess.run([yosys_exe, "-s", script_path], check=False)
    finally:
        os.unlink(script_path)
    if result.returncode != 0:
        raise RuntimeError("Yosys failed during {} with exit code {}".format(label, result.returncode))


def verilog_to_json(yosys_exe, input_v, top_name, out_json):
    tcl = """
read_verilog -sv {input_v}
hierarchy -top {top_name}
proc
write_json {out_json}
""".format(
        input_v=input_v,
        top_name=top_name,
        out_json=out_json,
    )
    run_yosys_script(yosys_exe, tcl, "verilog -> json ({})".format(top_name))


def emit_json_to_verilog(yosys_exe, json_path, top_name, out_v):
    tcl = """
read_json {json_path}
hierarchy -top {top_name}
write_verilog -norename -noexpr -noattr {out_v}
""".format(
        json_path=json_path,
        top_name=top_name,
        out_v=out_v,
    )
    run_yosys_script(yosys_exe, tcl, "json -> verilog ({})".format(top_name))


def strip_known_suffix(cell_type, suffixes):
    for suffix in suffixes:
        if cell_type.endswith(suffix):
            return cell_type[: -len(suffix)]
    return cell_type


def load_map_json(platform):
    map_json = Path(FLOW_HOME) / "platforms" / platform / "map.json"
    if not map_json.is_file():
        raise RuntimeError("map.json not found for platform {}: {}".format(platform, map_json))
    with open(map_json, encoding="utf-8") as fp:
        data = json.load(fp)
    if not isinstance(data.get("cells"), dict):
        raise RuntimeError("map.json missing top-level cells dictionary: {}".format(map_json))
    return data


def build_hetero_cell_maps(platform):
    map_json = load_map_json(platform)
    cells = map_json["cells"]
    bottom_to_base = {}
    upper_to_base = {}
    upper_to_base_ports = {}
    base_names = set()

    for base_name, entry in cells.items():
        bottom_macro = entry["bottom"]["macro"]
        upper_macro = entry["upper"]["macro"]
        pin_map = dict(entry["upper"]["pin_map"])

        bottom_to_base[bottom_macro] = base_name
        upper_to_base[upper_macro] = base_name
        upper_to_base_ports[base_name] = {
            upper_pin: base_pin for base_pin, upper_pin in pin_map.items()
        }
        base_names.add(base_name)

    return {
        "base_names": base_names,
        "bottom_to_base": bottom_to_base,
        "upper_to_base": upper_to_base,
        "upper_to_base_ports": upper_to_base_ports,
    }


def remap_module_to_base_names(module, platform):
    if platform == HETERO_PLATFORM:
        hetero_maps = build_hetero_cell_maps(platform)
        bottom_to_base = hetero_maps["bottom_to_base"]
        upper_to_base = hetero_maps["upper_to_base"]
        upper_to_base_ports = hetero_maps["upper_to_base_ports"]
        base_names = hetero_maps["base_names"]

        for cell_name, cell in module.cells.items():
            if cell.type in bottom_to_base:
                cell.type = bottom_to_base[cell.type]
                continue
            if cell.type in base_names:
                continue
            if cell.type in upper_to_base:
                raise RuntimeError(
                    "heterogeneous cds-synth-netlist prepare expects bottom-tier coarse source only; "
                    "found upper-tier cell {} in module {}".format(cell.type, module.name)
                )
            if cell.type.endswith("_upper"):
                raise RuntimeError(
                    "heterogeneous cds-synth-netlist prepare found invalid pseudo upper cell {} in module {}; "
                    "coarse source should contain bottom-tier or base cells only".format(cell.type, module.name)
                )
        return

    for cell in module.cells.values():
        cell.type = strip_known_suffix(cell.type, ["_upper", "_bottom"])


def canonicalize_coarse_unit(path, platform, yosys_exe, work_dir):
    module_name = path.stem
    json_path = Path(work_dir) / "{}.base_input.json".format(module_name)
    normalized_json_path = Path(work_dir) / "{}.base_output.json".format(module_name)
    normalized_verilog_path = Path(work_dir) / "{}.base_output.v".format(module_name)

    verilog_to_json(yosys_exe, str(path), module_name, str(json_path))
    design = load_design(json_path)
    validate_design(design)
    if module_name not in design.modules:
        raise RuntimeError("module {} missing from {}".format(module_name, path))

    module = design.get_module(module_name)
    remap_module_to_base_names(module, platform)

    dump_design(design, normalized_json_path)
    validate_design(load_design(normalized_json_path))
    emit_json_to_verilog(yosys_exe, str(normalized_json_path), module_name, str(normalized_verilog_path))
    return normalized_verilog_path


def main():
    args = parse_args()
    top_netlist = Path(args.top_netlist)
    coarse_unit_paths = list_coarse_units(args.coarse_unit_source_dir)
    output_netlist = Path(args.output_netlist)
    module_list_out = Path(args.coarse_unit_list_out)
    manifest_out = Path(args.manifest_out)
    work_dir = Path(args.work_dir)
    yosys_exe = resolve_yosys_exe(args.yosys)

    if not top_netlist.is_file():
        raise SystemExit("top netlist not found: {}".format(top_netlist))

    output_netlist.parent.mkdir(parents=True, exist_ok=True)
    module_list_out.parent.mkdir(parents=True, exist_ok=True)
    manifest_out.parent.mkdir(parents=True, exist_ok=True)
    work_dir.mkdir(parents=True, exist_ok=True)

    top_text = top_netlist.read_text(encoding="utf-8", errors="replace").rstrip()
    module_names = [path.stem for path in coarse_unit_paths]
    prepared_paths = []
    for path in coarse_unit_paths:
        prepared_paths.append(canonicalize_coarse_unit(path, args.platform, yosys_exe, work_dir))

    with output_netlist.open("w", encoding="utf-8") as fp:
        fp.write(top_text)
        fp.write("\n")
        if module_names:
            fp.write("\n// ---- appended coarse-unit definitions for hierarchy Genus ----\n\n")
            for path in prepared_paths:
                fp.write("// ---- coarse-unit type: {} ----\n".format(path.stem))
                fp.write(path.read_text(encoding="utf-8", errors="replace").rstrip())
                fp.write("\n\n")

    with module_list_out.open("w", encoding="utf-8") as fp:
        for module_name in module_names:
            fp.write(module_name)
            fp.write("\n")

    manifest = {
        "top_netlist": str(top_netlist),
        "coarse_unit_source_dir": str(Path(args.coarse_unit_source_dir)),
        "output_netlist": str(output_netlist),
        "module_count": len(module_names),
        "module_names": module_names,
        "platform": args.platform,
        "prepared_module_dir": str(work_dir),
    }
    with manifest_out.open("w", encoding="utf-8") as fp:
        json.dump(manifest, fp, indent=2, sort_keys=True)
        fp.write("\n")

    print("Prepared stitched Genus input: {}".format(output_netlist))
    print("Coarse-unit type count: {}".format(len(module_names)))


if __name__ == "__main__":
    main()
