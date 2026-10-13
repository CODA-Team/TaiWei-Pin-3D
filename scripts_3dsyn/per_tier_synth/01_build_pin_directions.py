"""
01_build_pin_dir.py
Build pin-direction lookup tables for all cells used in the flow.

Produces two JSON files in TMP_DIR:
  - pin_dir.json        : { base_cell: { pin: "INPUT"|"OUTPUT"|"INOUT" } }
                          for standard cells and fakeram macros used by the flow
  - coarse_pin_dir.json : { macro_name: { pin: direction } }
                          for coarse macros (from write_coarse_lef pass)

The standard-cell/base-cell mapping can come from two sources:
  - heterogeneous_map_json : explicit mapping from map.json
  - homogeneous_base       : derive base <-> tier cell names from _bottom/_upper,
                             but emit base names only

Usage:
    python3 01_build_pin_dir.py
    python3 01_build_pin_dir.py --verify   # cross-check top/bottom directions
"""

import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from flow_config import (
    CELL_NAME_MAPPING_MODE,
    COARSE_2D_LEF_FILE,
    COARSE_LEF_BOT,
    COARSE_LEF_UPPER,
    COARSE_PIN_DIR_JSON,
    DESIGN,
    LEF_BOT_DIR,
    LEF_UPPER_DIR,
    MAP_JSON,
    MAP_JSON_STATUS,
    PIN_DIR_JSON,
    STANDARD_CELL_LEF_BOTTOM,
    STANDARD_CELL_LEF_UPPER,
    TMP_DIR,
    BOTTOM_CELL_SUFFIX,
    UPPER_CELL_SUFFIX,
    assert_required_source_inputs,
)
from cell_map import load_cell_map

POWER_PINS = {"VDD", "VSS", "VDDIO", "VSSIO"}
VALID_DIRECTIONS = {"INPUT", "OUTPUT", "INOUT"}


def parse_lef_directions(lef_path: str) -> dict:
    """
    Returns:
      { macro_name: { "is_block": bool, "pins": { pin_key: direction } } }

    Pin keys always keep the raw LEF pin names.
    This is important because the flow preserves original Verilog bus syntax
    such as "rd_out[0]" instead of sanitizing it to "rd_out_0".
    """
    result = {}
    cur_macro = None
    cur_pin = None

    with open(lef_path) as f:
        for raw in f:
            tok = raw.split()
            if not tok:
                continue
            kw = tok[0].upper()

            if kw == "MACRO":
                cur_macro = tok[1]
                assert cur_macro not in result, (
                    f"[lef] duplicate macro {cur_macro!r} in {lef_path}"
                )
                result[cur_macro] = {"is_block": False, "pins": {}}
                cur_pin = None
            elif kw == "CLASS" and cur_macro is not None:
                if tok[1].upper() == "BLOCK":
                    result[cur_macro]["is_block"] = True
            elif kw == "PIN" and cur_macro is not None:
                cur_pin = tok[1]
                assert cur_pin not in result[cur_macro]["pins"], (
                    f"[lef] duplicate pin {cur_pin!r} in macro {cur_macro!r} "
                    f"from {lef_path}"
                )
                result[cur_macro]["pins"][cur_pin] = "UNKNOWN"
            elif kw == "DIRECTION" and cur_macro is not None and cur_pin is not None:
                direction = tok[1].rstrip(";").upper()
                assert direction in VALID_DIRECTIONS, (
                    f"[lef] unsupported direction {direction!r} for "
                    f"{cur_macro}/{cur_pin} in {lef_path}"
                )
                result[cur_macro]["pins"][cur_pin] = direction
            elif kw == "END" and len(tok) == 2:
                if cur_pin is not None and tok[1] == cur_pin:
                    cur_pin = None
                elif cur_macro is not None and tok[1] == cur_macro:
                    cur_macro = None

    return result


def collect_lef_directions(root_dir: str) -> dict:
    """Walk a directory and parse all .lef files found."""
    merged = {}
    if not os.path.isdir(root_dir):
        return merged
    for dirpath, _, filenames in os.walk(root_dir):
        for fname in sorted(filenames):
            if fname.endswith(".lef"):
                path = os.path.join(dirpath, fname)
                print(f"    reading {os.path.relpath(path, SCRIPT_DIR)}")
                parsed = parse_lef_directions(path)
                for macro_name, entry in parsed.items():
                    if macro_name in merged:
                        assert merged[macro_name] == entry, (
                            f"[lef] duplicate macro {macro_name!r} with different "
                            f"content while collecting {root_dir}"
                        )
                    merged[macro_name] = entry
    return merged


