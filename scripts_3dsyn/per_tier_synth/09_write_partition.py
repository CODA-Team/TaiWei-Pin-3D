"""
09_gen_partition.py

Serialize the structured partition seed into TaiWei backend
partition_from_flow.txt format.
"""

import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TOOLKIT_ROOT = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "coarse_synth", "common"))
sys.path.insert(0, SCRIPT_DIR)
sys.path.insert(0, TOOLKIT_ROOT)

from flow_config import (
    FINAL_BASE_V,
    FINAL_PARTITION,
    PARTITION_BOTTOM_VALUE,
    PARTITION_SEED_JSON,
    PARTITION_TOP_VALUE,
    RESTORED_BASE_JSON,
    TOP_MODULE_NAME,
)
from yosys_json_toolkit import load_design, port_bit_labels, validate_design


TIER_BOTTOM = "bottom"
TIER_UPPER = "upper"
VALID_TIERS = {TIER_BOTTOM, TIER_UPPER}
WRAPPER_ONLY_PORT_PREFIXES = ("__pi_", "__po_", "__syn3d_pi_", "__syn3d_po_", "__d2d_")
PSEUDO_CELL_PREFIXES = ("$",)


def assert_file_exists(path, label):
    assert path and os.path.isfile(path), "{} not found: {}".format(label, path)
    assert os.path.getsize(path) > 0, "{} is empty: {}".format(label, path)


def load_json_file(path):
    assert_file_exists(path, "JSON")
    with open(path) as fp:
        data = json.load(fp)
    assert isinstance(data, dict), "JSON root must be a dict: {}".format(path)
    return data


def assert_required_keys(data, required_keys, label):
    missing = [key for key in required_keys if key not in data]
    assert not missing, "{} missing keys: {}".format(label, missing)


def tier_to_die(tier):
    if tier == TIER_BOTTOM:
        return str(PARTITION_BOTTOM_VALUE)
    if tier == TIER_UPPER:
        return str(PARTITION_TOP_VALUE)
    raise AssertionError("Unsupported tier value: {}".format(tier))


def assert_no_wrapper_only_ports(module):
    offenders = [name for name in module.ports if name.startswith(WRAPPER_ONLY_PORT_PREFIXES)]
    assert not offenders, "Restored top exposes wrapper-only ports: {}".format(offenders[:20])


def assert_no_pseudo_cells(module):
    offenders = [
        name
        for name, cell in module.cells.items()
        if cell.type.startswith(PSEUDO_CELL_PREFIXES) or cell.type == "$scopeinfo"
    ]
    assert not offenders, "Restored top contains pseudo/non-backend cells: {}".format(offenders[:20])


def validate_seed_summary(seed):
    summary = seed["summary"]
    assert_required_keys(
        summary,
        [
            "final_top_port_count",
            "final_primary_bit_count",
            "final_instance_count",
            "bottom_instance_count",
            "upper_instance_count",
        ],
        "partition_seed.summary",
    )
    if "restored_instance_count" in summary:
        assert summary["restored_instance_count"] == summary["final_instance_count"]
    if "unmapped_cell_count" in summary:
        assert summary["unmapped_cell_count"] == 0
    if "unmapped_pin_count" in summary:
        assert summary["unmapped_pin_count"] == 0
    return summary


def validate_primary_entries(primary_entries, restored_top):
    assert isinstance(primary_entries, list), "partition_seed.primary_bits must be list"
    seen_bit_labels = set()
    seen_port_positions = set()
    seen_order_indices = set()
    ordered = []

    for item in primary_entries:
        assert_required_keys(
            item,
            [
                "order_index",
                "bit_label",
                "owner_tier",
                "final_port_name",
                "final_port_bit_position",
                "final_bit",
            ],
            "partition_seed.primary_bits entry",
        )

        order_index = item["order_index"]
        assert isinstance(order_index, int), "primary_bits order_index must be int: {}".format(item)
        assert order_index not in seen_order_indices, "Duplicate primary_bits order_index: {}".format(order_index)
        seen_order_indices.add(order_index)

        bit_label = item["bit_label"]
        assert bit_label not in seen_bit_labels, "Duplicate primary bit label: {}".format(bit_label)
        seen_bit_labels.add(bit_label)
        tier_to_die(item["owner_tier"])

        port_name = item["final_port_name"]
        assert port_name in restored_top.ports, "Primary entry references missing top port: {}".format(port_name)
        port = restored_top.ports[port_name]
        bit_position = item["final_port_bit_position"]
        assert isinstance(bit_position, int), "final_port_bit_position must be int: {}".format(item)
        assert 0 <= bit_position < len(port.bits), "final_port_bit_position out of range for {}".format(bit_label)
        assert port.bits[bit_position] == item["final_bit"], (
            "final_bit mismatch for {}: seed={} restored={}".format(
                bit_label, item["final_bit"], port.bits[bit_position]
            )
        )

        position_key = (port_name, bit_position)
        assert position_key not in seen_port_positions, "Duplicate final top port position: {}".format(position_key)
        seen_port_positions.add(position_key)

        expected_index, expected_label = port_bit_labels(restored_top, port_name)[bit_position]
        assert bit_label == expected_label, (
            "bit_label/final port shape mismatch: seed={} expected={}".format(bit_label, expected_label)
        )
        assert item.get("bit_index") == expected_index, "bit_index mismatch for {}".format(bit_label)

        ordered.append(item)

    ordered.sort(key=lambda item: item["order_index"])
    assert [item["order_index"] for item in ordered] == list(range(len(ordered))), (
        "primary_bits order_index must be contiguous from 0"
    )
    return ordered, seen_bit_labels


