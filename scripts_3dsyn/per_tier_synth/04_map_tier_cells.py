"""
04_remap_tier_cells.py
Normalize/remap tier cell naming for the wrapper/Genus handoff.

This step intentionally does only one thing:
- read the 03 full-design JSON
- classify direct instances in the tier top module
- in homogeneous mode, keep top direct leaf cells as base naming and normalize
  coarse module internals to base naming
- in heterogeneous mode, remap top direct leaf cells to target tier macro naming
- in heterogeneous mode, remap the selected leaf-cell instance pin names via `map.json` `pin_map`
- verify non-top modules are naming-consistent with the selected mode
- write 04 remapped JSON / Verilog outputs
"""

import json
import os
import subprocess
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TOOLKIT_ROOT = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "coarse_synth", "common"))
sys.path.insert(0, SCRIPT_DIR)
sys.path.insert(0, TOOLKIT_ROOT)

from flow_config import (
    BOTTOM_CELL_SUFFIX,
    BOTTOM_COARSE_FULL_JSON,
    BOTTOM_COARSE_MODULE_NAME,
    BOTTOM_REMAPPED_JSON,
    BOTTOM_REMAPPED_V,
    CELL_MAPPING_PLAN_JSON,
    CELL_NAME_MAPPING_MODE,
    MAP_JSON,
    OUTPUT_VERILOG,
    PIN_DIR_JSON,
    TMP_DIR,
    UPPER_CELL_SUFFIX,
    UPPER_COARSE_FULL_JSON,
    UPPER_COARSE_MODULE_NAME,
    UPPER_REMAPPED_JSON,
    UPPER_REMAPPED_V,
    YOSYS,
)
from cell_map import load_cell_map
from yosys_json_toolkit import (
    collect_instance_type_counts,
    dump_design,
    load_design,
    remap_cell_connection_ports,
    remap_cell_types,
    validate_design,
)


HOMOGENEOUS_BASE = "homogeneous_base"
HETEROGENEOUS_MAP_JSON = "heterogeneous_map_json"
BOTTOM_TIER = "bottom"
UPPER_TIER = "upper"


def run_yosys_script(body_tcl, label):
    assert os.path.exists(YOSYS), "Yosys not found: {}".format(YOSYS)
    with tempfile.NamedTemporaryFile(mode="w", suffix=".ys", delete=False) as tcl_fp:
        tcl_fp.write(body_tcl)
        tcl_path = tcl_fp.name
    try:
        result = subprocess.run([YOSYS, "-s", tcl_path], check=False)
    finally:
        os.unlink(tcl_path)
    assert result.returncode == 0, "Yosys failed during {} with exit code {}".format(label, result.returncode)


def emit_json_to_verilog(json_path, module_name, out_v):
    tcl = """
read_json {json_path}
hierarchy -top {module_name}
write_verilog -norename -noexpr -noattr {out_v}
""".format(
        json_path=json_path,
        module_name=module_name,
        out_v=out_v,
    )
    run_yosys_script(tcl, "json -> verilog ({})".format(module_name))
    assert os.path.exists(out_v), "Verilog was not created: {}".format(out_v)


def load_json_file(path):
    assert os.path.isfile(path), "Required JSON file not found: {}".format(path)
    with open(path) as fp:
        data = json.load(fp)
    assert isinstance(data, dict), "JSON file must contain a dictionary: {}".format(path)
    return data


def structural_signature(design):
    signature = {}
    for module_name, module in design.modules.items():
        signature[module_name] = {
            "ports": {name: port.to_dict() for name, port in module.ports.items()},
            "netnames": {name: netname.to_dict() for name, netname in module.netnames.items()},
            "cell_names": sorted(module.cells.keys()),
            "cell_connections": {name: cell.connections for name, cell in module.cells.items()},
        }
    return signature


def assert_structural_signature_unchanged(before, after, context):
    assert before == after, "{} changed ports/netnames/cell names/connections unexpectedly".format(context)


