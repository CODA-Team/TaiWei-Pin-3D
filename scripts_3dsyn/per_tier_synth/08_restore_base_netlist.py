"""
08_restore_base_netlist.py

Restore the flat synthesis handoff design to backend base cell naming while
preserving connectivity and structured partition metadata.
"""

import json
import os
import subprocess
import sys
import tempfile
from collections import OrderedDict
from copy import deepcopy

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TOOLKIT_ROOT = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "coarse_synth", "common"))
sys.path.insert(0, SCRIPT_DIR)
sys.path.insert(0, TOOLKIT_ROOT)

from flow_config import (
    BOTTOM_CELL_SUFFIX,
    CELL_MAPPING_PLAN_JSON,
    CELL_NAME_MAPPING_MODE,
    FINAL_BASE_V,
    FLAT_JSON,
    FLAT_V,
    MAP_JSON,
    PARTITION_SEED_JSON,
    RESTORED_BASE_JSON,
    RESTORED_BASE_V,
    SOURCE_JSON,
    TOP_MODULE_NAME,
    UPPER_CELL_SUFFIX,
    YOSYS,
)
from cell_map import load_cell_map
from yosys_json_toolkit import (
    assert_backend_netnames_normalized,
    dump_design,
    load_design,
    module_port_shape_signature,
    validate_design,
)


TIER_BOTTOM = "bottom"
TIER_UPPER = "upper"
VALID_TIERS = {TIER_BOTTOM, TIER_UPPER}
HOMOGENEOUS_BASE = "homogeneous_base"
HETEROGENEOUS_MAP_JSON = "heterogeneous_map_json"
WRAPPER_ONLY_PORT_PREFIXES = ("__pi_", "__po_", "__syn3d_pi_", "__syn3d_po_", "__d2d_")
PSEUDO_CELL_PREFIXES = ("$",)
POWER_PINS = {"VDD", "VSS", "VDDIO", "VSSIO", "VPWR", "VGND"}


def assert_file_exists(path, label):
    assert path and os.path.isfile(path), "{} not found: {}".format(label, path)
    assert os.path.getsize(path) > 0, "{} is empty: {}".format(label, path)


def load_json_file(path):
    assert_file_exists(path, "JSON")
    with open(path) as fp:
        data = json.load(fp)
    assert isinstance(data, dict), "JSON root must be a dict: {}".format(path)
    return data


