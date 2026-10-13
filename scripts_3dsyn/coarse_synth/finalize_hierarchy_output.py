#!/usr/bin/env python3
"""Publish actual coarse-unit variants from whole-design hierarchy Genus."""

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter, OrderedDict
from pathlib import Path
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FLOW_HOME = os.path.dirname(os.path.dirname(SCRIPT_DIR))
sys.path.insert(0, os.path.join(SCRIPT_DIR, "common"))

from yosys_json_toolkit import Design, dump_design, load_design, module_interface_signature, validate_design


BOTTOM = "bottom"
UPPER = "upper"
TWO_DIMENSIONAL = "2d"
HETERO_PLATFORM = "asap7_nangate45_3D"
TRUE_ATTR = "00000000000000000000000000000001"
ELIMINATE_ATTR = "_3dsyn_eliminate"
CELL_AREA_CACHE = {}


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--design-name", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--yosys", required=True)
    parser.add_argument("--input-verilog", required=True)
    parser.add_argument("--output-verilog", required=True)
    parser.add_argument("--coarse-unit-source-dir", required=True)
    parser.add_argument("--coarse-unit-list", required=True)
    parser.add_argument("--family-metrics-dir", required=True)
    parser.add_argument("--handoff-dir", required=True)
    parser.add_argument("--work-dir", required=True)
    return parser.parse_args()


def resolve_yosys_exe(requested_path):
    if requested_path:
        return requested_path
    by_path = shutil.which("yosys")
    if by_path:
        return by_path
    fallback = Path(FLOW_HOME).parent / "ORFS-Research" / "tools" / "install" / "yosys" / "bin" / "yosys"
    return str(fallback)


def run_yosys_script(yosys_exe, body_tcl, label, env=None):
    if not os.path.exists(yosys_exe):
        raise RuntimeError("Yosys not found: {}".format(yosys_exe))
    with tempfile.NamedTemporaryFile(mode="w", suffix=".ys", delete=False) as fp:
        fp.write(body_tcl)
        script_path = fp.name
    try:
        result = subprocess.run([yosys_exe, "-s", script_path], check=False, env=env)
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


def verilog_to_json_no_hierarchy(yosys_exe, input_v, out_json):
    tcl = """
read_verilog -sv {input_v}
proc
write_json {out_json}
""".format(
        input_v=input_v,
        out_json=out_json,
    )
    run_yosys_script(yosys_exe, tcl, "verilog -> json (all modules)")


def infer_top_module_name(yosys_exe, input_v, work_dir):
    out_json = Path(work_dir) / "auto_top_probe.json"
    verilog_to_json_no_hierarchy(yosys_exe, input_v, out_json)
    design = load_design(out_json)
    validate_design(design)
    referenced_by_other = Counter()
    hierarchical_cell_counts = {}
    for module_name, module in design.modules.items():
        hierarchical_count = 0
        for cell in module.cells.values():
            if cell.type in design.modules:
                referenced_by_other[cell.type] += 1
                hierarchical_count += 1
        hierarchical_cell_counts[module_name] = hierarchical_count

    root_candidates = [
        module_name
        for module_name in design.modules
        if referenced_by_other[module_name] == 0
    ]
    if not root_candidates:
        raise RuntimeError("failed to infer top module: no root candidates")
    if len(root_candidates) == 1:
        return root_candidates[0]

    hierarchical_roots = [
        module_name
        for module_name in root_candidates
        if hierarchical_cell_counts[module_name] > 0
    ]
    if len(hierarchical_roots) == 1:
        return hierarchical_roots[0]

    def compute_depth(module_name, memo, stack):
        if module_name in memo:
            return memo[module_name]
        if module_name in stack:
            raise RuntimeError("cycle detected while inferring top module at {}".format(module_name))
        stack.add(module_name)
        child_depths = []
        for cell in design.get_module(module_name).cells.values():
            if cell.type in design.modules:
                child_depths.append(compute_depth(cell.type, memo, stack) + 1)
        stack.remove(module_name)
        memo[module_name] = max(child_depths) if child_depths else 0
        return memo[module_name]

    depth_memo = {}
    ranked = []
    for module_name in root_candidates:
        ranked.append(
            (
                compute_depth(module_name, depth_memo, set()),
                hierarchical_cell_counts[module_name],
                module_name,
            )
        )
    ranked.sort(reverse=True)
    best = ranked[0]
    tied = [item for item in ranked if item[:2] == best[:2]]
    if len(tied) != 1:
        raise RuntimeError(
            "failed to infer a unique top module; root candidates ranked as {}".format(ranked)
        )
    return best[2]


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


def read_module_list(path):
    module_names = []
    with open(path, encoding="utf-8") as fp:
        for line in fp:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            module_names.append(line)
    return module_names


def load_map_json():
    map_json = Path(FLOW_HOME) / "platforms" / HETERO_PLATFORM / "map.json"
    with open(map_json, encoding="utf-8") as fp:
        data = json.load(fp)
    if not isinstance(data.get("cells"), dict):
        raise RuntimeError("map.json missing cells dictionary: {}".format(map_json))
    return data