class TierMapper(object):
    def __init__(
        self,
        mode,
        tier,
        base_to_target,
        target_to_base,
        other_to_base,
        target_label,
        other_label,
        base_to_target_port_map,
    ):
        self.mode = mode
        self.tier = tier
        self.base_to_target = dict(base_to_target)
        self.target_to_base = dict(target_to_base)
        self.other_to_base = dict(other_to_base)
        self.target_label = target_label
        self.other_label = other_label
        self.base_to_target_port_map = {key: dict(value) for key, value in base_to_target_port_map.items()}
        self.base_pin_sets = {}
        self.target_pin_sets = {}

    def classify_leaf_type(self, cell_type):
        if cell_type in self.target_to_base:
            return "already_target"
        if cell_type in self.other_to_base:
            return "wrong_tier"
        if cell_type in self.base_to_target:
            return "base"
        return "unknown"

    def remap_leaf_type(self, cell_type):
        assert cell_type in self.base_to_target, "Base leaf cell is not remappable: {}".format(cell_type)
        return self.base_to_target[cell_type]

    def remap_leaf_ports(self, cell_type):
        assert cell_type in self.base_to_target_port_map, "Base leaf ports are not remappable: {}".format(cell_type)
        return dict(self.base_to_target_port_map[cell_type])


def build_homogeneous_mapper(tier):
    assert tier in {BOTTOM_TIER, UPPER_TIER}
    target_suffix = BOTTOM_CELL_SUFFIX if tier == BOTTOM_TIER else UPPER_CELL_SUFFIX
    other_suffix = UPPER_CELL_SUFFIX if tier == BOTTOM_TIER else BOTTOM_CELL_SUFFIX
    pin_dir = load_json_file(PIN_DIR_JSON)

    class HomogeneousTierMapper(TierMapper):
        def __init__(self):
            super(HomogeneousTierMapper, self).__init__(
                mode=HOMOGENEOUS_BASE,
                tier=tier,
                base_to_target={base_name: base_name for base_name in pin_dir},
                target_to_base={base_name + target_suffix: base_name for base_name in pin_dir},
                other_to_base={base_name + other_suffix: base_name for base_name in pin_dir},
                target_label=target_suffix,
                other_label=other_suffix,
                base_to_target_port_map={},
            )
            self.base_pin_sets = {base_name: set(pins.keys()) for base_name, pins in pin_dir.items()}
            self.target_pin_sets = {
                base_name: set(pins.keys()) for base_name, pins in pin_dir.items()
            }

        def classify_leaf_type(self, cell_type):
            if cell_type in self.base_to_target:
                return "base"
            if cell_type in self.target_to_base:
                return "target_suffix"
            if cell_type in self.other_to_base:
                return "wrong_tier"
            return "unknown"

        def remap_leaf_type(self, cell_type):
            if cell_type in self.base_to_target:
                return cell_type
            assert cell_type in self.target_to_base, "Cannot normalize homogeneous cell type: {}".format(cell_type)
            return self.target_to_base[cell_type]

        def remap_leaf_ports(self, cell_type):
            return {}

    return HomogeneousTierMapper()


def build_heterogeneous_mapper(tier, map_json_path):
    assert tier in {BOTTOM_TIER, UPPER_TIER}
    assert os.path.exists(map_json_path), "map.json not found: {}".format(map_json_path)
    data = load_cell_map(map_json_path)

    assert "cells" in data and isinstance(data["cells"], dict), "map.json missing top-level 'cells' dictionary"
    cells = data["cells"]
    base_to_target = {}
    target_to_base = {}
    other_to_base = {}
    base_to_target_port_map = {}
    base_pin_sets = {}
    target_pin_sets = {}
    target_key = tier
    other_key = UPPER_TIER if tier == BOTTOM_TIER else BOTTOM_TIER

    for base_name, entry in cells.items():
        assert isinstance(entry, dict), "Cell entry for {} must be a dictionary".format(base_name)
        assert entry.get("base", base_name) == base_name, "Cell entry base mismatch for {}".format(base_name)
        target_info = entry.get(target_key)
        other_info = entry.get(other_key)
        assert isinstance(target_info, dict) and "macro" in target_info, (
            "Missing {} macro mapping for {}".format(target_key, base_name)
        )
        assert isinstance(other_info, dict) and "macro" in other_info, (
            "Missing {} macro mapping for {}".format(other_key, base_name)
        )
        assert isinstance(entry.get("pin_map"), dict), "Missing pin_map for {}".format(base_name)

        target_macro = target_info["macro"]
        other_macro = other_info["macro"]
        assert target_macro not in target_to_base, "Duplicate {} macro mapping for {}".format(target_key, target_macro)
        assert other_macro not in other_to_base, "Duplicate {} macro mapping for {}".format(other_key, other_macro)
        base_to_target[base_name] = target_macro
        target_to_base[target_macro] = base_name
        other_to_base[other_macro] = base_name

        if tier == BOTTOM_TIER:
            target_port_map = {pin_name: pin_name for pin_name in entry["pin_map"].keys()}
        else:
            target_port_map = dict(entry["pin_map"])
        base_to_target_port_map[base_name] = target_port_map
        base_pin_sets[base_name] = set(entry["pin_map"].keys())
        target_pin_sets[base_name] = set(target_port_map.values())

    mapper = TierMapper(
        mode=HETEROGENEOUS_MAP_JSON,
        tier=tier,
        base_to_target=base_to_target,
        target_to_base=target_to_base,
        other_to_base=other_to_base,
        target_label=target_key,
        other_label=other_key,
        base_to_target_port_map=base_to_target_port_map,
    )
    mapper.base_pin_sets = base_pin_sets
    mapper.target_pin_sets = target_pin_sets
    return mapper


