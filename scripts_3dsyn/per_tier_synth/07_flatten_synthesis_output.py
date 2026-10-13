"""
07_prepare_flat_handoff.py

Flatten the 06 Genus wrapper one level into the final backend top module while
preserving structured tier ownership metadata for partition generation.
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
    BOTTOM_COARSE_MODULE_NAME,
    CELL_MAPPING_PLAN_JSON,
    CELL_NAME_MAPPING_MODE,
    DESIGN,
    FLAT_JSON,
    FLAT_V,
    FLOW_VARIANT,
    GENUS_OUTPUT_JSON,
    GENUS_OUTPUT_V,
    GENUS_PLAN_JSON,
    LIBRARY,
    PARTITION_SEED_JSON,
    SOURCE_JSON,
    SPLIT_PLAN_JSON,
    SYNTH_MODE,
    TOP_MODULE_NAME,
    UPPER_COARSE_MODULE_NAME,
    WRAPPER_BOTTOM_INSTANCE_NAME,
    WRAPPER_PLAN_JSON,
    WRAPPER_TOP_MODULE_NAME,
    WRAPPER_UPPER_INSTANCE_NAME,
    YOSYS,
)
from yosys_json_toolkit import (
    BitAllocator,
    Cell,
    Design,
    Module,
    Netname,
    Port,
    dump_design,
    load_design,
    module_port_shape_signature,
    normalize_backend_internal_netnames,
    port_bit_labels,
    replace_bit_references,
    validate_design,
)


TIER_BOTTOM = "bottom"
TIER_UPPER = "upper"
VALID_TIERS = {TIER_BOTTOM, TIER_UPPER}
D2D_PREFIX = "__d2d"
WRAPPER_ONLY_PORT_PREFIXES = ("__syn3d_pi_", "__syn3d_po_", "__d2d_", "__pi_", "__po_")


def load_json_file(path):
    assert os.path.isfile(path), "Required JSON file not found: {}".format(path)
    with open(path) as fp:
        data = json.load(fp)
    assert isinstance(data, dict), "JSON file must contain a dictionary: {}".format(path)
    return data


def write_json_file(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fp:
        json.dump(data, fp, indent=2)
        fp.write("\n")
    assert load_json_file(path) == data, "JSON readback mismatch: {}".format(path)


def run_yosys_script(body_tcl, label):
    assert os.path.exists(YOSYS), "Yosys not found: {}".format(YOSYS)
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
    run_yosys_script(tcl, "flat json -> verilog ({})".format(top_module_name))
    assert os.path.isfile(out_v), "Flat Verilog was not created: {}".format(out_v)


def assert_same_port_shape(left, right, label):
    left_sig = module_port_shape_signature(left)
    right_sig = module_port_shape_signature(right)
    assert left_sig == right_sig, "Port shape mismatch for {}:\nleft={}\nright={}".format(label, left_sig, right_sig)


def assert_required_identity(genus_plan, wrapper_plan, cell_mapping_plan):
    identity = genus_plan["identity"]
    assert identity["design"] == DESIGN
    assert identity["library"] == LIBRARY
    assert identity["flow_variant"] == FLOW_VARIANT
    assert identity["synth_mode"] == SYNTH_MODE
    assert identity["mapping_mode"] == CELL_NAME_MAPPING_MODE

    wrapper_identity = wrapper_plan["identity"]
    for key in ["design", "library", "flow_variant", "mapping_mode"]:
        assert wrapper_identity[key] == identity[key], "Wrapper/genus identity mismatch for {}".format(key)

    assert cell_mapping_plan["mapping_mode"] == CELL_NAME_MAPPING_MODE, (
        "CELL_MAPPING_PLAN_JSON mapping_mode mismatch: {} != {}".format(
            cell_mapping_plan["mapping_mode"], CELL_NAME_MAPPING_MODE
        )
    )


def assert_genus_wrapper_contract(genus_design, source_design, genus_plan, wrapper_plan):
    assert WRAPPER_TOP_MODULE_NAME in genus_design.modules, "Genus wrapper top missing: {}".format(WRAPPER_TOP_MODULE_NAME)
    assert TOP_MODULE_NAME in source_design.modules, "Source top missing: {}".format(TOP_MODULE_NAME)
    top = genus_design.modules[WRAPPER_TOP_MODULE_NAME]
    source_top = source_design.modules[TOP_MODULE_NAME]
    assert_same_port_shape(source_top, top, "source vs genus wrapper")

    modules = wrapper_plan["modules"]
    assert modules["wrapper_top"] == WRAPPER_TOP_MODULE_NAME
    assert modules["upper_module"] == UPPER_COARSE_MODULE_NAME
    assert modules["bottom_module"] == BOTTOM_COARSE_MODULE_NAME
    assert modules["upper_instance"] == WRAPPER_UPPER_INSTANCE_NAME
    assert modules["bottom_instance"] == WRAPPER_BOTTOM_INSTANCE_NAME

    expected_cells = {WRAPPER_UPPER_INSTANCE_NAME, WRAPPER_BOTTOM_INSTANCE_NAME}
    actual_cells = set(top.cells.keys())
    assert actual_cells == expected_cells, "Genus wrapper top cells mismatch: expected={} actual={}".format(
        sorted(expected_cells), sorted(actual_cells)
    )
    assert top.cells[WRAPPER_UPPER_INSTANCE_NAME].type == UPPER_COARSE_MODULE_NAME
    assert top.cells[WRAPPER_BOTTOM_INSTANCE_NAME].type == BOTTOM_COARSE_MODULE_NAME
    assert UPPER_COARSE_MODULE_NAME in genus_design.modules, "Upper module missing in Genus output"
    assert BOTTOM_COARSE_MODULE_NAME in genus_design.modules, "Bottom module missing in Genus output"

    plan_data_d2d = len(wrapper_plan.get("data_d2d_channels", []))
    plan_clock_d2d = len(wrapper_plan.get("clock", {}).get("clock_d2d_channels", []))
    if "checks" in genus_plan:
        output_checks = genus_plan["checks"].get("output", {})
    else:
        output_checks = genus_plan.get("final_checks", {}).get("final", {})
    if output_checks:
        assert output_checks.get("data_d2d_count", plan_data_d2d) == plan_data_d2d
        assert output_checks.get("clock_d2d_count", plan_clock_d2d) == plan_clock_d2d


def map_tier_bit(bit, port_bit_map, local_bit_map, allocator):
    if isinstance(bit, str):
        return bit
    assert isinstance(bit, int), "Unsupported bit value: {!r}".format(bit)
    if bit in port_bit_map:
        return port_bit_map[bit]
    if bit not in local_bit_map:
        local_bit_map[bit] = allocator.allocate_one()
    return local_bit_map[bit]


def build_port_bit_map(tier_module, tier_instance):
    port_bit_map = {}
    constant_port_drivers = []
    for port_name, port in tier_module.ports.items():
        assert port_name in tier_instance.connections, (
            "Tier instance {} missing connection for port {}".format(tier_instance.name, port_name)
        )
        connected_bits = tier_instance.connections[port_name]
        assert len(connected_bits) == len(port.bits), (
            "Tier instance {} port {} width mismatch: module={} inst={}".format(
                tier_instance.name, port_name, len(port.bits), len(connected_bits)
            )
        )
        for module_bit, wrapper_bit in zip(port.bits, connected_bits):
            if isinstance(module_bit, str):
                assert module_bit in {"0", "1"}, (
                    "Tier module port {} contains unsupported constant bit {!r}".format(port_name, module_bit)
                )
                assert port.direction == "output", (
                    "Only output ports may be constant after Genus optimization, got {}.{} direction {}".format(
                        tier_module.name, port_name, port.direction
                    )
                )
                assert isinstance(wrapper_bit, int), (
                    "Constant output port {} maps to non-integer wrapper bit {!r}".format(port_name, wrapper_bit)
                )
                constant_port_drivers.append(
                    OrderedDict(
                        [
                            ("port_name", port_name),
                            ("constant", module_bit),
                            ("wrapper_bit", wrapper_bit),
                        ]
                    )
                )
                continue
            assert isinstance(module_bit, int), "Tier module port {} contains unsupported bit {!r}".format(
                port_name, module_bit
            )
            if module_bit in port_bit_map:
                assert port_bit_map[module_bit] == wrapper_bit, (
                    "Tier module bit {} maps to multiple wrapper bits: {} vs {}".format(
                        module_bit, port_bit_map[module_bit], wrapper_bit
                    )
                )
            port_bit_map[module_bit] = wrapper_bit
    return port_bit_map, constant_port_drivers


def apply_constant_port_drivers(flat_top, tier, constant_port_drivers):
    applied = []
    seen = {}
    for item in constant_port_drivers:
        wrapper_bit = item["wrapper_bit"]
        constant = item["constant"]
        if wrapper_bit in seen:
            assert seen[wrapper_bit] == constant, (
                "Conflicting constant drivers for wrapper bit {}: {} vs {}".format(
                    wrapper_bit, seen[wrapper_bit], constant
                )
            )
            continue
        seen[wrapper_bit] = constant
        replacements = replace_bit_references(flat_top, wrapper_bit, constant)
        assert replacements > 0, (
            "Constant port driver {}.{} did not replace wrapper bit {}".format(
                tier, item["port_name"], wrapper_bit
            )
        )
        applied.append(
            OrderedDict(
                [
                    ("tier", tier),
                    ("port_name", item["port_name"]),
                    ("wrapper_bit", wrapper_bit),
                    ("constant", constant),
                    ("replacement_count", replacements),
                ]
            )
        )
    return applied


def prefixed_name(prefix, name):
    return "{}.{}".format(prefix, name)


def copy_tier_netnames(flat_top, tier_module, tier_prefix, port_bit_map, local_bit_map, allocator):
    copied = 0
    for net_name, net in tier_module.netnames.items():
        new_name = prefixed_name(tier_prefix, net_name)
        assert new_name not in flat_top.netnames, "Duplicate flattened netname: {}".format(new_name)
        bits = [map_tier_bit(bit, port_bit_map, local_bit_map, allocator) for bit in net.bits]
        flat_top.netnames[new_name] = Netname(
            name=new_name,
            hide_name=net.hide_name,
            bits=bits,
            attributes=deepcopy(net.attributes),
            offset=net.offset,
            upto=net.upto,
            signed=net.signed,
            extras=deepcopy(net.extras),
        )
        copied += 1
    return copied


def copy_tier_cells(flat_top, tier_module, tier_prefix, tier, port_bit_map, local_bit_map, allocator):
    entries = OrderedDict()
    for cell_name, cell in tier_module.cells.items():
        assert not cell.type.startswith("_"), (
            "Tier module {} still contains coarse-internal helper boundary {} of type {}; "
            "06 selective ungroup must remove helper modules before 07".format(
                tier_module.name, cell_name, cell.type
            )
        )
        final_name = prefixed_name(tier_prefix, cell_name)
        assert final_name not in flat_top.cells, "Duplicate flattened cell name: {}".format(final_name)
        new_connections = OrderedDict()
        for port_name, bits in cell.connections.items():
            new_connections[port_name] = [
                map_tier_bit(bit, port_bit_map, local_bit_map, allocator) for bit in bits
            ]
        flat_top.cells[final_name] = Cell(
            name=final_name,
            hide_name=cell.hide_name,
            cell_type=cell.type,
            parameters=deepcopy(cell.parameters),
            attributes=deepcopy(cell.attributes),
            port_directions=deepcopy(cell.port_directions),
            connections=new_connections,
            extras=deepcopy(cell.extras),
        )
        entries[final_name] = OrderedDict(
            [
                ("tier", tier),
                ("hierarchical_source", "{}/{}".format(tier_prefix, cell_name)),
                ("synthesis_cell_type", cell.type),
                ("restore_required", CELL_NAME_MAPPING_MODE == "heterogeneous_map_json"),
            ]
        )
    return entries


def build_flat_design(genus_design):
    wrapper_top = genus_design.modules[WRAPPER_TOP_MODULE_NAME]
    upper_module = genus_design.modules[UPPER_COARSE_MODULE_NAME]
    bottom_module = genus_design.modules[BOTTOM_COARSE_MODULE_NAME]
    upper_inst = wrapper_top.cells[WRAPPER_UPPER_INSTANCE_NAME]
    bottom_inst = wrapper_top.cells[WRAPPER_BOTTOM_INSTANCE_NAME]

    flat_top = Module(
        name=TOP_MODULE_NAME,
        attributes=deepcopy(wrapper_top.attributes),
        parameter_default_values=deepcopy(wrapper_top.parameter_default_values),
        ports=OrderedDict(),
        cells=OrderedDict(),
        memories=OrderedDict(),
        netnames=OrderedDict(),
        extras=deepcopy(wrapper_top.extras),
    )
    flat_top.attributes.pop("top", None)
    flat_top.attributes["top"] = "1"

    for port_name, port in wrapper_top.ports.items():
        flat_top.ports[port_name] = Port(
            name=port_name,
            direction=port.direction,
            bits=list(port.bits),
            offset=port.offset,
            upto=port.upto,
            signed=port.signed,
            extras=deepcopy(port.extras),
        )
    for net_name, net in wrapper_top.netnames.items():
        flat_top.netnames[net_name] = Netname(
            name=net_name,
            hide_name=net.hide_name,
            bits=list(net.bits),
            attributes=deepcopy(net.attributes),
            offset=net.offset,
            upto=net.upto,
            signed=net.signed,
            extras=deepcopy(net.extras),
        )

    allocator = BitAllocator.after(flat_top)
    instance_tiers = OrderedDict()
    copy_stats = OrderedDict()

    for tier, prefix, tier_module, tier_inst in [
        (TIER_UPPER, WRAPPER_UPPER_INSTANCE_NAME, upper_module, upper_inst),
        (TIER_BOTTOM, WRAPPER_BOTTOM_INSTANCE_NAME, bottom_module, bottom_inst),
    ]:
        port_bit_map, constant_port_drivers = build_port_bit_map(tier_module, tier_inst)
        constant_driver_stats = apply_constant_port_drivers(flat_top, tier, constant_port_drivers)
        local_bit_map = {}
        copied_netnames = copy_tier_netnames(flat_top, tier_module, prefix, port_bit_map, local_bit_map, allocator)
        copied_cells = copy_tier_cells(flat_top, tier_module, prefix, tier, port_bit_map, local_bit_map, allocator)
        instance_tiers.update(copied_cells)
        copy_stats[tier] = OrderedDict(
            [
                ("source_module", tier_module.name),
                ("source_instance", prefix),
                ("source_cell_count", len(tier_module.cells)),
                ("flattened_cell_count", len(copied_cells)),
                ("copied_netname_count", copied_netnames),
                ("local_bit_count", len(local_bit_map)),
                ("constant_port_driver_count", len(constant_driver_stats)),
                ("constant_port_drivers", constant_driver_stats),
            ]
        )

    flat_design = Design(creator=genus_design.creator, modules=OrderedDict([(TOP_MODULE_NAME, flat_top)]))
    validate_design(flat_design)
    return flat_design, instance_tiers, copy_stats


def assert_source_primary_contract(source_top, split_plan):
    by_label = {}
    for item in split_plan["primary_bits"]:
        label = item["bit_label"]
        assert label not in by_label, "Duplicate primary bit label in split plan: {}".format(label)
        by_label[label] = item

    expected_labels = []
    for port_name, port in source_top.ports.items():
        labels = port_bit_labels(source_top, port_name)
        assert len(labels) == len(port.bits)
        for bit_position, bit in enumerate(port.bits):
            bit_index, bit_label = labels[bit_position]
            assert bit_label in by_label, "Source primary bit missing from split plan: {}".format(bit_label)
            item = by_label[bit_label]
            assert item["port_name"] == port_name
            assert item["bit_index"] == bit_index
            assert item["owner_tier"] in VALID_TIERS
            expected_labels.append(bit_label)
    assert set(expected_labels) == set(by_label.keys()), "Split primary bit set does not match source top ports"
    return by_label


def build_primary_seed(source_top, flat_top, split_plan):
    by_label = assert_source_primary_contract(source_top, split_plan)
    primary_entries = []
    order_index = 0
    for port_name, source_port in source_top.ports.items():
        assert port_name in flat_top.ports, "Flat top missing source port: {}".format(port_name)
        flat_port = flat_top.ports[port_name]
        assert source_port.direction == flat_port.direction
        assert len(source_port.bits) == len(flat_port.bits)
        labels = port_bit_labels(source_top, port_name)
        for bit_position, (bit_index, bit_label) in enumerate(labels):
            item = by_label[bit_label]
            primary_entries.append(
                OrderedDict(
                    [
                        ("order_index", order_index),
                        ("kind", item["kind"]),
                        ("case", item["case"]),
                        ("bit_label", bit_label),
                        ("port_name", item["port_name"]),
                        ("bit_index", item["bit_index"]),
                        ("direction", source_port.direction),
                        ("owner_tier", item["owner_tier"]),
                        ("driver_tier", item.get("driver_tier")),
                        ("user_tiers", item.get("user_tiers", [])),
                        ("final_port_name", port_name),
                        ("final_port_bit_position", bit_position),
                        ("final_bit", flat_port.bits[bit_position]),
                    ]
                )
            )
            order_index += 1
    return primary_entries


def classify_d2d_channel(flat_top, name):
    if name in flat_top.netnames:
        return OrderedDict([("status", "present"), ("final_netname", name), ("final_bits", flat_top.netnames[name].bits)])
    return OrderedDict([("status", "optimized_or_renamed"), ("final_netname", None), ("final_bits", [])])


def build_d2d_evidence(flat_top, wrapper_plan):
    data_channels = []
    for item in wrapper_plan.get("data_d2d_channels", []):
        entry = OrderedDict(item)
        entry.update(classify_d2d_channel(flat_top, item["d2d_name"]))
        data_channels.append(entry)

    clock_channels = []
    for item in wrapper_plan.get("clock", {}).get("clock_d2d_channels", []):
        entry = OrderedDict(item)
        d2d_name = item.get("d2d_name") or item.get("clock_d2d_name")
        if d2d_name:
            entry.update(classify_d2d_channel(flat_top, d2d_name))
        else:
            entry.update(OrderedDict([("status", "metadata_without_name"), ("final_netname", None), ("final_bits", [])]))
        clock_channels.append(entry)
    return data_channels, clock_channels


def assert_flat_output_contract(flat_design, source_design, instance_tiers, primary_entries):
    assert TOP_MODULE_NAME in flat_design.modules, "Flat top missing: {}".format(TOP_MODULE_NAME)
    flat_top = flat_design.modules[TOP_MODULE_NAME]
    source_top = source_design.modules[TOP_MODULE_NAME]
    assert_same_port_shape(source_top, flat_top, "source vs flat")

    forbidden_ports = [name for name in flat_top.ports if name.startswith(WRAPPER_ONLY_PORT_PREFIXES)]
    assert not forbidden_ports, "Flat top exposes wrapper-only ports: {}".format(forbidden_ports[:20])
    forbidden_cells = [
        name
        for name, cell in flat_top.cells.items()
        if name in {WRAPPER_UPPER_INSTANCE_NAME, WRAPPER_BOTTOM_INSTANCE_NAME}
        or cell.type in {UPPER_COARSE_MODULE_NAME, BOTTOM_COARSE_MODULE_NAME}
        or cell.type == "$scopeinfo"
    ]
    assert not forbidden_cells, "Flat top contains wrapper/pseudo cells: {}".format(forbidden_cells[:20])

    assert set(instance_tiers.keys()) == set(flat_top.cells.keys()), (
        "instance_tiers does not match flat cells: missing={} extra={}".format(
            sorted(set(flat_top.cells.keys()) - set(instance_tiers.keys()))[:20],
            sorted(set(instance_tiers.keys()) - set(flat_top.cells.keys()))[:20],
        )
    )

    seen_primary = set()
    seen_positions = set()
    for item in primary_entries:
        label = item["bit_label"]
        assert label not in seen_primary, "Duplicate primary bit label: {}".format(label)
        seen_primary.add(label)
        port_name = item["final_port_name"]
        bit_position = item["final_port_bit_position"]
        assert port_name in flat_top.ports
        assert 0 <= bit_position < len(flat_top.ports[port_name].bits)
        assert flat_top.ports[port_name].bits[bit_position] == item["final_bit"]
        key = (port_name, bit_position)
        assert key not in seen_positions, "Duplicate final port bit in primary seed: {}".format(key)
        seen_positions.add(key)

    flat_primary_count = sum(len(port.bits) for port in flat_top.ports.values())
    assert flat_primary_count == len(primary_entries), "Primary bit count mismatch"


def build_partition_seed(flat_design, source_design, wrapper_plan, genus_plan, split_plan, cell_mapping_plan, instance_tiers, copy_stats):
    flat_top = flat_design.modules[TOP_MODULE_NAME]
    source_top = source_design.modules[TOP_MODULE_NAME]
    primary_entries = build_primary_seed(source_top, flat_top, split_plan)
    data_d2d, clock_d2d = build_d2d_evidence(flat_top, wrapper_plan)

    bottom_count = sum(1 for item in instance_tiers.values() if item["tier"] == TIER_BOTTOM)
    upper_count = sum(1 for item in instance_tiers.values() if item["tier"] == TIER_UPPER)
    assert bottom_count + upper_count == len(instance_tiers)

    seed = OrderedDict(
        [
            (
                "identity",
                OrderedDict(
                    [
                        ("design", DESIGN),
                        ("library", LIBRARY),
                        ("flow_variant", FLOW_VARIANT),
                        ("synth_mode", SYNTH_MODE),
                        ("mapping_mode", CELL_NAME_MAPPING_MODE),
                    ]
                ),
            ),
            (
                "inputs",
                OrderedDict(
                    [
                        ("genus_output_json", GENUS_OUTPUT_JSON),
                        ("genus_output_v", GENUS_OUTPUT_V),
                        ("genus_plan_json", GENUS_PLAN_JSON),
                        ("wrapper_plan_json", WRAPPER_PLAN_JSON),
                        ("split_plan_json", SPLIT_PLAN_JSON),
                        ("source_json", SOURCE_JSON),
                        ("cell_mapping_plan_json", CELL_MAPPING_PLAN_JSON),
                    ]
                ),
            ),
            (
                "outputs",
                OrderedDict(
                    [
                        ("flat_json", FLAT_JSON),
                        ("flat_v", FLAT_V),
                        ("partition_seed_json", PARTITION_SEED_JSON),
                    ]
                ),
            ),
            (
                "top",
                OrderedDict(
                    [
                        ("source_top", TOP_MODULE_NAME),
                        ("wrapper_top", WRAPPER_TOP_MODULE_NAME),
                        ("flat_top", TOP_MODULE_NAME),
                    ]
                ),
            ),
            ("top_module_name", TOP_MODULE_NAME),
            ("primary_bits", primary_entries),
            ("instance_tiers", instance_tiers),
            ("data_d2d_channels", data_d2d),
            ("clock_d2d_channels", clock_d2d),
            (
                "summary",
                OrderedDict(
                    [
                        ("final_top_port_count", len(flat_top.ports)),
                        ("final_primary_bit_count", len(primary_entries)),
                        ("final_instance_count", len(instance_tiers)),
                        ("bottom_instance_count", bottom_count),
                        ("upper_instance_count", upper_count),
                        ("data_d2d_count", len(data_d2d)),
                        ("clock_d2d_count", len(clock_d2d)),
                    ]
                ),
            ),
            (
                "checks",
                OrderedDict(
                    [
                        ("copy_stats", copy_stats),
                        ("cell_mapping_mode", cell_mapping_plan["mapping_mode"]),
                        ("genus_strategy", genus_plan.get("synthesis_strategy", {}).get("name")),
                        ("unknown_tier_instance_count", 0),
                    ]
                ),
            ),
        ]
    )
    assert_flat_output_contract(flat_design, source_design, instance_tiers, primary_entries)
    return seed


def load_inputs():
    for path in [
        GENUS_OUTPUT_JSON,
        GENUS_OUTPUT_V,
        GENUS_PLAN_JSON,
        WRAPPER_PLAN_JSON,
        SOURCE_JSON,
        SPLIT_PLAN_JSON,
        CELL_MAPPING_PLAN_JSON,
    ]:
        assert os.path.isfile(path), "Required 07 input missing: {}".format(path)
    genus_design = load_design(GENUS_OUTPUT_JSON)
    source_design = load_design(SOURCE_JSON)
    validate_design(genus_design)
    validate_design(source_design)
    genus_plan = load_json_file(GENUS_PLAN_JSON)
    wrapper_plan = load_json_file(WRAPPER_PLAN_JSON)
    split_plan = load_json_file(SPLIT_PLAN_JSON)
    cell_mapping_plan = load_json_file(CELL_MAPPING_PLAN_JSON)
    return genus_design, source_design, genus_plan, wrapper_plan, split_plan, cell_mapping_plan


def main():
    genus_design, source_design, genus_plan, wrapper_plan, split_plan, cell_mapping_plan = load_inputs()
    assert_required_identity(genus_plan, wrapper_plan, cell_mapping_plan)
    assert_genus_wrapper_contract(genus_design, source_design, genus_plan, wrapper_plan)

    flat_design, instance_tiers, copy_stats = build_flat_design(genus_design)
    netname_normalization = normalize_backend_internal_netnames(flat_design, TOP_MODULE_NAME)
    seed = build_partition_seed(
        flat_design, source_design, wrapper_plan, genus_plan, split_plan, cell_mapping_plan, instance_tiers, copy_stats
    )
    seed["summary"]["normalized_backend_netname_count"] = netname_normalization.selected_count
    seed["checks"]["backend_netname_normalization"] = OrderedDict(
        [
            ("selected_count", netname_normalization.selected_count),
            ("collision_resolution_count", netname_normalization.collision_count),
            ("remaining_backslash_name_count", 0),
        ]
    )

    os.makedirs(os.path.dirname(FLAT_JSON), exist_ok=True)
    dump_design(flat_design, FLAT_JSON)
    validate_design(load_design(FLAT_JSON))
    emit_json_to_verilog(FLAT_JSON, TOP_MODULE_NAME, FLAT_V)
    write_json_file(PARTITION_SEED_JSON, seed)

    print("[07] flat_json                -> {}".format(FLAT_JSON))
    print("[07] flat_v                   -> {}".format(FLAT_V))
    print("[07] partition_seed_json      -> {}".format(PARTITION_SEED_JSON))
    print("[07] final instances          = {}".format(seed["summary"]["final_instance_count"]))
    print("[07] primary bits             = {}".format(seed["summary"]["final_primary_bit_count"]))
    print("[07] data d2d channels        = {}".format(seed["summary"]["data_d2d_count"]))
    print("[07] clock d2d channels       = {}".format(seed["summary"]["clock_d2d_count"]))
    print("[07] normalized netnames      = {}".format(netname_normalization.selected_count))
    print("[07] name collision attempts = {}".format(netname_normalization.collision_count))


if __name__ == "__main__":
    main()