def load_platform_lib_cell_areas(platform, tier):
    cache_key = (platform, tier)
    if cache_key in CELL_AREA_CACHE:
        return CELL_AREA_CACHE[cache_key]

    lib_root = Path(FLOW_HOME) / "platforms" / platform / "lib_{}".format(tier)
    area_map = {}
    if lib_root.is_dir():
        for lib_path in sorted(lib_root.rglob("*.lib")):
            current_cell = None
            depth = 0
            for line in lib_path.open(encoding="utf-8", errors="ignore"):
                if current_cell is None:
                    match = re.match(r"\s*cell\s*\(\s*([^)]+?)\s*\)\s*\{", line)
                    if match:
                        current_cell = match.group(1)
                        depth = 1
                    continue
                depth += line.count("{")
                depth -= line.count("}")
                area_match = re.match(r"\s*area\s*:\s*([0-9eE.+-]+)\s*;?\s*$", line)
                if area_match and current_cell not in area_map:
                    area_map[current_cell] = float(area_match.group(1))
                if depth <= 0:
                    current_cell = None
                    depth = 0
    CELL_AREA_CACHE[cache_key] = area_map
    return area_map


def build_map_tables(platform):
    cells = load_map_json()["cells"] if platform == HETERO_PLATFORM else {}
    tables = {
        "cells": cells,
        "base_to_bottom": {},
        "base_to_upper": {},
        "bottom_to_base": {},
        "upper_to_base": {},
        "base_to_upper_ports": {},
        "upper_to_base_ports": {},
    }
    for base_name, entry in cells.items():
        bottom_macro = entry["bottom"]["macro"]
        upper_macro = entry["upper"]["macro"]
        tables["base_to_bottom"][base_name] = bottom_macro
        tables["base_to_upper"][base_name] = upper_macro
        tables["bottom_to_base"][bottom_macro] = base_name
        tables["upper_to_base"][upper_macro] = base_name
        pin_map = dict(entry["upper"]["pin_map"])
        tables["base_to_upper_ports"][base_name] = pin_map
        tables["upper_to_base_ports"][base_name] = {
            upper_pin: base_pin for base_pin, upper_pin in pin_map.items()
        }
    return tables


def load_single_module_from_verilog(yosys_exe, verilog_path, module_name, work_dir, tag):
    json_path = Path(work_dir) / "{}_{}.json".format(module_name, tag)
    verilog_to_json(yosys_exe, verilog_path, module_name, json_path)
    design = load_design(json_path)
    validate_design(design)
    if module_name not in design.modules:
        raise RuntimeError("verilog {} missing module {}".format(verilog_path, module_name))
    return design.get_module(module_name)


def load_canonical_contracts(yosys_exe, coarse_unit_source_dir, module_names, work_dir):
    coarse_unit_source_dir = Path(coarse_unit_source_dir)
    contracts = {}
    for module_name in module_names:
        json_path = coarse_unit_source_dir / "{}.json".format(module_name)
        verilog_path = coarse_unit_source_dir / "{}.v".format(module_name)
        if json_path is not None:
            if not json_path.is_file():
                json_path = None
        if json_path is not None:
            design = load_design(str(json_path))
            validate_design(design)
            if module_name not in design.modules:
                raise RuntimeError("coarse-unit JSON missing module {}: {}".format(module_name, json_path))
            module = design.get_module(module_name)
        elif verilog_path.is_file():
            module = load_single_module_from_verilog(yosys_exe, verilog_path, module_name, work_dir, "contract")
        else:
            raise RuntimeError("missing coarse-unit implementation for {} under {}".format(
                module_name, coarse_unit_source_dir))
        contracts[module_name] = {
            "interface": module_interface_signature(module),
            "port_directions": {
                port_name: port.direction
                for port_name, port in module.ports.items()
            },
        }
    return contracts


def infer_family_name(actual_name, module_obj, canonical_contracts):
    if actual_name in canonical_contracts:
        return actual_name

    iface = module_interface_signature(module_obj)
    prefix_matches = []
    prefix_only_matches = []
    for canonical_name in sorted(canonical_contracts.keys(), key=len, reverse=True):
        if not actual_name.startswith(canonical_name):
            continue
        if len(actual_name) > len(canonical_name) and actual_name[len(canonical_name)] not in "_$":
            continue
        prefix_only_matches.append(canonical_name)
        if iface == canonical_contracts[canonical_name]["interface"]:
            prefix_matches.append(canonical_name)
    if len(prefix_matches) == 1:
        return prefix_matches[0]
    if len(prefix_only_matches) == 1:
        return prefix_only_matches[0]

    iface_matches = [
        canonical_name
        for canonical_name, contract in canonical_contracts.items()
        if iface == contract["interface"]
    ]
    if len(iface_matches) == 1:
        return iface_matches[0]

    raise RuntimeError(
        "cannot map actual coarse-unit type {} to a unique source type; prefix_matches={} iface_matches={}".format(
            actual_name,
            prefix_only_matches,
            iface_matches,
        )
    )


def collect_top_referenced_actual_modules(design, top_name, canonical_contracts):
    top_module = design.get_module(top_name)
    type_counts = Counter(cell.type for cell in top_module.cells.values())
    actual_modules = OrderedDict()
    for module_name in sorted(type_counts.keys()):
        if module_name not in design.modules:
            continue
        if module_name == top_name:
            continue
        module_obj = design.get_module(module_name).copy()
        family_name = infer_family_name(module_name, module_obj, canonical_contracts)
        actual_modules[module_name] = {
            "module": module_obj,
            "family_name": family_name,
            "top_instance_count": type_counts[module_name],
        }
    return actual_modules