def build_tier_mapper(tier):
    if CELL_NAME_MAPPING_MODE == HOMOGENEOUS_BASE:
        return build_homogeneous_mapper(tier)
    if CELL_NAME_MAPPING_MODE == HETEROGENEOUS_MAP_JSON:
        return build_heterogeneous_mapper(tier, MAP_JSON)
    raise AssertionError("Unsupported CELL_NAME_MAPPING_MODE: {}".format(CELL_NAME_MAPPING_MODE))


def collect_coarse_module_types(design, top_module_name):
    module_names = set(design.modules.keys())
    assert top_module_name in module_names, "Top module {} not found in design".format(top_module_name)
    module_names.remove(top_module_name)
    return module_names


def classify_top_module_cells(top_module, coarse_module_types, mapper):
    remap_cell_names = []
    remap_type_map = {}
    remap_source_type_by_cell = {}
    summary_counts = {
        "coarse_module": 0,
        "already_target": 0,
        "base": 0,
    }

    for cell_name in sorted(top_module.cells.keys()):
        cell = top_module.cells[cell_name]
        cell_type = cell.type
        if cell_type in coarse_module_types:
            summary_counts["coarse_module"] += 1
            continue

        status = mapper.classify_leaf_type(cell_type)
        if mapper.mode == HOMOGENEOUS_BASE:
            if status == "base":
                summary_counts["already_target"] += 1
                continue
            if status in {"target_suffix", "wrong_tier"}:
                raise AssertionError(
                    "Homogeneous top module {} contains suffixed leaf cell type {} in instance {}; "
                    "Per-tier synthesis expects base-named direct leaf cells before step 04".format(
                        top_module.name, cell_type, cell_name
                    )
                )
            raise AssertionError(
                "Top module {} contains unsupported homogeneous leaf cell type {}".format(
                    top_module.name, cell_type
                )
            )

        if status == "already_target":
            summary_counts["already_target"] += 1
            continue
        if status == "base":
            target_type = mapper.remap_leaf_type(cell_type)
            remap_cell_names.append(cell_name)
            remap_type_map[cell_type] = target_type
            remap_source_type_by_cell[cell_name] = cell_type
            summary_counts["base"] += 1
            continue
        if status == "wrong_tier":
            raise AssertionError(
                "Top module {} contains wrong-tier leaf cell type {} for tier {}".format(
                    top_module.name, cell_type, mapper.tier
                )
            )
        raise AssertionError(
            "Top module {} contains unsupported leaf cell type {}".format(top_module.name, cell_type)
        )

    return remap_cell_names, remap_type_map, remap_source_type_by_cell, summary_counts


def check_non_top_modules_already_tier_named(design, top_module_name, coarse_module_types, mapper):
    normalized = 0
    checked = 0
    for module_name in sorted(design.modules.keys()):
        if module_name == top_module_name:
            continue
        module = design.modules[module_name]
        for cell_name in sorted(module.cells.keys()):
            cell = module.cells[cell_name]
            cell_type = cell.type
            if cell_type in coarse_module_types:
                continue
            status = mapper.classify_leaf_type(cell_type)
            if mapper.mode == HOMOGENEOUS_BASE:
                if status == "base":
                    checked += 1
                    assert_cell_ports_match_mapper(cell, mapper, cell_type)
                    continue
                if status == "target_suffix":
                    base_type = mapper.remap_leaf_type(cell_type)
                    cell.type = base_type
                    normalized += 1
                    checked += 1
                    assert_cell_ports_match_mapper(cell, mapper, base_type)
                    continue
                if status == "wrong_tier":
                    raise AssertionError(
                        "Non-top module {} contains wrong-tier homogeneous leaf cell type {} in instance {}".format(
                            module_name, cell_type, cell_name
                        )
                    )
                raise AssertionError(
                    "Non-top module {} contains unsupported homogeneous leaf cell type {} in instance {}".format(
                        module_name, cell_type, cell_name
                    )
                )

            if status == "already_target":
                checked += 1
                assert_cell_ports_match_mapper(cell, mapper, cell_type)
                continue
            if status == "wrong_tier":
                raise AssertionError(
                    "Non-top module {} contains wrong-tier leaf cell type {} in instance {}".format(
                        module_name, cell_type, cell_name
                    )
                )
            if status == "base":
                raise AssertionError(
                    "Non-top module {} still contains source-side base leaf cell type {} in instance {}".format(
                        module_name, cell_type, cell_name
                    )
                )
            raise AssertionError(
                "Non-top module {} contains unsupported leaf cell type {} in instance {}".format(
                    module_name, cell_type, cell_name
                )
            )
    return {"checked_leaf_cells": checked, "normalized_leaf_cells": normalized}


