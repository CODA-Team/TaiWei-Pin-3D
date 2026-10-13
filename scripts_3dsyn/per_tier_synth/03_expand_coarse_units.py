"""
03_expand_coarse_modules.py
Inject per-tier coarse module definitions into the split designs produced by
02_analyze_partition.py.

This step intentionally does only one thing:
- read the 02 split design JSON
- find which coarse module types are instantiated by the tier top module
- load the corresponding coarse module Verilog files through Yosys JSON
- merge those module definitions into the tier design
- write 03 full-design JSON / Verilog outputs

No standard-cell remap and no re-synthesis are performed here.
"""

import os
import re
import subprocess
import sys
import tempfile
import json

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TOOLKIT_ROOT = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "coarse_synth", "common"))
sys.path.insert(0, SCRIPT_DIR)
sys.path.insert(0, TOOLKIT_ROOT)

from flow_config import (
    BOTTOM_COARSE_FULL_JSON,
    BOTTOM_COARSE_FULL_V,
    BOTTOM_COARSE_JSON,
    BOTTOM_COARSE_MODULE_NAME,
    BOTTOM_CELL_SUFFIX,
    CELL_NAME_MAPPING_MODE,
    COARSE_PIN_DIR_JSON,
    COARSE_SYNTH_BOT,
    COARSE_SYNTH_UPPER,
    MAP_JSON,
    OUTPUT_VERILOG,
    PIN_DIR_JSON,
    TMP_DIR,
    UPPER_CELL_SUFFIX,
    UPPER_COARSE_FULL_JSON,
    UPPER_COARSE_FULL_V,
    UPPER_COARSE_JSON,
    UPPER_COARSE_MODULE_NAME,
    YOSYS,
)
from cell_map import load_cell_map
from yosys_json_toolkit import (
    collect_instance_types,
    dump_design,
    load_design,
    merge_modules,
    validate_design,
)


MODULE_DECL_RE = re.compile(r"^\s*module\s+([A-Za-z_][A-Za-z0-9_$]*)\b", re.MULTILINE)
COMMENT_LINE_RE = re.compile(r"//.*")
COMMENT_BLOCK_RE = re.compile(r"/\*.*?\*/", re.DOTALL)


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


def read_text(path):
    with open(path) as fp:
        return fp.read()


def strip_verilog_comments(text):
    text = COMMENT_BLOCK_RE.sub("", text)
    text = COMMENT_LINE_RE.sub("", text)
    return text


def assert_single_matching_module_decl(v_path, expected_module_name):
    raw_text = read_text(v_path)
    text = strip_verilog_comments(raw_text)
    module_names = MODULE_DECL_RE.findall(text)
    assert module_names, "No module declaration found in {}".format(v_path)
    assert module_names == [expected_module_name], (
        "Expected exactly one module declaration {} in {}, found {}".format(
            expected_module_name, v_path, module_names
        )
    )


def list_available_coarse_module_files(synth_dir):
    assert os.path.isdir(synth_dir), "Coarse synth directory not found: {}".format(synth_dir)
    module_to_path = {}
    for entry in sorted(os.listdir(synth_dir)):
        if not entry.endswith(".v"):
            continue
        module_name = os.path.splitext(entry)[0]
        v_path = os.path.join(synth_dir, entry)
        assert module_name not in module_to_path, "Duplicate coarse module file for {}".format(module_name)
        module_to_path[module_name] = v_path
    return module_to_path


def load_json_file(path):
    assert os.path.isfile(path), "Required JSON file not found: {}".format(path)
    with open(path) as fp:
        data = json.load(fp)
    assert isinstance(data, dict), "JSON file must contain a dictionary: {}".format(path)
    return data


def top_module_signature(module):
    return {
        "ports": {name: port.to_dict() for name, port in module.ports.items()},
        "cells": {name: cell.to_dict() for name, cell in module.cells.items()},
        "netnames": {name: netname.to_dict() for name, netname in module.netnames.items()},
    }


def assert_top_signature_unchanged(before, after, context):
    assert before == after, "{} changed top module signature unexpectedly".format(context)


def collect_directly_used_coarse_modules(top_module, available_module_files):
    used_instance_types = collect_instance_types(top_module)
    return sorted(cell_type for cell_type in used_instance_types if cell_type in available_module_files)


def build_module_design_from_verilog(module_name, v_path):
    assert os.path.exists(v_path), "Coarse module file not found: {}".format(v_path)
    assert_single_matching_module_decl(v_path, module_name)

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as json_fp:
        json_path = json_fp.name

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
    try:
        run_yosys_script(tcl, "coarse module verilog -> json ({})".format(module_name))
        module_design = load_design(json_path)
    finally:
        if os.path.exists(json_path):
            os.unlink(json_path)

    validate_design(module_design)
    assert module_name in module_design.modules, (
        "Module {} not found in Yosys JSON produced from {}".format(module_name, v_path)
    )
    assert set(module_design.modules.keys()) == {module_name}, (
        "Expected only module {} in Yosys JSON for {}, found {}".format(
            module_name, v_path, sorted(module_design.modules.keys())
        )
    )
    return module_design


def assert_coarse_instance_ports_resolved(top_module, module_design, module_name):
    module_def = module_design.get_module(module_name)
    module_ports = set(module_def.ports.keys())
    assert module_ports, "Coarse module {} has no ports".format(module_name)
    for cell in top_module.cells.values():
        if cell.type != module_name:
            continue
        conn_ports = set(cell.connections.keys())
        missing = sorted(conn_ports - module_ports)
        assert not missing, (
            "Top instance {} of coarse module {} connects ports missing from module definition: {}".format(
                cell.name, module_name, missing
            )
        )