def flatten_eliminated_actual_instances(
        yosys_exe, raw_design, top_name, eliminated_actual_modules, work_dir):
    eliminated_actual_modules = set(eliminated_actual_modules)
    if not eliminated_actual_modules:
        return raw_design, None, 0

    marked_design = raw_design.copy()
    top_module = marked_design.get_module(top_name)
    marked_instance_count = 0
    for cell in top_module.cells.values():
        if cell.type in eliminated_actual_modules:
            cell.attributes[ELIMINATE_ATTR] = TRUE_ATTR
            marked_instance_count += 1

    if marked_instance_count == 0:
        raise RuntimeError(
            "no top-level instances found for eliminated actual modules: {}".format(
                sorted(eliminated_actual_modules)
            )
        )

    work_dir = Path(work_dir)
    marked_json = work_dir / "1_synth_netlist.zero_area_marked.json"
    pruned_json = work_dir / "1_synth_netlist.zero_area_flattened.json"
    dump_design(marked_design, marked_json)
    validate_design(load_design(marked_json))

    flatten_tcl = """
read_json {marked_json}
select -assert-count {marked_instance_count} a:{eliminate_attr}=1
flatten -noscopeinfo a:{eliminate_attr}=1
select -assert-none a:{eliminate_attr}=1
write_json {pruned_json}
""".format(
        marked_json=marked_json,
        marked_instance_count=marked_instance_count,
        eliminate_attr=ELIMINATE_ATTR,
        pruned_json=pruned_json,
    )
    run_yosys_script(yosys_exe, flatten_tcl, "zero-area actual-unit flatten")

    pruned_design = load_design(pruned_json)
    validate_design(pruned_design)
    remaining_types = sorted({
        cell.type
        for cell in pruned_design.get_module(top_name).cells.values()
        if cell.type in eliminated_actual_modules
    })
    if remaining_types:
        raise RuntimeError(
            "top still references eliminated actual modules after flatten: {}".format(
                remaining_types
            )
        )
    return pruned_design, pruned_json, marked_instance_count


def build_active_design(raw_design, top_name, actual_modules):
    modules = OrderedDict()
    modules[top_name] = raw_design.get_module(top_name).copy()
    for module_name, info in actual_modules.items():
        modules[module_name] = info["module"].copy()
    return Design(
        creator="normalize_genus_coarse_hierarchy_output.py",
        modules=modules,
    )


def build_top_only_design(design, top_name):
    return Design(
        creator="normalize_genus_coarse_hierarchy_output.py",
        modules=OrderedDict([(top_name, design.get_module(top_name).copy())]),
    )


def validate_top_level_contract(design, top_name, actual_module_names):
    if top_name not in design.modules:
        raise RuntimeError("top module missing after normalization: {}".format(top_name))
    top_module = design.get_module(top_name)
    bad_instance_names = sorted(name for name in top_module.cells if "/" in name)
    if bad_instance_names:
        raise RuntimeError(
            "top-level instance names contain '/': {}".format(", ".join(bad_instance_names[:20]))
        )
    referenced = sorted(
        {cell.type for cell in top_module.cells.values() if cell.type in design.modules and cell.type != top_name}
    )
    unexpected = sorted(name for name in referenced if name not in actual_module_names)
    if unexpected:
        raise RuntimeError("top still references unexpected hierarchical modules: {}".format(unexpected))
    return {
        "top_instance_count": len(top_module.cells),
        "referenced_coarse_unit_types_from_top": referenced,
        "retained_non_top_modules": sorted(name for name in design.modules if name != top_name),
    }


def remap_cell_connection_ports(module, port_map, cell_names=None, strict=False):
    if cell_names is None:
        target_cells = module.cells.values()
    else:
        target_cells = [module.cells[name] for name in cell_names]
    for cell in target_cells:
        new_connections = OrderedDict()
        new_directions = OrderedDict()
        seen_new = set()
        for old_name, bits in cell.connections.items():
            new_name = port_map.get(old_name, old_name)
            if new_name in seen_new:
                raise RuntimeError("duplicate remapped port {} on cell {}".format(new_name, cell.name))
            seen_new.add(new_name)
            new_connections[new_name] = list(bits)
            if old_name in cell.port_directions:
                new_directions[new_name] = cell.port_directions[old_name]
            elif strict:
                raise RuntimeError("missing port direction for {}.{}".format(cell.name, old_name))
        cell.connections = new_connections
        cell.port_directions = new_directions


def classify_hetero_cell_type(cell_type, map_tables):
    if cell_type in map_tables["base_to_bottom"]:
        return ("base", cell_type)
    if cell_type in map_tables["bottom_to_base"]:
        return ("bottom", map_tables["bottom_to_base"][cell_type])
    if cell_type in map_tables["upper_to_base"]:
        return ("upper", map_tables["upper_to_base"][cell_type])
    if cell_type.endswith("_upper"):
        base_name = cell_type[: -len("_upper")]
        if base_name in map_tables["base_to_upper"]:
            return ("pseudo_upper", base_name)
    return (None, None)


def remap_module_for_target(module, platform, target_tier, map_tables):
    if platform == HETERO_PLATFORM:
        for cell_name, cell in module.cells.items():
            current_form, base_name = classify_hetero_cell_type(cell.type, map_tables)
            if base_name is None:
                continue
            if current_form == "upper" and target_tier == BOTTOM:
                remap_cell_connection_ports(
                    module,
                    map_tables["upper_to_base_ports"][base_name],
                    cell_names=[cell_name],
                    strict=False,
                )
            elif target_tier == UPPER and current_form in {"base", "bottom", "pseudo_upper"}:
                remap_cell_connection_ports(
                    module,
                    map_tables["base_to_upper_ports"][base_name],
                    cell_names=[cell_name],
                    strict=False,
                )

            if target_tier == BOTTOM:
                cell.type = map_tables["base_to_bottom"][base_name]
            else:
                cell.type = map_tables["base_to_upper"][base_name]
        return

    suffix = "_bottom" if target_tier == BOTTOM else "_upper"
    other_suffix = "_upper" if target_tier == BOTTOM else "_bottom"
    for cell in module.cells.values():
        if cell.type.endswith(suffix):
            continue
        if cell.type.endswith(other_suffix):
            cell.type = cell.type[: -len(other_suffix)] + suffix
        else:
            cell.type = cell.type + suffix


