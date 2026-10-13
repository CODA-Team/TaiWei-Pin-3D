#!/usr/bin/env python3
"""Adapt the legacy backend partition updater to the 3D-Syn handoff."""

import argparse
import csv
import json
import os
import re
import shutil
import shlex
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_REPO_ROOT = SCRIPT_DIR.parent.parent.parent
TOOLKIT_ROOT = DEFAULT_REPO_ROOT / "scripts_3dsyn" / "coarse_synth" / "common"
sys.path.insert(0, str(TOOLKIT_ROOT))

from yosys_json_toolkit import load_design, validate_design  # noqa: E402


KNOWN_TIERS = ("upper", "bottom")
TIER_TO_DIE = {"bottom": 0, "upper": 1}
DIE_TO_TIER = {0: "bottom", 1: "upper"}

BUFFER_LIKE_ALLOWLIST = {
    "asap7_3D": {
        "BUFx10_ASAP7_75t_R",
        "BUFx12_ASAP7_75t_R",
        "BUFx12f_ASAP7_75t_R",
        "BUFx16f_ASAP7_75t_R",
        "BUFx24_ASAP7_75t_R",
        "BUFx2_ASAP7_75t_R",
        "BUFx3_ASAP7_75t_R",
        "BUFx4_ASAP7_75t_R",
        "BUFx4f_ASAP7_75t_R",
        "BUFx5_ASAP7_75t_R",
        "BUFx6f_ASAP7_75t_R",
        "BUFx8_ASAP7_75t_R",
        "CKINVDCx10_ASAP7_75t_R",
        "CKINVDCx11_ASAP7_75t_R",
        "CKINVDCx12_ASAP7_75t_R",
        "CKINVDCx14_ASAP7_75t_R",
        "CKINVDCx16_ASAP7_75t_R",
        "CKINVDCx20_ASAP7_75t_R",
        "CKINVDCx5p33_ASAP7_75t_R",
        "CKINVDCx6p67_ASAP7_75t_R",
        "CKINVDCx8_ASAP7_75t_R",
        "CKINVDCx9p33_ASAP7_75t_R",
        "HB1xp67_ASAP7_75t_R",
        "HB2xp67_ASAP7_75t_R",
        "HB3xp67_ASAP7_75t_R",
        "HB4xp67_ASAP7_75t_R",
        "INVx11_ASAP7_75t_R",
        "INVx13_ASAP7_75t_R",
        "INVx1_ASAP7_75t_R",
        "INVx2_ASAP7_75t_R",
        "INVx3_ASAP7_75t_R",
        "INVx4_ASAP7_75t_R",
        "INVx5_ASAP7_75t_R",
        "INVx6_ASAP7_75t_R",
        "INVx8_ASAP7_75t_R",
        "INVxp33_ASAP7_75t_R",
        "INVxp67_ASAP7_75t_R",
    },
    "nangate45_3D": {
        "BUF_X1",
        "BUF_X16",
        "BUF_X2",
        "BUF_X32",
        "BUF_X4",
        "BUF_X8",
        "CLKBUF_X1",
        "CLKBUF_X2",
        "CLKBUF_X3",
        "INV_X1",
        "INV_X16",
        "INV_X2",
        "INV_X32",
        "INV_X4",
        "INV_X8",
    },
    "asap7_nangate45_3D": {
        "BUF_X1",
        "BUF_X2",
        "BUF_X4",
        "BUF_X8",
        "INV_X1",
        "INV_X2",
        "INV_X4",
        "INV_X8",
    },
}

PIN_LIBS = {
    "asap7_3D": [
        "platforms/asap7/lib/NLDM/asap7sc7p5t_AO_RVT_FF_nldm_211120.lib",
        "platforms/asap7/lib/NLDM/asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.lib",
        "platforms/asap7/lib/NLDM/asap7sc7p5t_OA_RVT_FF_nldm_211120.lib",
        "platforms/asap7/lib/NLDM/asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.lib",
        "platforms/asap7/lib/NLDM/asap7sc7p5t_SEQ_RVT_FF_nldm_220123.lib",
        "platforms/asap7/lib/NLDM/asap7sc7p5t_DFFHQNH2V2X_RVT_TT_nldm_FAKE.lib",
        "platforms/asap7/lib/NLDM/asap7sc7p5t_DFFHQNV2X_RVT_TT_nldm_FAKE.lib",
    ],
    "nangate45_3D": [
        "platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib",
    ],
    "asap7_nangate45_3D": [
        "platforms/asap7_nangate45/lib/NangateOpenCellLibrary_typical.processed.lib",
    ],
}


