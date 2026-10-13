"""
05_build_wrapper.py
Build the hierarchical synthesis wrapper from the remapped tier designs.

This stage consumes the structured split metadata from 02 instead of treating
v5-style carrier ports as final wrapper semantics.  Primary PI/PO bits are
connected directly through the wrapper top, while internal cross-tier data and
generated-clock channels are represented as explicit wrapper internal nets.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
from collections import OrderedDict, defaultdict

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TOOLKIT_ROOT = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "coarse_synth", "common"))
sys.path.insert(0, SCRIPT_DIR)
sys.path.insert(0, TOOLKIT_ROOT)

from flow_config import (
    BOTTOM_COARSE_MODULE_NAME,
    BOTTOM_REMAPPED_JSON,
    CELL_MAPPING_PLAN_JSON,
    CELL_NAME_MAPPING_MODE,
    CLOCK_PORT_MAP_JSON,
    DESIGN,
    FLOW_VARIANT,
    LIBRARY,
    OUTPUT_VERILOG,
    SOURCE_JSON,
    SPLIT_PLAN_JSON,
    TOP_MODULE_NAME,
    TMP_DIR,
    UPPER_COARSE_MODULE_NAME,
    UPPER_REMAPPED_JSON,
    WRAPPER_BOTTOM_INSTANCE_NAME,
    WRAPPER_JSON,
    WRAPPER_PLAN_JSON,
    WRAPPER_TOP_MODULE_NAME,
    WRAPPER_UPPER_INSTANCE_NAME,
    WRAPPER_V,
    YOSYS,
)
from yosys_json_toolkit import (
    BitAllocator,
    Design,
    Module,
    add_cell,
    add_module,
    add_netname,
    add_port_with_netname,
    copy_port_shape_metadata,
    dump_design,
    load_design,
    module_port_shape_signature,
    port_bit_labels,
    port_shape,
    remove_port_and_optional_netname,
    rename_port_and_netname,
    validate_design,
)


TIER_BOTTOM = "bottom"
TIER_UPPER = "upper"
TIER_MODULES = {
    TIER_BOTTOM: BOTTOM_COARSE_MODULE_NAME,
    TIER_UPPER: UPPER_COARSE_MODULE_NAME,
}
TIER_INSTANCES = {
    TIER_BOTTOM: WRAPPER_BOTTOM_INSTANCE_NAME,
    TIER_UPPER: WRAPPER_UPPER_INSTANCE_NAME,
}
SUPPORTED_SOURCE_PORT_DIRECTIONS = {"input", "output"}
SUPPORTED_CELL_PIN_DIRECTIONS = {"input", "output"}


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
    assert os.path.exists(out_v), "Wrapper Verilog was not created: {}".format(out_v)


def assert_verilog_readback(v_path, module_name):
    tcl = """