def _strip_suffix(name: str, suffix: str) -> str:
    assert name.endswith(suffix), f"Expected suffix {suffix!r} in {name!r}"
    base = name[: -len(suffix)]
    assert base, f"Suffix strip produced empty base name from {name!r}"
    return base


def _signal_pins(entry: dict) -> dict:
    signal = {}
    for pin, direction in entry["pins"].items():
        if pin in POWER_PINS:
            continue
        assert direction != "UNKNOWN", (
            f"[lef] signal pin {pin!r} has UNKNOWN direction in macro entry"
        )
        assert direction in VALID_DIRECTIONS, (
            f"[lef] signal pin {pin!r} has unsupported direction {direction!r}"
        )
        signal[pin] = direction
    return signal


def load_map_data_from_json() -> dict:
    assert MAP_JSON, f"MAP_JSON is empty while mode={CELL_NAME_MAPPING_MODE}"
    assert os.path.exists(MAP_JSON), f"map.json not found: {MAP_JSON}"
    print("[3] Loading explicit map.json ...")
    map_data = load_cell_map(MAP_JSON)
    assert isinstance(map_data, dict), "map.json top level must be a dictionary"
    assert isinstance(map_data.get("cells"), dict) and map_data["cells"], (
        "map.json missing non-empty top-level 'cells' dictionary"
    )
    for base_name, entry in map_data["cells"].items():
        assert isinstance(base_name, str) and base_name, "map.json contains empty base cell name"
        assert isinstance(entry, dict), f"map.json entry for {base_name} must be a dictionary"
        assert isinstance(entry.get("bottom"), dict) and entry["bottom"].get("macro"), (
            f"map.json entry {base_name} missing bottom.macro"
        )
        assert isinstance(entry.get("upper"), dict) and entry["upper"].get("macro"), (
            f"map.json entry {base_name} missing upper.macro"
        )
        assert isinstance(entry.get("pin_map"), dict), f"map.json entry {base_name} missing pin_map dictionary"
    print(f"    mode={CELL_NAME_MAPPING_MODE}  cells={len(map_data['cells'])}")
    return map_data


def build_homogeneous_map_data(bot_dir: dict, top_dir: dict) -> dict:
    print("[3] Deriving homogeneous base-cell map from LEFs ...")
    print(f"    mode={CELL_NAME_MAPPING_MODE}")

    bot_by_base = {}
    for macro_name, entry in bot_dir.items():
        if macro_name.endswith(BOTTOM_CELL_SUFFIX):
            base = _strip_suffix(macro_name, BOTTOM_CELL_SUFFIX)
            assert base not in bot_by_base, f"duplicate bottom base cell after suffix strip: {base}"
            bot_by_base[base] = (macro_name, entry)

    top_by_base = {}
    for macro_name, entry in top_dir.items():
        if macro_name.endswith(UPPER_CELL_SUFFIX):
            base = _strip_suffix(macro_name, UPPER_CELL_SUFFIX)
            assert base not in top_by_base, f"duplicate upper base cell after suffix strip: {base}"
            top_by_base[base] = (macro_name, entry)

    missing_top = sorted(set(bot_by_base) - set(top_by_base))
    missing_bot = sorted(set(top_by_base) - set(bot_by_base))
    assert not missing_top, (
        f"[homogeneous_map] {len(missing_top)} bottom macros have no upper partner: {missing_top[:20]}"
    )
    assert not missing_bot, (
        f"[homogeneous_map] {len(missing_bot)} upper macros have no bottom partner: {missing_bot[:20]}"
    )
    assert bot_by_base, "[homogeneous_map] no bottom base cells derived from LEF suffix"
    assert top_by_base, "[homogeneous_map] no upper base cells derived from LEF suffix"

    cells = {}
    skipped_physical_only = []
    for base_name in sorted(set(bot_by_base) & set(top_by_base)):
        bot_macro, bot_entry = bot_by_base[base_name]
        top_macro, top_entry = top_by_base[base_name]

        assert bot_entry["is_block"] == top_entry["is_block"], (
            f"[homogeneous_map] block/class mismatch for {base_name}: "
            f"bottom is_block={bot_entry['is_block']} "
            f"upper is_block={top_entry['is_block']}"
        )

        bot_signal_pins = _signal_pins(bot_entry)
        top_signal_pins = _signal_pins(top_entry)
        if not bot_entry["is_block"] and not bot_signal_pins and not top_signal_pins:
            skipped_physical_only.append(base_name)
            continue
        assert set(bot_signal_pins) == set(top_signal_pins), (
            f"[homogeneous_map] pin-set mismatch for {base_name}:\n"
            f"  bottom-only={sorted(set(bot_signal_pins) - set(top_signal_pins))}\n"
            f"  upper-only={sorted(set(top_signal_pins) - set(bot_signal_pins))}"
        )

        pin_map = {}
        if not bot_entry["is_block"]:
            for pin, direction in bot_signal_pins.items():
                assert direction == top_signal_pins[pin], (
                    f"[homogeneous_map] direction mismatch for {base_name}/{pin}: "
                    f"bottom={direction} upper={top_signal_pins[pin]}"
                )
            pin_map = {pin: pin for pin in sorted(bot_signal_pins)}

        cells[base_name] = {
            "base": base_name,
            "bottom": {"macro": bot_macro},
            "upper": {"macro": top_macro},
            "pin_map": pin_map,
        }

    if skipped_physical_only:
        print(
            f"    skipped {len(skipped_physical_only)} physical-only standard cells "
            f"with no signal pins"
        )
    print(f"    derived {len(cells)} base cells from homogeneous tier LEFs")
    return {"cells": cells}


