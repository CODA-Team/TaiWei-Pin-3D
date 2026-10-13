"""
02_analyze_partition.py
Structured partition analysis based on Yosys JSON and yosys_json_toolkit.

This implementation intentionally avoids text-level Verilog surgery. The source
netlist is first converted into Yosys JSON, then analyzed at bit granularity,
and finally emitted as initial per-tier JSON handoff for wrapper construction.
construction.

Design rules:
- Think at the overall rule level, not around the current gcd testcase.
- Use strict assertions for unsupported or unexpected situations.
- Do not silently guess or sanitize ambiguous structures.
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
    DESIGN_SDC_FILE,
    DESIGN,
    LIBRARY,
    YOSYS,
    NETLIST_V,
    PARTITION_TXT,
    PIN_DIR_JSON,
    COARSE_PIN_DIR_JSON,
    TMP_DIR,
    TOP_MODULE_NAME,
    SOURCE_JSON,
    SOURCE_V,
    BOTTOM_COARSE_JSON,
    BOTTOM_COARSE_V,
    UPPER_COARSE_JSON,
    UPPER_COARSE_V,
    SPLIT_PLAN_JSON,
    OUTPUT_VERILOG,
    PARTITION_BOTTOM_VALUE,
    PARTITION_TOP_VALUE,
    CLOCK_PORT_MAP_JSON,
    BOTTOM_COARSE_MODULE_NAME,
    UPPER_COARSE_MODULE_NAME,
    COARSE_SYNTH_BOT,
    assert_required_source_inputs,
)
from yosys_json_toolkit import (
    Design,
    Module,
    add_cell,
    add_netname,
    add_port,
    collect_bit_references,
    dump_design,
    load_design,
    netname_bit_labels,
    port_bit_labels,
    replace_bit_references,
    validate_design,
)

TIER_BOTTOM = "bottom"
TIER_UPPER = "upper"
SUPPORTED_PORT_DIRECTIONS = {"input", "output"}
SUPPORTED_CELL_PIN_DIRECTIONS = {"input", "output"}
SUPPORTED_CONST_PORT_BITS = {"0", "1"}
SUPPORTED_CONST_BITS = {"0", "1", "x", "z"}
BIT_KIND_PI = "PI"
BIT_KIND_PO = "PO"
BIT_KIND_INTERNAL = "internal"
CLOCK_PIN_NAMES_BY_LIBRARY = {
    "asap7_3D": frozenset(["CLK", "clk"]),
    "nangate45_3D": frozenset(["CK", "CLK", "clk"]),
    "asap7_nangate45_3D": frozenset(["CK", "CLK", "clk"]),
}
COARSE_2D_SYNTH_DIR = COARSE_SYNTH_BOT


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


def build_source_json():
    tcl = """
read_verilog {netlist}
hierarchy -top {top}
proc
write_json {out_json}
""".format(
        netlist=NETLIST_V,
        top=TOP_MODULE_NAME,
        out_json=SOURCE_JSON,
    )
    run_yosys_script(tcl, "source verilog -> source json")
    assert os.path.exists(SOURCE_JSON), "source json was not created: {}".format(SOURCE_JSON)


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
    assert os.path.exists(out_v), "split verilog was not created: {}".format(out_v)


def load_single_module_design_from_verilog(v_path, module_name):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as json_fp:
        json_path = json_fp.name
    try:
        tcl = """