read_verilog {v_path}
hierarchy -top {module_name}
""".format(
        v_path=v_path,
        module_name=module_name,
    )
    run_yosys_script(tcl, "wrapper verilog readback ({})".format(module_name))


def load_json_file(path):
    assert os.path.isfile(path), "Required JSON file not found: {}".format(path)
    with open(path) as fp:
        data = json.load(fp)
    assert isinstance(data, dict), "JSON file must contain a dictionary: {}".format(path)
    return data


def write_json_file(path, data):
    with open(path, "w") as fp:
        json.dump(data, fp, indent=2)
        fp.write("\n")
    loaded = load_json_file(path)
    assert loaded == data, "JSON readback differs from written file: {}".format(path)


def other_tier(tier):
    assert tier in {TIER_BOTTOM, TIER_UPPER}, "Unexpected tier: {}".format(tier)
    return TIER_UPPER if tier == TIER_BOTTOM else TIER_BOTTOM


def canonical_name(kind, port_name, bit_index):
    if bit_index is None:
        return "__{}_{}".format(kind, port_name)
    return "__{}_{}_{}".format(kind, port_name, bit_index)


def safe_label(label):
    value = re.sub(r"[^A-Za-z0-9_$]+", "_", label).strip("_")
    assert value, "Cannot build safe label from {!r}".format(label)
    if value[0].isdigit():
        value = "b_" + value
    return value


def wrapper_primary_port_name(kind, bit_label):
    assert kind in {"PI", "PO"}, "Unexpected primary kind: {}".format(kind)
    prefix = "__syn3d_pi_" if kind == "PI" else "__syn3d_po_"
    return prefix + safe_label(bit_label)


def assert_design_valid(design, label):
    validate_design(design)
    assert design.modules, "{} has no modules".format(label)


def load_inputs():
    for path in [
        SOURCE_JSON,
        SPLIT_PLAN_JSON,
        CLOCK_PORT_MAP_JSON,
        CELL_MAPPING_PLAN_JSON,
        BOTTOM_REMAPPED_JSON,
        UPPER_REMAPPED_JSON,
    ]:
        assert os.path.isfile(path), "Required 05 input missing: {}".format(path)

    source_design = load_design(SOURCE_JSON)
    bottom_design = load_design(BOTTOM_REMAPPED_JSON)
    upper_design = load_design(UPPER_REMAPPED_JSON)
    assert_design_valid(source_design, "SOURCE_JSON")
    assert_design_valid(bottom_design, "BOTTOM_REMAPPED_JSON")
    assert_design_valid(upper_design, "UPPER_REMAPPED_JSON")

    split_plan = load_json_file(SPLIT_PLAN_JSON)
    clock_port_map = load_json_file(CLOCK_PORT_MAP_JSON)
    cell_mapping_plan = load_json_file(CELL_MAPPING_PLAN_JSON)
    return source_design, bottom_design, upper_design, split_plan, clock_port_map, cell_mapping_plan


def assert_input_contract(source_design, tier_designs, split_plan, clock_port_map, cell_mapping_plan):
    assert TOP_MODULE_NAME in source_design.modules, "Source top module {} not found".format(TOP_MODULE_NAME)
    source_top = source_design.get_module(TOP_MODULE_NAME)
    for port in source_top.ports.values():
        assert port.direction in SUPPORTED_SOURCE_PORT_DIRECTIONS, (
            "05 does not support source top port direction {} on {}".format(port.direction, port.name)
        )

    for tier, module_name in TIER_MODULES.items():
        assert module_name in tier_designs[tier].modules, (
            "{} remapped design missing top module {}".format(tier, module_name)
        )
        assert split_plan["modules"][tier]["name"] == module_name, (
            "Split plan {} module mismatch: {} != {}".format(
                tier, split_plan["modules"][tier]["name"], module_name
            )
        )
        top_module = tier_designs[tier].get_module(module_name)
        for port in top_module.ports.values():
            assert len(port.bits) == 1, (
                "05 first implementation expects scalar tier top ports, got {}.{} -> {}".format(
                    module_name, port.name, port.bits
                )
            )

    assert cell_mapping_plan["mapping_mode"] == CELL_NAME_MAPPING_MODE, (
        "CELL_MAPPING_PLAN_JSON mapping_mode mismatch: {} != {}".format(
            cell_mapping_plan["mapping_mode"], CELL_NAME_MAPPING_MODE
        )
    )
    assert WRAPPER_UPPER_INSTANCE_NAME == "inst_upper", (
        "WRAPPER_UPPER_INSTANCE_NAME must stay fixed for downstream scripts"
    )
    assert WRAPPER_BOTTOM_INSTANCE_NAME == "inst_bottom", (
        "WRAPPER_BOTTOM_INSTANCE_NAME must stay fixed for downstream scripts"
    )
    assert clock_port_map["source_clock_port_name"] in source_top.ports, (
        "Clock source port missing from source top: {}".format(clock_port_map["source_clock_port_name"])
    )
    clk_port = source_top.ports[clock_port_map["source_clock_port_name"]]
    assert clk_port.direction == "input", "Clock source port must be a primary input"
    assert len(clk_port.bits) == 1, "05 first implementation supports one scalar source clock"
    assert clock_port_map["clock_case"] in {"PI-1", "PI-2", "PI-3"}, (
        "Unsupported clock primary case: {}".format(clock_port_map["clock_case"])
    )
    generated = set(clock_port_map.get("generated_clock_channels", []))
    for tier, module_name in TIER_MODULES.items():
        assert tier in clock_port_map["tiers"], "CLOCK_PORT_MAP_JSON missing tier entry: {}".format(tier)
        entry = clock_port_map["tiers"][tier]
        assert entry["module_name"] == module_name, (
            "CLOCK_PORT_MAP_JSON {} module mismatch: {} != {}".format(tier, entry["module_name"], module_name)
        )
        top_module = tier_designs[tier].get_module(module_name)
        source_clock_ports = entry.get("source_clock_ports", [])
        generated_clock_ports = entry.get("generated_clock_ports", [])
        direct_source_clock_ports = entry.get("direct_source_clock_ports", [])
        generated_clock_input_ports = entry.get("generated_clock_input_ports", [])
        expected_related = sorted(
            [item["port_name"] for item in source_clock_ports] + [item["port_name"] for item in generated_clock_ports]
        )
        assert entry["clock_related_ports"] == expected_related, (
            "CLOCK_PORT_MAP_JSON {} related port mismatch: expected {} got {}".format(
                tier, expected_related, entry["clock_related_ports"]
            )
        )
        expected_direct = sorted(item["port_name"] for item in source_clock_ports if item["direction"] == "input")
        assert direct_source_clock_ports == expected_direct, (
            "CLOCK_PORT_MAP_JSON {} direct source clock port mismatch: expected {} got {}".format(
                tier, expected_direct, direct_source_clock_ports
            )
        )
        expected_generated_inputs = sorted(
            item["port_name"] for item in generated_clock_ports if item["direction"] == "input"
        )
        assert generated_clock_input_ports == expected_generated_inputs, (
            "CLOCK_PORT_MAP_JSON {} generated clock input mismatch: expected {} got {}".format(
                tier, expected_generated_inputs, generated_clock_input_ports
            )
        )
        for item in source_clock_ports:
            assert item["port_name"] in top_module.ports, (
                "CLOCK_PORT_MAP_JSON {} source clock port missing from tier module: {}".format(tier, item)
            )
            assert top_module.ports[item["port_name"]].direction == item["direction"], (
                "CLOCK_PORT_MAP_JSON {} source clock port direction mismatch: {}".format(tier, item)
            )
        for item in generated_clock_ports:
            assert item["d2d_name"] in generated, (
                "CLOCK_PORT_MAP_JSON {} generated port references unknown d2d channel: {}".format(tier, item)
            )
            assert item["port_name"] in top_module.ports, (
                "CLOCK_PORT_MAP_JSON {} generated clock port missing from tier module: {}".format(tier, item)
            )
            assert top_module.ports[item["port_name"]].direction == item["direction"], (
                "CLOCK_PORT_MAP_JSON {} generated clock port direction mismatch: {}".format(tier, item)
            )


def build_source_port_plan(source_top):
    allocator = BitAllocator(start=1)
    source_bit_to_wrapper_bit = {}
    label_to_wrapper_bit = OrderedDict()
    source_ports = []

    for port_name, port in source_top.ports.items():
        assert port.direction in SUPPORTED_SOURCE_PORT_DIRECTIONS, (
            "Unsupported source port direction {} on {}".format(port.direction, port_name)
        )
        labels = port_bit_labels(source_top, port_name)
        assert len(labels) == len(port.bits), "Source port label/bit length mismatch for {}".format(port_name)
        wrapper_bits = []
        bit_labels = []
        for index, bit in enumerate(port.bits):
            bit_label = labels[index][1]
            assert bit_label not in label_to_wrapper_bit, "Duplicate source bit label: {}".format(bit_label)
            if isinstance(bit, int):
                if bit not in source_bit_to_wrapper_bit:
                    source_bit_to_wrapper_bit[bit] = allocator.allocate_one()
                wrapper_bit = source_bit_to_wrapper_bit[bit]
            else:
                assert bit in {"0", "1"}, "Source top port constant must be 0/1: {} -> {!r}".format(bit_label, bit)
                wrapper_bit = bit
            wrapper_bits.append(wrapper_bit)
            bit_labels.append(bit_label)
            label_to_wrapper_bit[bit_label] = wrapper_bit
        source_ports.append(
            OrderedDict(
                [
                    ("name", port_name),
                    ("direction", port.direction),
                    ("width", len(port.bits)),
                    ("bit_labels", bit_labels),
                    ("wrapper_bits", wrapper_bits),
                    ("offset", port.offset),
                    ("upto", port.upto),
                    ("signed", port.signed),
                    ("single_bit_vector", port_shape(source_top, port_name)["single_bit_vector"]),
                ]
            )
        )

    return {
        "source_ports": source_ports,
        "source_bit_to_wrapper_bit": source_bit_to_wrapper_bit,
        "label_to_wrapper_bit": label_to_wrapper_bit,
        "allocator": allocator,
    }


def index_primary_bits(split_plan):
    by_label = OrderedDict()
    for item in split_plan["primary_bits"]:
        label = item["bit_label"]
        assert label not in by_label, "Duplicate primary bit label in split plan: {}".format(label)
        assert item["kind"] in {"PI", "PO"}, "Unexpected primary bit kind: {}".format(item)
        by_label[label] = item
    return by_label


def index_internal_d2d(split_plan):
    by_name = OrderedDict()
    for item in split_plan["internal_bits"]:
        if item["case"] in {"NET-1", "NET-5"}:
            assert "d2d_name" not in item, "Non-cross-tier internal bit has d2d_name: {}".format(item)
            continue
        assert item["case"] in {"NET-2", "NET-3"}, "Unsupported internal split case: {}".format(item)
        d2d_name = item.get("d2d_name")
        assert d2d_name, "Cross-tier internal bit missing d2d_name: {}".format(item)
        assert d2d_name not in by_name, "Duplicate d2d_name in split plan: {}".format(d2d_name)
        by_name[d2d_name] = item
    return by_name


class TierActionPlan(object):
    def __init__(self, tier, module):
        self.tier = tier
        self.module_name = module.name
        self.original_ports = set(module.ports.keys())
        self.actions = OrderedDict()

    def _check_common(self, module, port_name, expected_direction, expected_bit):
        assert port_name in module.ports, "Missing tier port {}.{}".format(module.name, port_name)
        port = module.ports[port_name]
        assert port.direction == expected_direction, (
            "Tier port {}.{} direction mismatch: {} != {}".format(
                module.name, port_name, port.direction, expected_direction
            )
        )
        assert len(port.bits) == 1, "Tier port {}.{} must be scalar".format(module.name, port_name)
        assert port.bits[0] == expected_bit, (
            "Tier port {}.{} bit mismatch: {} != {}".format(module.name, port_name, port.bits[0], expected_bit)
        )

    def keep(self, module, port_name, new_name, expected_direction, expected_bit, wrapper_bit, kind, reason, source):
        self._check_common(module, port_name, expected_direction, expected_bit)
        assert port_name not in self.actions, (
            "Tier port {}.{} already has an action".format(module.name, port_name)
        )
        self.actions[port_name] = OrderedDict(
            [
                ("action", "rename" if port_name != new_name else "keep"),
                ("old_name", port_name),
                ("new_name", new_name),
                ("direction", expected_direction),
                ("bit", expected_bit),
                ("wrapper_bit", wrapper_bit),
                ("kind", kind),
                ("reason", reason),
                ("source", source),
            ]
        )

    def remove(self, module, port_name, expected_direction, expected_bit, reason, source):
        self._check_common(module, port_name, expected_direction, expected_bit)
        assert port_name not in self.actions, (
            "Tier port {}.{} already has an action".format(module.name, port_name)
        )
        self.actions[port_name] = OrderedDict(
            [
                ("action", "remove"),
                ("old_name", port_name),
                ("new_name", None),
                ("direction", expected_direction),
                ("bit", expected_bit),
                ("wrapper_bit", None),
                ("kind", "removed_legacy_carrier"),
                ("reason", reason),
                ("source", source),
            ]
        )

    def assert_complete(self):
        missing = sorted(self.original_ports - set(self.actions.keys()))
        assert not missing, (
            "Tier {} has ports without wrapper action: {}".format(self.module_name, missing[:20])
        )


def build_tier_action_plans(tier_modules, split_plan, source_port_plan, clock_port_map):
    primary_by_label = index_primary_bits(split_plan)
    internal_by_name = index_internal_d2d(split_plan)
    generated_clock_channels = set(clock_port_map.get("generated_clock_channels", []))
    assert generated_clock_channels <= set(internal_by_name.keys()), (
        "Generated clock channels missing from internal d2d metadata: {}".format(
            sorted(generated_clock_channels - set(internal_by_name.keys()))
        )
    )

    plans = {
        TIER_UPPER: TierActionPlan(TIER_UPPER, tier_modules[TIER_UPPER]),
        TIER_BOTTOM: TierActionPlan(TIER_BOTTOM, tier_modules[TIER_BOTTOM]),
    }
    primary_connections = []
    tier_interface_rewrite = []
    data_d2d_channels = []
    clock_d2d_channels = []
    d2d_name_to_wrapper_bit = OrderedDict()

    def record_action(tier, action):
        if action["action"] == "remove":
            new_direction = None
        else:
            new_direction = action["direction"]
        tier_interface_rewrite.append(
            OrderedDict(
                [
                    ("tier", tier),
                    ("original_port_name", action["old_name"]),
                    ("new_wrapper_facing_port_name", action["new_name"]),
                    ("original_direction", action["direction"]),
                    ("new_direction", new_direction),
                    ("source_split_case", action["source"].get("case")),
                    ("reason", action["reason"]),
                ]
            )
        )

    def keep_primary(tier, old_name, direction, item, wrapper_bit, reason):
        new_name = wrapper_primary_port_name(item["kind"], item["bit_label"])
        plans[tier].keep(
            tier_modules[tier],
            old_name,
            new_name,
            direction,
            item["bit"],
            wrapper_bit,
            "primary_{}".format(item["kind"].lower()),
            reason,
            item,
        )
        return new_name

    def remove_primary(tier, old_name, direction, item, reason):
        plans[tier].remove(tier_modules[tier], old_name, direction, item["bit"], reason, item)

    for bit_label, item in primary_by_label.items():
        wrapper_bit = source_port_plan["label_to_wrapper_bit"][bit_label]
        owner = item["owner_tier"]
        other = other_tier(owner)
        connected_tier_ports = []
        removed_legacy_ports = []
        assert owner in {TIER_BOTTOM, TIER_UPPER}, "Unexpected primary owner tier: {}".format(item)

        if item["kind"] == "PI":
            owner_name = canonical_name("pi", item["port_name"], item["bit_index"])
            cross_name = canonical_name("d2d_pi", item["port_name"], item["bit_index"])
            if item["case"] == "PI-1":
                new_name = keep_primary(owner, owner_name, "input", item, wrapper_bit, "primary input direct")
                connected_tier_ports.append({"tier": owner, "port": new_name, "direction": "input"})
            elif item["case"] in {"PI-2", "PI-3"}:
                if owner in item["user_tiers"]:
                    new_name = keep_primary(owner, owner_name, "input", item, wrapper_bit, "primary input direct")
                    connected_tier_ports.append({"tier": owner, "port": new_name, "direction": "input"})
                else:
                    remove_primary(owner, owner_name, "input", item, "unused owner-side primary input carrier")
                    removed_legacy_ports.append({"tier": owner, "port": owner_name})
                assert other in item["user_tiers"], "PI cross case missing opposite-tier user: {}".format(item)
                new_name = keep_primary(other, cross_name, "input", item, wrapper_bit, "primary input direct cross-tier consumer")
                connected_tier_ports.append({"tier": other, "port": new_name, "direction": "input"})
                remove_primary(owner, cross_name, "output", item, "remove source-clock/data carrier output")
                removed_legacy_ports.append({"tier": owner, "port": cross_name})
            elif item["case"] == "PI-4":
                assert not item["user_tiers"], "PI-4 must have no user tiers: {}".format(item)
            else:
                raise AssertionError("Unsupported PI case: {}".format(item))
        elif item["kind"] == "PO":
            owner_name = canonical_name("po", item["port_name"], item["bit_index"])
            cross_name = canonical_name("d2d_po", item["port_name"], item["bit_index"])
            if item["case"] == "PO-1":
                new_name = keep_primary(owner, owner_name, "output", item, wrapper_bit, "primary output driver")
                connected_tier_ports.append({"tier": owner, "port": new_name, "direction": "output"})
            elif item["case"] == "PO-2":
                new_name = keep_primary(owner, owner_name, "output", item, wrapper_bit, "primary output driver")
                connected_tier_ports.append({"tier": owner, "port": new_name, "direction": "output"})
                new_name = keep_primary(other, cross_name, "input", item, wrapper_bit, "primary output direct consumer")
                connected_tier_ports.append({"tier": other, "port": new_name, "direction": "input"})
                remove_primary(owner, cross_name, "output", item, "remove duplicate primary output carrier")
                removed_legacy_ports.append({"tier": owner, "port": cross_name})
            elif item["case"] == "PO-3":
                driver = item["driver_tier"]
                assert driver in {TIER_BOTTOM, TIER_UPPER}, "PO-3 missing driver tier: {}".format(item)
                assert driver != owner, "PO-3 driver must differ from owner: {}".format(item)
                new_name = keep_primary(driver, cross_name, "output", item, wrapper_bit, "primary output real driver")
                connected_tier_ports.append({"tier": driver, "port": new_name, "direction": "output"})
                if owner in item["user_tiers"]:
                    new_name = keep_primary(owner, cross_name, "input", item, wrapper_bit, "primary output direct consumer")
                    connected_tier_ports.append({"tier": owner, "port": new_name, "direction": "input"})
                else:
                    remove_primary(owner, cross_name, "input", item, "unused owner-side primary output carrier input")
                    removed_legacy_ports.append({"tier": owner, "port": cross_name})
                remove_primary(owner, owner_name, "output", item, "remove owner-side primary output pass-through")
                removed_legacy_ports.append({"tier": owner, "port": owner_name})
            elif item["case"] == "PO-4":
                assert item["bit"] in {"0", "1"}, "PO-4 must be a constant output: {}".format(item)
                remove_primary(owner, owner_name, "output", item, "constant primary output does not need tier driver")
                removed_legacy_ports.append({"tier": owner, "port": owner_name})
            else:
                raise AssertionError("Unsupported PO case: {}".format(item))
        else:
            raise AssertionError("Unsupported primary kind: {}".format(item))

        primary_connections.append(
            OrderedDict(
                [
                    ("source_bit_label", bit_label),
                    ("kind", item["kind"]),
                    ("case", item["case"]),
                    ("owner_tier", owner),
                    ("driver_tier", item.get("driver_tier")),
                    ("user_tiers", item.get("user_tiers", [])),
                    ("wrapper_port", item["port_name"]),
                    ("wrapper_bit", wrapper_bit),
                    ("connected_tier_ports", connected_tier_ports),
                    ("removed_legacy_carrier_ports", removed_legacy_ports),
                ]
            )
        )

    allocator = source_port_plan["allocator"]
    for d2d_name, item in internal_by_name.items():
        producer = item["driver_tier"]
        consumer = other_tier(producer)
        assert consumer in item["user_tiers"], (
            "Cross-tier d2d {} missing opposite-tier consumer in {}".format(d2d_name, item)
        )
        wrapper_bit = allocator.allocate_one()
        assert d2d_name not in d2d_name_to_wrapper_bit, "Duplicate wrapper d2d bit for {}".format(d2d_name)
        d2d_name_to_wrapper_bit[d2d_name] = wrapper_bit
        kind = "clock_d2d" if d2d_name in generated_clock_channels else "data_d2d"
        plans[producer].keep(
            tier_modules[producer],
            d2d_name,
            d2d_name,
            "output",
            item["bit"],
            wrapper_bit,
            kind,
            "internal cross-tier {}".format(kind),
            item,
        )
        plans[consumer].keep(
            tier_modules[consumer],
            d2d_name,
            d2d_name,
            "input",
            item["bit"],
            wrapper_bit,
            kind,
            "internal cross-tier {}".format(kind),
            item,
        )
        channel = OrderedDict(
            [
                ("d2d_name", d2d_name),
                ("source_debug_name", item["debug_name"]),
                ("case", item["case"]),
                ("producer_tier", producer),
                ("consumer_tier", consumer),
                ("producer_port", d2d_name),
                ("consumer_port", d2d_name),
                ("wrapper_net_bit", wrapper_bit),
            ]
        )
        if d2d_name in generated_clock_channels:
            clock_d2d_channels.append(channel)
        else:
            data_d2d_channels.append(channel)

    for tier, plan in plans.items():
        plan.assert_complete()
        new_names = defaultdict(list)
        for action in plan.actions.values():
            if action["action"] == "remove":
                continue
            new_names[action["new_name"]].append(action["old_name"])
        duplicates = {name: olds for name, olds in new_names.items() if len(olds) > 1}
        assert not duplicates, "Tier {} has duplicate transformed port names: {}".format(tier, duplicates)
        for action in plan.actions.values():
            record_action(tier, action)

    return {
        "plans": plans,
        "primary_connections": primary_connections,
        "tier_interface_rewrite": tier_interface_rewrite,
        "data_d2d_channels": data_d2d_channels,
        "clock_d2d_channels": clock_d2d_channels,
        "d2d_name_to_wrapper_bit": d2d_name_to_wrapper_bit,
    }


def transform_tier_module_interface(tier, module, plan):
    transformed = module.copy()
    before_cells = {name: cell.to_dict() for name, cell in transformed.cells.items()}
    before_memories = {name: memory.to_dict() for name, memory in transformed.memories.items()}

    for action in plan.actions.values():
        if action["action"] == "remove":
            remove_port_and_optional_netname(transformed, action["old_name"], expected_bits=[action["bit"]])
    for action in plan.actions.values():
        if action["action"] == "rename":
            rename_port_and_netname(transformed, action["old_name"], action["new_name"])

    assert before_cells == {name: cell.to_dict() for name, cell in transformed.cells.items()}, (
        "05 {} interface transform unexpectedly changed cells".format(tier)
    )
    assert before_memories == {name: memory.to_dict() for name, memory in transformed.memories.items()}, (
        "05 {} interface transform unexpectedly changed memories".format(tier)
    )
    assert_live_module_boundary(transformed, "transformed {}".format(tier))
    return transformed


def assert_live_module_boundary(module, context):
    cell_output_driver_bits = set()
    cell_input_bits = set()
    module_input_bits = set()
    module_output_bits = set()

    for port in module.ports.values():
        for bit in port.bits:
            if not isinstance(bit, int):
                continue
            if port.direction == "input":
                module_input_bits.add(bit)
            elif port.direction == "output":
                module_output_bits.add(bit)
            else:
                raise AssertionError("{} has unsupported module port direction {}".format(context, port.direction))

    for cell in module.cells.values():
        for pin_name, bits in cell.connections.items():
            direction = cell.port_directions.get(pin_name)
            assert direction in SUPPORTED_CELL_PIN_DIRECTIONS, (
                "{} missing supported port direction for {}.{}".format(context, cell.name, pin_name)
            )
            for bit in bits:
                if not isinstance(bit, int):
                    continue
                if direction == "output":
                    cell_output_driver_bits.add(bit)
                else:
                    cell_input_bits.add(bit)

    missing_input_drivers = sorted(cell_input_bits - cell_output_driver_bits - module_input_bits)
    assert not missing_input_drivers, (
        "{} has live cell input bits without cell driver or module input: {}".format(
            context, missing_input_drivers[:20]
        )
    )
    missing_output_drivers = sorted(module_output_bits - cell_output_driver_bits - module_input_bits)
    assert not missing_output_drivers, (
        "{} has module output bits without cell driver or module input: {}".format(
            context, missing_output_drivers[:20]
        )
    )


def add_wrapper_primary_ports(wrapper_top, source_top, source_port_plan):
    bit_iter = iter(source_port_plan["source_ports"])
    for port_name, source_port in source_top.ports.items():
        plan_entry = next(bit_iter)
        assert plan_entry["name"] == port_name, "Source port order mismatch while building wrapper"
        add_port_with_netname(
            wrapper_top,
            port_name,
            source_port.direction,
            plan_entry["wrapper_bits"],
            offset=source_port.offset,
            upto=source_port.upto,
            signed=source_port.signed,
        )
        copy_port_shape_metadata(source_top, wrapper_top, port_name)


def add_d2d_netnames(wrapper_top, data_d2d_channels, clock_d2d_channels):
    seen = set()
    for kind, channels in [("data_d2d", data_d2d_channels), ("clock_d2d", clock_d2d_channels)]:
        for channel in channels:
            name = channel["d2d_name"]
            assert name not in seen, "Duplicate wrapper d2d netname: {}".format(name)
            seen.add(name)
            add_netname(
                wrapper_top,
                name,
                [channel["wrapper_net_bit"]],
                hide_name=0,
                attributes={"syn3d_channel_kind": kind},
            )


def build_instance_connections(module, plan):
    connections = OrderedDict()
    port_directions = OrderedDict()
    for port_name, port in module.ports.items():
        action = None
        for candidate in plan.actions.values():
            if candidate["action"] == "remove":
                continue
            if candidate["new_name"] == port_name:
                action = candidate
                break
        assert action is not None, "No wrapper connection action for port {}.{}".format(module.name, port_name)
        assert port.direction == action["direction"], (
            "Transformed port direction mismatch for {}.{}".format(module.name, port_name)
        )
        connections[port_name] = [action["wrapper_bit"]]
        port_directions[port_name] = port.direction
    assert set(connections.keys()) == set(module.ports.keys()), (
        "Instance connection set does not match transformed module ports for {}".format(module.name)
    )
    return connections, port_directions


def build_wrapper_top(source_top, transformed_tiers, action_plan, source_port_plan):
    wrapper_top = Module(
        name=WRAPPER_TOP_MODULE_NAME,
        attributes=OrderedDict(),
        parameter_default_values=OrderedDict(),
        ports=OrderedDict(),
        cells=OrderedDict(),
        memories=OrderedDict(),
        netnames=OrderedDict(),
    )
    add_wrapper_primary_ports(wrapper_top, source_top, source_port_plan)
    add_d2d_netnames(wrapper_top, action_plan["data_d2d_channels"], action_plan["clock_d2d_channels"])

    for tier in [TIER_UPPER, TIER_BOTTOM]:
        connections, port_directions = build_instance_connections(transformed_tiers[tier], action_plan["plans"][tier])
        add_cell(
            wrapper_top,
            TIER_INSTANCES[tier],
            TIER_MODULES[tier],
            connections,
            hide_name=0,
            parameters={},
            attributes={"syn3d_tier": tier},
            port_directions=port_directions,
        )

    return wrapper_top


def tier_namespaced_module_name(tier, module_name):
    assert tier in {TIER_BOTTOM, TIER_UPPER}, "Unexpected tier namespace: {}".format(tier)
    assert module_name, "Cannot namespace an empty module name"
    return "_syn3d_{}__{}".format(tier, module_name)


def build_tier_internal_module_map(tier_designs):
    maps = {}
    all_new_names = set()
    for tier in [TIER_UPPER, TIER_BOTTOM]:
        module_map = OrderedDict()
        for module_name in tier_designs[tier].modules:
            if module_name == TIER_MODULES[tier]:
                continue
            new_name = tier_namespaced_module_name(tier, module_name)
            assert new_name not in tier_designs[tier].modules, (
                "{} namespaced module name collides with existing module: {}".format(tier, new_name)
            )
            assert new_name not in all_new_names, "Duplicate namespaced module name: {}".format(new_name)
            all_new_names.add(new_name)
            module_map[module_name] = new_name
        maps[tier] = module_map
    return maps


def clone_module_with_type_map(module, new_name, type_map):
    cloned = module.copy()
    cloned.name = new_name
    remapped_cells = []
    for cell in cloned.cells.values():
        if cell.type in type_map:
            old_type = cell.type
            cell.type = type_map[old_type]
            remapped_cells.append((cell.name, old_type, cell.type))
    return cloned, remapped_cells


def build_wrapper_design(source_design, tier_designs, transformed_tiers, wrapper_top):
    wrapper_design = Design(
        creator=source_design.creator,
        modules=OrderedDict(),
        models=json.loads(json.dumps(source_design.models)),
        extras=json.loads(json.dumps(source_design.extras)),
    )
    tier_module_maps = build_tier_internal_module_map(tier_designs)

    add_module(wrapper_design, wrapper_top, clone=True)
    for tier in [TIER_UPPER, TIER_BOTTOM]:
        transformed_top, remapped_cells = clone_module_with_type_map(
            transformed_tiers[tier], TIER_MODULES[tier], tier_module_maps[tier]
        )
        add_module(wrapper_design, transformed_top, clone=False)
        assert not any(new_type in {TIER_MODULES[TIER_UPPER], TIER_MODULES[TIER_BOTTOM]} for _, _, new_type in remapped_cells), (
            "{} tier top unexpectedly references a tier top module after namespace rewrite".format(tier)
        )

    merge_log = []
    for tier in [TIER_UPPER, TIER_BOTTOM]:
        type_map = tier_module_maps[tier]
        for module_name, module in tier_designs[tier].modules.items():
            if module_name == TIER_MODULES[tier]:
                continue
            namespaced_name = type_map[module_name]
            namespaced_module, remapped_cells = clone_module_with_type_map(module, namespaced_name, type_map)
            assert namespaced_name not in wrapper_design.modules, (
                "Namespaced module collision while merging {}: {}".format(tier, namespaced_name)
            )
            add_module(wrapper_design, namespaced_module, clone=False)
            merge_log.append(
                OrderedDict(
                    [
                        ("tier", tier),
                        ("original_module", module_name),
                        ("namespaced_module", namespaced_name),
                        ("status", "tier_namespaced"),
                        ("remapped_internal_instance_count", len(remapped_cells)),
                    ]
                )
            )

    validate_design(wrapper_design)
    return wrapper_design, merge_log


def assert_wrapper_top_contract(wrapper_design, source_top, split_plan, clock_port_map, plan):
    assert WRAPPER_TOP_MODULE_NAME in wrapper_design.modules, "Wrapper top module missing"
    wrapper_top = wrapper_design.get_module(WRAPPER_TOP_MODULE_NAME)
    assert set(wrapper_top.cells.keys()) == {WRAPPER_UPPER_INSTANCE_NAME, WRAPPER_BOTTOM_INSTANCE_NAME}, (
        "Wrapper top must contain only inst_upper/inst_bottom, got {}".format(sorted(wrapper_top.cells.keys()))
    )
    assert wrapper_top.cells[WRAPPER_UPPER_INSTANCE_NAME].type == UPPER_COARSE_MODULE_NAME
    assert wrapper_top.cells[WRAPPER_BOTTOM_INSTANCE_NAME].type == BOTTOM_COARSE_MODULE_NAME

    assert module_port_shape_signature(wrapper_top) == module_port_shape_signature(source_top), (
        "Wrapper top primary port shape differs from source top"
    )

    legacy_top_ports = [
        name for name in wrapper_top.ports if name.startswith("__d2d_pi_") or name.startswith("__d2d_po_")
    ]
    assert not legacy_top_ports, "Wrapper top must not expose legacy carrier ports: {}".format(legacy_top_ports)

    expected_data = [
        item
        for item in split_plan["internal_bits"]
        if item.get("d2d_name") and item["d2d_name"] not in set(clock_port_map.get("generated_clock_channels", []))
    ]
    expected_clock = list(clock_port_map.get("generated_clock_channels", []))
    assert len(plan["data_d2d_channels"]) == len(expected_data), (
        "Data d2d count mismatch: {} != {}".format(len(plan["data_d2d_channels"]), len(expected_data))
    )
    assert len(plan["clock_d2d_channels"]) == len(expected_clock), (
        "Clock d2d count mismatch: {} != {}".format(len(plan["clock_d2d_channels"]), len(expected_clock))
    )
    data_names = {item["d2d_name"] for item in plan["data_d2d_channels"]}
    clock_names = {item["d2d_name"] for item in plan["clock_d2d_channels"]}
    assert not (data_names & clock_names), "Data d2d and clock d2d names overlap"

    for tier in [TIER_UPPER, TIER_BOTTOM]:
        cell = wrapper_top.cells[TIER_INSTANCES[tier]]
        module = wrapper_design.get_module(TIER_MODULES[tier])
        assert set(cell.connections.keys()) == set(module.ports.keys()), (
            "Wrapper instance {} connections do not match module ports".format(TIER_INSTANCES[tier])
        )
        assert cell.port_directions == {name: port.direction for name, port in module.ports.items()}, (
            "Wrapper instance {} port_directions do not match module ports".format(TIER_INSTANCES[tier])
        )

    assert_no_multiple_wrapper_drivers(wrapper_top)
    assert_clock_direct_fanout_not_backdriven(wrapper_top, clock_port_map, plan)


def assert_no_multiple_wrapper_drivers(wrapper_top):
    drivers = defaultdict(list)
    for port in wrapper_top.ports.values():
        if port.direction != "input":
            continue
        for bit in port.bits:
            if isinstance(bit, int):
                drivers[bit].append("wrapper_input:{}".format(port.name))
    for cell in wrapper_top.cells.values():
        for pin_name, bits in cell.connections.items():
            direction = cell.port_directions.get(pin_name)
            assert direction in SUPPORTED_CELL_PIN_DIRECTIONS, (
                "Wrapper cell {} missing direction for port {}".format(cell.name, pin_name)
            )
            if direction != "output":
                continue
            for bit in bits:
                if isinstance(bit, int):
                    drivers[bit].append("{}.{}".format(cell.name, pin_name))
    multiple = {bit: names for bit, names in drivers.items() if len(names) > 1}
    assert not multiple, "Wrapper top has multiple drivers per bit: {}".format(multiple)


def assert_clock_direct_fanout_not_backdriven(wrapper_top, clock_port_map, plan):
    generated = set(clock_port_map.get("generated_clock_channels", []))
    if generated:
        return
    source_clock_label = clock_port_map["source_clock_bit_label"]
    clock_bit = None
    for entry in plan["source_ports"]:
        for index, bit_label in enumerate(entry["bit_labels"]):
            if bit_label == source_clock_label:
                clock_bit = entry["wrapper_bits"][index]
    assert clock_bit is not None, "Source clock bit not found in wrapper source port plan"
    output_drivers = []
    for cell in wrapper_top.cells.values():
        for pin_name, bits in cell.connections.items():
            if bits != [clock_bit]:
                continue
            if cell.port_directions.get(pin_name) == "output":
                output_drivers.append("{}.{}".format(cell.name, pin_name))
    assert not output_drivers, (
        "Source clock direct fanout is back-driven by tier output ports: {}".format(output_drivers)
    )


def combine_contract_plan(action_plan, source_port_plan):
    combined = dict(action_plan)
    combined["source_ports"] = source_port_plan["source_ports"]
    return combined


def build_wrapper_plan(source_port_plan, action_plan, clock_port_map, merge_log, wrapper_design):
    wrapper_top = wrapper_design.get_module(WRAPPER_TOP_MODULE_NAME)
    removed_count = sum(
        1
        for tier_plan in action_plan["plans"].values()
        for action in tier_plan.actions.values()
        if action["action"] == "remove"
    )
    return OrderedDict(
        [
            (
                "identity",
                OrderedDict(
                    [
                        ("design", DESIGN),
                        ("library", LIBRARY),
                        ("mapping_mode", CELL_NAME_MAPPING_MODE),
                        ("flow_variant", FLOW_VARIANT),
                    ]
                ),
            ),
            (
                "modules",
                OrderedDict(
                    [
                        ("wrapper_top", WRAPPER_TOP_MODULE_NAME),
                        ("upper_module", UPPER_COARSE_MODULE_NAME),
                        ("bottom_module", BOTTOM_COARSE_MODULE_NAME),
                        ("upper_instance", WRAPPER_UPPER_INSTANCE_NAME),
                        ("bottom_instance", WRAPPER_BOTTOM_INSTANCE_NAME),
                    ]
                ),
            ),
            ("source_ports", source_port_plan["source_ports"]),
            ("tier_interface_rewrite", action_plan["tier_interface_rewrite"]),
            ("primary_connections", action_plan["primary_connections"]),
            ("data_d2d_channels", action_plan["data_d2d_channels"]),
            (
                "clock",
                OrderedDict(
                    [
                        ("source_clock_port", clock_port_map["source_clock_port_name"]),
                        ("source_clock_bit_label", clock_port_map["source_clock_bit_label"]),
                        ("clock_case", clock_port_map["clock_case"]),
                        ("direct_fanout_tier_ports", collect_clock_direct_fanout_ports(action_plan, clock_port_map)),
                        ("clock_d2d_channels", action_plan["clock_d2d_channels"]),
                    ]
                ),
            ),
            ("module_merge_log", merge_log),
            (
                "checks",
                OrderedDict(
                    [
                        ("top_cell_count", len(wrapper_top.cells)),
                        ("data_d2d_count", len(action_plan["data_d2d_channels"])),
                        ("clock_d2d_count", len(action_plan["clock_d2d_channels"])),
                        ("removed_legacy_carrier_count", removed_count),
                        ("unsupported_count", 0),
                    ]
                ),
            ),
        ]
    )


def collect_clock_direct_fanout_ports(action_plan, clock_port_map):
    if clock_port_map.get("generated_clock_channels"):
        return []
    source_label = clock_port_map["source_clock_bit_label"]
    ports = []
    for item in action_plan["primary_connections"]:
        if item["source_bit_label"] != source_label:
            continue
        for port in item["connected_tier_ports"]:
            ports.append(port)
    return ports


def assert_wrapper_plan_matches_design(wrapper_plan, wrapper_design):
    wrapper_top = wrapper_design.get_module(WRAPPER_TOP_MODULE_NAME)
    assert wrapper_plan["checks"]["top_cell_count"] == len(wrapper_top.cells)
    assert wrapper_plan["checks"]["data_d2d_count"] == len(wrapper_plan["data_d2d_channels"])
    assert wrapper_plan["checks"]["clock_d2d_count"] == len(wrapper_plan["clock"]["clock_d2d_channels"])
    assert wrapper_plan["checks"]["unsupported_count"] == 0
    assert wrapper_plan["modules"]["wrapper_top"] == WRAPPER_TOP_MODULE_NAME
    assert wrapper_plan["modules"]["upper_instance"] in wrapper_top.cells
    assert wrapper_plan["modules"]["bottom_instance"] in wrapper_top.cells

    assert len(wrapper_plan["source_ports"]) == len(wrapper_top.ports)
    for plan_entry, port_name in zip(wrapper_plan["source_ports"], wrapper_top.ports):
        shape = port_shape(wrapper_top, port_name)
        assert plan_entry["name"] == port_name
        assert plan_entry["direction"] == shape["direction"]
        assert plan_entry["width"] == shape["width"]
        assert plan_entry["bit_labels"] == shape["bit_labels"]
        assert plan_entry["single_bit_vector"] == shape["single_bit_vector"]

    d2d_netnames = {
        name
        for name, netname in wrapper_top.netnames.items()
        if netname.attributes.get("syn3d_channel_kind") in {"data_d2d", "clock_d2d"}
    }
    plan_d2d = {item["d2d_name"] for item in wrapper_plan["data_d2d_channels"]}
    plan_d2d.update(item["d2d_name"] for item in wrapper_plan["clock"]["clock_d2d_channels"])
    assert d2d_netnames == plan_d2d, (
        "Wrapper plan d2d netnames mismatch: json={} plan={}".format(sorted(d2d_netnames), sorted(plan_d2d))
    )


def main():
    os.makedirs(TMP_DIR, exist_ok=True)
    source_design, bottom_design, upper_design, split_plan, clock_port_map, cell_mapping_plan = load_inputs()
    tier_designs = {TIER_BOTTOM: bottom_design, TIER_UPPER: upper_design}
    assert_input_contract(source_design, tier_designs, split_plan, clock_port_map, cell_mapping_plan)

    source_top = source_design.get_module(TOP_MODULE_NAME)
    tier_modules = {
        TIER_BOTTOM: bottom_design.get_module(BOTTOM_COARSE_MODULE_NAME),
        TIER_UPPER: upper_design.get_module(UPPER_COARSE_MODULE_NAME),
    }

    print("[05] analyzing source primary port shape ...")
    source_port_plan = build_source_port_plan(source_top)

    print("[05] building tier interface rewrite plan ...")
    action_plan = build_tier_action_plans(tier_modules, split_plan, source_port_plan, clock_port_map)

    print("[05] transforming tier module interfaces ...")
    transformed_tiers = {
        TIER_UPPER: transform_tier_module_interface(
            TIER_UPPER, tier_modules[TIER_UPPER], action_plan["plans"][TIER_UPPER]
        ),
        TIER_BOTTOM: transform_tier_module_interface(
            TIER_BOTTOM, tier_modules[TIER_BOTTOM], action_plan["plans"][TIER_BOTTOM]
        ),
    }

    print("[05] building wrapper top ...")
    wrapper_top = build_wrapper_top(source_top, transformed_tiers, action_plan, source_port_plan)
    wrapper_design, merge_log = build_wrapper_design(source_design, tier_designs, transformed_tiers, wrapper_top)
    assert_wrapper_top_contract(
        wrapper_design,
        source_top,
        split_plan,
        clock_port_map,
        combine_contract_plan(action_plan, source_port_plan),
    )

    wrapper_plan = build_wrapper_plan(source_port_plan, action_plan, clock_port_map, merge_log, wrapper_design)
    assert_wrapper_plan_matches_design(wrapper_plan, wrapper_design)

    print("[05] writing wrapper json and plan ...")
    dump_design(wrapper_design, WRAPPER_JSON)
    reloaded = load_design(WRAPPER_JSON)
    validate_design(reloaded)
    assert_wrapper_plan_matches_design(wrapper_plan, reloaded)
    write_json_file(WRAPPER_PLAN_JSON, wrapper_plan)
    assert_wrapper_plan_matches_design(load_json_file(WRAPPER_PLAN_JSON), reloaded)

    if OUTPUT_VERILOG:
        print("[05] emitting wrapper verilog ...")
        emit_json_to_verilog(WRAPPER_JSON, WRAPPER_TOP_MODULE_NAME, WRAPPER_V)
        assert_verilog_readback(WRAPPER_V, WRAPPER_TOP_MODULE_NAME)

    print("[05] done")
    print("       wrapper_json -> {}".format(WRAPPER_JSON))
    print("       wrapper_plan -> {}".format(WRAPPER_PLAN_JSON))
    if OUTPUT_VERILOG:
        print("       wrapper_v    -> {}".format(WRAPPER_V))


if __name__ == "__main__":
    main()