def fail(message):
    raise AssertionError(message)


def norm_name(value):
    text = str(value).strip()
    if text.startswith("\\"):
        text = text[1:]
    return text.replace("\\[", "[").replace("\\]", "]")


def strip_tier_suffix(master):
    if master.endswith("_upper"):
        return master[:-6]
    if master.endswith("_bottom"):
        return master[:-7]
    return master


def tier_from_master(master):
    if master.endswith("_upper"):
        return "upper"
    if master.endswith("_bottom"):
        return "bottom"
    return ""


def bit_key(bit):
    return "b{}".format(bit) if isinstance(bit, int) else "c{}".format(bit)


def scalar_bits(bits):
    return [bit for bit in bits if isinstance(bit, int)]


def find_yosys(repo_root, requested):
    candidates = []
    if requested:
        candidates.append(Path(requested))
    for env_key in ("YOSYS_EXE", "YOSYS"):
        if os.environ.get(env_key):
            candidates.append(Path(os.environ[env_key]))
    which = shutil.which("yosys")
    if which:
        candidates.append(Path(which))
    candidates.append(repo_root.parent / "ORFS-Research" / "tools" / "install" / "yosys" / "bin" / "yosys")

    for candidate in candidates:
        path = candidate if candidate.is_absolute() else repo_root / candidate
        if path.is_file() and os.access(str(path), os.X_OK):
            return path.resolve()
    fail("Could not find yosys. Tried: {}".format([str(c) for c in candidates]))