def write_json_file(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fp:
        json.dump(data, fp, indent=2)
        fp.write("\n")
    assert load_json_file(path) == data, "JSON readback mismatch: {}".format(path)


def run_yosys_script(body_tcl, label):
    assert os.path.isfile(YOSYS), "Yosys not found: {}".format(YOSYS)
    with tempfile.NamedTemporaryFile(mode="w", suffix=".ys", delete=False) as fp:
        fp.write(body_tcl)
        tcl_path = fp.name
    try:
        result = subprocess.run([YOSYS, "-q", "-s", tcl_path], check=False)
    finally:
        os.unlink(tcl_path)
    assert result.returncode == 0, "Yosys failed during {} with exit code {}".format(label, result.returncode)


def emit_json_to_verilog(json_path, top_module_name, out_v):
    os.makedirs(os.path.dirname(out_v), exist_ok=True)
    tcl = """
read_json {json_path}
hierarchy -top {top_module_name}
write_verilog -norename -noexpr -noattr {out_v}
""".format(
        json_path=json_path,
        top_module_name=top_module_name,
        out_v=out_v,
    )
    run_yosys_script(tcl, "json -> verilog ({})".format(top_module_name))
    assert_file_exists(out_v, "emitted Verilog")


def roundtrip_verilog_to_json(verilog_path, top_module_name):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as fp:
        out_json = fp.name
    tcl = """
read_verilog {verilog_path}
hierarchy -top {top_module_name}
write_json {out_json}
""".format(
        verilog_path=verilog_path,
        top_module_name=top_module_name,
        out_json=out_json,
    )
    try:
        run_yosys_script(tcl, "verilog -> json roundtrip ({})".format(top_module_name))
        design = load_design(out_json)
        validate_design(design)
    finally:
        if os.path.exists(out_json):
            os.unlink(out_json)
    return design


def assert_same_port_shape(left, right, label):
    left_sig = module_port_shape_signature(left)
    right_sig = module_port_shape_signature(right)
    assert left_sig == right_sig, "Port shape mismatch for {}:\nleft={}\nright={}".format(label, left_sig, right_sig)


def assert_no_wrapper_only_ports(module):
    offenders = [name for name in module.ports if name.startswith(WRAPPER_ONLY_PORT_PREFIXES)]
    assert not offenders, "Top exposes wrapper-only ports: {}".format(offenders[:20])


def assert_no_pseudo_cells(module):
    offenders = [
        name
        for name, cell in module.cells.items()
        if cell.type.startswith(PSEUDO_CELL_PREFIXES) or cell.type == "$scopeinfo"
    ]
    assert not offenders, "Top contains pseudo/non-backend cells: {}".format(offenders[:20])


def assert_seed_matches_design(seed, module, require_restored=False):
    assert seed["top_module_name"] == TOP_MODULE_NAME, "Seed top_module_name mismatch"
    instance_tiers = seed["instance_tiers"]
    assert isinstance(instance_tiers, dict), "partition_seed.instance_tiers must be dict"
    assert set(instance_tiers.keys()) == set(module.cells.keys()), (
        "Seed instances do not match design cells: missing={} extra={}".format(
            sorted(set(module.cells.keys()) - set(instance_tiers.keys()))[:20],
            sorted(set(instance_tiers.keys()) - set(module.cells.keys()))[:20],
        )
    )
    for inst_name, item in instance_tiers.items():
        assert item["tier"] in VALID_TIERS, "Invalid tier for {}: {}".format(inst_name, item.get("tier"))
        assert "synthesis_cell_type" in item, "Seed entry missing synthesis_cell_type: {}".format(inst_name)
        if require_restored:
            assert "restored_base_cell_type" in item, "Seed entry missing restored_base_cell_type: {}".format(inst_name)
            assert item["restored_base_cell_type"] == module.cells[inst_name].type, (
                "Seed restored type mismatch for {}: seed={} design={}".format(
                    inst_name, item["restored_base_cell_type"], module.cells[inst_name].type
                )
            )


def assert_flat_input_contract(flat_design, source_design, seed, cell_mapping_plan):
    assert TOP_MODULE_NAME in flat_design.modules, "Flat top missing: {}".format(TOP_MODULE_NAME)
    assert TOP_MODULE_NAME in source_design.modules, "Source top missing: {}".format(TOP_MODULE_NAME)
    flat_top = flat_design.modules[TOP_MODULE_NAME]
    source_top = source_design.modules[TOP_MODULE_NAME]
    assert_backend_netnames_normalized(flat_design, TOP_MODULE_NAME)
    assert_same_port_shape(source_top, flat_top, "source vs flat")
    assert_no_wrapper_only_ports(flat_top)
    assert_no_pseudo_cells(flat_top)
    assert seed["identity"]["mapping_mode"] == CELL_NAME_MAPPING_MODE
    assert cell_mapping_plan["mapping_mode"] == CELL_NAME_MAPPING_MODE
    assert CELL_NAME_MAPPING_MODE in {HOMOGENEOUS_BASE, HETEROGENEOUS_MAP_JSON}
    assert_seed_matches_design(seed, flat_top, require_restored=False)


def suffix_looks_tier_specific(cell_type):
    return cell_type.endswith(BOTTOM_CELL_SUFFIX) or cell_type.endswith(UPPER_CELL_SUFFIX)


def restore_homogeneous_base(restored_top, seed):
    changed_cells = 0
    changed_pins = 0
    for inst_name, cell in restored_top.cells.items():
        assert not suffix_looks_tier_specific(cell.type), (
            "Homogeneous 08 expects base cell naming, but {} has tier-specific type {}".format(
                inst_name, cell.type
            )
        )
        item = seed["instance_tiers"][inst_name]
        item["restored_base_cell_type"] = cell.type
        item["cell_restore_status"] = "unchanged_base"
        item["pin_restore_status"] = "not_needed"
        item["pin_name_changes"] = OrderedDict()
        item["restore_checks"] = OrderedDict([("checked_mode", HOMOGENEOUS_BASE)])
    return changed_cells, changed_pins


def add_unique(mapping, key, value, label):
    if key in mapping:
        assert mapping[key] == value, "{} reverse mapping conflict for {}: {} vs {}".format(
            label, key, mapping[key], value
        )
    mapping[key] = value


def build_heterogeneous_reverse_maps(map_json):
    cells = map_json.get("cells")
    assert isinstance(cells, dict) and cells, "map.json must contain non-empty cells dict"
    bottom_cell_to_base = {}
    upper_cell_to_base = {}
    bottom_pin_to_base_by_cell = {}
    upper_pin_to_base_by_cell = {}

    for base_name, item in cells.items():
        assert item.get("base") == base_name, "map.json base key mismatch for {}".format(base_name)
        for tier_key in ["bottom", "upper"]:
            assert tier_key in item and "macro" in item[tier_key], "map.json missing {} macro for {}".format(
                tier_key, base_name
            )
        bottom_macro = item["bottom"]["macro"]
        upper_macro = item["upper"]["macro"]
        add_unique(bottom_cell_to_base, bottom_macro, base_name, "bottom cell")
        add_unique(upper_cell_to_base, upper_macro, base_name, "upper cell")

        pin_map = item.get("pin_map", {})
        assert isinstance(pin_map, dict), "pin_map must be dict for {}".format(base_name)

        bottom_pin_to_base = OrderedDict()
        for pin in item["bottom"].get("pins", []):
            bottom_pin_to_base[pin] = pin
        bottom_pin_to_base_by_cell[bottom_macro] = bottom_pin_to_base

        upper_pin_to_base = OrderedDict()
        seen_upper_pins = set()
        for base_pin, upper_pin in pin_map.items():
            assert upper_pin not in seen_upper_pins, "Non-invertible upper pin_map for {}".format(base_name)
            seen_upper_pins.add(upper_pin)
            upper_pin_to_base[upper_pin] = base_pin
        upper_pin_to_base_by_cell[upper_macro] = upper_pin_to_base

    return bottom_cell_to_base, upper_cell_to_base, bottom_pin_to_base_by_cell, upper_pin_to_base_by_cell


def remap_cell_pins(cell, pin_map, inst_name, strict):
    old_connections = cell.connections
    new_connections = OrderedDict()
    changes = OrderedDict()
    for old_pin, bits in old_connections.items():
        if old_pin in POWER_PINS and old_pin not in pin_map:
            new_pin = old_pin
        else:
            if strict:
                assert old_pin in pin_map, "Missing pin reverse mapping for {} pin {}".format(inst_name, old_pin)
            new_pin = pin_map.get(old_pin, old_pin)
        assert new_pin not in new_connections, "Pin remap creates duplicate pin {} on {}".format(new_pin, inst_name)
        new_connections[new_pin] = list(bits)
        if new_pin != old_pin:
            changes[old_pin] = new_pin

    new_port_directions = OrderedDict()
    for old_pin, direction in cell.port_directions.items():
        if old_pin in POWER_PINS and old_pin not in pin_map:
            new_pin = old_pin
        else:
            if strict:
                assert old_pin in pin_map, "Missing port_direction reverse mapping for {} pin {}".format(
                    inst_name, old_pin
                )
            new_pin = pin_map.get(old_pin, old_pin)
        assert new_pin not in new_port_directions, "Pin remap creates duplicate direction pin {} on {}".format(
            new_pin, inst_name
        )
        new_port_directions[new_pin] = direction

    cell.connections = new_connections
    cell.port_directions = new_port_directions
    return changes


def restore_heterogeneous_map_json(restored_top, seed):
    map_json = load_cell_map(MAP_JSON)
    (
        bottom_cell_to_base,
        upper_cell_to_base,
        bottom_pin_to_base_by_cell,
        upper_pin_to_base_by_cell,
    ) = build_heterogeneous_reverse_maps(map_json)

    changed_cells = 0
    changed_pins = 0
    for inst_name, cell in restored_top.cells.items():
        item = seed["instance_tiers"][inst_name]
        tier = item["tier"]
        original_type = cell.type
        if tier == TIER_BOTTOM:
            assert original_type in bottom_cell_to_base, "Unmapped bottom cell type on {}: {}".format(
                inst_name, original_type
            )
            base_type = bottom_cell_to_base[original_type]
            pin_map = bottom_pin_to_base_by_cell[original_type]
            pin_changes = remap_cell_pins(cell, pin_map, inst_name, strict=True)
        elif tier == TIER_UPPER:
            assert original_type in upper_cell_to_base, "Unmapped upper cell type on {}: {}".format(
                inst_name, original_type
            )
            base_type = upper_cell_to_base[original_type]
            pin_map = upper_pin_to_base_by_cell[original_type]
            pin_changes = remap_cell_pins(cell, pin_map, inst_name, strict=True)
        else:
            raise AssertionError("Invalid tier for {}: {}".format(inst_name, tier))

        if cell.type != base_type:
            changed_cells += 1
        if pin_changes:
            changed_pins += 1
        cell.type = base_type
        item["restored_base_cell_type"] = base_type
        item["cell_restore_status"] = "restored_from_map_json"
        item["pin_restore_status"] = "restored_from_map_json" if pin_changes else "verified_map_json"
        item["pin_name_changes"] = pin_changes
        item["restore_checks"] = OrderedDict(
            [
                ("checked_mode", HETEROGENEOUS_MAP_JSON),
                ("original_cell_type", original_type),
            ]
        )

    return changed_cells, changed_pins


def assert_restored_output_contract(restored_design, source_design, seed):
    validate_design(restored_design)
    assert TOP_MODULE_NAME in restored_design.modules, "Restored top missing: {}".format(TOP_MODULE_NAME)
    restored_top = restored_design.modules[TOP_MODULE_NAME]
    source_top = source_design.modules[TOP_MODULE_NAME]
    assert_same_port_shape(source_top, restored_top, "source vs restored")
    assert_no_wrapper_only_ports(restored_top)
    assert_no_pseudo_cells(restored_top)

    offenders = [name for name, cell in restored_top.cells.items() if suffix_looks_tier_specific(cell.type)]
    assert not offenders, "Restored base still has tier-suffix cell types: {}".format(offenders[:20])
    if CELL_NAME_MAPPING_MODE == HETEROGENEOUS_MAP_JSON:
        mapped_type_offenders = [
            name
            for name, cell in restored_top.cells.items()
            if "ASAP7_75t_R_upper" in cell.type or cell.type.endswith(BOTTOM_CELL_SUFFIX)
        ]
        assert not mapped_type_offenders, "Restored base still has hetero mapped types: {}".format(
            mapped_type_offenders[:20]
        )
    assert_seed_matches_design(seed, restored_top, require_restored=True)


def assert_roundtrip_matches(restored_design, roundtrip_design):
    assert TOP_MODULE_NAME in roundtrip_design.modules, "Roundtrip top missing: {}".format(TOP_MODULE_NAME)
    expected = restored_design.modules[TOP_MODULE_NAME]
    actual = roundtrip_design.modules[TOP_MODULE_NAME]
    assert_same_port_shape(expected, actual, "restored json vs final verilog roundtrip")
    assert set(expected.cells.keys()) == set(actual.cells.keys()), (
        "Roundtrip cell name mismatch: expected_only={} actual_only={}".format(
            sorted(set(expected.cells.keys()) - set(actual.cells.keys()))[:20],
            sorted(set(actual.cells.keys()) - set(expected.cells.keys()))[:20],
        )
    )
    for inst_name, expected_cell in expected.cells.items():
        actual_cell = actual.cells[inst_name]
        assert expected_cell.type == actual_cell.type, "Roundtrip cell type mismatch for {}".format(inst_name)
        assert set(expected_cell.connections.keys()) == set(actual_cell.connections.keys()), (
            "Roundtrip connection port mismatch for {}: expected_only={} actual_only={}".format(
                inst_name,
                sorted(set(expected_cell.connections.keys()) - set(actual_cell.connections.keys())),
                sorted(set(actual_cell.connections.keys()) - set(expected_cell.connections.keys())),
            )
        )
        for port_name, expected_bits in expected_cell.connections.items():
            actual_bits = actual_cell.connections[port_name]
            assert len(expected_bits) == len(actual_bits), (
                "Roundtrip connection width mismatch for {}.{}: expected={} actual={}".format(
                    inst_name, port_name, len(expected_bits), len(actual_bits)
                )
            )
            for expected_bit, actual_bit in zip(expected_bits, actual_bits):
                if isinstance(expected_bit, str) or isinstance(actual_bit, str):
                    assert expected_bit == actual_bit, (
                        "Roundtrip constant connection mismatch for {}.{}: expected={} actual={}".format(
                            inst_name, port_name, expected_bit, actual_bit
                        )
                    )


def update_seed_summary(seed, restored_top, changed_cells, changed_pins):
    instance_tiers = seed["instance_tiers"]
    bottom_count = sum(1 for item in instance_tiers.values() if item["tier"] == TIER_BOTTOM)
    upper_count = sum(1 for item in instance_tiers.values() if item["tier"] == TIER_UPPER)
    summary = seed["summary"]
    summary["restored_instance_count"] = len(restored_top.cells)
    summary["cell_type_changed_count"] = changed_cells
    summary["pin_name_changed_count"] = changed_pins
    summary["unmapped_cell_count"] = 0
    summary["unmapped_pin_count"] = 0
    assert summary["final_instance_count"] == len(restored_top.cells)
    assert summary["bottom_instance_count"] == bottom_count
    assert summary["upper_instance_count"] == upper_count


def load_inputs():
    for path, label in [
        (FLAT_JSON, "FLAT_JSON"),
        (FLAT_V, "FLAT_V"),
        (PARTITION_SEED_JSON, "PARTITION_SEED_JSON"),
        (SOURCE_JSON, "SOURCE_JSON"),
        (CELL_MAPPING_PLAN_JSON, "CELL_MAPPING_PLAN_JSON"),
    ]:
        assert_file_exists(path, label)
    if CELL_NAME_MAPPING_MODE == HETEROGENEOUS_MAP_JSON:
        assert_file_exists(MAP_JSON, "MAP_JSON")
    flat_design = load_design(FLAT_JSON)
    source_design = load_design(SOURCE_JSON)
    validate_design(flat_design)
    validate_design(source_design)
    seed = load_json_file(PARTITION_SEED_JSON)
    cell_mapping_plan = load_json_file(CELL_MAPPING_PLAN_JSON)
    return flat_design, source_design, seed, cell_mapping_plan


def main():
    flat_design, source_design, seed, cell_mapping_plan = load_inputs()
    assert_flat_input_contract(flat_design, source_design, seed, cell_mapping_plan)

    restored_design = deepcopy(flat_design)
    restored_top = restored_design.modules[TOP_MODULE_NAME]
    if CELL_NAME_MAPPING_MODE == HOMOGENEOUS_BASE:
        changed_cells, changed_pins = restore_homogeneous_base(restored_top, seed)
    elif CELL_NAME_MAPPING_MODE == HETEROGENEOUS_MAP_JSON:
        changed_cells, changed_pins = restore_heterogeneous_map_json(restored_top, seed)
    else:
        raise AssertionError("Unsupported CELL_NAME_MAPPING_MODE: {}".format(CELL_NAME_MAPPING_MODE))

    update_seed_summary(seed, restored_top, changed_cells, changed_pins)
    assert_restored_output_contract(restored_design, source_design, seed)

    os.makedirs(os.path.dirname(RESTORED_BASE_JSON), exist_ok=True)
    dump_design(restored_design, RESTORED_BASE_JSON)
    validate_design(load_design(RESTORED_BASE_JSON))
    emit_json_to_verilog(RESTORED_BASE_JSON, TOP_MODULE_NAME, RESTORED_BASE_V)
    emit_json_to_verilog(RESTORED_BASE_JSON, TOP_MODULE_NAME, FINAL_BASE_V)
    roundtrip_design = roundtrip_verilog_to_json(FINAL_BASE_V, TOP_MODULE_NAME)
    assert_roundtrip_matches(restored_design, roundtrip_design)
    write_json_file(PARTITION_SEED_JSON, seed)

    print("[08] restored_base_json        -> {}".format(RESTORED_BASE_JSON))
    print("[08] restored_base_v           -> {}".format(RESTORED_BASE_V))
    print("[08] final_base_v              -> {}".format(FINAL_BASE_V))
    print("[08] restored instances        = {}".format(seed["summary"]["restored_instance_count"]))
    print("[08] cell type changes         = {}".format(seed["summary"]["cell_type_changed_count"]))
    print("[08] pin name changes          = {}".format(seed["summary"]["pin_name_changed_count"]))


if __name__ == "__main__":
    main()