def validate_instance_entries(instance_tiers, restored_top):
    assert isinstance(instance_tiers, dict), "partition_seed.instance_tiers must be dict"
    restored_names = list(restored_top.cells.keys())
    recorded_names = list(instance_tiers.keys())
    assert set(recorded_names) == set(restored_names), (
        "instance_tiers keys must match restored top cells: missing={} extra={}".format(
            sorted(set(restored_names) - set(recorded_names))[:20],
            sorted(set(recorded_names) - set(restored_names))[:20],
        )
    )

    bottom_count = 0
    upper_count = 0
    ordered_names = []
    for inst_name, item in instance_tiers.items():
        assert_required_keys(item, ["tier", "restored_base_cell_type"], "partition_seed.instance_tiers entry")
        tier = item["tier"]
        tier_to_die(tier)
        restored_cell = restored_top.cells[inst_name]
        assert restored_cell.type == item["restored_base_cell_type"], (
            "restored_base_cell_type mismatch for {}: seed={} design={}".format(
                inst_name, item["restored_base_cell_type"], restored_cell.type
            )
        )
        if tier == TIER_BOTTOM:
            bottom_count += 1
        elif tier == TIER_UPPER:
            upper_count += 1
        else:
            raise AssertionError("Unsupported tier: {}".format(tier))
        ordered_names.append(inst_name)

    return ordered_names, bottom_count, upper_count


def build_primary_lines(ordered_primary_entries):
    return ["{} {}".format(item["bit_label"], tier_to_die(item["owner_tier"])) for item in ordered_primary_entries]


def build_instance_lines(ordered_instance_names, instance_tiers):
    return ["{} {}".format(inst_name, tier_to_die(instance_tiers[inst_name]["tier"])) for inst_name in ordered_instance_names]


def write_partition(lines, out_path):
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as fp:
        for line in lines:
            fp.write(line + "\n")


def assert_written_partition(out_path, expected_line_count, expected_names):
    assert_file_exists(out_path, "FINAL_PARTITION")
    with open(out_path) as fp:
        lines = [line.rstrip("\n") for line in fp]
    assert len(lines) == expected_line_count, (
        "partition_from_flow.txt line count mismatch: expected={} actual={}".format(
            expected_line_count, len(lines)
        )
    )
    names = []
    for line in lines:
        parts = line.split()
        assert len(parts) == 2, "Malformed partition output line: {}".format(line)
        assert parts[1] in {str(PARTITION_BOTTOM_VALUE), str(PARTITION_TOP_VALUE)}, (
            "Invalid die encoding in output line: {}".format(line)
        )
        names.append(parts[0])
    assert len(names) == len(set(names)), "Duplicate names in partition output"
    assert set(names) == set(expected_names), (
        "Partition output name set mismatch: missing={} extra={}".format(
            sorted(set(expected_names) - set(names))[:20],
            sorted(set(names) - set(expected_names))[:20],
        )
    )
    return lines


def main():
    assert_file_exists(PARTITION_SEED_JSON, "PARTITION_SEED_JSON")
    assert_file_exists(RESTORED_BASE_JSON, "RESTORED_BASE_JSON")
    assert_file_exists(FINAL_BASE_V, "FINAL_BASE_V")

    seed = load_json_file(PARTITION_SEED_JSON)
    assert_required_keys(seed, ["identity", "primary_bits", "instance_tiers", "summary", "top_module_name"], "partition_seed")
    assert seed["top_module_name"] == TOP_MODULE_NAME, (
        "partition_seed top_module_name mismatch: expected={} actual={}".format(TOP_MODULE_NAME, seed["top_module_name"])
    )

    restored_design = load_design(RESTORED_BASE_JSON)
    validate_design(restored_design)
    assert TOP_MODULE_NAME in restored_design.modules, "Restored top module missing: {}".format(TOP_MODULE_NAME)
    restored_top = restored_design.modules[TOP_MODULE_NAME]
    assert_no_wrapper_only_ports(restored_top)
    assert_no_pseudo_cells(restored_top)

    summary = validate_seed_summary(seed)
    ordered_primary, primary_names = validate_primary_entries(seed["primary_bits"], restored_top)
    ordered_instances, bottom_count, upper_count = validate_instance_entries(seed["instance_tiers"], restored_top)
    assert primary_names.isdisjoint(set(ordered_instances)), (
        "Primary-bit names overlap instance names: {}".format(sorted(primary_names & set(ordered_instances))[:20])
    )

    assert len(ordered_primary) == summary["final_primary_bit_count"], "Primary-bit count mismatch vs summary"
    assert len(ordered_instances) == summary["final_instance_count"], "Instance count mismatch vs summary"
    assert len(restored_top.ports) == summary["final_top_port_count"], "Top-port count mismatch vs summary"
    assert bottom_count == summary["bottom_instance_count"], "Bottom-instance count mismatch vs summary"
    assert upper_count == summary["upper_instance_count"], "Upper-instance count mismatch vs summary"

    primary_lines = build_primary_lines(ordered_primary)
    instance_lines = build_instance_lines(ordered_instances, seed["instance_tiers"])
    all_lines = primary_lines + instance_lines
    expected_names = [item["bit_label"] for item in ordered_primary] + ordered_instances

    write_partition(all_lines, FINAL_PARTITION)
    assert_written_partition(FINAL_PARTITION, len(all_lines), expected_names)

    print("[09] primary bits              = {}".format(len(primary_lines)))
    print("[09] instances                 = {}".format(len(instance_lines)))
    print("[09] bottom instances          = {}".format(bottom_count))
    print("[09] upper instances           = {}".format(upper_count))
    print("[09] final_partition           -> {}".format(FINAL_PARTITION))


if __name__ == "__main__":
    main()