read_verilog {v_path}
hierarchy -top {module_name}
proc
write_json {json_path}
""".format(
            v_path=v_path,
            module_name=module_name,
            json_path=json_path,
        )
        run_yosys_script(tcl, "coarse synth verilog -> json ({})".format(module_name))
        design = load_design(json_path)
    finally:
        if os.path.exists(json_path):
            os.unlink(json_path)
    validate_design(design)
    assert set(design.modules.keys()) == {module_name}, (
        "Expected single module {} in {}, found {}".format(
            module_name,
            v_path,
            sorted(design.modules.keys()),
        )
    )
    return design


def decode_partition_tier(raw_value):
    raw_value = str(raw_value).strip()
    if raw_value == str(PARTITION_BOTTOM_VALUE):
        return TIER_BOTTOM
    if raw_value == str(PARTITION_TOP_VALUE):
        return TIER_UPPER
    raise AssertionError("Unsupported partition tier value: {!r}".format(raw_value))


def other_tier(tier):
    assert tier in (TIER_BOTTOM, TIER_UPPER), "Unexpected tier: {}".format(tier)
    return TIER_UPPER if tier == TIER_BOTTOM else TIER_BOTTOM


def load_json_file(path):
    with open(path) as fp:
        return json.load(fp)


def read_sdc_var(sdc_path, var_name):
    pattern = re.compile(r"set\s+" + re.escape(var_name) + r"\s+(\S+)")
    with open(sdc_path) as fp:
        for line in fp:
            match = pattern.match(line.strip())
            if match:
                return match.group(1)
    raise AssertionError("{} not found in {}".format(var_name, sdc_path))


def read_clk_port_name(sdc_path):
    return read_sdc_var(sdc_path, "clk_port_name")


def normalize_pin_direction(raw_direction, context):
    mapping = {
        "INPUT": "input",
        "OUTPUT": "output",
        "INOUT": "inout",
        "input": "input",
        "output": "output",
        "inout": "inout",
    }
    assert raw_direction in mapping, "{} has unsupported direction value {!r}".format(context, raw_direction)
    return mapping[raw_direction]


def collapse_pin_direction_table(raw_table, table_name):
    collapsed = {}
    for cell_type, pin_map in raw_table.items():
        base_dirs = OrderedDict()
        for raw_pin, raw_dir in pin_map.items():
            direction = normalize_pin_direction(raw_dir, "{}:{}:{}".format(table_name, cell_type, raw_pin))
            base = raw_pin.split("[", 1)[0]
            seen = base_dirs.setdefault(base, set())
            seen.add(direction)
        per_cell = {}
        for base, directions in base_dirs.items():
            assert len(directions) == 1, (
                "{} has mixed directions across bus bits for {}.{}: {}".format(
                    table_name, cell_type, base, sorted(directions)
                )
            )
            per_cell[base] = next(iter(directions))
            assert per_cell[base] in SUPPORTED_CELL_PIN_DIRECTIONS, (
                "{} has unsupported pin direction for {}.{}: {}".format(
                    table_name, cell_type, base, per_cell[base]
                )
            )
        collapsed[cell_type] = per_cell
    return collapsed


def load_pin_direction_tables():
    std_table = collapse_pin_direction_table(load_json_file(PIN_DIR_JSON), "pin_dir.json")
    coarse_table = collapse_pin_direction_table(load_json_file(COARSE_PIN_DIR_JSON), "coarse_pin_dir.json")
    merged = dict(std_table)
    for cell_type, coarse_map in coarse_table.items():
        if cell_type in merged:
            assert merged[cell_type] == coarse_map, (
                "pin direction conflict for cell {} between pin_dir.json and coarse_pin_dir.json".format(cell_type)
            )
        merged[cell_type] = coarse_map
    return merged


def resolve_cell_port_directions(module, pin_direction_table):
    for cell in module.cells.values():
        table_dirs = pin_direction_table.get(cell.type)
        resolved = OrderedDict()
        for pin_name in cell.connections.keys():
            json_dir = cell.port_directions.get(pin_name)
            if json_dir is not None:
                direction = normalize_pin_direction(json_dir, "cell {}.{}".format(cell.name, pin_name))
                if table_dirs and pin_name in table_dirs:
                    assert direction == table_dirs[pin_name], (
                        "direction mismatch for {}.{}: json={} table={}".format(
                            cell.name, pin_name, direction, table_dirs[pin_name]
                        )
                    )
            else:
                assert table_dirs is not None, (
                    "Missing pin direction table for cell type {} used by instance {}".format(cell.type, cell.name)
                )
                assert pin_name in table_dirs, (
                    "Pin {} missing from direction table for cell type {} (instance {})".format(
                        pin_name, cell.type, cell.name
                    )
                )
                direction = table_dirs[pin_name]
            assert direction in SUPPORTED_CELL_PIN_DIRECTIONS, (
                "Unsupported cell pin direction for {}.{}: {}".format(cell.name, pin_name, direction)
            )
            resolved[pin_name] = direction
        cell.port_directions = resolved


def build_primary_port_entries(module):
    entries = []
    label_to_entry = OrderedDict()
    int_bit_to_entries = defaultdict(list)

    for port_name, port in module.ports.items():
        assert port.direction in SUPPORTED_PORT_DIRECTIONS, (
            "Unsupported primary port direction for {}: {}".format(port_name, port.direction)
        )
        labels = port_bit_labels(module, port_name)
        assert len(labels) == len(port.bits), "Port label/bit length mismatch for {}".format(port_name)
        for offset_index, bit in enumerate(port.bits):
            bit_index, bit_label = labels[offset_index]
            entry = {
                "port_name": port_name,
                "direction": port.direction,
                "bit": bit,
                "bit_index": bit_index,
                "bit_label": bit_label,
                "position": offset_index,
            }
            assert bit_label not in label_to_entry, "Duplicate primary bit label: {}".format(bit_label)
            label_to_entry[bit_label] = entry
            if port.direction == "input":
                assert isinstance(bit, int), "Primary input bit must be an integer bit id: {} -> {!r}".format(bit_label, bit)
            elif isinstance(bit, str):
                assert bit in SUPPORTED_CONST_PORT_BITS, (
                    "Primary output constant must be 0/1 only: {} -> {!r}".format(bit_label, bit)
                )
            if isinstance(bit, int):
                alias_entries = int_bit_to_entries[bit]
                if alias_entries:
                    alias_labels = [item["bit_label"] for item in alias_entries] + [bit_label]
                    alias_directions = {item["direction"] for item in alias_entries}
                    alias_directions.add(port.direction)
                    assert len(alias_directions) == 1, (
                        "Mixed-direction primary bit alias is unsupported: bit {} used by {}".format(
                            bit, alias_labels
                        )
                    )
                    assert port.direction == "output", (
                        "Primary input alias is unsupported: bit {} used by {}".format(bit, alias_labels)
                    )
                alias_entries.append(entry)
            entries.append(entry)

    return entries, label_to_entry, dict(int_bit_to_entries)


def build_bit_name_candidates(module):
    candidates = defaultdict(list)

    def add_signal(bits, labels, hide_name):
        for index_in_list, bit in enumerate(bits):
            if not isinstance(bit, int):
                continue
            candidates[bit].append((hide_name, labels[index_in_list][1]))

    for port in module.ports.values():
        add_signal(port.bits, port_bit_labels(module, port.name), 0)
    for netname in module.netnames.values():
        hide_name = 0 if netname.hide_name is None else netname.hide_name
        add_signal(netname.bits, netname_bit_labels(netname), hide_name)
    return candidates


def pick_bit_debug_name(bit, candidates):
    if isinstance(bit, str):
        return bit
    bit_candidates = sorted(candidates.get(bit, []), key=lambda item: (item[0], item[1]))
    if bit_candidates:
        return bit_candidates[0][1]
    return "<bit:{}>".format(bit)


def load_partition_entries(label_to_entry, module):
    cell_names = set(module.cells.keys())
    primary_bit_names = set(label_to_entry.keys())
    cell_tiers = {}
    primary_owner_tiers = {}
    seen_names = set()

    with open(PARTITION_TXT) as fp:
        for lineno, line in enumerate(fp, 1):
            parts = line.split()
            if not parts:
                continue
            assert len(parts) == 2, "Malformed partition line {}: {}".format(lineno, line.rstrip())
            raw_name, raw_tier = parts
            assert raw_name not in seen_names, "Duplicate partition entry for {}".format(raw_name)
            seen_names.add(raw_name)
            tier = decode_partition_tier(raw_tier)
            if raw_name in cell_names:
                cell_tiers[raw_name] = tier
            elif raw_name in primary_bit_names:
                primary_owner_tiers[raw_name] = tier
            else:
                raise AssertionError("Unexpected partition entry not matched to a source-json cell or original primary bit: {}".format(raw_name))

    partition_cell_names = set(cell_tiers.keys())
    partition_primary_names = set(primary_owner_tiers.keys())

    assert len(partition_cell_names) == len(cell_names), (
        "Partition/source-json cell count mismatch: partition={} json={}".format(
            len(partition_cell_names), len(cell_names)
        )
    )
    assert len(partition_primary_names) == len(primary_bit_names), (
        "Partition/original-primary-bit count mismatch: partition={} json={}".format(
            len(partition_primary_names), len(primary_bit_names)
        )
    )

    missing_cells = sorted(cell_names - partition_cell_names)
    unexpected_cells = sorted(partition_cell_names - cell_names)
    assert partition_cell_names == cell_names, (
        "Partition/source-json cell name mismatch. missing_from_partition={} unexpected_in_partition={}".format(
            missing_cells[:20], unexpected_cells[:20]
        )
    )

    missing_primary_bits = sorted(primary_bit_names - partition_primary_names)
    unexpected_primary_bits = sorted(partition_primary_names - primary_bit_names)
    assert partition_primary_names == primary_bit_names, (
        "Partition/original-primary-bit name mismatch. missing_from_partition={} unexpected_in_partition={}".format(
            missing_primary_bits[:20], unexpected_primary_bits[:20]
        )
    )

    return cell_tiers, primary_owner_tiers


def summarize_cell_refs(bit_references, bit, cell_tiers):
    refs = bit_references.get(bit, [])
    drivers = []
    users = []
    for ref in refs:
        if ref.kind != "cell":
            continue
        assert ref.direction in SUPPORTED_CELL_PIN_DIRECTIONS, (
            "Cell reference with unresolved direction on bit {}: {}".format(bit, ref)
        )
        assert ref.owner_name in cell_tiers, "Cell {} missing tier assignment".format(ref.owner_name)
        tier = cell_tiers[ref.owner_name]
        if ref.direction == "output":
            drivers.append((ref, tier))
        elif ref.direction == "input":
            users.append((ref, tier))
        else:
            raise AssertionError("Unsupported cell pin direction {} on {}".format(ref.direction, ref))

    driver_tiers = sorted(set(tier for _ref, tier in drivers))
    user_tiers = sorted(set(tier for _ref, tier in users))
    return drivers, users, driver_tiers, user_tiers


def collect_primary_bits(module):
    primary_bits = set()
    for port in module.ports.values():
        for bit in port.bits:
            if isinstance(bit, int):
                primary_bits.add(bit)
    return primary_bits


def load_actual_coarse_module_definitions():
    assert os.path.isdir(COARSE_2D_SYNTH_DIR), "coarse synth dir not found: {}".format(COARSE_2D_SYNTH_DIR)
    module_defs = {}
    for entry in sorted(os.listdir(COARSE_2D_SYNTH_DIR)):
        if entry.endswith(".json"):
            module_name = os.path.splitext(entry)[0]
            design = load_design(os.path.join(COARSE_2D_SYNTH_DIR, entry))
            validate_design(design)
            assert module_name in design.modules, (
                "coarse synth json {} missing module {}".format(entry, module_name)
            )
            module_defs[module_name] = design.get_module(module_name)
    if module_defs:
        return module_defs

    for entry in sorted(os.listdir(COARSE_2D_SYNTH_DIR)):
        if not entry.endswith(".v"):
            continue
        module_name = os.path.splitext(entry)[0]
        design = load_single_module_design_from_verilog(os.path.join(COARSE_2D_SYNTH_DIR, entry), module_name)
        module_defs[module_name] = design.get_module(module_name)
    return module_defs


def build_unused_input_positions(module_def):
    refs_by_bit = collect_bit_references(module_def)
    unused = {}
    for port_name, port in module_def.ports.items():
        if port.direction != "input":
            continue
        positions = set()
        for bit_index, bit in enumerate(port.bits):
            if not isinstance(bit, int):
                continue
            refs = refs_by_bit.get(bit, [])
            used = False
            for ref in refs:
                if ref.kind == "port" and ref.owner_name == port_name and ref.direction == "input":
                    continue
                if ref.kind == "netname":
                    continue
                used = True
                break
            if not used:
                positions.add(bit_index)
        unused[port_name] = positions
    return unused


def cleanup_replaced_internal_bits(module, replaced_bits):
    if not replaced_bits:
        return {"removed_netnames": [], "trimmed_netnames": []}
    refs_by_bit = collect_bit_references(module)
    removed = []
    trimmed = []
    for net_name in sorted(list(module.netnames.keys())):
        net = module.netnames[net_name]
        touched = False
        new_bits = []
        for bit in net.bits:
            if isinstance(bit, int) and bit in replaced_bits and all(ref.kind == "netname" for ref in refs_by_bit.get(bit, [])):
                touched = True
                continue
            new_bits.append(bit)
        if not touched:
            continue
        if new_bits:
            net.bits = new_bits
            trimmed.append(net_name)
        else:
            del module.netnames[net_name]
            removed.append(net_name)
    return {"removed_netnames": removed, "trimmed_netnames": trimmed}


def constantize_undriven_unused_coarse_inputs(module, cell_tiers):
    actual_module_defs = load_actual_coarse_module_definitions()
    unused_cache = {}
    primary_bits = collect_primary_bits(module)
    bit_references = collect_bit_references(module)
    coarse_cell_types = set(actual_module_defs.keys())
    replaced = []
    blocked = []
    replaced_bits = set()

    for bit, refs in sorted(bit_references.items(), key=lambda item: item[0] if isinstance(item[0], int) else -1):
        if not isinstance(bit, int):
            continue
        if bit in primary_bits:
            continue
        drivers, users, driver_tiers, user_tiers = summarize_cell_refs(bit_references, bit, cell_tiers)
        del drivers, users, user_tiers
        if driver_tiers:
            continue
        cell_refs = [ref for ref in refs if ref.kind == "cell"]
        if not cell_refs:
            continue
        if any(ref.direction != "input" for ref in cell_refs):
            continue

        candidate_refs = []
        unsupported_ref_kinds = [ref for ref in refs if ref.kind not in {"cell", "netname"}]
        if unsupported_ref_kinds:
            continue

        can_replace = True
        for ref in cell_refs:
            cell = module.cells[ref.owner_name]
            if cell.type not in coarse_cell_types:
                can_replace = False
                break
            actual_def = actual_module_defs[cell.type]
            if cell.type not in unused_cache:
                unused_cache[cell.type] = build_unused_input_positions(actual_def)
            port_name = ref.field_name
            assert port_name in actual_def.ports, (
                "coarse module {} missing port {} used by instance {}".format(
                    cell.type,
                    port_name,
                    cell.name,
                )
            )
            port = actual_def.ports[port_name]
            assert port.direction == "input", (
                "expected input port {}.{} for undriven handling".format(cell.type, port_name)
            )
            assert ref.bit_index < len(port.bits), (
                "bit index {} out of range for {}.{} width {}".format(
                    ref.bit_index,
                    cell.type,
                    port_name,
                    len(port.bits),
                )
            )
            if ref.bit_index not in unused_cache[cell.type].get(port_name, set()):
                blocked.append(
                    {
                        "bit": bit,
                        "cell_name": cell.name,
                        "cell_type": cell.type,
                        "port_name": port_name,
                        "bit_index": ref.bit_index,
                    }
                )
                can_replace = False
                break
            candidate_refs.append(
                {
                    "cell_name": cell.name,
                    "cell_type": cell.type,
                    "port_name": port_name,
                    "bit_index": ref.bit_index,
                }
            )

        if not can_replace or not candidate_refs:
            continue

        replace_bit_references(module, bit, "0", include_ports=False, include_netnames=False, include_cells=True)
        replaced_bits.add(bit)
        replaced.append(
            {
                "bit": bit,
                "replacement": "0",
                "cell_refs": candidate_refs,
            }
        )

    if blocked:
        raise AssertionError(
            "Found undriven coarse-input bits that are still used inside actual coarse modules: {}".format(blocked[:20])
        )

    cleanup = cleanup_replaced_internal_bits(module, replaced_bits)
    return {
        "replaced_bit_count": len(replaced),
        "replaced_bits": replaced,
        "cleanup": cleanup,
        "coarse_module_count": len(actual_module_defs),
    }


def constantize_undriven_general_internal_inputs(module, cell_tiers, excluded_cell_types=None):
    primary_bits = collect_primary_bits(module)
    bit_references = collect_bit_references(module)
    candidates = build_bit_name_candidates(module)
    excluded_cell_types = set(excluded_cell_types or [])
    replaced = []
    blocked = []
    replaced_bits = set()

    for bit, refs in sorted(bit_references.items(), key=lambda item: item[0] if isinstance(item[0], int) else -1):
        if not isinstance(bit, int):
            continue
        if bit in primary_bits:
            continue

        drivers, users, driver_tiers, user_tiers = summarize_cell_refs(bit_references, bit, cell_tiers)
        del drivers, users, user_tiers
        if driver_tiers:
            continue

        cell_refs = [ref for ref in refs if ref.kind == "cell"]
        if not cell_refs:
            continue

        debug_name = pick_bit_debug_name(bit, candidates)
        unsupported_ref_kinds = sorted(set(ref.kind for ref in refs if ref.kind not in {"cell", "netname"}))
        if unsupported_ref_kinds:
            blocked.append(
                {
                    "bit": bit,
                    "debug_name": debug_name,
                    "reason": "unsupported_ref_kinds",
                    "ref_kinds": unsupported_ref_kinds,
                }
            )
            continue

        non_input_refs = [ref for ref in cell_refs if ref.direction != "input"]
        if non_input_refs:
            blocked.append(
                {
                    "bit": bit,
                    "debug_name": debug_name,
                    "reason": "non_input_cell_ref",
                    "cell_refs": [
                        {
                            "cell_name": ref.owner_name,
                            "cell_type": module.cells[ref.owner_name].type,
                            "port_name": ref.field_name,
                            "direction": ref.direction,
                            "bit_index": ref.bit_index,
                        }
                        for ref in non_input_refs
                    ],
                }
            )
            continue

        coarse_refs = [ref for ref in cell_refs if module.cells[ref.owner_name].type in excluded_cell_types]
        if coarse_refs:
            continue

        candidate_refs = [
            {
                "cell_name": ref.owner_name,
                "cell_type": module.cells[ref.owner_name].type,
                "port_name": ref.field_name,
                "bit_index": ref.bit_index,
            }
            for ref in cell_refs
        ]
        replace_bit_references(module, bit, "0", include_ports=False, include_netnames=False, include_cells=True)
        replaced_bits.add(bit)
        replaced.append(
            {
                "bit": bit,
                "debug_name": debug_name,
                "replacement": "0",
                "cell_refs": candidate_refs,
            }
        )

    if blocked:
        raise AssertionError(
            "Found undriven internal bits that are not safe to constantize automatically: {}".format(blocked[:20])
        )

    cleanup = cleanup_replaced_internal_bits(module, replaced_bits)
    return {
        "replaced_bit_count": len(replaced),
        "replaced_bits": replaced,
        "cleanup": cleanup,
        "excluded_cell_type_count": len(excluded_cell_types),
    }


def canonicalize_undriven_internal_bits(module, cell_tiers):
    coarse_fix = constantize_undriven_unused_coarse_inputs(module, cell_tiers)
    coarse_module_defs = load_actual_coarse_module_definitions()
    general_fix = constantize_undriven_general_internal_inputs(
        module,
        cell_tiers,
        excluded_cell_types=coarse_module_defs.keys(),
    )
    return {
        "replaced_bit_count": coarse_fix["replaced_bit_count"] + general_fix["replaced_bit_count"],
        "coarse_input_fix": coarse_fix,
        "general_internal_input_fix": general_fix,
    }


def canonical_name(kind, port_name, bit_index):
    if bit_index is None:
        return "__{}_{}".format(kind, port_name)
    return "__{}_{}_{}".format(kind, port_name, bit_index)


def classify_primary_input(entry, owner_tier, bit_references, cell_tiers):
    bit = entry["bit"]
    drivers, users, driver_tiers, user_tiers = summarize_cell_refs(bit_references, bit, cell_tiers)
    assert not driver_tiers, "Primary input bit unexpectedly driven by a cell: {}".format(entry["bit_label"])

    other = other_tier(owner_tier)
    owner_used = owner_tier in user_tiers
    other_used = other in user_tiers
    if owner_used and not other_used:
        case_name = "PI-1"
    elif owner_used and other_used:
        case_name = "PI-2"
    elif (not owner_used) and other_used:
        case_name = "PI-3"
    elif not user_tiers:
        case_name = "PI-4"
    else:
        raise AssertionError("Unexpected PI tier usage pattern for {}: {}".format(entry["bit_label"], user_tiers))

    return {
        "kind": BIT_KIND_PI,
        "case": case_name,
        "port_name": entry["port_name"],
        "bit_label": entry["bit_label"],
        "bit_index": entry["bit_index"],
        "bit": bit,
        "owner_tier": owner_tier,
        "driver_tier": None,
        "user_tiers": user_tiers,
        "debug_name": entry["bit_label"],
    }


def classify_primary_output(entry, owner_tier, bit_references, cell_tiers):
    bit = entry["bit"]
    if isinstance(bit, str):
        return {
            "kind": BIT_KIND_PO,
            "case": "PO-4",
            "port_name": entry["port_name"],
            "bit_label": entry["bit_label"],
            "bit_index": entry["bit_index"],
            "bit": bit,
            "owner_tier": owner_tier,
            "driver_tier": None,
            "user_tiers": [],
            "debug_name": entry["bit_label"],
        }

    drivers, users, driver_tiers, user_tiers = summarize_cell_refs(bit_references, bit, cell_tiers)
    assert driver_tiers, "Non-constant PO has no driver: {}".format(entry["bit_label"])
    assert len(driver_tiers) == 1, "PO has multiple driver tiers: {} -> {}".format(entry["bit_label"], driver_tiers)
    driver_tier = driver_tiers[0]
    other = other_tier(owner_tier)

    if driver_tier == owner_tier and other not in user_tiers:
        case_name = "PO-1"
    elif driver_tier == owner_tier and other in user_tiers:
        case_name = "PO-2"
    elif driver_tier != owner_tier:
        case_name = "PO-3"
    else:
        raise AssertionError("Unexpected PO classification state for {}".format(entry["bit_label"]))

    return {
        "kind": BIT_KIND_PO,
        "case": case_name,
        "port_name": entry["port_name"],
        "bit_label": entry["bit_label"],
        "bit_index": entry["bit_index"],
        "bit": bit,
        "owner_tier": owner_tier,
        "driver_tier": driver_tier,
        "user_tiers": user_tiers,
        "debug_name": entry["bit_label"],
    }


def classify_internal_bit(bit, bit_references, cell_tiers, debug_name):
    drivers, users, driver_tiers, user_tiers = summarize_cell_refs(bit_references, bit, cell_tiers)
    assert driver_tiers, "Internal bit has no driver: {}".format(debug_name)
    assert len(driver_tiers) == 1, "Internal bit has multiple driver tiers: {} -> {}".format(debug_name, driver_tiers)
    driver_tier = driver_tiers[0]

    if not user_tiers:
        case_name = "NET-5"
    elif user_tiers == [driver_tier]:
        case_name = "NET-1"
    elif driver_tier == TIER_UPPER:
        case_name = "NET-2"
    elif driver_tier == TIER_BOTTOM:
        case_name = "NET-3"
    else:
        raise AssertionError("Unexpected internal driver tier for {}: {}".format(debug_name, driver_tier))

    return {
        "kind": BIT_KIND_INTERNAL,
        "case": case_name,
        "port_name": None,
        "bit_label": None,
        "bit_index": None,
        "bit": bit,
        "owner_tier": None,
        "driver_tier": driver_tier,
        "user_tiers": user_tiers,
        "debug_name": debug_name,
    }


def classify_bits(module, primary_entries, primary_owner_tiers, cell_tiers):
    bit_references = collect_bit_references(module)
    primary_by_int_bit = {}
    for entry in primary_entries:
        if isinstance(entry["bit"], int):
            primary_by_int_bit[entry["bit"]] = entry

    candidates = build_bit_name_candidates(module)
    classified_primary = []
    for entry in primary_entries:
        owner_tier = primary_owner_tiers[entry["bit_label"]]
        if entry["direction"] == "input":
            classified_primary.append(classify_primary_input(entry, owner_tier, bit_references, cell_tiers))
        else:
            classified_primary.append(classify_primary_output(entry, owner_tier, bit_references, cell_tiers))

    internal_bits = OrderedDict()
    for bit, refs in bit_references.items():
        if not isinstance(bit, int):
            continue
        if bit in primary_by_int_bit:
            continue
        if not any(ref.kind == "cell" for ref in refs):
            continue
        debug_name = pick_bit_debug_name(bit, candidates)
        internal_bits[bit] = classify_internal_bit(bit, bit_references, cell_tiers, debug_name)

    return classified_primary, list(internal_bits.values())


def make_split_module(src_module, new_name):
    return Module(
        name=new_name,
        attributes=json.loads(json.dumps(src_module.attributes)),
        parameter_default_values=json.loads(json.dumps(src_module.parameter_default_values)),
        ports=OrderedDict(),
        cells=OrderedDict(),
        memories=OrderedDict(),
        netnames=OrderedDict(),
        extras=json.loads(json.dumps(src_module.extras)),
    )


def add_canonical_port(module, module_state, port_name, direction, bit):
    assert port_name not in module_state["port_names"], "Duplicate canonical port {} in module {}".format(port_name, module.name)
    add_port(module, port_name, direction, [bit])
    add_netname(module, port_name, [bit], hide_name=0, attributes={})
    module_state["port_names"].add(port_name)
    module_state["ports"].append({
        "name": port_name,
        "direction": direction,
        "bit": bit,
    })


def populate_ports(upper_module, bottom_module, primary_cases, internal_cases):
    upper_state = {"port_names": set(), "ports": []}
    bottom_state = {"port_names": set(), "ports": []}

    def module_for_tier(tier):
        return upper_module if tier == TIER_UPPER else bottom_module

    def state_for_tier(tier):
        return upper_state if tier == TIER_UPPER else bottom_state

    ordered_primary = sorted(primary_cases, key=lambda item: (item["kind"], item["port_name"], -1 if item["bit_index"] is None else item["bit_index"]))
    for item in ordered_primary:
        port_name = item["port_name"]
        bit_index = item["bit_index"]
        bit = item["bit"]
        owner_tier = item["owner_tier"]
        owner_module = module_for_tier(owner_tier)
        owner_state = state_for_tier(owner_tier)
        non_owner_tier = other_tier(owner_tier)
        non_owner_module = module_for_tier(non_owner_tier)
        non_owner_state = state_for_tier(non_owner_tier)

        if item["kind"] == BIT_KIND_PI:
            owner_name = canonical_name("pi", port_name, bit_index)
            cross_name = canonical_name("d2d_pi", port_name, bit_index)
            if item["case"] == "PI-1":
                add_canonical_port(owner_module, owner_state, owner_name, "input", bit)
            elif item["case"] == "PI-2":
                add_canonical_port(owner_module, owner_state, owner_name, "input", bit)
                add_canonical_port(owner_module, owner_state, cross_name, "output", bit)
                add_canonical_port(non_owner_module, non_owner_state, cross_name, "input", bit)
            elif item["case"] == "PI-3":
                add_canonical_port(owner_module, owner_state, owner_name, "input", bit)
                add_canonical_port(owner_module, owner_state, cross_name, "output", bit)
                add_canonical_port(non_owner_module, non_owner_state, cross_name, "input", bit)
            elif item["case"] == "PI-4":
                pass
            else:
                raise AssertionError("Unsupported PI case: {}".format(item["case"]))
            continue

        owner_name = canonical_name("po", port_name, bit_index)
        cross_name = canonical_name("d2d_po", port_name, bit_index)
        if item["case"] == "PO-1":
            add_canonical_port(owner_module, owner_state, owner_name, "output", bit)
        elif item["case"] == "PO-2":
            add_canonical_port(owner_module, owner_state, owner_name, "output", bit)
            add_canonical_port(owner_module, owner_state, cross_name, "output", bit)
            add_canonical_port(non_owner_module, non_owner_state, cross_name, "input", bit)
        elif item["case"] == "PO-3":
            driver_tier = item["driver_tier"]
            driver_module = module_for_tier(driver_tier)
            driver_state = state_for_tier(driver_tier)
            add_canonical_port(driver_module, driver_state, cross_name, "output", bit)
            add_canonical_port(owner_module, owner_state, cross_name, "input", bit)
            add_canonical_port(owner_module, owner_state, owner_name, "output", bit)
        elif item["case"] == "PO-4":
            add_canonical_port(owner_module, owner_state, owner_name, "output", bit)
        else:
            raise AssertionError("Unsupported PO case: {}".format(item["case"]))

    ordered_internal = sorted(internal_cases, key=lambda item: item["debug_name"])
    for item in ordered_internal:
        if item["case"] in ("NET-1", "NET-5"):
            continue
        assert item["case"] in ("NET-2", "NET-3"), "Unsupported internal case: {}".format(item["case"])
        d2d_name = "__d2d_{}".format(item["debug_name"].replace("[", "_").replace("]", "").replace(":", "_").replace(".", "_"))
        driver_tier = item["driver_tier"]
        receiver_tier = other_tier(driver_tier)
        add_canonical_port(module_for_tier(driver_tier), state_for_tier(driver_tier), d2d_name, "output", item["bit"])
        add_canonical_port(module_for_tier(receiver_tier), state_for_tier(receiver_tier), d2d_name, "input", item["bit"])
        item["d2d_name"] = d2d_name

    return upper_state, bottom_state


def copy_cells_to_split_modules(src_module, upper_module, bottom_module, cell_tiers):
    counts = {TIER_UPPER: 0, TIER_BOTTOM: 0}
    for cell_name, cell in src_module.cells.items():
        tier = cell_tiers[cell_name]
        dst_module = upper_module if tier == TIER_UPPER else bottom_module
        add_cell(
            dst_module,
            cell.name,
            cell.type,
            cell.connections,
            hide_name=cell.hide_name,
            parameters=cell.parameters,
            attributes=cell.attributes,
            port_directions=cell.port_directions,
            extras=cell.extras,
        )
        counts[tier] += 1
    return counts


def build_split_design(src_design, new_module):
    return Design(
        creator=src_design.creator,
        modules=OrderedDict([(new_module.name, new_module)]),
        models=json.loads(json.dumps(src_design.models)),
        extras=json.loads(json.dumps(src_design.extras)),
    )


def build_split_plan(src_module, primary_cases, internal_cases, upper_state, bottom_state, cell_counts):
    case_counts = OrderedDict()
    for item in primary_cases + internal_cases:
        case_counts[item["case"]] = case_counts.get(item["case"], 0) + 1

    return OrderedDict([
        ("source", OrderedDict([
            ("netlist_v", NETLIST_V),
            ("partition_txt", PARTITION_TXT),
            ("source_json", SOURCE_JSON),
            ("top_module", src_module.name),
        ])),
        ("outputs", OrderedDict([
            ("bottom_json", BOTTOM_COARSE_JSON),
            ("upper_json", UPPER_COARSE_JSON),
        ])),
        ("summary", OrderedDict([
            ("source_cells", len(src_module.cells)),
            ("source_ports", len(src_module.ports)),
            ("upper_cells", cell_counts[TIER_UPPER]),
            ("bottom_cells", cell_counts[TIER_BOTTOM]),
            ("upper_ports", len(upper_state["ports"])),
            ("bottom_ports", len(bottom_state["ports"])),
            ("case_counts", case_counts),
        ])),
        ("modules", OrderedDict([
            ("upper", OrderedDict([
                ("name", UPPER_COARSE_MODULE_NAME),
                ("ports", upper_state["ports"]),
            ])),
            ("bottom", OrderedDict([
                ("name", BOTTOM_COARSE_MODULE_NAME),
                ("ports", bottom_state["ports"]),
            ])),
        ])),
        ("primary_bits", primary_cases),
        ("internal_bits", internal_cases),
    ])


def write_split_plan(plan):
    with open(SPLIT_PLAN_JSON, "w") as fp:
        json.dump(plan, fp, indent=2)
        fp.write("\n")
    with open(SPLIT_PLAN_JSON) as fp:
        loaded = json.load(fp)
    assert loaded == plan, "SPLIT_PLAN_JSON readback differs from written plan"


def find_clock_primary_case(primary_cases, clk_port_name):
    matches = []
    for item in primary_cases:
        if item["kind"] != BIT_KIND_PI:
            continue
        if item["port_name"] != clk_port_name:
            continue
        matches.append(item)
    assert matches, "Clock source port {} not found in primary split cases".format(clk_port_name)
    assert len(matches) == 1, "Clock source port {} maps to multiple primary split cases".format(clk_port_name)
    clock_primary = matches[0]
    assert clock_primary["case"] in ("PI-1", "PI-2", "PI-3"), (
        "Clock primary bit must map to a live PI case, got {}".format(clock_primary["case"])
    )
    assert clock_primary["bit_index"] in (None, 0), (
        "Clock primary input must resolve to a unique scalar bit, got bit_index={}".format(clock_primary["bit_index"])
    )
    return clock_primary


def clock_pin_names_for_library(library):
    assert library in CLOCK_PIN_NAMES_BY_LIBRARY, "Unsupported library for clock pin names: {}".format(library)
    return CLOCK_PIN_NAMES_BY_LIBRARY[library]


def base_pin_name(pin_name):
    return pin_name.split("[", 1)[0]


def collect_clock_set(src_module, clock_pin_names):
    clock_bits = set()
    for cell in src_module.cells.values():
        for pin_name, bits in cell.connections.items():
            if cell.port_directions.get(pin_name) != "input":
                continue
            if base_pin_name(pin_name) not in clock_pin_names:
                continue
            assert len(bits) == 1, "Clock-like pin must remain scalar: {}.{} -> {}".format(cell.name, pin_name, bits)
            bit = bits[0]
            assert isinstance(bit, int), "Clock-like pin must connect to an integer bit: {}.{} -> {!r}".format(
                cell.name,
                pin_name,
                bit,
            )
            clock_bits.add(bit)
    return clock_bits


def collect_carrier_clock_bits(internal_cases, clock_set):
    carrier_bits = set()
    for item in internal_cases:
        if item["case"] not in ("NET-2", "NET-3"):
            continue
        if item["bit"] in clock_set:
            carrier_bits.add(item["bit"])
    return carrier_bits


def build_tier_clock_map_entry(module_name, module_state, source_clock_bit, carrier_bit_to_name):
    source_clock_ports = []
    direct_source_clock_ports = []
    generated_clock_ports = []
    generated_clock_input_ports = []
    related_ports = []
    all_input_ports = []

    for item in module_state["ports"]:
        port_name = item["name"]
        direction = item["direction"]
        bit = item["bit"]
        if bit == source_clock_bit:
            source_clock_ports.append(
                OrderedDict([
                    ("port_name", port_name),
                    ("direction", direction),
                ])
            )
            related_ports.append(port_name)
            if direction == "input":
                direct_source_clock_ports.append(port_name)
                all_input_ports.append(port_name)
        elif bit in carrier_bit_to_name:
            generated_clock_ports.append(
                OrderedDict([
                    ("port_name", port_name),
                    ("direction", direction),
                    ("d2d_name", carrier_bit_to_name[bit]),
                ])
            )
            related_ports.append(port_name)
            if direction == "input":
                generated_clock_input_ports.append(port_name)
                all_input_ports.append(port_name)

    source_clock_ports = sorted(source_clock_ports, key=lambda item: (item["port_name"], item["direction"]))
    direct_source_clock_ports = sorted(direct_source_clock_ports)
    generated_clock_ports = sorted(
        generated_clock_ports,
        key=lambda item: (item["d2d_name"], item["port_name"], item["direction"]),
    )
    generated_clock_input_ports = sorted(generated_clock_input_ports)
    related_ports = sorted(related_ports)
    all_input_ports = sorted(all_input_ports)
    legacy_clock_input_port = all_input_ports[0] if len(all_input_ports) == 1 else None

    return OrderedDict([
        ("module_name", module_name),
        ("clock_input_port", legacy_clock_input_port),
        ("clock_related_ports", related_ports),
        ("source_clock_ports", source_clock_ports),
        ("direct_source_clock_ports", direct_source_clock_ports),
        ("generated_clock_ports", generated_clock_ports),
        ("generated_clock_input_ports", generated_clock_input_ports),
    ])


def build_clock_port_map(src_module, primary_cases, internal_cases, upper_state, bottom_state):
    clk_port_name = read_clk_port_name(DESIGN_SDC_FILE)
    clock_primary = find_clock_primary_case(primary_cases, clk_port_name)
    source_clock_bit = clock_primary["bit"]
    clock_set = collect_clock_set(src_module, clock_pin_names_for_library(LIBRARY))
    assert source_clock_bit in clock_set, "Source clock bit {} was not identified in the source-level clock set".format(
        source_clock_bit
    )
    carrier_clock_bits = collect_carrier_clock_bits(internal_cases, clock_set)
    carrier_bit_to_name = OrderedDict()
    for item in sorted(internal_cases, key=lambda entry: (entry["bit"], entry.get("d2d_name") or "")):
        if item["bit"] not in carrier_clock_bits:
            continue
        assert item.get("d2d_name"), "Clock carrier bit missing d2d_name: {}".format(item)
        assert item["bit"] not in carrier_bit_to_name, (
            "Clock carrier bit mapped to multiple d2d names: bit={} existing={} new={}".format(
                item["bit"], carrier_bit_to_name.get(item["bit"]), item["d2d_name"]
            )
        )
        carrier_bit_to_name[item["bit"]] = item["d2d_name"]
    return OrderedDict([
        ("source_clock_port_name", clk_port_name),
        ("source_clock_bit_label", clock_primary["bit_label"]),
        ("source_clock_bit_index", clock_primary["bit_index"]),
        ("source_clock_bit", source_clock_bit),
        ("clock_case", clock_primary["case"]),
        ("owner_tier", clock_primary["owner_tier"]),
        ("tiers", OrderedDict([
            (
                TIER_BOTTOM,
                build_tier_clock_map_entry(BOTTOM_COARSE_MODULE_NAME, bottom_state, source_clock_bit, carrier_bit_to_name),
            ),
            (
                TIER_UPPER,
                build_tier_clock_map_entry(UPPER_COARSE_MODULE_NAME, upper_state, source_clock_bit, carrier_bit_to_name),
            ),
        ])),
        ("generated_clock_channels", list(carrier_bit_to_name.values())),
    ])


def write_clock_port_map(clock_port_map):
    with open(CLOCK_PORT_MAP_JSON, "w") as fp:
        json.dump(clock_port_map, fp, indent=2)
        fp.write("\n")
    with open(CLOCK_PORT_MAP_JSON) as fp:
        loaded = json.load(fp)
    assert loaded == clock_port_map, "CLOCK_PORT_MAP_JSON readback differs from written map"


def assert_split_plan_contract(plan, src_module, primary_entries, internal_cases, upper_module, bottom_module, cell_tiers):
    assert plan["summary"]["source_cells"] == len(src_module.cells)
    assert plan["summary"]["source_ports"] == len(src_module.ports)
    assert plan["summary"]["upper_cells"] == sum(1 for tier in cell_tiers.values() if tier == TIER_UPPER)
    assert plan["summary"]["bottom_cells"] == sum(1 for tier in cell_tiers.values() if tier == TIER_BOTTOM)
    assert len(upper_module.cells) == plan["summary"]["upper_cells"]
    assert len(bottom_module.cells) == plan["summary"]["bottom_cells"]

    source_primary_labels = {entry["bit_label"] for entry in primary_entries}
    plan_primary_labels = {entry["bit_label"] for entry in plan["primary_bits"]}
    assert plan_primary_labels == source_primary_labels, (
        "SPLIT_PLAN_JSON primary bit set mismatch: missing={} extra={}".format(
            sorted(source_primary_labels - plan_primary_labels)[:20],
            sorted(plan_primary_labels - source_primary_labels)[:20],
        )
    )
    assert len(plan["primary_bits"]) == len(primary_entries)

    for module_name, module in [(UPPER_COARSE_MODULE_NAME, upper_module), (BOTTOM_COARSE_MODULE_NAME, bottom_module)]:
        for cell_name in module.cells:
            assert cell_tiers[cell_name] == (TIER_UPPER if module_name == UPPER_COARSE_MODULE_NAME else TIER_BOTTOM), (
                "Tier module {} contains cell {} assigned to {}".format(module_name, cell_name, cell_tiers[cell_name])
            )

    d2d_by_name = {}
    clock_d2d = set()
    data_d2d = set()
    for item in internal_cases:
        if item["case"] in ("NET-1", "NET-5"):
            assert "d2d_name" not in item, "Non-cross-tier internal bit has d2d_name: {}".format(item)
            continue
        assert item["case"] in ("NET-2", "NET-3")
        assert item.get("d2d_name"), "Cross-tier internal bit missing d2d_name: {}".format(item)
        assert item["d2d_name"] not in d2d_by_name, "Duplicate d2d_name: {}".format(item["d2d_name"])
        d2d_by_name[item["d2d_name"]] = item["bit"]
        assert item["driver_tier"] in item["user_tiers"] or item["user_tiers"], (
            "Cross-tier internal bit has no consumer tiers: {}".format(item)
        )

    for module_state in plan["modules"].values():
        seen_ports = set()
        for port in module_state["ports"]:
            assert port["name"] not in seen_ports, "Duplicate tier port in split plan: {}".format(port)
            seen_ports.add(port["name"])
            if port["name"].startswith("__d2d_") and port["name"] in d2d_by_name:
                data_d2d.add(port["name"])

    assert len(data_d2d) == len(d2d_by_name), (
        "Not all internal d2d names appear in tier ports: missing={}".format(
            sorted(set(d2d_by_name) - data_d2d)[:20]
        )
    )
    assert not (data_d2d & clock_d2d), "Data d2d and clock d2d sets overlap"


def assert_clock_port_map_contract(clock_port_map, src_module, primary_cases, internal_cases):
    assert clock_port_map["source_clock_port_name"] in src_module.ports
    clk_port = src_module.ports[clock_port_map["source_clock_port_name"]]
    assert clk_port.direction == "input", "Source clock port must be primary input"
    assert len(clk_port.bits) == 1, "The current clock model supports only a scalar source clock"
    assert clock_port_map["source_clock_bit"] == clk_port.bits[0]
    assert clock_port_map["clock_case"] in {"PI-1", "PI-2", "PI-3"}

    generated = set(clock_port_map.get("generated_clock_channels", []))
    internal_d2d = {item.get("d2d_name") for item in internal_cases if item.get("d2d_name")}
    assert generated <= internal_d2d, (
        "Generated clock channels not found in internal d2d metadata: {}".format(sorted(generated - internal_d2d))
    )
    for tier, entry in clock_port_map["tiers"].items():
        assert tier in {TIER_BOTTOM, TIER_UPPER}
        related = entry["clock_related_ports"]
        source_clock_ports = entry.get("source_clock_ports", [])
        direct_source_clock_ports = entry.get("direct_source_clock_ports", [])
        generated_clock_ports = entry.get("generated_clock_ports", [])
        generated_clock_input_ports = entry.get("generated_clock_input_ports", [])

        source_names = []
        for item in source_clock_ports:
            assert item["direction"] in {"input", "output"}, (
                "Unexpected source clock port direction in tier {}: {}".format(tier, item)
            )
            source_names.append(item["port_name"])
        generated_names = []
        for item in generated_clock_ports:
            assert item["direction"] in {"input", "output"}, (
                "Unexpected generated clock port direction in tier {}: {}".format(tier, item)
            )
            assert item["d2d_name"] in generated, (
                "Tier {} generated clock port references unknown d2d channel: {}".format(tier, item)
            )
            generated_names.append(item["port_name"])

        expected_related = sorted(source_names + generated_names)
        assert related == expected_related, (
            "Tier {} clock_related_ports mismatch: expected {} got {}".format(tier, expected_related, related)
        )

        expected_direct = sorted(item["port_name"] for item in source_clock_ports if item["direction"] == "input")
        assert direct_source_clock_ports == expected_direct, (
            "Tier {} direct_source_clock_ports mismatch: expected {} got {}".format(
                tier, expected_direct, direct_source_clock_ports
            )
        )
        assert len(direct_source_clock_ports) <= 1, (
            "Tier {} must not expose multiple direct source clock inputs: {}".format(tier, direct_source_clock_ports)
        )

        expected_generated_inputs = sorted(
            item["port_name"] for item in generated_clock_ports if item["direction"] == "input"
        )
        assert generated_clock_input_ports == expected_generated_inputs, (
            "Tier {} generated_clock_input_ports mismatch: expected {} got {}".format(
                tier, expected_generated_inputs, generated_clock_input_ports
            )
        )

        all_input_ports = sorted(direct_source_clock_ports + generated_clock_input_ports)
        if len(all_input_ports) == 1:
            assert entry["clock_input_port"] == all_input_ports[0], (
                "Tier {} legacy clock_input_port mismatch: expected {} got {}".format(
                    tier, all_input_ports[0], entry["clock_input_port"]
                )
            )
        else:
            assert entry["clock_input_port"] is None, (
                "Tier {} legacy clock_input_port must be None when multiple/no clock inputs exist, got {}".format(
                    tier, entry["clock_input_port"]
                )
            )


def print_summary(plan):
    summary = plan["summary"]
    print("[split] source_cells={} source_ports={}".format(summary["source_cells"], summary["source_ports"]))
    print("[split] upper_cells={} upper_ports={}".format(summary["upper_cells"], summary["upper_ports"]))
    print("[split] bottom_cells={} bottom_ports={}".format(summary["bottom_cells"], summary["bottom_ports"]))
    print("[split] case_counts={}".format(dict(summary["case_counts"])))


def main():
    assert_required_source_inputs()
    assert os.path.exists(NETLIST_V), "Netlist not found: {}".format(NETLIST_V)
    assert os.path.exists(PARTITION_TXT), "partition.txt not found: {}".format(PARTITION_TXT)
    assert os.path.exists(PIN_DIR_JSON), "pin_dir.json not found: {}".format(PIN_DIR_JSON)
    assert os.path.exists(COARSE_PIN_DIR_JSON), "coarse_pin_dir.json not found: {}".format(COARSE_PIN_DIR_JSON)
    os.makedirs(TMP_DIR, exist_ok=True)

    print("[1] Building source json with Yosys ...")
    build_source_json()
    if OUTPUT_VERILOG:
        emit_json_to_verilog(SOURCE_JSON, TOP_MODULE_NAME, SOURCE_V)
        print("[02] source_verilog -> {}".format(SOURCE_V))

    print("[2] Loading source json through toolkit ...")
    src_design = load_design(SOURCE_JSON)
    validate_design(src_design)
    assert TOP_MODULE_NAME in src_design.modules, "Top module {} not found in {}".format(TOP_MODULE_NAME, SOURCE_JSON)
    src_module = src_design.get_module(TOP_MODULE_NAME)

    print("[3] Resolving cell pin directions ...")
    pin_direction_table = load_pin_direction_tables()
    resolve_cell_port_directions(src_module, pin_direction_table)

    print("[4] Expanding primary port bits and partition ownership ...")
    primary_entries, label_to_entry, _primary_int_bits = build_primary_port_entries(src_module)
    cell_tiers, primary_owner_tiers = load_partition_entries(label_to_entry, src_module)

    print("[5] Canonicalizing undriven internal inputs ...")
    undriven_fix_report = canonicalize_undriven_internal_bits(src_module, cell_tiers)
    with open(os.path.join(TMP_DIR, "02_undriven_actual_coarse_fix_report.json"), "w") as fp:
        json.dump(undriven_fix_report, fp, indent=2, sort_keys=True)
        fp.write("\n")
    dump_design(src_design, SOURCE_JSON)
    if OUTPUT_VERILOG:
        emit_json_to_verilog(SOURCE_JSON, TOP_MODULE_NAME, SOURCE_V)

    print("[6] Classifying bit-level split cases ...")
    primary_cases, internal_cases = classify_bits(src_module, primary_entries, primary_owner_tiers, cell_tiers)

    print("[7] Constructing split modules in memory ...")
    upper_module = make_split_module(src_module, UPPER_COARSE_MODULE_NAME)
    bottom_module = make_split_module(src_module, BOTTOM_COARSE_MODULE_NAME)
    upper_state, bottom_state = populate_ports(upper_module, bottom_module, primary_cases, internal_cases)
    cell_counts = copy_cells_to_split_modules(src_module, upper_module, bottom_module, cell_tiers)

    print("[8] Validating and writing split json ...")
    upper_design = build_split_design(src_design, upper_module)
    bottom_design = build_split_design(src_design, bottom_module)
    validate_design(upper_design)
    validate_design(bottom_design)
    dump_design(upper_design, UPPER_COARSE_JSON)
    dump_design(bottom_design, BOTTOM_COARSE_JSON)
    if OUTPUT_VERILOG:
        emit_json_to_verilog(UPPER_COARSE_JSON, upper_module.name, UPPER_COARSE_V)
        emit_json_to_verilog(BOTTOM_COARSE_JSON, bottom_module.name, BOTTOM_COARSE_V)
        print("[02] upper_verilog  -> {}".format(UPPER_COARSE_V))
        print("[02] bottom_verilog -> {}".format(BOTTOM_COARSE_V))

    plan = build_split_plan(src_module, primary_cases, internal_cases, upper_state, bottom_state, cell_counts)
    assert_split_plan_contract(
        plan,
        src_module,
        primary_entries,
        internal_cases,
        upper_module,
        bottom_module,
        cell_tiers,
    )
    write_split_plan(plan)
    clock_port_map = build_clock_port_map(src_module, primary_cases, internal_cases, upper_state, bottom_state)
    assert_clock_port_map_contract(clock_port_map, src_module, primary_cases, internal_cases)
    write_clock_port_map(clock_port_map)
    print_summary(plan)

    print("[9] Split JSON handoff is ready")

    print("[done]")
    print("  source_json   -> {}".format(SOURCE_JSON))
    print("  upper_json    -> {}".format(UPPER_COARSE_JSON))
    print("  bottom_json   -> {}".format(BOTTOM_COARSE_JSON))
    print("  split_plan    -> {}".format(SPLIT_PLAN_JSON))
    print("  clock_port_map-> {}".format(CLOCK_PORT_MAP_JSON))


if __name__ == "__main__":
    main()