def load_map_data(bot_dir: dict, top_dir: dict) -> dict:
    if CELL_NAME_MAPPING_MODE == "heterogeneous_map_json":
        return load_map_data_from_json()
    if CELL_NAME_MAPPING_MODE == "homogeneous_base":
        return build_homogeneous_map_data(bot_dir, top_dir)
    raise ValueError(f"Unsupported CELL_NAME_MAPPING_MODE: {CELL_NAME_MAPPING_MODE}")


def build_pin_dir(
    map_data: dict,
    bot_dir: dict,
    top_dir: dict,
    verify: bool = False,
) -> dict:
    table = {}
    missing_bottom = []
    missing_upper = []
    mismatches = []

    for base_name, info in map_data["cells"].items():
        bot_macro = info["bottom"]["macro"]
        top_macro = info["upper"]["macro"]
        pin_map = info.get("pin_map", {})

        bot_entry = bot_dir.get(bot_macro)
        top_entry = top_dir.get(top_macro)

        if bot_entry is None:
            missing_bottom.append(f"  [MISS-BOT] {base_name} ({bot_macro})")
            continue
        if top_entry is None:
            missing_upper.append(f"  [MISS-UPPER] {base_name} ({top_macro})")
            continue

        is_block = bot_entry["is_block"]
        bot_pins = bot_entry["pins"]
        top_pins = top_entry["pins"] if top_entry else {}
        cell_dir = {}

        if is_block:
            for raw_pin, direction in bot_pins.items():
                if raw_pin in POWER_PINS:
                    continue
                assert direction in VALID_DIRECTIONS, (
                    f"[pin_dir] invalid direction for block pin "
                    f"{base_name}/{raw_pin} in {bot_macro}: {direction}"
                )
                cell_dir[raw_pin] = direction

                if verify and top_pins:
                    top_direction = top_pins.get(raw_pin, "UNKNOWN")
                    if top_direction not in ("UNKNOWN",) and top_direction != direction:
                        mismatches.append(
                            f"  [MISMATCH] {base_name}/{raw_pin}: "
                            f"bot={direction} top={top_direction}"
                        )
        else:
            for base_pin in pin_map:
                if base_pin in POWER_PINS:
                    continue
                direction = bot_pins.get(base_pin, "UNKNOWN")
                assert direction != "UNKNOWN", (
                    f"[pin_dir] unknown direction for standard-cell pin "
                    f"{base_name}/{base_pin} in {bot_macro}"
                )
                assert direction in VALID_DIRECTIONS, (
                    f"[pin_dir] invalid direction for standard-cell pin "
                    f"{base_name}/{base_pin} in {bot_macro}: {direction}"
                )
                cell_dir[base_pin] = direction

                upper_pin = pin_map.get(base_pin, base_pin)
                assert upper_pin in top_pins, (
                    f"[pin_dir] upper pin {upper_pin} for {base_name}/{base_pin} "
                    f"not found in {top_macro}"
                )
                top_direction = top_pins.get(upper_pin, "UNKNOWN")
                assert top_direction != "UNKNOWN", (
                    f"[pin_dir] unknown upper direction for standard-cell pin "
                    f"{base_name}/{upper_pin} in {top_macro}"
                )
                assert top_direction == direction, (
                    f"[pin_dir] direction mismatch for {base_name}/{base_pin}: "
                    f"bottom={direction} upper={top_direction}"
                )

        table[base_name] = cell_dir

    if missing_bottom or missing_upper:
        print(
            "    skipped {} map entries without complete tier LEF views".format(
                len(missing_bottom) + len(missing_upper)
            )
        )
        for message in missing_bottom + missing_upper:
            print(message)
    assert not mismatches, "[pin_dir] direction mismatches between top/bottom:\n{}".format("\n".join(mismatches))

    return table