def run_yosys_to_json(yosys, verilog_path, json_path, log_path):
    json_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    script_path = json_path.with_suffix(".ys")
    script_path.write_text(
        "read_verilog {}\n"
        "hierarchy -auto-top\n"
        "write_json {}\n".format(verilog_path, json_path),
        encoding="utf-8",
    )
    with log_path.open("w", encoding="utf-8") as log_fp:
        result = subprocess.run([str(yosys), "-q", "-s", str(script_path)], stdout=log_fp, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        fail("Yosys failed for {}. See {}".format(verilog_path, log_path))


def load_single_top(json_path):
    design = load_design(json_path)
    validate_design(design)
    if len(design.modules) != 1:
        fail("Expected exactly one module in {}, found {}".format(json_path, sorted(design.modules)))
    return next(iter(design.modules.values()))


def parse_partition(path):
    mapping = {}
    order = []
    for lineno, raw in enumerate(path.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("//"):
            continue
        toks = line.split()
        if len(toks) < 2:
            fail("Malformed partition line {} in {}: {!r}".format(lineno, path, raw))
        die_s = toks[-1]
        if die_s not in ("0", "1"):
            fail("Unsupported partition die on line {} in {}: {!r}".format(lineno, path, raw))
        name = norm_name(toks[0])
        die = int(die_s)
        if name in mapping:
            fail("Duplicate partition key {!r} in {}".format(name, path))
        mapping[name] = die
        order.append(name)
    return mapping, order


def load_map_json(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    cells = data.get("cells")
    if not isinstance(cells, dict) or not cells:
        fail("map.json missing non-empty cells dict: {}".format(path))

    base_to_entry = {}
    macro_to_base = {}
    for key, entry in cells.items():
        if not isinstance(entry, dict):
            fail("map.json entry for {} is not a dict".format(key))
        raw_base = entry.get("base", key)
        if isinstance(raw_base, dict):
            base = raw_base.get("macro")
        else:
            base = raw_base
        if not isinstance(base, str) or not base:
            fail("map.json entry {} missing base.macro".format(key))
        bottom = entry.get("bottom", {})
        upper = entry.get("upper", {})
        if not isinstance(bottom, dict) or not bottom.get("macro"):
            fail("map.json entry {} missing bottom.macro".format(base))
        if not isinstance(upper, dict) or not upper.get("macro"):
            fail("map.json entry {} missing upper.macro".format(base))
        base_to_entry[base] = entry
        macro_to_base[base] = base
        macro_to_base[bottom["macro"]] = base
        macro_to_base[upper["macro"]] = base
    return base_to_entry, macro_to_base


def liberty_blocks(text, kind):
    pat = re.compile(r"\b" + re.escape(kind) + r"\s*\(([^)]+)\)\s*\{")
    pos = 0
    while True:
        match = pat.search(text, pos)
        if not match:
            break
        name = match.group(1).strip()
        i = match.end() - 1
        depth = 0
        j = i
        while j < len(text):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    yield name, text[i + 1 : j]
                    pos = j + 1
                    break
            j += 1
        else:
            break


def load_pin_directions(repo_root, enablement):
    pin_dirs = {}
    lib_paths = [repo_root / rel for rel in PIN_LIBS[enablement]]
    lib_paths.extend(Path(path) for path in shlex.split(os.environ.get("ADDITIONAL_LIBS", "")))
    for path in lib_paths:
        if not path.is_absolute():
            path = repo_root / path
        if not path.is_file():
            fail("Required liberty file not found: {}".format(path))
        text = path.read_text(encoding="utf-8", errors="ignore")
        for cell_name, cell_body in liberty_blocks(text, "cell"):
            pins = pin_dirs.setdefault(cell_name, {})
            for group_kind in ("pin", "bus"):
                for pin_name, pin_body in liberty_blocks(cell_body, group_kind):
                    match = re.search(r"\bdirection\s*:\s*([^;]+);", pin_body)
                    if not match:
                        continue
                    direction = match.group(1).strip().lower()
                    previous = pins.get(pin_name)
                    if previous is not None and previous != direction:
                        fail(
                            "Conflicting pin direction for {}/{}: {} vs {}".format(
                                cell_name, pin_name, previous, direction
                            )
                        )
                    pins[pin_name] = direction
    if not pin_dirs:
        fail("No pin directions loaded for {}".format(enablement))
    return pin_dirs


def resolve_pin_direction(cell, pin, pin_dirs):
    if cell.port_directions and pin in cell.port_directions:
        return cell.port_directions[pin].lower()
    master = strip_tier_suffix(cell.type)
    if master in pin_dirs and pin in pin_dirs[master]:
        return pin_dirs[master][pin]
    if cell.type in pin_dirs and pin in pin_dirs[cell.type]:
        return pin_dirs[cell.type][pin]
    fail("Cannot resolve pin direction for {} pin {} type {}".format(cell.name, pin, cell.type))


def build_bit_netnames(module):
    bit_to_names = defaultdict(list)
    for net_name, net in module.netnames.items():
        for bit in scalar_bits(net.bits):
            bit_to_names[bit].append(norm_name(net_name))
    for names in bit_to_names.values():
        names.sort(key=lambda n: (n.startswith("$"), len(n), n))
    return bit_to_names


def names_for_bits(bits, bit_to_names):
    labels = []
    for bit in scalar_bits(bits):
        labels.append((bit_to_names.get(bit) or ["<bit:{}>".format(bit)])[0])
    return labels


def build_cell_tiers(pre_module, partition):
    tiers = {}
    for inst_name, cell in pre_module.cells.items():
        if inst_name in partition:
            tiers[inst_name] = DIE_TO_TIER[partition[inst_name]]
            continue
        tier = tier_from_master(cell.type)
        if tier:
            tiers[inst_name] = tier
    return tiers


def build_bit_connections(module, cell_tiers, pin_dirs):
    bit_to_conns = defaultdict(list)
    for inst_name, cell in module.cells.items():
        tier = cell_tiers.get(inst_name, "unknown")
        for pin, bits in cell.connections.items():
            direction = resolve_pin_direction(cell, pin, pin_dirs)
            for bit in scalar_bits(bits):
                bit_to_conns[bit].append(
                    {
                        "kind": "cell",
                        "inst": inst_name,
                        "master": cell.type,
                        "pin": pin,
                        "direction": direction,
                        "tier": tier,
                    }
                )
    return bit_to_conns


def counter_for_conns(conns):
    c = Counter()
    for conn in conns:
        tier = conn.get("tier")
        if tier in KNOWN_TIERS:
            c[tier] += 1
    return c


def format_counter(counter):
    return ";".join("{}:{}".format(tier, counter[tier]) for tier in KNOWN_TIERS if counter[tier])


def format_conns(conns, limit=80):
    vals = []
    for conn in conns:
        vals.append(
            "{}:{}:{}:{}:{}".format(
                conn.get("inst", ""),
                conn.get("master", ""),
                conn.get("pin", ""),
                conn.get("direction", ""),
                conn.get("tier", ""),
            )
        )
    vals.sort()
    if len(vals) > limit:
        vals = vals[:limit] + ["...(+{} more)".format(len(vals) - limit)]
    return ";".join(vals)


def base_master_for_mode(master, enablement, macro_to_base):
    stripped = strip_tier_suffix(master)
    if enablement == "asap7_nangate45_3D":
        if stripped in macro_to_base:
            return macro_to_base[stripped]
        fail("Cannot map hetero master {} to map.json base cell".format(master))
    return stripped


def target_macro_for_mode(base, tier, enablement, base_to_entry):
    if enablement == "asap7_nangate45_3D":
        entry = base_to_entry.get(base)
        if not entry:
            fail("Base cell {} missing in map.json".format(base))
        macro = entry[tier]["macro"]
        if not macro:
            fail("Base cell {} missing {} macro".format(base, tier))
        return macro
    suffix = "_upper" if tier == "upper" else "_bottom"
    return base + suffix


def edge_cost(driver_counter, output_load_counter, target_tier):
    cost = 0
    for tier in KNOWN_TIERS:
        if tier != target_tier:
            cost += driver_counter[tier]
            cost += output_load_counter[tier]
    return cost


def net_cost(input_existing_counter, output_load_counter, target_tier):
    before = {tier for tier in KNOWN_TIERS if input_existing_counter[tier]}
    after = set(before)
    after.add(target_tier)
    input_delta = int(len(after) > 1) - int(len(before) > 1)
    output = {tier for tier in KNOWN_TIERS if output_load_counter[tier]}
    output.add(target_tier)
    return input_delta + int(len(output) > 1)


def choose_tier(driver_counter, input_side_counter, output_load_counter, enablement, assigned_new_count):
    upper = edge_cost(driver_counter, output_load_counter, "upper")
    bottom = edge_cost(driver_counter, output_load_counter, "bottom")
    if upper < bottom:
        return "upper", "edge_cost"
    if bottom < upper:
        return "bottom", "edge_cost"
    if enablement == "asap7_nangate45_3D":
        return "upper", "tie_hetero_default_upper"
    if assigned_new_count["upper"] < assigned_new_count["bottom"]:
        return "upper", "tie_homo_balance_new_count"
    if assigned_new_count["bottom"] < assigned_new_count["upper"]:
        return "bottom", "tie_homo_balance_new_count"
    return "upper", "tie_homo_equal_default_upper"


def analyze_added_instance(inst_name, cell, bit_to_conns, bit_to_names, pin_dirs, added_set):
    driver_conns = []
    input_side_load_conns = []
    output_load_conns = []
    output_other_driver_conns = []
    skipped_added = []
    input_net_names = []
    output_net_names = []

    for pin, bits in cell.connections.items():
        direction = resolve_pin_direction(cell, pin, pin_dirs)
        for bit in scalar_bits(bits):
            if direction == "output":
                output_net_names.extend(names_for_bits([bit], bit_to_names))
            else:
                input_net_names.extend(names_for_bits([bit], bit_to_names))

            for conn in bit_to_conns.get(bit, []):
                if conn["inst"] == inst_name:
                    continue
                if conn["inst"] in added_set:
                    skipped_added.append(conn)
                    continue
                if direction == "output":
                    if conn["direction"] == "output":
                        output_other_driver_conns.append(conn)
                    else:
                        output_load_conns.append(conn)
                else:
                    if conn["direction"] == "output":
                        driver_conns.append(conn)
                    else:
                        input_side_load_conns.append(conn)

    if output_other_driver_conns:
        fail("Added instance {} output net has other drivers: {}".format(inst_name, format_conns(output_other_driver_conns, 10)))
    if not driver_conns and not output_load_conns and not skipped_added:
        fail("Added instance {} has no driver/load connectivity".format(inst_name))

    driver_counter = counter_for_conns(driver_conns)
    input_side_counter = counter_for_conns(input_side_load_conns)
    output_load_counter = counter_for_conns(output_load_conns)
    decision_basis = "existing_neighbors"
    if not (sum(driver_counter.values()) or sum(output_load_counter.values())):
        decision_basis = "no_known_existing_neighbor_after_skip"

    return {
        "driver_conns": driver_conns,
        "input_side_load_conns": input_side_load_conns,
        "output_load_conns": output_load_conns,
        "skipped_added": skipped_added,
        "driver_counter": driver_counter,
        "input_side_counter": input_side_counter,
        "output_load_counter": output_load_counter,
        "input_net_names": sorted(set(input_net_names)),
        "output_net_names": sorted(set(output_net_names)),
        "decision_basis": decision_basis,
    }


def write_csv(path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fp:
        writer = csv.DictWriter(fp, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def append_partition_entries(partition_path, entries):
    backup = partition_path.with_name("partition.before_preplace_update.txt")
    if not backup.exists():
        shutil.copy2(partition_path, backup)
    if entries:
        with partition_path.open("a", encoding="utf-8") as fp:
            if not partition_path.read_text(encoding="utf-8", errors="ignore").endswith("\n"):
                fp.write("\n")
            for inst, die in entries:
                fp.write("{} {}\n".format(inst, die))
    return backup


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results-dir", required=True, type=Path)
    ap.add_argument("--enablement", required=True, choices=sorted(BUFFER_LIKE_ALLOWLIST))
    ap.add_argument("--design-nickname", required=True)
    ap.add_argument("--flow-root", default=str(DEFAULT_REPO_ROOT), type=Path)
    ap.add_argument("--objects-dir", required=True, type=Path)
    ap.add_argument("--log-dir", required=True, type=Path)
    ap.add_argument("--yosys", default="")
    ap.add_argument("--expect-unchanged", action="store_true")
    ap.add_argument("--fail-on-removed-non-buffer", action="store_true", default=True)
    args = ap.parse_args()

    repo_root = args.flow_root.resolve()
    results_dir = args.results_dir.resolve()
    objects_dir = args.objects_dir.resolve() / "partition_update_after_preplace"
    log_dir = args.log_dir.resolve() / "partition_update_after_preplace"
    objects_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    base_v = results_dir / "base.v"
    pre_v = results_dir / "2_2_floorplan_io.v"
    partition_txt = results_dir / "partition.txt"
    for path, label in ((base_v, "base.v"), (pre_v, "2_2_floorplan_io.v"), (partition_txt, "partition.txt")):
        if not path.is_file():
            fail("Required {} not found: {}".format(label, path))

    yosys = find_yosys(repo_root, args.yosys)
    base_json = objects_dir / "base.json"
    pre_json = objects_dir / "preplace.json"
    run_yosys_to_json(yosys, base_v, base_json, log_dir / "base_yosys.log")
    run_yosys_to_json(yosys, pre_v, pre_json, log_dir / "preplace_yosys.log")

    base_module = load_single_top(base_json)
    pre_module = load_single_top(pre_json)
    partition, _ = parse_partition(partition_txt)
    pin_dirs = load_pin_directions(repo_root, args.enablement)
    buffer_allow = BUFFER_LIKE_ALLOWLIST[args.enablement]

    base_to_entry = {}
    macro_to_base = {}
    map_json = None
    if args.enablement == "asap7_nangate45_3D":
        map_json = repo_root / "platforms" / args.enablement / "map.json"
        if not map_json.is_file():
            fail("map.json not found: {}".format(map_json))
        base_to_entry, macro_to_base = load_map_json(map_json)

    base_cells = set(base_module.cells)
    pre_cells = set(pre_module.cells)
    added = sorted(pre_cells - base_cells)
    removed = sorted(base_cells - pre_cells)
    changed_masters = sorted(
        (inst, base_module.cells[inst].type, pre_module.cells[inst].type)
        for inst in base_cells & pre_cells
        if base_module.cells[inst].type != pre_module.cells[inst].type
    )
    if args.expect_unchanged and (added or removed or changed_masters):
        fail(
            "Netlist-preserving preplace changed the instance/master set: "
            "added={} removed={} changed_masters={}".format(
                added[:20], removed[:20], changed_masters[:20]
            )
        )
    removed_non_buffer = []
    for inst in removed:
        master = strip_tier_suffix(base_module.cells[inst].type)
        if master not in buffer_allow:
            removed_non_buffer.append((inst, base_module.cells[inst].type))
    if removed_non_buffer and args.fail_on_removed_non_buffer:
        fail("Removed non-buffer-like instances: {}".format(removed_non_buffer[:20]))

    cell_tiers = build_cell_tiers(pre_module, partition)
    bit_to_names = build_bit_netnames(pre_module)
    bit_to_conns = build_bit_connections(pre_module, cell_tiers, pin_dirs)

    assigned_new_count = Counter()
    detail_rows = []
    append_entries = []
    already_present = []

    for inst_name in added:
        cell = pre_module.cells[inst_name]
        info = analyze_added_instance(inst_name, cell, bit_to_conns, bit_to_names, pin_dirs, set(added))
        target_tier, decision_reason = choose_tier(
            info["driver_counter"],
            info["input_side_counter"],
            info["output_load_counter"],
            args.enablement,
            assigned_new_count,
        )
        target_die = TIER_TO_DIE[target_tier]
        base_master = base_master_for_mode(cell.type, args.enablement, macro_to_base)
        target_macro = target_macro_for_mode(base_master, target_tier, args.enablement, base_to_entry)

        if inst_name in partition:
            if partition[inst_name] != target_die:
                fail("Added instance {} already in partition with conflicting die {} vs {}".format(inst_name, partition[inst_name], target_die))
            already_present.append(inst_name)
        else:
            append_entries.append((inst_name, target_die))
            assigned_new_count[target_tier] += 1

        input_existing_counter = info["driver_counter"] + info["input_side_counter"]
        row = {
            "inst": inst_name,
            "master": cell.type,
            "base_master": base_master,
            "target_tier": target_tier,
            "target_die": target_die,
            "target_macro": target_macro,
            "decision_reason": decision_reason,
            "decision_basis": info["decision_basis"],
            "edge_cost_if_upper": edge_cost(info["driver_counter"], info["output_load_counter"], "upper"),
            "edge_cost_if_bottom": edge_cost(info["driver_counter"], info["output_load_counter"], "bottom"),
            "net_cost_if_upper": net_cost(input_existing_counter, info["output_load_counter"], "upper"),
            "net_cost_if_bottom": net_cost(input_existing_counter, info["output_load_counter"], "bottom"),
            "driver_count": len(info["driver_conns"]),
            "driver_tiers": format_counter(info["driver_counter"]),
            "input_side_load_count": len(info["input_side_load_conns"]),
            "input_side_load_tiers": format_counter(info["input_side_counter"]),
            "output_load_count": len(info["output_load_conns"]),
            "output_load_tiers": format_counter(info["output_load_counter"]),
            "skipped_added_neighbor_count": len(info["skipped_added"]),
            "skipped_added_neighbor_driver_count": sum(1 for c in info["skipped_added"] if c["direction"] == "output"),
            "skipped_added_neighbor_load_count": sum(1 for c in info["skipped_added"] if c["direction"] != "output"),
            "input_net_names": ";".join(info["input_net_names"]),
            "output_net_names": ";".join(info["output_net_names"]),
            "driver_details": format_conns(info["driver_conns"]),
            "input_side_load_details": format_conns(info["input_side_load_conns"]),
            "output_load_details": format_conns(info["output_load_conns"]),
            "skipped_added_neighbor_details": format_conns(info["skipped_added"]),
        }
        detail_rows.append(row)

    backup = append_partition_entries(partition_txt, append_entries)
    updated_partition, _ = parse_partition(partition_txt)
    for inst, die in append_entries:
        if updated_partition.get(inst) != die:
            fail("Post-check failed: appended {} {} not found in partition".format(inst, die))

    appended_fields = ["inst", "die", "tier"]
    write_csv(
        log_dir / "appended_partition_entries.csv",
        [{"inst": inst, "die": die, "tier": DIE_TO_TIER[die]} for inst, die in append_entries],
        appended_fields,
    )
    detail_fields = [
        "inst",
        "master",
        "base_master",
        "target_tier",
        "target_die",
        "target_macro",
        "decision_reason",
        "decision_basis",
        "edge_cost_if_upper",
        "edge_cost_if_bottom",
        "net_cost_if_upper",
        "net_cost_if_bottom",
        "driver_count",
        "driver_tiers",
        "input_side_load_count",
        "input_side_load_tiers",
        "output_load_count",
        "output_load_tiers",
        "skipped_added_neighbor_count",
        "skipped_added_neighbor_driver_count",
        "skipped_added_neighbor_load_count",
        "input_net_names",
        "output_net_names",
        "driver_details",
        "input_side_load_details",
        "output_load_details",
        "skipped_added_neighbor_details",
    ]
    write_csv(log_dir / "added_instance_detail.csv", detail_rows, detail_fields)

    summary = {
        "design": args.design_nickname,
        "enablement": args.enablement,
        "inputs": {
            "base_v": str(base_v),
            "preplace_v": str(pre_v),
            "partition_txt": str(partition_txt),
            "map_json": str(map_json) if map_json else "",
            "yosys": str(yosys),
        },
        "json_outputs": {"base": str(base_json), "preplace": str(pre_json)},
        "partition_backup": str(backup),
        "orientation_source": "default_backend_contract",
        "added_instance_count": len(added),
        "removed_instance_count": len(removed),
        "changed_master_count": len(changed_masters),
        "changed_master_examples": changed_masters[:20],
        "removed_non_buffer_like_count": len(removed_non_buffer),
        "removed_non_buffer_like_examples": removed_non_buffer[:20],
        "already_present_same_tier_count": len(already_present),
        "appended_partition_entry_count": len(append_entries),
        "target_tier_counts": dict(Counter(row["target_tier"] for row in detail_rows)),
        "decision_reason_counts": dict(Counter(row["decision_reason"] for row in detail_rows)),
        "decision_basis_counts": dict(Counter(row["decision_basis"] for row in detail_rows)),
        "skipped_added_neighbor_total": sum(int(row["skipped_added_neighbor_count"]) for row in detail_rows),
        "buffer_like_allowlist_count": len(buffer_allow),
    }
    (log_dir / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    md = [
        "# update_partition_after_preplace summary",
        "",
        "- design: {}".format(args.design_nickname),
        "- enablement: {}".format(args.enablement),
        "- added instances: {}".format(len(added)),
        "- appended partition entries: {}".format(len(append_entries)),
        "- already present same tier: {}".format(len(already_present)),
        "- removed instances: {}".format(len(removed)),
        "- removed non-buffer-like: {}".format(len(removed_non_buffer)),
        "- target tier counts: {}".format(dict(Counter(row["target_tier"] for row in detail_rows))),
        "- decision reason counts: {}".format(dict(Counter(row["decision_reason"] for row in detail_rows))),
        "- decision basis counts: {}".format(dict(Counter(row["decision_basis"] for row in detail_rows))),
        "- skipped added neighbors: {}".format(summary["skipped_added_neighbor_total"]),
        "",
    ]
    (log_dir / "summary.md").write_text("\n".join(md), encoding="utf-8")
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