def assert_top_module_no_base_leaf_types(top_module, coarse_module_types, mapper):
    offenders = []
    for cell_name in sorted(top_module.cells.keys()):
        cell_type = top_module.cells[cell_name].type
        if cell_type in coarse_module_types:
            continue
        status = mapper.classify_leaf_type(cell_type)
        if mapper.mode == HOMOGENEOUS_BASE:
            if status != "base":
                offenders.append((cell_name, cell_type, status))
        elif status != "already_target":
            offenders.append((cell_name, cell_type, status))
    assert not offenders, "Top module still contains non-target leaf cells after remap: {}".format(offenders[:10])


def assert_cell_ports_match_mapper(cell, mapper, current_type):
    if mapper.mode == HOMOGENEOUS_BASE:
        base_type = current_type
        if current_type in mapper.target_to_base:
            base_type = mapper.target_to_base[current_type]
        assert base_type in mapper.base_pin_sets, "Unknown homogeneous base type after normalize: {}".format(base_type)
        allowed_pins = mapper.base_pin_sets[base_type]
    else:
        assert current_type in mapper.target_to_base, "Cell type is not current target macro: {}".format(current_type)
        base_type = mapper.target_to_base[current_type]
        allowed_pins = mapper.target_pin_sets[base_type]
    missing = []
    for pin_name, bits in cell.connections.items():
        if pin_name in allowed_pins:
            continue
        indexed_pins = {
            "{}[{}]".format(pin_name, index)
            for index in range(len(bits))
        }
        if indexed_pins and indexed_pins.issubset(allowed_pins):
            continue
        missing.append(pin_name)
    missing.sort()
    assert not missing, (
        "Cell {} type {} has connection pins not present in mapper pin set: {}".format(
            cell.name, current_type, missing
        )
    )


def assert_top_leaf_ports(top_module, coarse_module_types, mapper):
    for cell in top_module.cells.values():
        if cell.type in coarse_module_types:
            continue
        assert_cell_ports_match_mapper(cell, mapper, cell.type)