def prepare_output_locations(handoff_dir):
    handoff_dir = Path(handoff_dir)
    if handoff_dir.exists():
        shutil.rmtree(handoff_dir)
    for path in [
        handoff_dir / "coarse_units" / BOTTOM,
        handoff_dir / "coarse_units" / UPPER,
        handoff_dir / "metrics" / BOTTOM,
        handoff_dir / "metrics" / UPPER,
        handoff_dir / "lef" / BOTTOM,
        handoff_dir / "lef" / UPPER,
        handoff_dir / "lef" / TWO_DIMENSIONAL,
        handoff_dir / "lib" / TWO_DIMENSIONAL,
        handoff_dir / "lib" / BOTTOM,
        handoff_dir / "lib" / UPPER,
    ]:
        path.mkdir(parents=True, exist_ok=True)


def write_single_module_verilog(yosys_exe, module_name, module_obj, out_v, work_dir, tag):
    single_design = Design(
        creator="finalize_hierarchy_output.py",
        modules=OrderedDict([(module_name, module_obj.copy())]),
    )
    json_path = Path(work_dir) / "{}_{}.json".format(module_name, tag)
    dump_design(single_design, json_path)
    validate_design(load_design(json_path))
    emit_json_to_verilog(yosys_exe, json_path, module_name, out_v)


def load_family_metrics(family_metrics_dir, family_name):
    family_metrics_dir = Path(family_metrics_dir)
    bottom_path = family_metrics_dir / BOTTOM / family_name / "metrics.json"
    upper_path = family_metrics_dir / UPPER / family_name / "metrics.json"
    if bottom_path is None:
        raise RuntimeError("missing bottom family metrics for {}".format(family_name))
    if not bottom_path.is_file():
        raise RuntimeError("missing bottom family metrics: {}".format(bottom_path))
    if not upper_path.is_file():
        raise RuntimeError("missing upper family metrics: {}".format(upper_path))
    with open(bottom_path, encoding="utf-8") as fp:
        bottom_metrics = json.load(fp)
    with open(upper_path, encoding="utf-8") as fp:
        upper_metrics = json.load(fp)
    return {
        BOTTOM: bottom_metrics,
        UPPER: upper_metrics,
    }


def resolve_cell_area(cell_type, platform, target_tier, map_tables):
    cells = map_tables["cells"]
    lib_area_map = load_platform_lib_cell_areas(platform, target_tier)
    if cell_type in lib_area_map:
        return float(lib_area_map[cell_type])
    if platform == HETERO_PLATFORM:
        if cell_type in map_tables["bottom_to_base"]:
            entry = cells[map_tables["bottom_to_base"][cell_type]][BOTTOM]
            return float(entry["width"]) * float(entry["height"])
        if cell_type in map_tables["upper_to_base"]:
            entry = cells[map_tables["upper_to_base"][cell_type]][UPPER]
            return float(entry["width"]) * float(entry["height"])
        raise RuntimeError("cannot resolve hetero cell area for {}".format(cell_type))

    if cell_type.endswith("_bottom"):
        base_name = cell_type[: -len("_bottom")]
    elif cell_type.endswith("_upper"):
        base_name = cell_type[: -len("_upper")]
    else:
        base_name = cell_type
    if base_name not in cells:
        if base_name in map_tables["upper_to_base"]:
            base_name = map_tables["upper_to_base"][base_name]
        elif base_name in map_tables["bottom_to_base"]:
            base_name = map_tables["bottom_to_base"][base_name]
        else:
            raise RuntimeError("cannot resolve homogeneous cell base {} from {}".format(base_name, cell_type))

    if platform == "nangate45_3D":
        entry = cells[base_name][BOTTOM]
    elif platform == "asap7_3D":
        entry = cells[base_name][UPPER]
    else:
        raise RuntimeError("unsupported platform for area lookup: {}".format(platform))
    return float(entry["width"]) * float(entry["height"])


def compute_module_leaf_area(module_obj, platform, target_tier, map_tables):
    total = 0.0
    for cell in module_obj.cells.values():
        total += resolve_cell_area(cell.type, platform, target_tier, map_tables)
    return total


def should_eliminate_actual_unit(
        actual_name, bottom_area, upper_area, bottom_cell_count, upper_cell_count):
    zero_area_candidate = bottom_area == 0.0 and upper_area == 0.0
    if not zero_area_candidate:
        return False
    if bottom_cell_count != 0 or upper_cell_count != 0:
        raise RuntimeError(
            "zero-area actual unit {} must have zero cells in both tiers; "
            "bottom_cell_count={} upper_cell_count={}".format(
                actual_name,
                bottom_cell_count,
                upper_cell_count,
            )
        )
    return True


