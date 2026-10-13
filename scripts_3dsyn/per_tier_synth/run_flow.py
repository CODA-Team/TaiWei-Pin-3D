#!/usr/bin/env python3
"""Run the 3D-Syn per-tier synthesis stage end to end."""

import importlib.util
import json
import os
import sys
from collections import OrderedDict


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

import flow_config
from flow_config import (
    BOTTOM_COARSE_FULL_JSON,
    BOTTOM_COARSE_JSON,
    BOTTOM_REMAPPED_JSON,
    CELL_MAPPING_PLAN_JSON,
    CLOCK_PORT_MAP_JSON,
    COARSE_2D_LEF_FILE,
    COARSE_LEF_BOT,
    COARSE_LEF_UPPER,
    COARSE_SYNTH_BOT,
    COARSE_SYNTH_UPPER,
    DESIGN,
    FINAL_BASE_V,
    FINAL_PARTITION,
    FLOW_VARIANT,
    GENUS,
    GENUS_OUTPUT_JSON,
    GENUS_PLAN_JSON,
    LIBRARY,
    NETLIST_V,
    PARTITION_SEED_JSON,
    PER_TIER_SYNTH_DIR,
    PIN_DIR_JSON,
    COARSE_PIN_DIR_JSON,
    RESTORED_BASE_JSON,
    RESULTS_DIR,
    SOURCE_DEF,
    SOURCE_PARTITION_TXT,
    SPLIT_PLAN_JSON,
    SYNTH_MODE,
    TMP_DIR,
    UPPER_COARSE_FULL_JSON,
    UPPER_COARSE_JSON,
    UPPER_REMAPPED_JSON,
    WRAPPER_JSON,
    WRAPPER_PLAN_JSON,
    YOSYS,
)
from partition_contract import build_effective_partition


STEPS = [
    ("01 build pin directions", "01_build_pin_directions.py", [PIN_DIR_JSON, COARSE_PIN_DIR_JSON]),
    ("02 split tiers", "02_split_tiers.py", [SPLIT_PLAN_JSON, BOTTOM_COARSE_JSON, UPPER_COARSE_JSON]),
    (
        "03 expand coarse units",
        "03_expand_coarse_units.py",
        [BOTTOM_COARSE_FULL_JSON, UPPER_COARSE_FULL_JSON],
    ),
    ("04 map tier cells", "04_map_tier_cells.py", [CELL_MAPPING_PLAN_JSON, BOTTOM_REMAPPED_JSON, UPPER_REMAPPED_JSON]),
    ("05 build wrapper", "05_build_wrapper.py", [WRAPPER_PLAN_JSON, WRAPPER_JSON]),
    ("06 synthesize tiers", "06_synthesize_tiers.py", [GENUS_PLAN_JSON, GENUS_OUTPUT_JSON]),
    ("07 flatten synthesis output", "07_flatten_synthesis_output.py", [PARTITION_SEED_JSON]),
    ("08 restore base netlist", "08_restore_base_netlist.py", [RESTORED_BASE_JSON, FINAL_BASE_V]),
    ("09 write partition", "09_write_partition.py", [FINAL_PARTITION]),
]