def _load_coarse_lef_bundle(path: str) -> dict:
    if os.path.isdir(path):
        print(f"    reading coarse LEF dir {os.path.relpath(path, SCRIPT_DIR)}")
        merged = collect_lef_directions(path)
        print(f"    -> {len(merged)} coarse macros")
        return merged
    print(f"    reading {os.path.relpath(path, SCRIPT_DIR)}")
    merged = parse_lef_directions(path)
    print(f"    -> {len(merged)} coarse macros")
    return merged


def build_coarse_pin_dir(bot_lef_path: str, top_lef_path: str) -> dict:
    """Return { macro_name: { pin_key: direction } } for coarse macros."""
    bot_dir = _load_coarse_lef_bundle(bot_lef_path)
    top_dir = _load_coarse_lef_bundle(top_lef_path)

    table = {}
    mismatches = []

    for macro_name, bot_entry in bot_dir.items():
        cell_dir = {}
        for pin, direction in bot_entry["pins"].items():
            if pin in POWER_PINS:
                continue
            assert direction != "UNKNOWN", (
                f"[coarse_pin_dir] unknown direction for coarse macro pin "
                f"{macro_name}/{pin}"
            )
            assert direction in VALID_DIRECTIONS, (
                f"[coarse_pin_dir] invalid direction for coarse macro pin "
                f"{macro_name}/{pin}: {direction}"
            )
            cell_dir[pin] = direction
        assert cell_dir, f"[coarse_pin_dir] coarse macro {macro_name} has no signal pins"
        table[macro_name] = cell_dir

        top_entry = top_dir.get(macro_name)
        if top_entry:
            for pin, direction in cell_dir.items():
                top_direction = top_entry["pins"].get(pin, "UNKNOWN")
                if top_direction not in ("UNKNOWN",) and top_direction != direction:
                    mismatches.append(
                        f"  [MISMATCH] {macro_name}/{pin}: "
                        f"bot={direction} top={top_direction}"
                    )

    assert not mismatches, "[coarse_pin_dir] direction mismatches in coarse LEFs:\n{}".format(
        "\n".join(mismatches)
    )

    return table


def assert_valid_direction_table(table: dict, table_name: str, expected_keys=None, allow_empty=False):
    assert isinstance(table, dict), f"{table_name} must be a dictionary"
    if not allow_empty:
        assert table, f"{table_name} must be a non-empty dictionary"
    if expected_keys is not None:
        assert set(table) == set(expected_keys), (
            f"{table_name} key mismatch: missing={sorted(set(expected_keys) - set(table))[:20]} "
            f"extra={sorted(set(table) - set(expected_keys))[:20]}"
        )
    for cell_name, pins in table.items():
        assert isinstance(cell_name, str) and cell_name, f"{table_name} has empty cell key"
        if CELL_NAME_MAPPING_MODE == "homogeneous_base" and table_name == "pin_dir.json":
            assert not cell_name.endswith(BOTTOM_CELL_SUFFIX), (
                f"{table_name} contains bottom suffix key in homogeneous_base mode: {cell_name}"
            )
            assert not cell_name.endswith(UPPER_CELL_SUFFIX), (
                f"{table_name} contains upper suffix key in homogeneous_base mode: {cell_name}"
            )
        assert isinstance(pins, dict) and pins, f"{table_name}:{cell_name} has empty pin dictionary"
        for pin_name, direction in pins.items():
            assert isinstance(pin_name, str) and pin_name, f"{table_name}:{cell_name} has empty pin name"
            assert direction in VALID_DIRECTIONS, (
                f"{table_name}:{cell_name}/{pin_name} has unsupported direction {direction!r}"
            )