def prepare_actual_variant_data(args, actual_modules):
    map_tables = build_map_tables(args.platform)
    variant_data = OrderedDict()
    eliminated_actual_modules = OrderedDict()

    for actual_name, info in actual_modules.items():
        bottom_module = info["module"].copy()
        remap_module_for_target(bottom_module, args.platform, BOTTOM, map_tables)
        bottom_area = compute_module_leaf_area(
            bottom_module, args.platform, BOTTOM, map_tables)

        upper_module = info["module"].copy()
        remap_module_for_target(upper_module, args.platform, UPPER, map_tables)
        upper_area = compute_module_leaf_area(
            upper_module, args.platform, UPPER, map_tables)

        bottom_cell_count = len(bottom_module.cells)
        upper_cell_count = len(upper_module.cells)
        eliminated = should_eliminate_actual_unit(
            actual_name,
            bottom_area,
            upper_area,
            bottom_cell_count,
            upper_cell_count,
        )
        data = {
            "family_name": info["family_name"],
            "top_instance_count": info["top_instance_count"],
            "bottom_module": bottom_module,
            "upper_module": upper_module,
            "bottom_area": bottom_area,
            "upper_area": upper_area,
            "bottom_cell_count": bottom_cell_count,
            "upper_cell_count": upper_cell_count,
            "eliminated": eliminated,
        }
        variant_data[actual_name] = data
        if eliminated:
            eliminated_actual_modules[actual_name] = {
                "family_name": info["family_name"],
                "top_instance_count": info["top_instance_count"],
                "bottom_cell_area": round_to_milli(bottom_area),
                "upper_cell_area": round_to_milli(upper_area),
                "bottom_cell_count": bottom_cell_count,
                "upper_cell_count": upper_cell_count,
            }

    return {
        "variant_data": variant_data,
        "eliminated_actual_modules": eliminated_actual_modules,
    }


def round_to_milli(value):
    return round(float(value) + 1e-9, 3)


def build_actual_metrics(actual_name, family_name, platform, bottom_area, upper_area, family_metrics):
    bottom_family = family_metrics[BOTTOM]
    upper_family = family_metrics[UPPER]

    predicted_util = bottom_family.get("predicted_utilization")
    if predicted_util is None or not (float(predicted_util) > 0.0):
        raise RuntimeError("family {} bottom metrics missing predicted_utilization".format(family_name))
    predicted_util = float(predicted_util)
    bottom_footprint = round_to_milli(bottom_area / predicted_util)

    scale_factor = upper_family.get("scale_factor")
    if scale_factor is None:
        upper_family_area = float(upper_family["footprint_area"])
        bottom_family_area = float(bottom_family["footprint_area"])
        if not (bottom_family_area > 0.0):
            raise RuntimeError("invalid family bottom footprint area for {}".format(family_name))
        scale_factor = upper_family_area / bottom_family_area
    scale_factor = float(scale_factor)
    if not (scale_factor > 0.0):
        raise RuntimeError("invalid scale_factor {} for family {}".format(scale_factor, family_name))
    upper_footprint = round_to_milli(bottom_footprint * scale_factor)

    metrics = {
        BOTTOM: {
            "schema_version": 1,
            "macro_name": actual_name,
            "rtlil_name": "\\{}".format(actual_name),
            "library": platform,
            "tier": BOTTOM,
            "synthesis_source": "genus_actual_variant_preserved",
            "util_source": bottom_family.get("util_source", "family_reuse"),
            "synthesis_lib_role": bottom_family.get("synthesis_lib_role"),
            "gnn_tech": bottom_family.get("gnn_tech"),
            "cell_area": round_to_milli(bottom_area),
            "raw_predicted_utilization": bottom_family.get("raw_predicted_utilization"),
            "predicted_utilization": round_to_milli(predicted_util),
            "footprint_area": bottom_footprint,
            "footprint_source": "actual_cell_area / family_predicted_utilization",
            "family_name": family_name,
        },
        UPPER: {
            "schema_version": 1,
            "macro_name": actual_name,
            "rtlil_name": "\\{}".format(actual_name),
            "library": platform,
            "tier": UPPER,
            "synthesis_source": "genus_actual_variant_preserved",
            "util_source": upper_family.get("util_source", "family_reuse"),
            "synthesis_lib_role": upper_family.get("synthesis_lib_role"),
            "gnn_tech": upper_family.get("gnn_tech"),
            "cell_area": round_to_milli(upper_area),
            "raw_predicted_utilization": upper_family.get("raw_predicted_utilization"),
            "predicted_utilization": upper_family.get("predicted_utilization"),
            "footprint_area": upper_footprint,
            "footprint_source": "scaled_from_bottom",
            "scale_from_tier": BOTTOM,
            "scale_factor": round_to_milli(scale_factor),
            "family_name": family_name,
        },
    }
    return metrics


def write_metrics(handoff_dir, actual_name, metrics_by_tier):
    for tier, metrics in metrics_by_tier.items():
        metrics_dir = Path(handoff_dir) / "metrics" / tier / actual_name
        metrics_dir.mkdir(parents=True, exist_ok=True)
        with open(metrics_dir / "metrics.json", "w", encoding="utf-8") as fp:
            json.dump(metrics, fp, indent=2, sort_keys=False)
            fp.write("\n")


def coarse_unit_lef_style(platform, view):
    if view not in {TWO_DIMENSIONAL, BOTTOM, UPPER}:
        raise RuntimeError("unsupported coarse-unit LEF view: {}".format(view))

    if platform == "asap7_3D":
        layer = "M4_m" if view == UPPER else "M4"
        return {"layer": layer, "pin_rect_w": 0.024, "pin_rect_h": 0.024, "grid": 0.001}

    if platform == "nangate45_3D":
        layer = "M3_m" if view == UPPER else "M3"
        return {"layer": layer, "pin_rect_w": 0.070, "pin_rect_h": 0.070, "grid": 0.005}

    if platform == HETERO_PLATFORM:
        if view == UPPER:
            return {"layer": "M4_m", "pin_rect_w": 0.024, "pin_rect_h": 0.024, "grid": 0.001}
        return {"layer": "M3", "pin_rect_w": 0.070, "pin_rect_h": 0.070, "grid": 0.001}

    raise RuntimeError("unsupported platform: {}".format(platform))