def load_step(filename):
    path = os.path.join(SCRIPT_DIR, filename)
    assert os.path.isfile(path), "Flow step not found: {}".format(path)
    spec = importlib.util.spec_from_file_location(filename, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert hasattr(module, "main"), "Flow step has no main(): {}".format(path)
    return module.main


def assert_file(path, label):
    assert os.path.isfile(path), "{} not found: {}".format(label, path)
    assert os.path.getsize(path) > 0, "{} is empty: {}".format(label, path)


def assert_dir(path, label):
    assert os.path.isdir(path), "{} not found: {}".format(label, path)


def expected_synth_mode(platform):
    if platform in {"asap7_3D", "nangate45_3D"}:
        return "genus_homo"
    if platform == "asap7_nangate45_3D":
        return "genus_hetero"
    raise AssertionError("Unsupported 3D-Syn platform: {}".format(platform))


def check_prerequisites():
    expected_mode = expected_synth_mode(LIBRARY)
    assert SYNTH_MODE == expected_mode, (
        "Platform {} requires per-tier mode {}, got {}".format(LIBRARY, expected_mode, SYNTH_MODE)
    )
    for path, label in [
        (YOSYS, "Yosys executable"),
        (GENUS, "Genus executable"),
        (NETLIST_V, "coarse-partition netlist"),
        (SOURCE_DEF, "coarse-partition floorplan"),
        (SOURCE_PARTITION_TXT, "coarse partition"),
        (COARSE_2D_LEF_FILE, "2D coarse-unit LEF"),
        (COARSE_LEF_BOT, "bottom coarse-unit LEF"),
        (COARSE_LEF_UPPER, "upper coarse-unit LEF"),
    ]:
        assert_file(path, label)
    assert_dir(COARSE_SYNTH_BOT, "bottom coarse-unit implementations")
    assert_dir(COARSE_SYNTH_UPPER, "upper coarse-unit implementations")

    print(
        "[per_tier_synth] design={} platform={} variant={} mode={}".format(
            DESIGN, LIBRARY, FLOW_VARIANT, SYNTH_MODE
        )
    )
    print("[per_tier_synth] work    : {}".format(PER_TIER_SYNTH_DIR))
    print("[per_tier_synth] results : {}".format(RESULTS_DIR))


def prepare_effective_partition():
    effective_path = os.path.join(TMP_DIR, "00_effective_partition.txt")
    summary = build_effective_partition(
        library=LIBRARY,
        source_partition_path=SOURCE_PARTITION_TXT,
        source_def_path=SOURCE_DEF,
        out_partition_path=effective_path,
    )
    assert_file(effective_path, "canonical coarse partition")
    flow_config.PARTITION_TXT = effective_path
    os.environ["PARTITION_TXT"] = effective_path
    print(
        "[per_tier_synth] partition normalization: mode={} swap={}".format(
            summary["mode"], summary["swap_applied"]
        )
    )
    return effective_path, summary


def run_step(label, filename, expected_outputs):
    print("\n{}\n  {}\n{}".format("=" * 72, label, "=" * 72))
    load_step(filename)()
    for path in expected_outputs:
        assert_file(path, "{} output".format(label))


def write_manifest(effective_partition, partition_summary):
    manifest_path = os.path.join(RESULTS_DIR, "per_tier_synth_manifest.json")
    with open(GENUS_PLAN_JSON) as fp:
        genus_plan = json.load(fp)
    manifest = OrderedDict(
        [
            ("stage", "per_tier_synth"),
            ("design", DESIGN),
            ("platform", LIBRARY),
            ("flow_variant", FLOW_VARIANT),
            ("synthesis_mode", SYNTH_MODE),
            (
                "inputs",
                OrderedDict(
                    [
                        ("netlist", NETLIST_V),
                        ("floorplan", SOURCE_DEF),
                        ("partition", SOURCE_PARTITION_TXT),
                        ("effective_partition", effective_partition),
                    ]
                ),
            ),
            ("partition_normalization", partition_summary),
            ("hbt_model", genus_plan["synthesis_strategy"]["hbt_model"]),
            ("outputs", OrderedDict([("base_v", FINAL_BASE_V), ("partition", FINAL_PARTITION)])),
        ]
    )
    with open(manifest_path, "w") as fp:
        json.dump(manifest, fp, indent=2)
        fp.write("\n")
    assert_file(manifest_path, "per-tier synthesis manifest")
    return manifest_path


def main():
    check_prerequisites()
    flow_config.ensure_output_dirs()
    effective_partition, partition_summary = prepare_effective_partition()
    for label, filename, expected_outputs in STEPS:
        run_step(label, filename, expected_outputs)

    manifest_path = write_manifest(effective_partition, partition_summary)
    assert_file(FINAL_BASE_V, "final base.v")
    assert_file(FINAL_PARTITION, "final partition_from_flow.txt")
    print("\n[per_tier_synth] complete")
    print("  base netlist : {}".format(FINAL_BASE_V))
    print("  partition    : {}".format(FINAL_PARTITION))
    print("  manifest     : {}".format(manifest_path))


if __name__ == "__main__":
    main()