def write_and_recheck_json(path: str, data: dict, table_name: str, expected_keys=None, allow_empty=False):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    with open(path) as f:
        loaded = json.load(f)
    assert loaded == data, f"{table_name} JSON readback differs from written data"
    assert_valid_direction_table(
        loaded,
        table_name,
        expected_keys=expected_keys,
        allow_empty=allow_empty,
    )


def get_pin_direction(table: dict, base_cell: str, pin_key: str) -> str:
    return table.get(base_cell, {}).get(pin_key, "UNKNOWN")


def is_output_pin(table: dict, base_cell: str, pin_key: str) -> bool:
    return get_pin_direction(table, base_cell, pin_key) == "OUTPUT"


def is_input_pin(table: dict, base_cell: str, pin_key: str) -> bool:
    return get_pin_direction(table, base_cell, pin_key) in ("INPUT", "INOUT")


def main():
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Cross-check top/bottom pin directions",
    )
    args, _ = parser.parse_known_args()

    assert_required_source_inputs()
    os.makedirs(TMP_DIR, exist_ok=True)
    assert CELL_NAME_MAPPING_MODE in {"homogeneous_base", "heterogeneous_map_json"}, (
        f"Unsupported CELL_NAME_MAPPING_MODE: {CELL_NAME_MAPPING_MODE}"
    )
    assert BOTTOM_CELL_SUFFIX and UPPER_CELL_SUFFIX and BOTTOM_CELL_SUFFIX != UPPER_CELL_SUFFIX

    assert os.path.exists(STANDARD_CELL_LEF_BOTTOM), (
        f"bottom standard-cell LEF not found: {STANDARD_CELL_LEF_BOTTOM}"
    )
    assert os.path.exists(STANDARD_CELL_LEF_UPPER), (
        f"upper standard-cell LEF not found: {STANDARD_CELL_LEF_UPPER}"
    )

    # The partition netlist uses unsuffixed coarse-unit type names.  Tier LEFs
    # intentionally use _bottom/_upper names and do not match this boundary.
    coarse_bot_src = COARSE_2D_LEF_FILE
    coarse_top_src = COARSE_2D_LEF_FILE
    assert os.path.exists(coarse_bot_src), f"Coarse LEF source not found: {coarse_bot_src}"

    print("[1] Parsing bottom LEFs ...")
    bot_dir = {}
    bot_dir.update(collect_lef_directions(os.path.join(LEF_BOT_DIR, "fakeram_block")))
    bot_dir.update(parse_lef_directions(STANDARD_CELL_LEF_BOTTOM))
    print(f"    reading {os.path.relpath(STANDARD_CELL_LEF_BOTTOM, SCRIPT_DIR)}")
    print(f"    -> {len(bot_dir)} macros total")

    print("[2] Parsing upper LEFs ...")
    top_dir = {}
    top_dir.update(collect_lef_directions(os.path.join(LEF_UPPER_DIR, "fakeram_block")))
    top_dir.update(parse_lef_directions(STANDARD_CELL_LEF_UPPER))
    print(f"    reading {os.path.relpath(STANDARD_CELL_LEF_UPPER, SCRIPT_DIR)}")
    print(f"    -> {len(top_dir)} macros total")

    map_data = load_map_data(bot_dir, top_dir)

    print("[4] Building standard cell pin-direction table ...")
    table = build_pin_dir(map_data, bot_dir, top_dir, verify=args.verify)
    assert_valid_direction_table(table, "pin_dir.json", expected_keys=table.keys())
    print(f"    -> {len(table)} cells resolved")

    write_and_recheck_json(PIN_DIR_JSON, table, "pin_dir.json", expected_keys=table.keys())
    print(f"[done] saved to {PIN_DIR_JSON}")

    print("\n[5] Building coarse macro pin-direction table ...")
    coarse_table = build_coarse_pin_dir(coarse_bot_src, coarse_top_src)
    assert_valid_direction_table(coarse_table, "coarse_pin_dir.json", allow_empty=True)
    print(f"    -> {len(coarse_table)} coarse macros resolved")

    write_and_recheck_json(
        COARSE_PIN_DIR_JSON,
        coarse_table,
        "coarse_pin_dir.json",
        allow_empty=True,
    )
    print(f"[done] saved to {COARSE_PIN_DIR_JSON}")
    print(f"[summary] DESIGN={DESIGN} mode={CELL_NAME_MAPPING_MODE} map_json={MAP_JSON_STATUS}")


if __name__ == "__main__":
    main()