def snap_up_to_grid(value, grid):
    if grid <= 0.0:
        raise RuntimeError("invalid grid {}".format(grid))
    return math.ceil(float(value) / float(grid) - 1e-12) * float(grid)


def snap_to_grid(value, grid):
    if grid <= 0.0:
        raise RuntimeError("invalid grid {}".format(grid))
    return round(float(value) / float(grid)) * float(grid)


def clampf(value, lo, hi):
    return max(lo, min(value, hi))


def format_coord(value):
    return "{:.3f}".format(float(value))


def module_pin_entries(module_obj):
    pins = []
    for port_name, port in module_obj.ports.items():
        width = len(port.bits)
        if width == 1:
            pins.append({"name": port_name, "is_output": port.direction == "output"})
        else:
            for index in range(width):
                pins.append({"name": "{}[{}]".format(port_name, index), "is_output": port.direction == "output"})
    return pins


def write_macro(fh, macro_name, module_obj, area, style):
    side = snap_up_to_grid(math.sqrt(float(area)), style["grid"])
    pin_w = max(style["grid"], snap_up_to_grid(style["pin_rect_w"], style["grid"]))
    pin_h = max(style["grid"], snap_up_to_grid(style["pin_rect_h"], style["grid"]))
    side = max(side, pin_w, pin_h)

    fh.write("MACRO {}\n".format(macro_name))
    fh.write("  CLASS BLOCK ;\n")
    fh.write("  FOREIGN {} 0 0 ;\n".format(macro_name))
    fh.write("  ORIGIN 0 0 ;\n")
    fh.write("  SYMMETRY X Y R90 ;\n")
    fh.write("  SIZE {} BY {} ;\n\n".format(format_coord(side), format_coord(side)))

    pins = module_pin_entries(module_obj)
    count = len(pins)
    y_limit = max(0.0, side - pin_h)
    y_step = (y_limit / float(count + 1)) if count > 0 else y_limit
    for index, pin in enumerate(pins):
        y_lo = snap_to_grid(y_step * float(index + 1), style["grid"])
        y_lo = clampf(y_lo, 0.0, y_limit)
        y_hi = snap_to_grid(y_lo + pin_h, style["grid"])
        if y_hi > side:
            y_hi = side
            y_lo = clampf(snap_to_grid(y_hi - pin_h, style["grid"]), 0.0, y_limit)
        direction = "OUTPUT" if pin["is_output"] else "INPUT"
        fh.write("  PIN {}\n".format(pin["name"]))
        fh.write("    DIRECTION {} ;\n".format(direction))
        fh.write("    USE SIGNAL ;\n")
        fh.write("    SHAPE ABUTMENT ;\n")
        fh.write("    PORT\n")
        fh.write("      LAYER {} ;\n".format(style["layer"]))
        fh.write(
            "        RECT 0.000 {} {} {} ;\n".format(
                format_coord(y_lo),
                format_coord(pin_w),
                format_coord(y_hi),
            )
        )
        fh.write("    END\n")
        fh.write("  END {}\n\n".format(pin["name"]))
    fh.write("END {}\n\n".format(macro_name))


def write_macro_lef(path, modules_by_name, metrics_by_name, platform, view):
    style = coarse_unit_lef_style(platform, view)
    metrics_tier = BOTTOM if view == TWO_DIMENSIONAL else view
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("VERSION 5.7 ;\n")
        fh.write("BUSBITCHARS \"[]\" ;\n")
        fh.write("DIVIDERCHAR \"/\" ;\n\n")
        for module_name in sorted(modules_by_name.keys()):
            macro_name = module_name if view == TWO_DIMENSIONAL else "{}_{}".format(module_name, view)
            write_macro(
                fh,
                macro_name,
                modules_by_name[module_name],
                metrics_by_name[module_name][metrics_tier]["footprint_area"],
                style,
            )
        fh.write("END LIBRARY\n")


def build_pass_input_json(work_dir, modules_by_name):
    pass_design = Design(creator="finalize_hierarchy_output.py", modules=OrderedDict())
    for module_name in sorted(modules_by_name.keys()):
        module_obj = modules_by_name[module_name].copy()
        module_obj.attributes["syn3d_coarse_unit"] = TRUE_ATTR
        pass_design.modules[module_name] = module_obj
    json_path = Path(work_dir) / "actual_coarse_units_for_lib_writer.json"
    dump_design(pass_design, json_path)
    validate_design(load_design(json_path))
    return json_path


def write_coarse_unit_libs(yosys_exe, work_dir, platform, handoff_dir, results_dir,
                           modules_by_name):
    if not modules_by_name:
        return
    input_json = build_pass_input_json(work_dir, modules_by_name)
    env = os.environ.copy()
    env["FLOW_HOME"] = FLOW_HOME
    env["LIBRARY"] = platform
    env["SYN3D_HANDOFF_DIR"] = str(handoff_dir)
    env["RESULTS_DIR"] = str(results_dir)
    env["YOSYS_EXE"] = yosys_exe
    lib_tcl = """
read_json {input_json}
syn3d_write_coarse_unit_libs
""".format(input_json=input_json)
    run_yosys_script(yosys_exe, lib_tcl, "final coarse-unit LIB generation", env=env)


def collect_macro_names(lef_path):
    macro_names = set()
    with open(lef_path, encoding="utf-8") as fp:
        for line in fp:
            match = re.match(r"\s*MACRO\s+(\S+)\s*$", line)
            if match:
                macro_names.add(match.group(1))
    return macro_names