def assert_no_unresolved_coarse_module_references(design, available_module_files):
    available_types = set(available_module_files.keys())
    defined_modules = set(design.modules.keys())
    unresolved = []
    for module in design.modules.values():
        for cell_type in sorted(collect_instance_types(module)):
            if cell_type in available_types and cell_type not in defined_modules:
                unresolved.append((module.name, cell_type))
    assert not unresolved, (
        "Merged design still contains unresolved coarse-module references: {}".format(unresolved)
    )


def assert_no_unresolved_non_leaf_references(design, top_module_name, known_leaf_types):
    defined_modules = set(design.modules.keys())
    unresolved = []
    for module_name, module in design.modules.items():
        for cell_type in sorted(collect_instance_types(module)):
            if cell_type in defined_modules:
                continue
            if cell_type in known_leaf_types:
                continue
            unresolved.append((module_name, cell_type))
    assert not unresolved, (
        "Merged design contains unresolved non-leaf or unknown leaf references: {}".format(unresolved[:20])
    )


def build_known_leaf_types():
    base_leaf_types = set(load_json_file(PIN_DIR_JSON))
    coarse_leaf_types = set(load_json_file(COARSE_PIN_DIR_JSON))
    known = set(base_leaf_types) | set(coarse_leaf_types)
    if CELL_NAME_MAPPING_MODE == "homogeneous_base":
        for base_name in base_leaf_types:
            known.add(base_name + BOTTOM_CELL_SUFFIX)
            known.add(base_name + UPPER_CELL_SUFFIX)
    elif CELL_NAME_MAPPING_MODE == "heterogeneous_map_json":
        data = load_cell_map(MAP_JSON)
        assert isinstance(data.get("cells"), dict), "map.json missing cells dictionary"
        for base_name, entry in data["cells"].items():
            assert isinstance(entry, dict), "map.json cell entry must be a dictionary: {}".format(base_name)
            known.add(entry["bottom"]["macro"])
            known.add(entry["upper"]["macro"])
    else:
        raise AssertionError("Unsupported CELL_NAME_MAPPING_MODE: {}".format(CELL_NAME_MAPPING_MODE))
    return known


def expand_tier_with_coarse_modules(tier, in_json, out_json, out_v, synth_dir, top_module_name):
    assert os.path.exists(in_json), "Input split JSON not found: {}".format(in_json)
    os.makedirs(TMP_DIR, exist_ok=True)

    print("[03] tier={} loading split design ...".format(tier))
    design = load_design(in_json)
    validate_design(design)
    assert top_module_name in design.modules, "Top module {} not found in {}".format(top_module_name, in_json)
    top_module = design.get_module(top_module_name)
    before_signature = top_module_signature(top_module)

    available_module_files = list_available_coarse_module_files(synth_dir)
    required_module_names = collect_directly_used_coarse_modules(top_module, available_module_files)
    print("[03] tier={} directly used coarse modules: {}".format(tier, required_module_names))

    for module_name in required_module_names:
        print("[03] tier={} merging coarse module {} ...".format(tier, module_name))
        module_design = build_module_design_from_verilog(module_name, available_module_files[module_name])
        assert_coarse_instance_ports_resolved(top_module, module_design, module_name)
        merge_modules(design, module_design, [module_name])

    validate_design(design)
    assert_top_signature_unchanged(before_signature, top_module_signature(design.get_module(top_module_name)), "03 {}".format(tier))
    assert_no_unresolved_coarse_module_references(design, available_module_files)
    known_leaf_types = build_known_leaf_types()
    assert_no_unresolved_non_leaf_references(design, top_module_name, known_leaf_types)

    dump_design(design, out_json)
    assert os.path.exists(out_json), "Full design JSON was not created: {}".format(out_json)
    reloaded = load_design(out_json)
    validate_design(reloaded)
    assert_top_signature_unchanged(before_signature, top_module_signature(reloaded.get_module(top_module_name)), "03 {} readback".format(tier))
    if OUTPUT_VERILOG:
        emit_json_to_verilog(out_json, top_module_name, out_v)
        print("       full_v    -> {}".format(out_v))

    print("[03] tier={} done".format(tier))
    print("       full_json -> {}".format(out_json))


def main():
    assert os.path.exists(BOTTOM_COARSE_JSON), "Input not found: {}".format(BOTTOM_COARSE_JSON)
    assert os.path.exists(UPPER_COARSE_JSON), "Input not found: {}".format(UPPER_COARSE_JSON)
    assert os.path.exists(COARSE_SYNTH_BOT), "Coarse synth dir not found: {}".format(COARSE_SYNTH_BOT)
    assert os.path.exists(COARSE_SYNTH_UPPER), "Coarse synth dir not found: {}".format(COARSE_SYNTH_UPPER)
    assert os.path.exists(YOSYS), "Yosys not found: {}".format(YOSYS)

    expand_tier_with_coarse_modules(
        tier="bottom",
        in_json=BOTTOM_COARSE_JSON,
        out_json=BOTTOM_COARSE_FULL_JSON,
        out_v=BOTTOM_COARSE_FULL_V,
        synth_dir=COARSE_SYNTH_BOT,
        top_module_name=BOTTOM_COARSE_MODULE_NAME,
    )
    expand_tier_with_coarse_modules(
        tier="upper",
        in_json=UPPER_COARSE_JSON,
        out_json=UPPER_COARSE_FULL_JSON,
        out_v=UPPER_COARSE_FULL_V,
        synth_dir=COARSE_SYNTH_UPPER,
        top_module_name=UPPER_COARSE_MODULE_NAME,
    )


if __name__ == "__main__":
    main()