def remap_tier_design(tier, in_json, out_json, out_v, top_module_name):
    assert os.path.exists(in_json), "Input full design JSON not found: {}".format(in_json)
    os.makedirs(TMP_DIR, exist_ok=True)

    print("[04] tier={} loading full design ...".format(tier))
    design = load_design(in_json)
    validate_design(design)
    assert top_module_name in design.modules, "Top module {} not found in {}".format(top_module_name, in_json)
    top_module = design.get_module(top_module_name)
    before_signature = structural_signature(design)

    mapper = build_tier_mapper(tier)
    coarse_module_types = collect_coarse_module_types(design, top_module_name)
    remap_cell_names, remap_type_map, remap_source_type_by_cell, summary_counts = classify_top_module_cells(top_module, coarse_module_types, mapper)

    print("[04] tier={} top cell-type counts before remap: {}".format(tier, collect_instance_type_counts(top_module)))
    print("[04] tier={} classification summary: {}".format(tier, summary_counts))
    print("[04] tier={} coarse module types: {}".format(tier, sorted(coarse_module_types)))
    print("[04] tier={} remap type map: {}".format(tier, remap_type_map))

    remapped = remap_cell_types(top_module, remap_type_map, cell_names=remap_cell_names)
    assert remapped == len(remap_cell_names), (
        "Expected to remap {} cells in top module {}, but remapped {}".format(
            len(remap_cell_names), top_module_name, remapped
        )
    )

    port_remap_count = 0
    for cell_name in remap_cell_names:
        assert cell_name in remap_source_type_by_cell, "Missing source type record for {}".format(cell_name)
        source_type = remap_source_type_by_cell[cell_name]
        port_map = mapper.remap_leaf_ports(source_type)
        if port_map:
            changed = remap_cell_connection_ports(
                top_module,
                port_map,
                cell_names=[cell_name],
                strict=True,
            )
            assert changed in {0, 1}, "Unexpected remap count {} for cell {}".format(changed, cell_name)
            port_remap_count += changed

    non_top_summary = check_non_top_modules_already_tier_named(design, top_module_name, coarse_module_types, mapper)
    assert_top_module_no_base_leaf_types(top_module, coarse_module_types, mapper)
    assert_top_leaf_ports(top_module, coarse_module_types, mapper)
    validate_design(design)
    after_signature = structural_signature(design)
    if mapper.mode == HETEROGENEOUS_MAP_JSON:
        # Top direct cell type and upper pin-name remap are intentional; the
        # structural signature excludes cell.type and includes connections, so
        # compare only after allowing the top-module connection change.
        for module_name in before_signature:
            if module_name == top_module_name and port_remap_count:
                before_signature[module_name]["cell_connections"] = after_signature[module_name]["cell_connections"]
    assert_structural_signature_unchanged(before_signature, after_signature, "04 {}".format(tier))

    print("[04] tier={} remapped connection-port count: {}".format(tier, port_remap_count))
    print("[04] tier={} non-top summary: {}".format(tier, non_top_summary))
    print("[04] tier={} top cell-type counts after remap: {}".format(tier, collect_instance_type_counts(top_module)))

    dump_design(design, out_json)
    assert os.path.exists(out_json), "Remapped JSON was not created: {}".format(out_json)
    reloaded = load_design(out_json)
    validate_design(reloaded)
    if OUTPUT_VERILOG:
        emit_json_to_verilog(out_json, top_module_name, out_v)
        print("       remapped_v    -> {}".format(out_v))

    print("[04] tier={} done".format(tier))
    print("       remapped_json -> {}".format(out_json))
    return {
        "tier": tier,
        "mapping_mode": mapper.mode,
        "top_module": top_module_name,
        "coarse_module_types": sorted(coarse_module_types),
        "top_summary": summary_counts,
        "top_remapped_cells": len(remap_cell_names),
        "top_remapped_types": remap_type_map,
        "top_port_remap_count": port_remap_count,
        "non_top_summary": non_top_summary,
        "output_json": out_json,
        "output_verilog": out_v if OUTPUT_VERILOG else "",
    }


def write_mapping_plan(plan):
    with open(CELL_MAPPING_PLAN_JSON, "w") as fp:
        json.dump(plan, fp, indent=2, sort_keys=True)
        fp.write("\n")
    loaded = load_json_file(CELL_MAPPING_PLAN_JSON)
    assert loaded == plan, "cell_mapping_plan.json readback differs from written plan"


def main():
    assert os.path.exists(BOTTOM_COARSE_FULL_JSON), "Input not found: {}".format(BOTTOM_COARSE_FULL_JSON)
    assert os.path.exists(UPPER_COARSE_FULL_JSON), "Input not found: {}".format(UPPER_COARSE_FULL_JSON)
    assert os.path.exists(YOSYS), "Yosys not found: {}".format(YOSYS)
    assert CELL_NAME_MAPPING_MODE in {HOMOGENEOUS_BASE, HETEROGENEOUS_MAP_JSON}, (
        "Unsupported CELL_NAME_MAPPING_MODE: {}".format(CELL_NAME_MAPPING_MODE)
    )
    if CELL_NAME_MAPPING_MODE == HETEROGENEOUS_MAP_JSON:
        assert os.path.exists(MAP_JSON), "map.json not found: {}".format(MAP_JSON)

    bottom_plan = remap_tier_design(
        tier=BOTTOM_TIER,
        in_json=BOTTOM_COARSE_FULL_JSON,
        out_json=BOTTOM_REMAPPED_JSON,
        out_v=BOTTOM_REMAPPED_V,
        top_module_name=BOTTOM_COARSE_MODULE_NAME,
    )
    upper_plan = remap_tier_design(
        tier=UPPER_TIER,
        in_json=UPPER_COARSE_FULL_JSON,
        out_json=UPPER_REMAPPED_JSON,
        out_v=UPPER_REMAPPED_V,
        top_module_name=UPPER_COARSE_MODULE_NAME,
    )
    plan = {
        "mapping_mode": CELL_NAME_MAPPING_MODE,
        "tiers": {
            BOTTOM_TIER: bottom_plan,
            UPPER_TIER: upper_plan,
        },
    }
    write_mapping_plan(plan)
    print("[04] cell_mapping_plan -> {}".format(CELL_MAPPING_PLAN_JSON))


if __name__ == "__main__":
    main()