def validate_published_variant_sets(handoff_dir, retained_actual_names):
    handoff_dir = Path(handoff_dir)
    expected = set(retained_actual_names)
    observed = OrderedDict()
    observed["coarse_units/bottom"] = {
        path.stem for path in (handoff_dir / "coarse_units" / BOTTOM).glob("*.v")
    }
    observed["coarse_units/upper"] = {
        path.stem for path in (handoff_dir / "coarse_units" / UPPER).glob("*.v")
    }
    observed["metrics/bottom"] = {
        path.name for path in (handoff_dir / "metrics" / BOTTOM).iterdir() if path.is_dir()
    }
    observed["metrics/upper"] = {
        path.name for path in (handoff_dir / "metrics" / UPPER).iterdir() if path.is_dir()
    }
    observed["lib/2d"] = {
        path.stem
        for path in (handoff_dir / "lib" / TWO_DIMENSIONAL).glob("*.lib")
        if path.name != "coarse_units.lib"
    }
    observed["lib/bottom"] = {
        path.name[: -len(".bottom.lib")]
        for path in (handoff_dir / "lib" / BOTTOM).glob("*.bottom.lib")
    }
    observed["lib/upper"] = {
        path.name[: -len(".upper.lib")]
        for path in (handoff_dir / "lib" / UPPER).glob("*.upper.lib")
    }

    lef_expectations = {
        "lef/2d": expected,
        "lef/bottom": {"{}_bottom".format(name) for name in expected},
        "lef/upper": {"{}_upper".format(name) for name in expected},
    }
    for view, view_expected in lef_expectations.items():
        tier = view.split("/", 1)[1]
        lef_path = handoff_dir / "lef" / tier / "coarse_units.lef"
        observed[view] = collect_macro_names(lef_path)
        if observed[view] != view_expected:
            raise RuntimeError(
                "published variant set mismatch for {}: expected={} observed={}".format(
                    view, sorted(view_expected), sorted(observed[view])
                )
            )

    for output_name, output_names in observed.items():
        if output_name.startswith("lef/"):
            continue
        if output_names != expected:
            raise RuntimeError(
                "published variant set mismatch for {}: expected={} observed={}".format(
                    output_name, sorted(expected), sorted(output_names)
                )
            )


def publish_retained_actual_outputs(args, actual_modules, variant_data):
    work_dir = Path(args.work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)
    results_dir = Path(args.output_verilog).resolve().parent
    family_metrics_cache = {}
    for info in actual_modules.values():
        family_name = info["family_name"]
        if family_name not in family_metrics_cache:
            family_metrics_cache[family_name] = load_family_metrics(
                args.family_metrics_dir, family_name)

    prepare_output_locations(args.handoff_dir)

    bottom_modules = OrderedDict()
    upper_modules = OrderedDict()
    metrics_by_name = OrderedDict()
    actual_report = OrderedDict()

    for actual_name, info in actual_modules.items():
        if actual_name not in variant_data:
            raise RuntimeError("missing prepared data for retained actual unit {}".format(actual_name))
        prepared = variant_data[actual_name]
        if prepared["eliminated"]:
            raise RuntimeError("eliminated actual unit reached publish stage: {}".format(actual_name))
        family_name = info["family_name"]
        family_metrics = family_metrics_cache[family_name]

        bottom_module = prepared["bottom_module"].copy()
        bottom_area = prepared["bottom_area"]
        write_single_module_verilog(
            args.yosys,
            actual_name,
            bottom_module,
            Path(args.handoff_dir) / "coarse_units" / BOTTOM / "{}.v".format(actual_name),
            work_dir,
            "bottom",
        )

        upper_module = prepared["upper_module"].copy()
        upper_area = prepared["upper_area"]
        write_single_module_verilog(
            args.yosys,
            actual_name,
            upper_module,
            Path(args.handoff_dir) / "coarse_units" / UPPER / "{}.v".format(actual_name),
            work_dir,
            "upper",
        )

        metrics = build_actual_metrics(
            actual_name,
            family_name,
            args.platform,
            bottom_area,
            upper_area,
            family_metrics,
        )
        write_metrics(args.handoff_dir, actual_name, metrics)

        bottom_modules[actual_name] = bottom_module
        upper_modules[actual_name] = upper_module
        metrics_by_name[actual_name] = metrics
        actual_report[actual_name] = {
            "family_name": family_name,
            "top_instance_count": info["top_instance_count"],
            "bottom_cell_area": metrics[BOTTOM]["cell_area"],
            "upper_cell_area": metrics[UPPER]["cell_area"],
            "bottom_cell_count": prepared["bottom_cell_count"],
            "upper_cell_count": prepared["upper_cell_count"],
            "bottom_footprint_area": metrics[BOTTOM]["footprint_area"],
            "upper_footprint_area": metrics[UPPER]["footprint_area"],
        }

    write_macro_lef(Path(args.handoff_dir) / "lef" / BOTTOM / "coarse_units.lef",
                    bottom_modules, metrics_by_name, args.platform, BOTTOM)
    write_macro_lef(Path(args.handoff_dir) / "lef" / UPPER / "coarse_units.lef",
                    upper_modules, metrics_by_name, args.platform, UPPER)
    write_macro_lef(Path(args.handoff_dir) / "lef" / TWO_DIMENSIONAL / "coarse_units.lef",
                    bottom_modules, metrics_by_name, args.platform, TWO_DIMENSIONAL)
    write_coarse_unit_libs(
        args.yosys,
        work_dir,
        args.platform,
        args.handoff_dir,
        results_dir,
        bottom_modules,
    )
    validate_published_variant_sets(args.handoff_dir, actual_modules.keys())

    return {
        "actual_variants": actual_report,
    }


def main():
    args = parse_args()
    args.yosys = resolve_yosys_exe(args.yosys)
    work_dir = Path(args.work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)

    module_names = read_module_list(args.coarse_unit_list)
    if not module_names:
        shutil.copyfile(args.input_verilog, args.output_verilog)
        report = {
            "design_name": args.design_name,
            "platform": args.platform,
            "module_count": 0,
            "status": "no coarse units; copied raw Genus output",
        }
        with open(work_dir / "normalization_report.json", "w", encoding="utf-8") as fp:
            json.dump(report, fp, indent=2, sort_keys=True)
            fp.write("\n")
        print(report["status"])
        return

    raw_json = work_dir / "1_synth_netlist.raw.json"
    pruned_raw_json = None
    active_json = work_dir / "1_synth_netlist.actual_modules.json"
    top_only_json = work_dir / "1_synth_netlist.top_only.json"

    top_module_name = args.design_name
    try:
        verilog_to_json(args.yosys, args.input_verilog, top_module_name, raw_json)
    except RuntimeError as exc:
        if "verilog -> json" not in str(exc):
            raise
        top_module_name = infer_top_module_name(args.yosys, args.input_verilog, work_dir)
        verilog_to_json(args.yosys, args.input_verilog, top_module_name, raw_json)
    raw_design = load_design(raw_json)
    validate_design(raw_design)
    if top_module_name not in raw_design.modules:
        raise RuntimeError("top module {} missing from Genus JSON".format(top_module_name))

    canonical_contracts = load_canonical_contracts(
        args.yosys,
        args.coarse_unit_source_dir,
        module_names,
        work_dir,
    )
    pre_actual_modules = collect_top_referenced_actual_modules(
        raw_design, top_module_name, canonical_contracts)
    prepared = prepare_actual_variant_data(args, pre_actual_modules)
    eliminated_actual_modules = prepared["eliminated_actual_modules"]

    (
        pruned_raw_design,
        pruned_raw_json,
        flattened_instance_count,
    ) = flatten_eliminated_actual_instances(
        args.yosys,
        raw_design,
        top_module_name,
        eliminated_actual_modules.keys(),
        work_dir,
    )

    if eliminated_actual_modules:
        actual_modules = collect_top_referenced_actual_modules(
            pruned_raw_design, top_module_name, canonical_contracts)
    else:
        actual_modules = pre_actual_modules

    expected_retained = set(pre_actual_modules) - set(eliminated_actual_modules)
    actual_retained = set(actual_modules)
    if actual_retained != expected_retained:
        raise RuntimeError(
            "retained actual-unit set mismatch after zero-area flatten: "
            "expected={} observed={}".format(
                sorted(expected_retained), sorted(actual_retained)
            )
        )

    active_design = build_active_design(pruned_raw_design, top_module_name, actual_modules)
    dump_design(active_design, active_json)
    validate_design(load_design(active_json))

    top_contract = validate_top_level_contract(active_design, top_module_name, set(actual_modules.keys()))
    top_only_design = build_top_only_design(active_design, top_module_name)
    dump_design(top_only_design, top_only_json)
    validate_design(load_design(top_only_json))
    emit_json_to_verilog(args.yosys, top_only_json, top_module_name, args.output_verilog)

    collateral_report = publish_retained_actual_outputs(
        args,
        actual_modules,
        prepared["variant_data"],
    )

    for actual_name, eliminated_info in eliminated_actual_modules.items():
        print("[3dsyn] eliminated zero-area actual unit:")
        print("  module={}".format(actual_name))
        print("  family={}".format(eliminated_info["family_name"]))
        print("  bottom_area={}".format(eliminated_info["bottom_cell_area"]))
        print("  upper_area={}".format(eliminated_info["upper_cell_area"]))
        print("  bottom_cell_count={}".format(eliminated_info["bottom_cell_count"]))
        print("  upper_cell_count={}".format(eliminated_info["upper_cell_count"]))
        print("  top_instance_count={}".format(eliminated_info["top_instance_count"]))

    print("[3dsyn] pre_actual_count={}".format(len(pre_actual_modules)))
    print("[3dsyn] eliminated_actual_count={}".format(len(eliminated_actual_modules)))
    print("[3dsyn] retained_actual_count={}".format(len(actual_modules)))

    report = {
        "design_name": args.design_name,
        "top_module_name": top_module_name,
        "platform": args.platform,
        "module_count": len(module_names),
        "pre_actual_coarse_unit_type_count": len(pre_actual_modules),
        "eliminated_actual_coarse_unit_type_count": len(eliminated_actual_modules),
        "eliminated_actual_coarse_unit_types": eliminated_actual_modules,
        "flattened_zero_area_instance_count": flattened_instance_count,
        "actual_coarse_unit_type_count": len(actual_modules),
        "actual_coarse_unit_types": collateral_report["actual_variants"],
        "top_level_contract": top_contract,
        "input_verilog": args.input_verilog,
        "output_verilog": args.output_verilog,
        "active_json": str(active_json),
        "top_only_json": str(top_only_json),
        "zero_area_flattened_json": str(pruned_raw_json) if pruned_raw_json else None,
        "handoff_dir": args.handoff_dir,
    }
    with open(work_dir / "normalization_report.json", "w", encoding="utf-8") as fp:
        json.dump(report, fp, indent=2, sort_keys=False)
        fp.write("\n")
    print("Normalized Genus output written to {}".format(args.output_verilog))
    print("Published actual coarse-unit handoff under {}".format(args.handoff_dir))


if __name__ == "__main__":
    main()
