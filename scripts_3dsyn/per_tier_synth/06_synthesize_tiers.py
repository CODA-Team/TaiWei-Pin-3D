"""
06_run_genus.py
Run wrapper-level Genus synthesis for the two tiers.

The first implementation supports homogeneous synthesis only.  It consumes the
05 hierarchical wrapper, keeps the upper/bottom module boundaries intact, and
lets Genus optimize inside each tier module under a base 2D liberty set.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import OrderedDict

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TOOLKIT_ROOT = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "coarse_synth", "common"))
sys.path.insert(0, SCRIPT_DIR)
sys.path.insert(0, TOOLKIT_ROOT)

from flow_config import (
    BOTTOM_CELL_SUFFIX,
    BOTTOM_COARSE_MODULE_NAME,
    ABC_DRV_CELL_BOTTOM,
    ABC_DRV_CELL_UPPER,
    BOTTOM_LIB_DIR,
    BOTTOM_LIB_FILES,
    CELL_MAPPING_PLAN_JSON,
    CELL_NAME_MAPPING_MODE,
    CLOCK_PORT_MAP_JSON,
    DESIGN,
    DESIGN_MACRO_LIB_FILES,
    DESIGN_SDC_FILE,
    FLOW_VARIANT,
    GENUS,
    GENUS_DB_DIR,
    GENUS_INPUT_V,
    GENUS_LOG_PREFIX,
    GENUS_OUTPUT_JSON,
    GENUS_OUTPUT_V,
    GENUS_PLAN_JSON,
    GENUS_POST_SDC,
    GENUS_REPORT_DIR,
    GENUS_SDC,
    GENUS_TCL,
    GENUS_TMP_DIR,
    LIBRARY,
    MAP_JSON,
    SDC_CLK_PERIOD_PS,
    SDC_CLK_PERIOD_RAW,
    SDC_CLK_PERIOD_UNIT,
    SYNTHESIS_2D_LIB_DIR,
    SYNTHESIS_2D_LIB_FILES,
    SYNTHESIS_2D_PLATFORM_DIR,
    SYNTH_MODE,
    TIEHI_CELL_BOTTOM,
    TIEHI_CELL_UPPER,
    TIEHI_PIN_BOTTOM,
    TIEHI_PIN_UPPER,
    TIELO_CELL_BOTTOM,
    TIELO_CELL_UPPER,
    TIELO_PIN_BOTTOM,
    TIELO_PIN_UPPER,
    TOP_MODULE_NAME,
    UPPER_CELL_SUFFIX,
    UPPER_COARSE_MODULE_NAME,
    UPPER_LIB_DIR,
    UPPER_LIB_FILES,
    WRAPPER_BOTTOM_INSTANCE_NAME,
    WRAPPER_JSON,
    WRAPPER_PLAN_JSON,
    WRAPPER_TOP_MODULE_NAME,
    WRAPPER_UPPER_INSTANCE_NAME,
    WRAPPER_V,
    YOSYS,
)
from yosys_json_toolkit import (
    dump_design,
    load_design,
    module_port_shape_signature,
    normalize_module_port_shapes,
    validate_design,
)
from hbt_model import build_hbt_model, render_hbt_tcl, resolve_hbt_config


DEFAULT_MAX_CPUS = os.getenv("GENUS_MAX_CPUS", "16")
SUPPORTED_HOMO_MAPPING_MODE = "homogeneous_base"
SUPPORTED_HETERO_MAPPING_MODE = "heterogeneous_map_json"
SUPPORTED_CELL_PIN_DIRECTIONS = {"input", "output"}
LIBERTY_CELL_RE = re.compile(r"\bcell\s*\(\s*([A-Za-z_][A-Za-z0-9_$]*)\s*\)")
SDC_SET_RE = re.compile(r"^\s*set\s+([A-Za-z_][A-Za-z0-9_]*)\s+(.+?)\s*$")
SDC_SET_UNITS_TIME_RE = re.compile(r"^\s*set_units\s+-time\s+([0-9.]+)\s*(ps|ns)\s*$", re.IGNORECASE)
SDC_CREATE_CLOCK_PERIOD_RE = re.compile(r"\bcreate_clock\b.*\s-period\s+\"?([0-9.]+|\$[A-Za-z_][A-Za-z0-9_]*)\"?", re.IGNORECASE)
GENUS_SEVERITY_SUMMARY_RE = re.compile(r"\bError\s*=\s*(\d+)\s*,\s*Fatal\s*=\s*(\d+)", re.IGNORECASE)
GENUS_MESSAGE_TABLE_RE = re.compile(r"^\|\s*[^|]+\|\s*(Error|Fatal)\s*\|\s*(\d+)\s*\|", re.IGNORECASE)
GENUS_EXPLICIT_SEVERITY_RE = re.compile(r"^\s*(\*+\s*)?(Error|Fatal)\s*[:(]", re.IGNORECASE)
GENUS_REPORT_COUNT_RE = re.compile(r"^(?P<label>.+?)\s+(?P<count>\d+)\s*$")
GENUS_UNCLOCKED_SOURCE_RE = re.compile(
    r"^pin:(?P<pin>\S+)\s+port:(?P<source>\S+)\s+\{Unclocked source\}$"
)
D2D_EXTRA_RC_TCL = os.path.join(GENUS_TMP_DIR, "06_hbt_model.tcl")
D2D_EXTRA_RC_JSON = os.path.join(GENUS_TMP_DIR, "06_hbt_model.json")


def normalize_genus_primary_interface(output_design, reference_design, output_json):
    output_top = output_design.get_module(WRAPPER_TOP_MODULE_NAME)
    reference_top = reference_design.get_module(WRAPPER_TOP_MODULE_NAME)
    changed_ports = normalize_module_port_shapes(reference_top, output_top)
    assert module_port_shape_signature(output_top) == module_port_shape_signature(reference_top), (
        "Genus output primary interface differs from the wrapper input"
    )
    if changed_ports:
        dump_design(output_design, output_json)
    return changed_ports


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
    loaded = load_json_file(path)
    assert loaded == data, "JSON readback differs from written file: {}".format(path)


def read_text(path):
    with open(path) as fp:
        return fp.read()


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fp:
        fp.write(text)


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//.*", "", text)


def tcl_quote(value):
    return "{" + str(value).replace("}", "\\}") + "}"


def format_tcl_list(items):
    return " ".join(tcl_quote(item) for item in items)


def strip_required_suffix(value, suffix, label):
    assert value.endswith(suffix), "{} must end with {}: {}".format(label, suffix, value)
    base = value[: -len(suffix)]
    assert base, "{} becomes empty after removing suffix {}".format(label, suffix)
    return base


def homogeneous_constant_tie_specs():
    bottom = [
        (strip_required_suffix(TIELO_CELL_BOTTOM, BOTTOM_CELL_SUFFIX, "bottom TIELO cell"), TIELO_PIN_BOTTOM),
        (strip_required_suffix(TIEHI_CELL_BOTTOM, BOTTOM_CELL_SUFFIX, "bottom TIEHI cell"), TIEHI_PIN_BOTTOM),
    ]
    upper = [
        (strip_required_suffix(TIELO_CELL_UPPER, UPPER_CELL_SUFFIX, "upper TIELO cell"), TIELO_PIN_UPPER),
        (strip_required_suffix(TIEHI_CELL_UPPER, UPPER_CELL_SUFFIX, "upper TIEHI cell"), TIEHI_PIN_UPPER),
    ]
    assert bottom == upper, "Homogeneous tiers resolve to different base tie cells: {} != {}".format(bottom, upper)
    return bottom


def tier_constant_tie_specs(tier):
    if tier == "bottom":
        return [(TIELO_CELL_BOTTOM, TIELO_PIN_BOTTOM), (TIEHI_CELL_BOTTOM, TIEHI_PIN_BOTTOM)]
    if tier == "upper":
        return [(TIELO_CELL_UPPER, TIELO_PIN_UPPER), (TIEHI_CELL_UPPER, TIEHI_PIN_UPPER)]
    raise AssertionError("Unsupported tier for tie-cell configuration: {}".format(tier))


def render_constant_tie_configuration(tie_specs):
    assert len(tie_specs) == 2, "Expected TIELO/TIEHI specifications"
    assert tie_specs[0] != tie_specs[1], "TIELO and TIEHI specifications must differ"
    rendered_specs = " ".join(
        "[list {} {}]".format(tcl_quote(cell_name), tcl_quote(port_name))
        for cell_name, port_name in tie_specs
    )
    template = """proc syn3d_configure_constant_tie_cells {tie_specs} {
  set tie_cells {}
  foreach tie_spec $tie_specs {
    if {[llength $tie_spec] != 2} { error "Invalid constant tie-cell specification: $tie_spec" }
    set cell_name [lindex $tie_spec 0]
    set port_name [lindex $tie_spec 1]
    if {[regexp {[\[\]*?]} $cell_name]} {
      error "Constant tie-cell name must not contain glob metacharacters: $cell_name"
    }
    set cell_matches [get_db lib_cells */$cell_name]
    if {[llength $cell_matches] != 1} {
      error "Constant tie-cell $cell_name must match exactly one loaded library cell; matches=$cell_matches"
    }
    set tie_cell [lindex $cell_matches 0]
    set port_matches {}
    foreach lib_pin [get_db $tie_cell .lib_pins] {
      if {[get_db $lib_pin .base_name] eq $port_name} { lappend port_matches $lib_pin }
    }
    if {[llength $port_matches] != 1 || [get_db [lindex $port_matches 0] .direction] ne "out"} {
      error "Constant tie-cell port $cell_name/$port_name must resolve to exactly one output pin"
    }
    set_db $tie_cell .avoid false
    set_db $tie_cell .preserve false
    lappend tie_cells $tie_cell
  }
  if {[lindex $tie_cells 0] eq [lindex $tie_cells 1]} {
    error "TIELO and TIEHI resolve to the same library cell"
  }
  set_db use_tiehilo_for_const duplicate
  if {[get_db / .use_tiehilo_for_const] ne "duplicate"} {
    error "Failed to enable duplicate constant tie-cell mapping"
  }
  puts "SYN3D_CONSTANT_TIE_MAPPING=duplicate"
}
syn3d_configure_constant_tie_cells [list @TIE_SPECS@]
"""
    return template.replace("@TIE_SPECS@", rendered_specs)


def collect_all_d2d_channels(wrapper_plan):
    channels = []
    for channel in wrapper_plan["data_d2d_channels"]:
        channels.append(("data_d2d", channel))
    for channel in wrapper_plan["clock"]["clock_d2d_channels"]:
        channels.append(("clock_d2d", channel))
    return channels


def build_d2d_extra_rc_model(wrapper_plan):
    return build_hbt_model(
        wrapper_plan,
        LIBRARY,
        resolve_hbt_config(os.environ),
        {
            "upper": ABC_DRV_CELL_UPPER,
            "bottom": ABC_DRV_CELL_BOTTOM,
        },
    )


def write_d2d_extra_rc_artifacts(wrapper_plan):
    model = build_d2d_extra_rc_model(wrapper_plan)
    write_json_file(D2D_EXTRA_RC_JSON, model)
    write_text(D2D_EXTRA_RC_TCL, render_hbt_tcl(model))
    assert os.path.isfile(D2D_EXTRA_RC_TCL), "Failed to create {}".format(D2D_EXTRA_RC_TCL)
    return model


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


def build_read_liberty_tcl(lib_files):
    macro_libs = {os.path.realpath(path) for path in DESIGN_MACRO_LIB_FILES}
    commands = []
    for path in lib_files:
        options = "-lib -ignore_miss_func" if os.path.realpath(path) in macro_libs else "-ignore_miss_func"
        commands.append("read_liberty {} {}".format(options, path))
    return "\n".join(commands)


def assert_verilog_readback(v_path, module_name):
    tcl = """
{read_lib_tcl}
read_verilog {v_path}
hierarchy -check -top {module_name}
""".format(
        read_lib_tcl=build_read_liberty_tcl(SYNTHESIS_2D_LIB_FILES),
        v_path=v_path,
        module_name=module_name,
    )
    run_yosys_script(tcl, "verilog readback ({})".format(module_name))


def assert_verilog_readback_with_libs(v_path, module_name, lib_files):
    tcl = """
{read_lib_tcl}
read_verilog {v_path}
hierarchy -check -top {module_name}
""".format(
        read_lib_tcl=build_read_liberty_tcl(lib_files),
        v_path=v_path,
        module_name=module_name,
    )
    run_yosys_script(tcl, "verilog readback ({})".format(module_name))


def emit_verilog_to_json(in_v, top_module_name, out_json, lib_files):
    tcl = """
{read_lib_tcl}
read_verilog {in_v}
hierarchy -check -top {top_module_name}
write_json {out_json}
""".format(
        read_lib_tcl=build_read_liberty_tcl(lib_files),
        in_v=in_v,
        top_module_name=top_module_name,
        out_json=out_json,
    )
    run_yosys_script(tcl, "genus verilog -> json ({})".format(top_module_name))
    assert os.path.exists(out_json), "GENUS_OUTPUT_JSON was not created: {}".format(out_json)


def load_inputs():
    for path in [
        WRAPPER_JSON,
        WRAPPER_V,
        WRAPPER_PLAN_JSON,
        CLOCK_PORT_MAP_JSON,
        CELL_MAPPING_PLAN_JSON,
        DESIGN_SDC_FILE,
    ]:
        assert os.path.isfile(path), "Required 06 input missing: {}".format(path)
    wrapper_design = load_design(WRAPPER_JSON)
    validate_design(wrapper_design)
    wrapper_plan = load_json_file(WRAPPER_PLAN_JSON)
    clock_port_map = load_json_file(CLOCK_PORT_MAP_JSON)
    cell_mapping_plan = load_json_file(CELL_MAPPING_PLAN_JSON)
    return wrapper_design, wrapper_plan, clock_port_map, cell_mapping_plan


def assert_wrapper_input_contract(wrapper_design, wrapper_plan, clock_port_map, cell_mapping_plan):
    assert SYNTH_MODE == "genus_homo", (
        "06 homogeneous Genus currently supports SYNTH_MODE=genus_homo only, got {}".format(SYNTH_MODE)
    )
    assert CELL_NAME_MAPPING_MODE == SUPPORTED_HOMO_MAPPING_MODE, (
        "06 homogeneous Genus requires CELL_NAME_MAPPING_MODE={}, got {}".format(
            SUPPORTED_HOMO_MAPPING_MODE, CELL_NAME_MAPPING_MODE
        )
    )
    assert cell_mapping_plan["mapping_mode"] == CELL_NAME_MAPPING_MODE, (
        "CELL_MAPPING_PLAN_JSON mapping_mode mismatch: {} != {}".format(
            cell_mapping_plan["mapping_mode"], CELL_NAME_MAPPING_MODE
        )
    )
    assert WRAPPER_TOP_MODULE_NAME in wrapper_design.modules, "Wrapper top missing: {}".format(WRAPPER_TOP_MODULE_NAME)
    assert UPPER_COARSE_MODULE_NAME in wrapper_design.modules, "Upper module missing: {}".format(UPPER_COARSE_MODULE_NAME)
    assert BOTTOM_COARSE_MODULE_NAME in wrapper_design.modules, "Bottom module missing: {}".format(BOTTOM_COARSE_MODULE_NAME)

    modules_plan = wrapper_plan["modules"]
    assert modules_plan["wrapper_top"] == WRAPPER_TOP_MODULE_NAME
    assert modules_plan["upper_module"] == UPPER_COARSE_MODULE_NAME
    assert modules_plan["bottom_module"] == BOTTOM_COARSE_MODULE_NAME
    assert modules_plan["upper_instance"] == WRAPPER_UPPER_INSTANCE_NAME
    assert modules_plan["bottom_instance"] == WRAPPER_BOTTOM_INSTANCE_NAME
    assert wrapper_plan["identity"]["design"] == DESIGN
    assert wrapper_plan["identity"]["library"] == LIBRARY
    assert wrapper_plan["identity"]["mapping_mode"] == CELL_NAME_MAPPING_MODE

    wrapper_top = wrapper_design.get_module(WRAPPER_TOP_MODULE_NAME)
    expected_cells = {WRAPPER_UPPER_INSTANCE_NAME, WRAPPER_BOTTOM_INSTANCE_NAME}
    assert set(wrapper_top.cells.keys()) == expected_cells, (
        "Wrapper top must contain only inst_upper/inst_bottom, got {}".format(sorted(wrapper_top.cells.keys()))
    )
    assert wrapper_top.cells[WRAPPER_UPPER_INSTANCE_NAME].type == UPPER_COARSE_MODULE_NAME
    assert wrapper_top.cells[WRAPPER_BOTTOM_INSTANCE_NAME].type == BOTTOM_COARSE_MODULE_NAME

    assert len(wrapper_plan["data_d2d_channels"]) == wrapper_plan["checks"]["data_d2d_count"]
    assert len(wrapper_plan["clock"]["clock_d2d_channels"]) == wrapper_plan["checks"]["clock_d2d_count"]
    assert clock_port_map["source_clock_port_name"] == wrapper_plan["clock"]["source_clock_port"]
    assert clock_port_map["source_clock_bit_label"] == wrapper_plan["clock"]["source_clock_bit_label"]

    d2d_netnames = {
        name
        for name, netname in wrapper_top.netnames.items()
        if netname.attributes.get("syn3d_channel_kind") in {"data_d2d", "clock_d2d"}
    }
    plan_d2d = {item["d2d_name"] for item in wrapper_plan["data_d2d_channels"]}
    plan_d2d.update(item["d2d_name"] for item in wrapper_plan["clock"]["clock_d2d_channels"])
    assert d2d_netnames == plan_d2d, (
        "Wrapper d2d netnames mismatch: json={} plan={}".format(sorted(d2d_netnames), sorted(plan_d2d))
    )

    for instance_name, module_name in [
        (WRAPPER_UPPER_INSTANCE_NAME, UPPER_COARSE_MODULE_NAME),
        (WRAPPER_BOTTOM_INSTANCE_NAME, BOTTOM_COARSE_MODULE_NAME),
    ]:
        cell = wrapper_top.cells[instance_name]
        module = wrapper_design.get_module(module_name)
        assert set(cell.connections.keys()) == set(module.ports.keys()), (
            "Wrapper instance {} connections do not match module ports".format(instance_name)
        )
        assert cell.port_directions == {name: port.direction for name, port in module.ports.items()}, (
            "Wrapper instance {} port_directions do not match module ports".format(instance_name)
        )
        for direction in cell.port_directions.values():
            assert direction in SUPPORTED_CELL_PIN_DIRECTIONS, (
                "Unsupported wrapper instance pin direction: {}".format(direction)
            )

    assert_no_multiple_wrapper_drivers(wrapper_top)
    assert_tier_cells_are_base_named(wrapper_design)


def assert_no_multiple_wrapper_drivers(wrapper_top):
    drivers = OrderedDict()

    def add_driver(bit, label):
        if not isinstance(bit, int):
            return
        drivers.setdefault(bit, []).append(label)

    for port in wrapper_top.ports.values():
        if port.direction == "input":
            for bit in port.bits:
                add_driver(bit, "wrapper_input:{}".format(port.name))
    for cell in wrapper_top.cells.values():
        for pin_name, bits in cell.connections.items():
            if cell.port_directions.get(pin_name) != "output":
                continue
            for bit in bits:
                add_driver(bit, "{}.{}".format(cell.name, pin_name))
    multiple = {bit: names for bit, names in drivers.items() if len(names) > 1}
    assert not multiple, "Wrapper top has multiple drivers per bit: {}".format(multiple)


def assert_tier_cells_are_base_named(wrapper_design):
    bad = []
    for module_name in [UPPER_COARSE_MODULE_NAME, BOTTOM_COARSE_MODULE_NAME]:
        module = wrapper_design.get_module(module_name)
        for cell in module.cells.values():
            if cell.type in wrapper_design.modules:
                continue
            if cell.type.endswith(UPPER_CELL_SUFFIX) or cell.type.endswith(BOTTOM_CELL_SUFFIX):
                bad.append("{}.{}:{}".format(module_name, cell.name, cell.type))
    assert not bad, "Tier leaf cells must be base-named before 06 homo Genus: {}".format(bad[:20])


def collect_leaf_cell_types(design):
    module_names = set(design.modules.keys())
    leaf_types = set()
    for module_name, module in design.modules.items():
        if module_name == WRAPPER_TOP_MODULE_NAME:
            continue
        for cell in module.cells.values():
            if cell.type not in module_names:
                leaf_types.add(cell.type)
    assert leaf_types, "No leaf cells found in wrapper design"
    return leaf_types


def scan_liberty_cell_names(lib_files):
    cell_names = set()
    for lib_path in lib_files:
        assert os.path.isfile(lib_path), "Liberty file missing: {}".format(lib_path)
        assert os.path.getsize(lib_path) > 0, "Liberty file is empty: {}".format(lib_path)
        text = strip_comments(read_text(lib_path))
        cell_names.update(LIBERTY_CELL_RE.findall(text))
    assert cell_names, "No liberty cell definitions parsed from {}".format(lib_files)
    return cell_names


def assert_homo_2d_lib_coverage(wrapper_design):
    assert os.path.isdir(SYNTHESIS_2D_PLATFORM_DIR), (
        "SYNTHESIS_2D_PLATFORM_DIR missing: {}".format(SYNTHESIS_2D_PLATFORM_DIR)
    )
    assert os.path.isdir(SYNTHESIS_2D_LIB_DIR), "SYNTHESIS_2D_LIB_DIR missing: {}".format(SYNTHESIS_2D_LIB_DIR)
    assert SYNTHESIS_2D_LIB_FILES, "SYNTHESIS_2D_LIB_FILES is empty"
    leaf_types = collect_leaf_cell_types(wrapper_design)
    lib_cells = scan_liberty_cell_names(SYNTHESIS_2D_LIB_FILES)
    missing = sorted(leaf_types - lib_cells)
    assert not missing, (
        "2D liberty does not cover wrapper leaf cell types. Missing count={} examples={}".format(
            len(missing), missing[:50]
        )
    )
    checks = OrderedDict(
        [
            ("configured_platform_dir", SYNTHESIS_2D_PLATFORM_DIR),
            ("configured_lib_dir", SYNTHESIS_2D_LIB_DIR),
            ("configured_lib_files", list(SYNTHESIS_2D_LIB_FILES)),
            ("configured_lib_file_count", len(SYNTHESIS_2D_LIB_FILES)),
            ("leaf_cell_count", len(leaf_types)),
            ("lib_cell_count", len(lib_cells)),
            ("missing_leaf_cell_count", len(missing)),
            ("missing_leaf_cells", missing),
        ]
    )
    return checks, lib_cells


def parse_design_sdc_vars(path):
    vars_by_name = {}
    for line in read_text(path).splitlines():
        match = SDC_SET_RE.match(line)
        if not match:
            continue
        name = match.group(1)
        value = match.group(2).strip()
        if value.startswith("[") or value.startswith("$"):
            continue
        vars_by_name[name] = value
    for required in ["clk_name", "clk_port_name", "clk_period", "clk_io_pct"]:
        assert required in vars_by_name, "Required SDC variable {} missing from {}".format(required, path)
    return vars_by_name


def format_tcl_number(value):
    value = float(value)
    rounded = round(value)
    if abs(value - rounded) < 1e-9:
        return str(int(rounded))
    return "{:.12g}".format(value)


def safe_tcl_var_suffix(name):
    suffix = re.sub(r"[^A-Za-z0-9_]+", "_", str(name)).strip("_")
    assert suffix, "Cannot build Tcl suffix from {!r}".format(name)
    if suffix[0].isdigit():
        suffix = "n_" + suffix
    return suffix


def clock_d2d_pin_path(channel):
    consumer_tier = channel["consumer_tier"]
    if consumer_tier == "upper":
        instance = WRAPPER_UPPER_INSTANCE_NAME
    elif consumer_tier == "bottom":
        instance = WRAPPER_BOTTOM_INSTANCE_NAME
    else:
        raise AssertionError("Unexpected clock d2d consumer tier: {}".format(channel))
    return "{}/{}".format(instance, channel["consumer_port"])


def write_generated_clock_sdc_lines(clock_d2d_channels):
    lines = []
    for index, channel in enumerate(clock_d2d_channels):
        d2d_name = channel["d2d_name"]
        suffix = safe_tcl_var_suffix("{}_{}".format(index, d2d_name))
        pin_path = clock_d2d_pin_path(channel)
        generated_name = "${{clk_name}}_{}".format(safe_tcl_var_suffix(d2d_name))
        lines.extend(
            [
                "",
                "# Generated clock crossing for {}.".format(d2d_name),
                "set clock_d2d_pin_{} [get_pins {}]".format(suffix, tcl_quote(pin_path)),
                'if {[llength $clock_d2d_pin_%s] != 1} { error "Expected exactly one clock d2d pin %s" }'
                % (suffix, pin_path),
                "create_generated_clock -name {} -source $clk_port -divide_by 1 $clock_d2d_pin_{}".format(
                    generated_name, suffix
                ),
            ]
        )
    return lines


def write_clock_sdc_lines(vars_by_name, clock_port, clock_d2d_channels=None):
    clock_d2d_channels = list(clock_d2d_channels or [])
    clock_period_ps = float(SDC_CLK_PERIOD_PS)
    assert clock_period_ps > 0, "SDC_CLK_PERIOD_PS must be positive, got {}".format(SDC_CLK_PERIOD_PS)
    return [
        "# Input clk_period {} {} normalized to {} ps for Genus.".format(
            SDC_CLK_PERIOD_RAW, SDC_CLK_PERIOD_UNIT, format_tcl_number(clock_period_ps)
        ),
        "set_units -time 1ps",
        "set_units -capacitance 1fF",
        "set clk_name {}".format(vars_by_name["clk_name"]),
        "set clk_port_name {}".format(clock_port),
        "set clk_period {}".format(format_tcl_number(clock_period_ps)),
        "set clk_io_pct {}".format(vars_by_name["clk_io_pct"]),
        "set clk_port [get_ports $clk_port_name]",
        'if {[llength $clk_port] != 1} { error "Expected exactly one clock port named $clk_port_name" }',
        "create_clock -name $clk_name -period $clk_period $clk_port",
        *write_generated_clock_sdc_lines(clock_d2d_channels),
        "set non_clock_inputs [all_inputs -no_clocks]",
        "set_input_delay [expr $clk_period * $clk_io_pct] -clock $clk_name $non_clock_inputs",
        "set_output_delay [expr $clk_period * $clk_io_pct] -clock $clk_name [all_outputs]",
    ]


def sdc_time_unit_to_ps_factor(unit_value, unit_name):
    value = float(unit_value)
    unit = unit_name.lower()
    if unit == "ps":
        return value
    if unit == "ns":
        return value * 1000.0
    raise AssertionError("Unsupported SDC time unit: {}{}".format(unit_value, unit_name))


def assert_sdc_clock_period_ps(path, expected_period_ps):
    text = read_text(path)
    vars_by_name = {}
    time_factor_ps = None
    clock_period = None
    for line in text.splitlines():
        set_match = SDC_SET_RE.match(line)
        if set_match:
            vars_by_name[set_match.group(1)] = set_match.group(2).strip()
        unit_match = SDC_SET_UNITS_TIME_RE.match(line.strip())
        if unit_match:
            time_factor_ps = sdc_time_unit_to_ps_factor(unit_match.group(1), unit_match.group(2))
            continue
        clock_match = SDC_CREATE_CLOCK_PERIOD_RE.search(line)
        if clock_match:
            assert clock_period is None, "Multiple create_clock -period lines found in {}".format(path)
            period_token = clock_match.group(1)
            if period_token.startswith("$"):
                period_var = period_token[1:]
                assert period_var in vars_by_name, (
                    "create_clock period variable {} not defined before use in {}".format(period_token, path)
                )
                period_token = vars_by_name[period_var]
            clock_period = float(period_token)
    assert time_factor_ps is not None, "SDC missing explicit set_units -time: {}".format(path)
    assert clock_period is not None, "SDC missing create_clock -period: {}".format(path)
    actual_period_ps = clock_period * time_factor_ps
    expected = float(expected_period_ps)
    assert abs(actual_period_ps - expected) < 1e-6, (
        "Clock period mismatch in {}: actual {} ps, expected {} ps".format(
            path, actual_period_ps, expected
        )
    )
    return OrderedDict(
        [
            ("path", path),
            ("time_unit_ps", time_factor_ps),
            ("clock_period_in_sdc_units", clock_period),
            ("clock_period_ps", actual_period_ps),
            ("expected_clock_period_ps", expected),
        ]
    )


def write_genus_sdc(wrapper_plan):
    vars_by_name = parse_design_sdc_vars(DESIGN_SDC_FILE)
    clock_port = wrapper_plan["clock"]["source_clock_port"]
    assert vars_by_name["clk_port_name"] == clock_port, (
        "DESIGN_SDC_FILE clk_port_name {} != wrapper clock port {}".format(
            vars_by_name["clk_port_name"], clock_port
        )
    )
    lines = [
        "# Generated by per-tier synthesis step 06.",
        *write_clock_sdc_lines(vars_by_name, clock_port, wrapper_plan["clock"]["clock_d2d_channels"]),
    ]
    text = "\n".join(lines) + "\n"
    write_text(GENUS_SDC, text)
    assert "create_clock" in read_text(GENUS_SDC), "GENUS_SDC missing create_clock after write"
    input_sdc_clock = assert_sdc_clock_period_ps(GENUS_SDC, SDC_CLK_PERIOD_PS)
    return OrderedDict(
        [
            ("clock_name", vars_by_name["clk_name"]),
            ("clock_port", clock_port),
            ("clock_period_raw", SDC_CLK_PERIOD_RAW),
            ("clock_period_unit", SDC_CLK_PERIOD_UNIT),
            ("clock_period_ps", SDC_CLK_PERIOD_PS),
            ("clock_io_pct", vars_by_name["clk_io_pct"]),
            ("input_sdc_clock", input_sdc_clock),
        ]
    )


def report_paths():
    prefix = WRAPPER_TOP_MODULE_NAME
    return OrderedDict(
        [
            ("check_design", os.path.join(GENUS_REPORT_DIR, "{}_check_design.rpt".format(prefix))),
            ("timing_intent", os.path.join(GENUS_REPORT_DIR, "{}_check_timing_intent.rpt".format(prefix))),
            ("pre_timing", os.path.join(GENUS_REPORT_DIR, "{}_pre_timing.rpt".format(prefix))),
            ("messages", os.path.join(GENUS_REPORT_DIR, "{}_messages.rpt".format(prefix))),
            ("gates", os.path.join(GENUS_REPORT_DIR, "{}_gates.rpt".format(prefix))),
            ("power", os.path.join(GENUS_REPORT_DIR, "{}_power.rpt".format(prefix))),
            ("area", os.path.join(GENUS_REPORT_DIR, "{}_area.rpt".format(prefix))),
            ("timing", os.path.join(GENUS_REPORT_DIR, "{}_timing.rpt".format(prefix))),
            ("ungroup", os.path.join(GENUS_REPORT_DIR, "{}_ungroup_modules.rpt".format(prefix))),
            ("upper_boundary", os.path.join(GENUS_REPORT_DIR, "{}_inst_upper_boundary_opt.rpt".format(prefix))),
            ("bottom_boundary", os.path.join(GENUS_REPORT_DIR, "{}_inst_bottom_boundary_opt.rpt".format(prefix))),
        ]
    )


def collect_protected_top_names(wrapper_design, wrapper_plan):
    wrapper_top = wrapper_design.get_module(WRAPPER_TOP_MODULE_NAME)
    names = set(wrapper_top.ports.keys())
    names.update(item["d2d_name"] for item in wrapper_plan["data_d2d_channels"])
    names.update(item["d2d_name"] for item in wrapper_plan["clock"]["clock_d2d_channels"])
    return sorted(names)


def write_genus_tcl(wrapper_design, wrapper_plan):
    reports = report_paths()
    protected_top_names = collect_protected_top_names(wrapper_design, wrapper_plan)
    tcl = """# Generated by per-tier synthesis step 06.
set_db max_cpus_per_server {max_cpus}
set_db super_thread_servers "localhost"
set_db hdl_flatten_complex_port true
set_db hdl_record_naming_style %s_%s
set_db auto_ungroup both

set lib_list [list {lib_files}]
set link_library $lib_list
set target_library $lib_list
set_db library $lib_list

set in_v {in_v}
set in_sdc {in_sdc}
set out_v {out_v}
set out_sdc {out_sdc}
set report_dir {report_dir}
set db_dir {db_dir}
set d2d_extra_rc_tcl {d2d_extra_rc_tcl}

foreach d [list $report_dir $db_dir] {{
  if {{![file exists $d]}} {{
    file mkdir $d
  }}
}}

read_hdl -sv $in_v
elaborate {wrapper_top}
init_design
read_sdc $in_sdc

{constant_tie_configuration}

set upper_mod [get_db modules {upper_module}]
set bottom_mod [get_db modules {bottom_module}]
set upper_hinst [get_db hinsts {upper_instance}]
set bottom_hinst [get_db hinsts {bottom_instance}]

if {{[llength $upper_mod] != 1}} {{ error "Unable to resolve upper module {upper_module}" }}
if {{[llength $bottom_mod] != 1}} {{ error "Unable to resolve bottom module {bottom_module}" }}
if {{[llength $upper_hinst] != 1}} {{ error "Unable to resolve upper hinst {upper_instance}" }}
if {{[llength $bottom_hinst] != 1}} {{ error "Unable to resolve bottom hinst {bottom_instance}" }}

set_db / .boundary_opto false
set_db / .boundary_optimize_invert_hpins false
set_db / .boundary_optimize_feedthrough_hpins false
set_db $upper_mod .ungroup_ok false
set_db $bottom_mod .ungroup_ok false
set_db $upper_mod .boundary_opto strict_no
set_db $bottom_mod .boundary_opto strict_no
set_db $upper_mod .boundary_optimize_invert_hpins false
set_db $bottom_mod .boundary_optimize_invert_hpins false
set_db $upper_mod .boundary_optimize_feedthrough_hpins false
set_db $bottom_mod .boundary_optimize_feedthrough_hpins false
catch {{ set_db $upper_hinst .ungroup_ok false }}
catch {{ set_db $bottom_hinst .ungroup_ok false }}

set internal_design_hinsts [get_db hinsts -if {{.module.name =~ _*}}]
puts "SYN3D_INTERNAL_DESIGN_HINST_COUNT=[llength $internal_design_hinsts]"
if {{[llength $internal_design_hinsts] > 0}} {{
  ungroup $internal_design_hinsts
}}

set protected_top_name_count 0
set protected_top_object_count 0
foreach one_name [list {protected_top_names}] {{
  incr protected_top_name_count
  set net_objs [get_db nets $one_name]
  if {{[llength $net_objs] > 0}} {{
    incr protected_top_object_count [llength $net_objs]
    catch {{ set_db $net_objs .dont_touch true }}
  }}
}}
puts "SYN3D_PROTECTED_TOP_NAME_COUNT=$protected_top_name_count"
puts "SYN3D_PROTECTED_TOP_OBJECT_COUNT=$protected_top_object_count"
puts "SYN3D_AUTO_UNGROUP=[get_db / .auto_ungroup]"
puts "SYN3D_UPPER_UNGROUP_OK=[get_db $upper_mod .ungroup_ok]"
puts "SYN3D_BOTTOM_UNGROUP_OK=[get_db $bottom_mod .ungroup_ok]"
puts "SYN3D_UPPER_BOUNDARY_OPTO=[get_db $upper_mod .boundary_opto]"
puts "SYN3D_BOTTOM_BOUNDARY_OPTO=[get_db $bottom_mod .boundary_opto]"
source $d2d_extra_rc_tcl

check_design -unresolved > {check_design}
check_timing_intent -verbose > {timing_intent}
report_timing > {pre_timing}

# syn_generic
# set_db syn_generic_effort low
# syn_generic
# write_reports -directory $report_dir -tag generic
# write_db [file join $db_dir {wrapper_top}_generic.db]
#
# syn_map
# set_db syn_map_effort low
# syn_map
# write_reports -directory $report_dir -tag map
# write_db [file join $db_dir {wrapper_top}_map.db]
#
# syn_opt
# set_db syn_opt_effort low
# syn_opt
# 2026-07-08: minimize homogeneous Genus intervention; run only low-effort incremental syn_opt.
syn_opt -incr -effort low
write_reports -directory $report_dir -tag final
write_db [file join $db_dir {wrapper_top}_opt.db]

# Database transformations can invalidate previously cached object handles even
# when the corresponding hierarchical instances are preserved.  Resolve the
# two tier instances again before issuing object-specific reports.
set upper_hinst [get_db hinsts {upper_instance}]
set bottom_hinst [get_db hinsts {bottom_instance}]
if {{[llength $upper_hinst] != 1}} {{ error "Unable to resolve post-synthesis upper hinst {upper_instance}" }}
if {{[llength $bottom_hinst] != 1}} {{ error "Unable to resolve post-synthesis bottom hinst {bottom_instance}" }}

report_ungroup_modules > {ungroup}
report_boundary_opt $upper_hinst > {upper_boundary}
report_boundary_opt $bottom_hinst > {bottom_boundary}
report_messages > {messages}
report_gates > {gates}
report_power > {power}
report_area > {area}
report_timing > {timing}

write_hdl > $out_v
write_sdc > $out_sdc
exit
""".format(
        max_cpus=DEFAULT_MAX_CPUS,
        lib_files=format_tcl_list(SYNTHESIS_2D_LIB_FILES),
        in_v=tcl_quote(GENUS_INPUT_V),
        in_sdc=tcl_quote(GENUS_SDC),
        out_v=tcl_quote(GENUS_OUTPUT_V),
        out_sdc=tcl_quote(GENUS_POST_SDC),
        report_dir=tcl_quote(GENUS_REPORT_DIR),
        db_dir=tcl_quote(GENUS_DB_DIR),
        d2d_extra_rc_tcl=tcl_quote(D2D_EXTRA_RC_TCL),
        wrapper_top=WRAPPER_TOP_MODULE_NAME,
        upper_module=UPPER_COARSE_MODULE_NAME,
        bottom_module=BOTTOM_COARSE_MODULE_NAME,
        upper_instance=WRAPPER_UPPER_INSTANCE_NAME,
        bottom_instance=WRAPPER_BOTTOM_INSTANCE_NAME,
        protected_top_names=format_tcl_list(protected_top_names),
        constant_tie_configuration=render_constant_tie_configuration(homogeneous_constant_tie_specs()),
        **{key: tcl_quote(value) for key, value in reports.items()}
    )
    write_text(GENUS_TCL, tcl)
    loaded = read_text(GENUS_TCL)
    assert "ungroup -all -flatten" not in loaded, "06 Tcl must not flatten"
    assert "set_db auto_ungroup both" in loaded, "06 Tcl must allow selective internal ungroup"
    assert "ungroup $internal_design_hinsts" in loaded, "06 Tcl missing explicit internal hinst ungroup"
    assert "set_db $upper_mod .boundary_opto strict_no" in loaded, "06 Tcl missing upper boundary guard"
    assert "source $d2d_extra_rc_tcl" in loaded, "06 Tcl missing d2d extra RC source"
    assert "SYN3D_CONSTANT_TIE_MAPPING=duplicate" in loaded, "06 Tcl missing duplicate constant tie mapping"
    assert "Unable to resolve post-synthesis upper hinst" in loaded, "06 Tcl must refresh post-synthesis hinsts"
    assert "Unable to resolve post-synthesis bottom hinst" in loaded, "06 Tcl must refresh post-synthesis hinsts"
    return reports


def prepare_genus_inputs(wrapper_design, wrapper_plan):
    os.makedirs(GENUS_TMP_DIR, exist_ok=True)
    os.makedirs(GENUS_REPORT_DIR, exist_ok=True)
    os.makedirs(GENUS_DB_DIR, exist_ok=True)
    shutil.copyfile(WRAPPER_V, GENUS_INPUT_V)
    assert os.path.isfile(GENUS_INPUT_V), "GENUS_INPUT_V copy failed: {}".format(GENUS_INPUT_V)
    assert_verilog_readback(GENUS_INPUT_V, WRAPPER_TOP_MODULE_NAME)
    timing_constraints = write_genus_sdc(wrapper_plan)
    d2d_extra_rc_model = write_d2d_extra_rc_artifacts(wrapper_plan)
    reports = write_genus_tcl(wrapper_design, wrapper_plan)
    return timing_constraints, d2d_extra_rc_model, reports


def run_genus():
    assert os.path.exists(GENUS), "Genus not found: {}".format(GENUS)
    cmd = [
        GENUS,
        "-no_gui",
        "-batch",
        "-abort_on_error",
        "-overwrite",
        "-log",
        GENUS_LOG_PREFIX,
        "-files",
        GENUS_TCL,
    ]
    result = subprocess.run(cmd, check=False)
    return result.returncode, cmd


def assert_genus_output_files(reports):
    required = [GENUS_OUTPUT_V, GENUS_POST_SDC, GENUS_LOG_PREFIX + ".log", GENUS_LOG_PREFIX + ".cmd"]
    required.extend(reports.values())
    for path in required:
        assert os.path.isfile(path), "Genus expected output missing: {}".format(path)
        if path == reports["ungroup"]:
            continue
        assert os.path.getsize(path) > 0, "Genus expected output is empty: {}".format(path)
    db_files = [
        os.path.join(GENUS_DB_DIR, "{}_opt.db".format(WRAPPER_TOP_MODULE_NAME)),
    ]
    for path in db_files:
        assert os.path.isfile(path), "Genus DB output missing: {}".format(path)
    return db_files


def assert_no_design_submodule_boundaries(output_design, module_name, leaf_module_types):
    reachable = collect_reachable_module_names(output_design, module_name, leaf_module_types)
    residual = [name for name in reachable if name != module_name]
    assert not residual, (
        "{} still has coarse-internal design submodule boundaries after Genus selective ungroup: {}".format(
            module_name, residual[:20]
        )
    )
    return OrderedDict(
        [
            ("module", module_name),
            ("reachable_design_module_count", len(reachable)),
            ("residual_design_submodule_count", len(residual)),
            ("residual_design_submodules", residual),
        ]
    )


def assert_hierarchical_output_contract(output_design, wrapper_plan, leaf_module_types):
    validate_design(output_design)
    assert WRAPPER_TOP_MODULE_NAME in output_design.modules, "Genus output missing wrapper top"
    assert UPPER_COARSE_MODULE_NAME in output_design.modules, "Genus output missing upper module"
    assert BOTTOM_COARSE_MODULE_NAME in output_design.modules, "Genus output missing bottom module"

    top = output_design.get_module(WRAPPER_TOP_MODULE_NAME)
    expected_cells = {WRAPPER_UPPER_INSTANCE_NAME, WRAPPER_BOTTOM_INSTANCE_NAME}
    assert set(top.cells.keys()) == expected_cells, (
        "Genus output wrapper top must contain only inst_upper/inst_bottom, got {}".format(sorted(top.cells.keys()))
    )
    assert top.cells[WRAPPER_UPPER_INSTANCE_NAME].type == UPPER_COARSE_MODULE_NAME
    assert top.cells[WRAPPER_BOTTOM_INSTANCE_NAME].type == BOTTOM_COARSE_MODULE_NAME

    for instance_name, module_name in [
        (WRAPPER_UPPER_INSTANCE_NAME, UPPER_COARSE_MODULE_NAME),
        (WRAPPER_BOTTOM_INSTANCE_NAME, BOTTOM_COARSE_MODULE_NAME),
    ]:
        cell = top.cells[instance_name]
        module = output_design.get_module(module_name)
        assert set(cell.connections.keys()) == set(module.ports.keys()), (
            "Output instance {} connections do not match module ports".format(instance_name)
        )

    for channel in wrapper_plan["data_d2d_channels"]:
        name = channel["d2d_name"]
        assert name in top.netnames, "Output wrapper top lost data d2d netname: {}".format(name)
    for channel in wrapper_plan["clock"]["clock_d2d_channels"]:
        name = channel["d2d_name"]
        assert name in top.netnames, "Output wrapper top lost clock d2d netname: {}".format(name)

    upper_flatten = assert_no_design_submodule_boundaries(output_design, UPPER_COARSE_MODULE_NAME, leaf_module_types)
    bottom_flatten = assert_no_design_submodule_boundaries(output_design, BOTTOM_COARSE_MODULE_NAME, leaf_module_types)
    constant_checks = assert_no_direct_constants_in_synthesized_design(output_design, leaf_module_types)

    return OrderedDict(
        [
            ("top_cell_count", len(top.cells)),
            ("top_instance_names", sorted(top.cells.keys())),
            ("top_leaf_cell_count", 0),
            ("upper_internal_boundary", upper_flatten),
            ("bottom_internal_boundary", bottom_flatten),
            ("data_d2d_count", len(wrapper_plan["data_d2d_channels"])),
            ("clock_d2d_count", len(wrapper_plan["clock"]["clock_d2d_channels"])),
            ("direct_constants", constant_checks),
        ]
    )


def assert_no_direct_constants_in_synthesized_design(design, leaf_module_types):
    cell_pin_constants = []
    output_port_constants = []
    for module_name in collect_reachable_module_names(
        design, WRAPPER_TOP_MODULE_NAME, leaf_module_types
    ):
        module = design.get_module(module_name)
        for port_name, port in module.ports.items():
            if port.direction != "output":
                continue
            for bit_index, bit in enumerate(port.bits):
                if not isinstance(bit, int):
                    output_port_constants.append((module_name, port_name, bit_index, bit))
        for cell_name, cell in module.cells.items():
            for pin_name, bits in cell.connections.items():
                for bit_index, bit in enumerate(bits):
                    if not isinstance(bit, int):
                        cell_pin_constants.append((module_name, cell_name, pin_name, bit_index, bit))
    assert not cell_pin_constants, (
        "Genus output retains direct constants on cell pins; duplicate tie mapping failed: {}".format(
            cell_pin_constants[:20]
        )
    )
    assert not output_port_constants, (
        "Genus output retains direct constants on module outputs; duplicate tie mapping failed: {}".format(
            output_port_constants[:20]
        )
    )
    return OrderedDict(
        [
            ("cell_pin_constant_count", 0),
            ("output_port_constant_count", 0),
            ("mapping_mode", "duplicate"),
        ]
    )


def parse_dangerous_messages(paths):
    hits = []

    def append_hit(path, line_no, pattern, text):
        hits.append(
            OrderedDict(
                [
                    ("path", path),
                    ("line", line_no),
                    ("pattern", pattern),
                    ("text", text[:240]),
                ]
            )
        )

    for path in paths:
        if not path or not os.path.isfile(path):
            continue
        for line_no, line in enumerate(read_text(path).splitlines(), 1):
            stripped = line.strip()
            if not stripped:
                continue
            lowered = stripped.lower()

            summary_match = GENUS_SEVERITY_SUMMARY_RE.search(stripped)
            if summary_match:
                error_count = int(summary_match.group(1))
                fatal_count = int(summary_match.group(2))
                if error_count or fatal_count:
                    append_hit(path, line_no, "Error/Fatal summary", stripped)
                continue

            table_match = GENUS_MESSAGE_TABLE_RE.match(stripped)
            if table_match:
                severity = table_match.group(1)
                count = int(table_match.group(2))
                if count:
                    append_hit(path, line_no, "{} message count".format(severity), stripped)
                continue

            if GENUS_EXPLICIT_SEVERITY_RE.match(stripped):
                append_hit(path, line_no, "explicit Error/Fatal", stripped)
                continue

            if "check_design -unresolved" in lowered:
                continue
            if "no unresolved references" in lowered:
                continue
            if stripped == "Unresolved References & Empty Modules":
                continue
            if "unresolved" in lowered:
                append_hit(path, line_no, "unresolved", stripped)
                continue

            count_match = GENUS_REPORT_COUNT_RE.match(stripped)
            if count_match:
                label = count_match.group("label").strip().lower()
                count = int(count_match.group("count"))
                if label == "nets with multiple drivers":
                    if count:
                        append_hit(path, line_no, "multiple drivers", stripped)
                    continue
                if label == "loop-breaking cells for combinational feedback":
                    if count:
                        append_hit(path, line_no, "combinational loop", stripped)
                    continue

            if "multiple driver" in lowered or "multiple-driver" in lowered:
                append_hit(path, line_no, "multiple drivers", stripped)
                continue
            if "cdn_loop_breaker" in lowered or "combinational loop" in lowered:
                append_hit(path, line_no, "combinational loop", stripped)
                continue
            if "cannot find any clocks" in lowered:
                append_hit(path, line_no, "missing clock", stripped)
                continue
            if "no clock" in lowered and "no clocks" not in lowered:
                append_hit(path, line_no, "missing clock", stripped)
                continue
            if "no path" in lowered and "no paths" not in lowered:
                append_hit(path, line_no, "missing path", stripped)
                continue
    return hits


def parse_boundary_report(path):
    text = read_text(path)
    lowered = text.lower()
    has_change = "boundary change" in lowered
    no_boundary = "no boundary optimization done" in lowered or "no boundary optimization" in lowered
    return OrderedDict(
        [
            ("path", path),
            ("no_boundary_optimization", no_boundary and not has_change),
            ("has_boundary_change", has_change),
            ("preview", [line for line in text.splitlines()[:20]]),
        ]
    )


def parse_ungroup_report(path):
    text = read_text(path)
    interesting = []
    for line in text.splitlines():
        if UPPER_COARSE_MODULE_NAME in line or BOTTOM_COARSE_MODULE_NAME in line:
            interesting.append(line.strip())
    lowered = "\n".join(interesting).lower()
    ungrouped = any(word in lowered for word in ["ungrouped", "true", "yes"])
    return OrderedDict(
        [
            ("path", path),
            ("tier_module_lines", interesting),
            ("tier_modules_ungrouped", ungrouped),
        ]
    )


def analyze_unclocked_sequential_sources(path, wrapper_design, wrapper_plan):
    lines = read_text(path).splitlines()
    summary_counts = []
    records = []
    for line in lines:
        stripped = line.strip()
        count_match = GENUS_REPORT_COUNT_RE.match(stripped)
        if count_match and count_match.group("label").strip().lower() == (
            "sequential clock pins without clock waveform"
        ):
            summary_counts.append(int(count_match.group("count")))
        source_match = GENUS_UNCLOCKED_SOURCE_RE.match(stripped)
        if source_match:
            records.append(source_match.groupdict())

    assert len(summary_counts) == 1, "Expected one unclocked sequential-pin summary in {}".format(path)
    expected_count = summary_counts[0]
    assert len(records) == expected_count, (
        "Verbose timing-intent report lists {} unclocked sources but summary reports {}".format(
            len(records), expected_count
        )
    )

    top = wrapper_design.get_module(WRAPPER_TOP_MODULE_NAME)
    constrained_clock_port = wrapper_plan["clock"]["source_clock_port"]
    source_counts = OrderedDict()
    for record in records:
        prefix = WRAPPER_TOP_MODULE_NAME + "/"
        assert record["source"].startswith(prefix), (
            "Unclocked sequential pin is not driven by a wrapper primary input: {}".format(record)
        )
        source_name = record["source"][len(prefix) :]
        base_name = re.sub(r"\[[0-9]+\]$", "", source_name)
        assert base_name in top.ports, "Unclocked source port is absent from wrapper interface: {}".format(record)
        assert top.ports[base_name].direction == "input", (
            "Unclocked sequential source is not a primary input: {}".format(record)
        )
        assert base_name != constrained_clock_port, (
            "Configured source clock lost its waveform during Genus synthesis: {}".format(record)
        )
        source_counts[source_name] = source_counts.get(source_name, 0) + 1

    return OrderedDict(
        [
            ("pin_count", len(records)),
            ("source_port_counts", source_counts),
            ("classification", "original_unconstrained_primary_inputs"),
        ]
    )


def analyze_reports(reports, wrapper_design, wrapper_plan):
    log_path = GENUS_LOG_PREFIX + ".log"
    dangerous = parse_dangerous_messages(
        [log_path, reports["messages"], reports["check_design"]]
    )
    timing_dangerous = parse_dangerous_messages([reports["timing_intent"]])
    timing_dangerous = [
        hit
        for hit in timing_dangerous
        if not (
            hit["pattern"] == "missing clock"
            and "have no clock waveform driving them" in hit["text"].lower()
        )
    ]
    dangerous.extend(timing_dangerous)
    unclocked_sources = analyze_unclocked_sequential_sources(
        reports["timing_intent"], wrapper_design, wrapper_plan
    )
    post_sdc_clock = assert_sdc_clock_period_ps(GENUS_POST_SDC, SDC_CLK_PERIOD_PS)
    upper_boundary = parse_boundary_report(reports["upper_boundary"])
    bottom_boundary = parse_boundary_report(reports["bottom_boundary"])
    ungroup = parse_ungroup_report(reports["ungroup"])
    assert not dangerous, "Dangerous Genus log/report patterns found: {}".format(dangerous[:10])
    assert upper_boundary["no_boundary_optimization"], "Upper boundary optimization detected or unproven"
    assert bottom_boundary["no_boundary_optimization"], "Bottom boundary optimization detected or unproven"
    assert not ungroup["tier_modules_ungrouped"], "Tier modules appear ungrouped: {}".format(
        ungroup["tier_module_lines"]
    )
    return OrderedDict(
        [
            ("dangerous_messages", dangerous),
            ("dangerous_log_pattern_count", len(dangerous)),
            ("post_sdc_clock", post_sdc_clock),
            ("unclocked_sequential_sources", unclocked_sources),
            ("upper_boundary", upper_boundary),
            ("bottom_boundary", bottom_boundary),
            ("ungroup", ungroup),
        ]
    )


def build_genus_plan(
    liberty_checks,
    timing_constraints,
    d2d_extra_rc_model,
    reports,
    db_files,
    genus_return_code,
    genus_cmd,
    output_checks,
    report_checks,
):
    return OrderedDict(
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
                        ("wrapper_json", WRAPPER_JSON),
                        ("wrapper_v", WRAPPER_V),
                        ("wrapper_plan_json", WRAPPER_PLAN_JSON),
                        ("design_sdc", DESIGN_SDC_FILE),
                        ("synthesis_2d_platform_dir", SYNTHESIS_2D_PLATFORM_DIR),
                        ("synthesis_2d_lib_dir", SYNTHESIS_2D_LIB_DIR),
                        ("synthesis_2d_lib_files", list(SYNTHESIS_2D_LIB_FILES)),
                    ]
                ),
            ),
            (
                "outputs",
                OrderedDict(
                    [
                        ("genus_input_v", GENUS_INPUT_V),
                        ("genus_sdc", GENUS_SDC),
                        ("genus_tcl", GENUS_TCL),
                        ("d2d_extra_rc_tcl", D2D_EXTRA_RC_TCL),
                        ("d2d_extra_rc_json", D2D_EXTRA_RC_JSON),
                        ("genus_output_v", GENUS_OUTPUT_V),
                        ("genus_output_json", GENUS_OUTPUT_JSON),
                        ("genus_post_sdc", GENUS_POST_SDC),
                        ("genus_plan_json", GENUS_PLAN_JSON),
                        ("log_prefix", GENUS_LOG_PREFIX),
                        ("report_dir", GENUS_REPORT_DIR),
                        ("db_dir", GENUS_DB_DIR),
                        ("db_files", db_files),
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
            (
                "synthesis_strategy",
                OrderedDict(
                    [
                        ("name", "homogeneous_keep_boundary"),
                        ("auto_ungroup", "both"),
                        ("kept_boundaries", [UPPER_COARSE_MODULE_NAME, BOTTOM_COARSE_MODULE_NAME]),
                        ("boundary_settings_applied", True),
                        ("timing_constraints", timing_constraints),
                        ("hbt_model", d2d_extra_rc_model),
                    ]
                ),
            ),
            ("liberty_checks", liberty_checks),
            ("reports", reports),
            (
                "checks",
                OrderedDict(
                    [
                        ("genus_return_code", genus_return_code),
                        ("genus_cmd", genus_cmd),
                        ("output", output_checks),
                        ("report", report_checks),
                        ("unsupported_count", 0),
                    ]
                ),
            ),
        ]
    )


def assert_genus_plan_matches_outputs(plan):
    assert plan["outputs"]["d2d_extra_rc_tcl"] == D2D_EXTRA_RC_TCL
    assert os.path.isfile(plan["outputs"]["d2d_extra_rc_tcl"])
    assert plan["outputs"]["d2d_extra_rc_json"] == D2D_EXTRA_RC_JSON
    assert os.path.isfile(plan["outputs"]["d2d_extra_rc_json"])
    assert plan["outputs"]["genus_output_v"] == GENUS_OUTPUT_V
    assert os.path.isfile(plan["outputs"]["genus_output_v"])
    assert plan["outputs"]["genus_output_json"] == GENUS_OUTPUT_JSON
    assert os.path.isfile(plan["outputs"]["genus_output_json"])
    assert plan["checks"]["genus_return_code"] == 0
    assert plan["checks"]["unsupported_count"] == 0
    assert plan["liberty_checks"]["missing_leaf_cell_count"] == 0
    assert plan["checks"]["report"]["dangerous_log_pattern_count"] == 0


def run_homogeneous_genus():
    wrapper_design, wrapper_plan, clock_port_map, cell_mapping_plan = load_inputs()
    assert_wrapper_input_contract(wrapper_design, wrapper_plan, clock_port_map, cell_mapping_plan)
    liberty_checks, lib_cells = assert_homo_2d_lib_coverage(wrapper_design)
    timing_constraints, d2d_extra_rc_model, reports = prepare_genus_inputs(wrapper_design, wrapper_plan)

    print("[06] running Genus on wrapper {} ...".format(WRAPPER_TOP_MODULE_NAME))
    genus_return_code, genus_cmd = run_genus()
    assert genus_return_code == 0, "Genus failed with exit code {}".format(genus_return_code)
    db_files = assert_genus_output_files(reports)

    emit_verilog_to_json(GENUS_OUTPUT_V, WRAPPER_TOP_MODULE_NAME, GENUS_OUTPUT_JSON, SYNTHESIS_2D_LIB_FILES)
    output_design = load_design(GENUS_OUTPUT_JSON)
    normalized_ports = normalize_genus_primary_interface(output_design, wrapper_design, GENUS_OUTPUT_JSON)
    output_checks = assert_hierarchical_output_contract(output_design, wrapper_plan, lib_cells)
    output_checks["normalized_primary_port_count"] = len(normalized_ports)
    output_checks["normalized_primary_ports"] = normalized_ports
    report_checks = analyze_reports(reports, wrapper_design, wrapper_plan)

    plan = build_genus_plan(
        liberty_checks=liberty_checks,
        timing_constraints=timing_constraints,
        d2d_extra_rc_model=d2d_extra_rc_model,
        reports=reports,
        db_files=db_files,
        genus_return_code=genus_return_code,
        genus_cmd=genus_cmd,
        output_checks=output_checks,
        report_checks=report_checks,
    )
    write_json_file(GENUS_PLAN_JSON, plan)
    assert_genus_plan_matches_outputs(load_json_file(GENUS_PLAN_JSON))
    print("[06] done")
    print("       genus_v    -> {}".format(GENUS_OUTPUT_V))
    print("       genus_json -> {}".format(GENUS_OUTPUT_JSON))
    print("       genus_plan -> {}".format(GENUS_PLAN_JSON))


def all_hetero_lib_files():
    libs = list(UPPER_LIB_FILES) + list(BOTTOM_LIB_FILES)
    assert libs, "Heterogeneous Genus lib list is empty"
    return libs


def module_signature(module):
    return OrderedDict(
        [
            (
                "ports",
                OrderedDict(
                    (
                        name,
                        OrderedDict(
                            [
                                ("direction", port.direction),
                                ("bits", list(port.bits)),
                                ("offset", port.offset),
                                ("upto", port.upto),
                                ("signed", port.signed),
                            ]
                        ),
                    )
                    for name, port in sorted(module.ports.items())
                ),
            ),
            (
                "cells",
                OrderedDict(
                    (
                        name,
                        OrderedDict(
                            [
                                ("type", cell.type),
                                ("parameters", OrderedDict(sorted(cell.parameters.items()))),
                                (
                                    "port_directions",
                                    OrderedDict(sorted(cell.port_directions.items())),
                                ),
                                (
                                    "connections",
                                    OrderedDict((key, list(value)) for key, value in sorted(cell.connections.items())),
                                ),
                            ]
                        ),
                    )
                    for name, cell in sorted(module.cells.items())
                ),
            ),
            (
                "netnames",
                OrderedDict(
                    (
                        name,
                        OrderedDict(
                            [
                                ("bits", list(netname.bits)),
                                ("offset", netname.offset),
                                ("upto", netname.upto),
                                ("signed", netname.signed),
                            ]
                        ),
                    )
                    for name, netname in sorted(module.netnames.items())
                ),
            ),
        ]
    )


def module_frozen_behavior_signature(module):
    return OrderedDict(
        [
            (
                "ports",
                OrderedDict(
                    (
                        name,
                        OrderedDict(
                            [
                                ("direction", port.direction),
                                ("bits", list(port.bits)),
                                ("offset", port.offset),
                                ("upto", port.upto),
                                ("signed", port.signed),
                            ]
                        ),
                    )
                    for name, port in sorted(module.ports.items())
                ),
            ),
            (
                "cells",
                OrderedDict(
                    (
                        name,
                        OrderedDict(
                            [
                                ("type", cell.type),
                                ("parameters", OrderedDict(sorted(cell.parameters.items()))),
                                (
                                    "port_directions",
                                    OrderedDict(sorted(cell.port_directions.items())),
                                ),
                                (
                                    "connections",
                                    OrderedDict((key, list(value)) for key, value in sorted(cell.connections.items())),
                                ),
                            ]
                        ),
                    )
                    for name, cell in sorted(module.cells.items())
                ),
            ),
        ]
    )


def collect_reachable_module_names(design, root_module_name, leaf_module_types=None):
    assert root_module_name in design.modules, "Root module not found: {}".format(root_module_name)
    leaf_module_types = set(leaf_module_types or [])
    reachable = OrderedDict()

    def visit(module_name):
        if module_name in reachable:
            return
        reachable[module_name] = True
        module = design.get_module(module_name)
        for cell in module.cells.values():
            if cell.type in design.modules and cell.type not in leaf_module_types:
                visit(cell.type)

    visit(root_module_name)
    return list(reachable.keys())


def collect_leaf_cell_types_from_root(design, root_module_name, leaf_module_types=None):
    leaf_module_types = set(leaf_module_types or [])
    leaf_types = set()
    for module_name in collect_reachable_module_names(design, root_module_name, leaf_module_types):
        module = design.get_module(module_name)
        for cell in module.cells.values():
            if cell.type not in design.modules or cell.type in leaf_module_types:
                leaf_types.add(cell.type)
    return leaf_types


def collect_leaf_cell_instances_from_root(design, root_module_name, leaf_module_types=None):
    leaf_module_types = set(leaf_module_types or [])
    leaf_cells = []
    for module_name in collect_reachable_module_names(design, root_module_name, leaf_module_types):
        module = design.get_module(module_name)
        for cell in module.cells.values():
            if cell.type not in design.modules or cell.type in leaf_module_types:
                leaf_cells.append((module_name, cell.name, cell.type))
    return leaf_cells


def assert_hetero_wrapper_input_contract(wrapper_design, wrapper_plan, clock_port_map, cell_mapping_plan):
    assert SYNTH_MODE == "genus_hetero", (
        "06 heterogeneous Genus requires SYNTH_MODE=genus_hetero, got {}".format(SYNTH_MODE)
    )
    assert CELL_NAME_MAPPING_MODE == SUPPORTED_HETERO_MAPPING_MODE, (
        "06 heterogeneous Genus requires CELL_NAME_MAPPING_MODE={}, got {}".format(
            SUPPORTED_HETERO_MAPPING_MODE, CELL_NAME_MAPPING_MODE
        )
    )
    assert MAP_JSON and os.path.isfile(MAP_JSON), "Heterogeneous Genus requires MAP_JSON: {}".format(MAP_JSON)
    assert cell_mapping_plan["mapping_mode"] == CELL_NAME_MAPPING_MODE, (
        "CELL_MAPPING_PLAN_JSON mapping_mode mismatch: {} != {}".format(
            cell_mapping_plan["mapping_mode"], CELL_NAME_MAPPING_MODE
        )
    )
    assert wrapper_plan["identity"]["mapping_mode"] == CELL_NAME_MAPPING_MODE
    assert wrapper_plan["identity"]["library"] == LIBRARY
    assert wrapper_plan["identity"]["design"] == DESIGN
    assert WRAPPER_TOP_MODULE_NAME in wrapper_design.modules, "Wrapper top missing: {}".format(WRAPPER_TOP_MODULE_NAME)
    assert UPPER_COARSE_MODULE_NAME in wrapper_design.modules, "Upper module missing: {}".format(UPPER_COARSE_MODULE_NAME)
    assert BOTTOM_COARSE_MODULE_NAME in wrapper_design.modules, "Bottom module missing: {}".format(BOTTOM_COARSE_MODULE_NAME)

    modules_plan = wrapper_plan["modules"]
    assert modules_plan["wrapper_top"] == WRAPPER_TOP_MODULE_NAME
    assert modules_plan["upper_module"] == UPPER_COARSE_MODULE_NAME
    assert modules_plan["bottom_module"] == BOTTOM_COARSE_MODULE_NAME
    assert modules_plan["upper_instance"] == WRAPPER_UPPER_INSTANCE_NAME
    assert modules_plan["bottom_instance"] == WRAPPER_BOTTOM_INSTANCE_NAME

    wrapper_top = wrapper_design.get_module(WRAPPER_TOP_MODULE_NAME)
    expected_cells = {WRAPPER_UPPER_INSTANCE_NAME, WRAPPER_BOTTOM_INSTANCE_NAME}
    assert set(wrapper_top.cells.keys()) == expected_cells, (
        "Wrapper top must contain only inst_upper/inst_bottom, got {}".format(sorted(wrapper_top.cells.keys()))
    )
    assert wrapper_top.cells[WRAPPER_UPPER_INSTANCE_NAME].type == UPPER_COARSE_MODULE_NAME
    assert wrapper_top.cells[WRAPPER_BOTTOM_INSTANCE_NAME].type == BOTTOM_COARSE_MODULE_NAME
    assert len(wrapper_plan["data_d2d_channels"]) == wrapper_plan["checks"]["data_d2d_count"]
    assert len(wrapper_plan["clock"]["clock_d2d_channels"]) == wrapper_plan["checks"]["clock_d2d_count"]
    assert clock_port_map["source_clock_port_name"] == wrapper_plan["clock"]["source_clock_port"]
    assert_no_multiple_wrapper_drivers(wrapper_top)


def assert_hetero_lib_coverage(wrapper_design):
    assert os.path.isdir(UPPER_LIB_DIR), "UPPER_LIB_DIR missing: {}".format(UPPER_LIB_DIR)
    assert os.path.isdir(BOTTOM_LIB_DIR), "BOTTOM_LIB_DIR missing: {}".format(BOTTOM_LIB_DIR)
    assert UPPER_LIB_FILES, "UPPER_LIB_FILES is empty"
    assert BOTTOM_LIB_FILES, "BOTTOM_LIB_FILES is empty"
    upper_lib_cells = scan_liberty_cell_names(UPPER_LIB_FILES)
    bottom_lib_cells = scan_liberty_cell_names(BOTTOM_LIB_FILES)
    overlap = sorted(upper_lib_cells & bottom_lib_cells)
    assert not overlap, "Upper/bottom liberty cell sets overlap: {}".format(overlap[:50])

    all_lib_cells = upper_lib_cells | bottom_lib_cells
    upper_leaf = collect_leaf_cell_types_from_root(wrapper_design, UPPER_COARSE_MODULE_NAME, all_lib_cells)
    bottom_leaf = collect_leaf_cell_types_from_root(wrapper_design, BOTTOM_COARSE_MODULE_NAME, all_lib_cells)
    assert upper_leaf, "No upper leaf cells found before hetero Genus"
    assert bottom_leaf, "No bottom leaf cells found before hetero Genus"
    upper_missing = sorted(upper_leaf - upper_lib_cells)
    bottom_missing = sorted(bottom_leaf - bottom_lib_cells)
    upper_wrong = sorted(upper_leaf & bottom_lib_cells)
    bottom_wrong = sorted(bottom_leaf & upper_lib_cells)
    assert not upper_missing, "Upper leaf cells missing from upper liberty: {}".format(upper_missing[:50])
    assert not bottom_missing, "Bottom leaf cells missing from bottom liberty: {}".format(bottom_missing[:50])
    assert not upper_wrong, "Upper module contains bottom library cells: {}".format(upper_wrong[:50])
    assert not bottom_wrong, "Bottom module contains upper library cells: {}".format(bottom_wrong[:50])

    checks = OrderedDict(
        [
            ("upper_lib_dir", UPPER_LIB_DIR),
            ("bottom_lib_dir", BOTTOM_LIB_DIR),
            ("upper_lib_files", list(UPPER_LIB_FILES)),
            ("bottom_lib_files", list(BOTTOM_LIB_FILES)),
            ("upper_lib_file_count", len(UPPER_LIB_FILES)),
            ("bottom_lib_file_count", len(BOTTOM_LIB_FILES)),
            ("upper_lib_cell_count", len(upper_lib_cells)),
            ("bottom_lib_cell_count", len(bottom_lib_cells)),
            ("upper_bottom_overlap_count", len(overlap)),
            ("initial_upper_leaf_cell_count", len(upper_leaf)),
            ("initial_bottom_leaf_cell_count", len(bottom_leaf)),
            ("initial_upper_missing_cell_count", len(upper_missing)),
            ("initial_bottom_missing_cell_count", len(bottom_missing)),
        ]
    )
    return checks, upper_lib_cells, bottom_lib_cells


def write_hetero_genus_sdc(wrapper_plan):
    vars_by_name = parse_design_sdc_vars(DESIGN_SDC_FILE)
    clock_port = wrapper_plan["clock"]["source_clock_port"]
    assert vars_by_name["clk_port_name"] == clock_port, (
        "DESIGN_SDC_FILE clk_port_name {} != wrapper clock port {}".format(
            vars_by_name["clk_port_name"], clock_port
        )
    )
    lines = [
        "# Generated by per-tier synthesis step 06 in heterogeneous mode.",
        "# Output load intentionally disabled by policy in the first hetero implementation.",
        *write_clock_sdc_lines(vars_by_name, clock_port, wrapper_plan["clock"]["clock_d2d_channels"]),
    ]
    write_text(GENUS_SDC, "\n".join(lines) + "\n")
    assert "set_load" not in read_text(GENUS_SDC), "Hetero GENUS_SDC must not set output load"
    input_sdc_clock = assert_sdc_clock_period_ps(GENUS_SDC, SDC_CLK_PERIOD_PS)
    return OrderedDict(
        [
            ("output_load_status", "disabled_by_policy"),
            ("clock_name", vars_by_name["clk_name"]),
            ("clock_port", clock_port),
            ("clock_period_raw", SDC_CLK_PERIOD_RAW),
            ("clock_period_unit", SDC_CLK_PERIOD_UNIT),
            ("clock_period_ps", SDC_CLK_PERIOD_PS),
            ("clock_io_pct", vars_by_name["clk_io_pct"]),
            ("input_sdc_clock", input_sdc_clock),
        ]
    )


def hetero_pass_paths(pass_name):
    pass_dir = os.path.join(GENUS_TMP_DIR, "hetero", pass_name)
    return OrderedDict(
        [
            ("pass_dir", pass_dir),
            ("input_v", os.path.join(pass_dir, "input.v")),
            ("input_json", os.path.join(pass_dir, "input.json")),
            ("sdc", os.path.join(pass_dir, "genus.sdc")),
            ("tcl", os.path.join(pass_dir, "run.tcl")),
            ("output_v", os.path.join(pass_dir, "output.v")),
            ("output_json", os.path.join(pass_dir, "output.json")),
            ("output_sdc", os.path.join(pass_dir, "output.sdc")),
            ("log_prefix", os.path.join(pass_dir, "genus")),
            ("report_dir", os.path.join(pass_dir, "reports")),
            ("db_dir", os.path.join(pass_dir, "db")),
        ]
    )


def hetero_report_paths(paths):
    report_dir = paths["report_dir"]
    return OrderedDict(
        [
            ("check_design", os.path.join(report_dir, "check_design.rpt")),
            ("timing_intent", os.path.join(report_dir, "check_timing_intent.rpt")),
            ("pre_messages", os.path.join(report_dir, "pre_messages.rpt")),
            ("post_messages", os.path.join(report_dir, "post_messages.rpt")),
            ("pre_gates", os.path.join(report_dir, "pre_gates.rpt")),
            ("post_gates", os.path.join(report_dir, "post_gates.rpt")),
            ("post_area", os.path.join(report_dir, "post_area.rpt")),
            ("post_timing", os.path.join(report_dir, "post_timing.rpt")),
            ("final", os.path.join(report_dir, "final.rpt")),
            ("final_area", os.path.join(report_dir, "final_area.rpt")),
            ("final_gates", os.path.join(report_dir, "final_gates.rpt")),
            ("final_qor", os.path.join(report_dir, "final_qor.rpt")),
            ("final_time", os.path.join(report_dir, "final_time.rpt")),
            ("ungroup", os.path.join(report_dir, "ungroup_modules.rpt")),
            ("active_boundary_before", os.path.join(report_dir, "active_boundary_before.rpt")),
            ("frozen_boundary_before", os.path.join(report_dir, "frozen_boundary_before.rpt")),
            ("active_boundary_after", os.path.join(report_dir, "active_boundary_after.rpt")),
            ("frozen_boundary_after", os.path.join(report_dir, "frozen_boundary_after.rpt")),
        ]
    )


def dont_use_pattern_for_frozen_tier(frozen_tier):
    if frozen_tier == "upper":
        return "*/*{}".format(UPPER_CELL_SUFFIX)
    if frozen_tier == "bottom":
        return "*/*{}".format(BOTTOM_CELL_SUFFIX)
    raise AssertionError("Unsupported frozen tier: {}".format(frozen_tier))


def build_hetero_pass_descriptors(upper_lib_cells, bottom_lib_cells, wrapper_plan):
    protected_top_names = collect_protected_top_names(load_design(WRAPPER_JSON), wrapper_plan)
    pass_specs = [
        ("upper_first", "upper", "bottom"),
        ("bottom_final", "bottom", "upper"),
    ]
    descriptors = OrderedDict()
    for pass_name, active_tier, frozen_tier in pass_specs:
        paths = hetero_pass_paths(pass_name)
        reports = hetero_report_paths(paths)
        active_module = UPPER_COARSE_MODULE_NAME if active_tier == "upper" else BOTTOM_COARSE_MODULE_NAME
        frozen_module = UPPER_COARSE_MODULE_NAME if frozen_tier == "upper" else BOTTOM_COARSE_MODULE_NAME
        active_instance = WRAPPER_UPPER_INSTANCE_NAME if active_tier == "upper" else WRAPPER_BOTTOM_INSTANCE_NAME
        frozen_instance = WRAPPER_UPPER_INSTANCE_NAME if frozen_tier == "upper" else WRAPPER_BOTTOM_INSTANCE_NAME
        active_lib_files = list(UPPER_LIB_FILES) if active_tier == "upper" else list(BOTTOM_LIB_FILES)
        frozen_lib_files = list(UPPER_LIB_FILES) if frozen_tier == "upper" else list(BOTTOM_LIB_FILES)
        frozen_lib_cells = upper_lib_cells if frozen_tier == "upper" else bottom_lib_cells
        descriptors[pass_name] = OrderedDict(
            [
                ("pass_name", pass_name),
                ("active_tier", active_tier),
                ("frozen_tier", frozen_tier),
                ("active_module", active_module),
                ("frozen_module", frozen_module),
                ("active_instance", active_instance),
                ("frozen_instance", frozen_instance),
                ("active_lib_files", active_lib_files),
                ("frozen_lib_files", frozen_lib_files),
                ("dont_use_pattern", dont_use_pattern_for_frozen_tier(frozen_tier)),
                ("dont_use_cell_count", len(frozen_lib_cells)),
                ("protected_top_names", protected_top_names),
                ("output_load_status", "disabled_by_policy"),
                ("paths", paths),
                ("reports", reports),
            ]
        )
    return descriptors


def write_hetero_pass_tcl(desc):
    paths = desc["paths"]
    reports = desc["reports"]
    db_opt = os.path.join(paths["db_dir"], "{}_opt.db".format(desc["pass_name"]))
    tcl = """# Generated by per-tier synthesis step 06 in heterogeneous mode.
set_db max_cpus_per_server {max_cpus}
set_db super_thread_servers "localhost"
set_db hdl_flatten_complex_port true
set_db hdl_record_naming_style %s_%s
set_db auto_ungroup both

set lib_list [list {lib_files}]
set link_library $lib_list
set target_library $lib_list
set_db library $lib_list

set in_v {in_v}
set in_sdc {in_sdc}
set out_v {out_v}
set out_sdc {out_sdc}
set report_dir {report_dir}
set db_dir {db_dir}
set d2d_extra_rc_tcl {d2d_extra_rc_tcl}

foreach d [list $report_dir $db_dir] {{
  if {{![file exists $d]}} {{
    file mkdir $d
  }}
}}

read_hdl -sv $in_v
elaborate {wrapper_top}
init_design
read_sdc $in_sdc

{constant_tie_configuration}

set upper_mod [get_db modules {upper_module}]
set bottom_mod [get_db modules {bottom_module}]
set active_hinst [get_db hinsts {active_instance}]
set frozen_hinst [get_db hinsts {frozen_instance}]

if {{[llength $upper_mod] != 1}} {{ error "Unable to resolve upper module {upper_module}" }}
if {{[llength $bottom_mod] != 1}} {{ error "Unable to resolve bottom module {bottom_module}" }}
if {{[llength $active_hinst] != 1}} {{ error "Unable to resolve active hinst {active_instance}" }}
if {{[llength $frozen_hinst] != 1}} {{ error "Unable to resolve frozen hinst {frozen_instance}" }}

set_db / .boundary_opto false
set_db / .boundary_optimize_invert_hpins false
set_db / .boundary_optimize_feedthrough_hpins false
set_db $upper_mod .ungroup_ok false
set_db $bottom_mod .ungroup_ok false
set_db $upper_mod .boundary_opto strict_no
set_db $bottom_mod .boundary_opto strict_no
set_db $upper_mod .boundary_optimize_invert_hpins false
set_db $bottom_mod .boundary_optimize_invert_hpins false
set_db $upper_mod .boundary_optimize_feedthrough_hpins false
set_db $bottom_mod .boundary_optimize_feedthrough_hpins false
catch {{ set_db $active_hinst .ungroup_ok false }}
catch {{ set_db $frozen_hinst .ungroup_ok false }}
catch {{ set_db $frozen_hinst .preserve true }}
catch {{ set_db [get_db insts -if {{.base_name =~ {frozen_instance}/*}}] .dont_touch true }}

set active_internal_design_hinsts [get_db hinsts -if {{.name =~ {active_instance}/* && .module.name =~ _*}}]
puts "SYN3D_ACTIVE_INTERNAL_DESIGN_HINST_COUNT=[llength $active_internal_design_hinsts]"
if {{[llength $active_internal_design_hinsts] > 0}} {{
  ungroup $active_internal_design_hinsts
}}

set protected_top_name_count 0
set protected_top_object_count 0
foreach one_name [list {protected_top_names}] {{
  incr protected_top_name_count
  set net_objs [get_db nets $one_name]
  if {{[llength $net_objs] > 0}} {{
    incr protected_top_object_count [llength $net_objs]
    catch {{ set_db $net_objs .dont_touch true }}
  }}
}}

set frozen_lib_cells [get_db lib_cells {dont_use_pattern}]
if {{[llength $frozen_lib_cells] == 0}} {{ error "No frozen lib cells matched {dont_use_pattern}" }}
set_dont_use $frozen_lib_cells

puts "SYN3D_HETERO_PASS={pass_name}"
puts "SYN3D_ACTIVE_TIER={active_tier}"
puts "SYN3D_FROZEN_TIER={frozen_tier}"
puts "SYN3D_DONT_USE_PATTERN={dont_use_pattern}"
puts "SYN3D_DONT_USE_CELL_COUNT=[llength $frozen_lib_cells]"
puts "SYN3D_PROTECTED_TOP_NAME_COUNT=$protected_top_name_count"
puts "SYN3D_PROTECTED_TOP_OBJECT_COUNT=$protected_top_object_count"
puts "SYN3D_AUTO_UNGROUP=[get_db / .auto_ungroup]"
puts "SYN3D_OUTPUT_LOAD_STATUS=disabled_by_policy"
source $d2d_extra_rc_tcl

check_design -unresolved > {check_design}
check_timing_intent > {timing_intent}
report_messages > {pre_messages}
report_gates > {pre_gates}
report_ungroup_modules > {ungroup}
report_boundary_opt $active_hinst > {active_boundary_before}
report_boundary_opt $frozen_hinst > {frozen_boundary_before}

# set syn_opt_rc [catch {{ syn_opt -incr }} syn_opt_msg]
# set_db syn_opt_effort low
# set syn_opt_rc [catch {{ syn_opt -incr }} syn_opt_msg]
# 2026-07-08: minimize heterogeneous Genus intervention; run only low-effort incremental syn_opt.
set syn_opt_rc [catch {{ syn_opt -incr -effort low }} syn_opt_msg]

write_reports -directory $report_dir -tag final
report_messages > {post_messages}
report_gates > {post_gates}
report_area > {post_area}
report_timing > {post_timing}
report_boundary_opt $active_hinst > {active_boundary_after}
report_boundary_opt $frozen_hinst > {frozen_boundary_after}
write_db {db_opt}

write_hdl > $out_v
write_sdc > $out_sdc
if {{$syn_opt_rc != 0}} {{
  puts stderr $syn_opt_msg
  exit 2
}}
exit
""".format(
        max_cpus=DEFAULT_MAX_CPUS,
        lib_files=format_tcl_list(all_hetero_lib_files()),
        in_v=tcl_quote(paths["input_v"]),
        in_sdc=tcl_quote(paths["sdc"]),
        out_v=tcl_quote(paths["output_v"]),
        out_sdc=tcl_quote(paths["output_sdc"]),
        report_dir=tcl_quote(paths["report_dir"]),
        db_dir=tcl_quote(paths["db_dir"]),
        d2d_extra_rc_tcl=tcl_quote(D2D_EXTRA_RC_TCL),
        wrapper_top=WRAPPER_TOP_MODULE_NAME,
        upper_module=UPPER_COARSE_MODULE_NAME,
        bottom_module=BOTTOM_COARSE_MODULE_NAME,
        active_instance=desc["active_instance"],
        frozen_instance=desc["frozen_instance"],
        protected_top_names=format_tcl_list(desc["protected_top_names"]),
        dont_use_pattern=desc["dont_use_pattern"],
        pass_name=desc["pass_name"],
        active_tier=desc["active_tier"],
        frozen_tier=desc["frozen_tier"],
        constant_tie_configuration=render_constant_tie_configuration(
            tier_constant_tie_specs(desc["active_tier"])
        ),
        db_opt=tcl_quote(db_opt),
        **{key: tcl_quote(value) for key, value in reports.items()}
    )
    write_text(paths["tcl"], tcl)
    loaded = read_text(paths["tcl"])
    assert "set_load" not in loaded, "Hetero Tcl must not set output load"
    assert "set_max_transition" not in loaded, "Hetero Tcl must not set max transition"
    assert "set_db auto_ungroup both" in loaded, "Hetero Tcl must allow selective internal ungroup"
    assert "ungroup $active_internal_design_hinsts" in loaded, "Hetero Tcl missing explicit active internal hinst ungroup"
    assert "syn_opt -incr -effort low" in loaded, "Hetero Tcl must run low-effort incremental syn_opt"
    assert "source $d2d_extra_rc_tcl" in loaded, "Hetero Tcl missing d2d extra RC source"
    assert "SYN3D_CONSTANT_TIE_MAPPING=duplicate" in loaded, "Hetero Tcl missing duplicate constant tie mapping"
    return db_opt


def run_genus_with_tcl(tcl_path, log_prefix):
    assert os.path.exists(GENUS), "Genus not found: {}".format(GENUS)
    cmd = [
        GENUS,
        "-no_gui",
        "-batch",
        "-abort_on_error",
        "-overwrite",
        "-log",
        log_prefix,
        "-files",
        tcl_path,
    ]
    result = subprocess.run(cmd, check=False)
    return result.returncode, cmd


def assert_hetero_pass_output_files(desc, db_file):
    paths = desc["paths"]
    reports = desc["reports"]
    required = [
        paths["output_v"],
        paths["output_sdc"],
        paths["log_prefix"] + ".log",
        paths["log_prefix"] + ".cmd",
        db_file,
    ]
    required.extend(reports.values())
    for path in required:
        assert os.path.isfile(path), "Hetero pass expected output missing: {}".format(path)
        if path == reports["ungroup"]:
            continue
        assert os.path.getsize(path) > 0, "Hetero pass expected output is empty: {}".format(path)


def assert_hetero_top_shell_contract(output_design, wrapper_plan):
    validate_design(output_design)
    top = output_design.get_module(WRAPPER_TOP_MODULE_NAME)
    expected_cells = {WRAPPER_UPPER_INSTANCE_NAME, WRAPPER_BOTTOM_INSTANCE_NAME}
    assert set(top.cells.keys()) == expected_cells, (
        "Hetero output wrapper top must contain only inst_upper/inst_bottom, got {}".format(
            sorted(top.cells.keys())
        )
    )
    assert top.cells[WRAPPER_UPPER_INSTANCE_NAME].type == UPPER_COARSE_MODULE_NAME
    assert top.cells[WRAPPER_BOTTOM_INSTANCE_NAME].type == BOTTOM_COARSE_MODULE_NAME
    for channel in wrapper_plan["data_d2d_channels"]:
        name = channel["d2d_name"]
        assert name in top.netnames, "Hetero output wrapper top lost data d2d netname: {}".format(name)
    return OrderedDict(
        [
            ("top_cell_count", len(top.cells)),
            ("top_instance_names", sorted(top.cells.keys())),
            ("top_leaf_cell_count", 0),
            ("data_d2d_count", len(wrapper_plan["data_d2d_channels"])),
            ("clock_d2d_count", len(wrapper_plan["clock"]["clock_d2d_channels"])),
        ]
    )


def assert_no_wrong_lib_cells(output_design, upper_lib_cells, bottom_lib_cells):
    all_lib_cells = upper_lib_cells | bottom_lib_cells
    upper_wrong = []
    bottom_wrong = []
    upper_unknown = []
    bottom_unknown = []
    for module_name, cell_name, cell_type in collect_leaf_cell_instances_from_root(
        output_design, UPPER_COARSE_MODULE_NAME, all_lib_cells
    ):
        if cell_type in bottom_lib_cells:
            upper_wrong.append("{}.{}:{}".format(module_name, cell_name, cell_type))
        if cell_type not in upper_lib_cells:
            upper_unknown.append("{}.{}:{}".format(module_name, cell_name, cell_type))
    for module_name, cell_name, cell_type in collect_leaf_cell_instances_from_root(
        output_design, BOTTOM_COARSE_MODULE_NAME, all_lib_cells
    ):
        if cell_type in upper_lib_cells:
            bottom_wrong.append("{}.{}:{}".format(module_name, cell_name, cell_type))
        if cell_type not in bottom_lib_cells:
            bottom_unknown.append("{}.{}:{}".format(module_name, cell_name, cell_type))
    assert not upper_wrong, "Upper tier contains bottom lib cells: {}".format(upper_wrong[:50])
    assert not bottom_wrong, "Bottom tier contains upper lib cells: {}".format(bottom_wrong[:50])
    assert not upper_unknown, "Upper tier contains unknown leaf cells: {}".format(upper_unknown[:50])
    assert not bottom_unknown, "Bottom tier contains unknown leaf cells: {}".format(bottom_unknown[:50])
    return OrderedDict(
        [
            ("upper_wrong_lib_cell_count", len(upper_wrong)),
            ("bottom_wrong_lib_cell_count", len(bottom_wrong)),
            ("upper_unknown_cell_count", len(upper_unknown)),
            ("bottom_unknown_cell_count", len(bottom_unknown)),
        ]
    )


def assert_active_tier_internal_boundaries_removed(output_design, desc, upper_lib_cells, bottom_lib_cells):
    if desc["active_tier"] == "upper":
        leaf_module_types = upper_lib_cells
    elif desc["active_tier"] == "bottom":
        leaf_module_types = bottom_lib_cells
    else:
        raise AssertionError("Unsupported active tier: {}".format(desc["active_tier"]))
    return assert_no_design_submodule_boundaries(output_design, desc["active_module"], leaf_module_types)


def assert_final_tier_internal_boundaries_removed(output_design, upper_lib_cells, bottom_lib_cells):
    return OrderedDict(
        [
            (
                "upper",
                assert_no_design_submodule_boundaries(output_design, UPPER_COARSE_MODULE_NAME, upper_lib_cells),
            ),
            (
                "bottom",
                assert_no_design_submodule_boundaries(output_design, BOTTOM_COARSE_MODULE_NAME, bottom_lib_cells),
            ),
        ]
    )


def assert_frozen_reachable_modules_exact_match(input_design, output_design, frozen_root_module, leaf_module_types=None):
    input_modules = collect_reachable_module_names(input_design, frozen_root_module, leaf_module_types)
    output_modules = collect_reachable_module_names(output_design, frozen_root_module, leaf_module_types)
    assert set(input_modules) == set(output_modules), (
        "Frozen reachable module set changed for {}: input={} output={}".format(
            frozen_root_module, sorted(input_modules), sorted(output_modules)
        )
    )
    changed = []
    netname_alias_changed = []
    for module_name in sorted(input_modules):
        input_module = input_design.get_module(module_name)
        output_module = output_design.get_module(module_name)
        if module_frozen_behavior_signature(input_module) != module_frozen_behavior_signature(output_module):
            changed.append(module_name)
        elif module_signature(input_module) != module_signature(output_module):
            netname_alias_changed.append(module_name)
    assert not changed, "Frozen modules changed for {}: {}".format(frozen_root_module, changed)
    return OrderedDict(
        [
            ("frozen_root_module", frozen_root_module),
            ("frozen_reachable_module_count", len(input_modules)),
            ("frozen_behavior_exact_match", True),
            ("frozen_netname_alias_change_count", len(netname_alias_changed)),
            ("frozen_netname_alias_changed_modules", netname_alias_changed),
        ]
    )


def analyze_hetero_pass_reports(desc):
    reports = desc["reports"]
    log_path = desc["paths"]["log_prefix"] + ".log"
    dangerous = parse_dangerous_messages(
        [log_path, reports["post_messages"], reports["timing_intent"], reports["check_design"]]
    )
    post_sdc_clock = assert_sdc_clock_period_ps(desc["paths"]["output_sdc"], SDC_CLK_PERIOD_PS)
    active_boundary = parse_boundary_report(reports["active_boundary_after"])
    frozen_boundary = parse_boundary_report(reports["frozen_boundary_after"])
    ungroup = parse_ungroup_report(reports["ungroup"])
    assert not dangerous, "Dangerous Genus log/report patterns found in {}: {}".format(
        desc["pass_name"], dangerous[:10]
    )
    assert active_boundary["no_boundary_optimization"], (
        "{} active boundary optimization detected or unproven".format(desc["pass_name"])
    )
    assert frozen_boundary["no_boundary_optimization"], (
        "{} frozen boundary optimization detected or unproven".format(desc["pass_name"])
    )
    assert not ungroup["tier_modules_ungrouped"], "{} tier modules appear ungrouped: {}".format(
        desc["pass_name"], ungroup["tier_module_lines"]
    )
    return OrderedDict(
        [
            ("dangerous_messages", dangerous),
            ("dangerous_log_pattern_count", len(dangerous)),
            ("post_sdc_clock", post_sdc_clock),
            ("active_boundary", active_boundary),
            ("frozen_boundary", frozen_boundary),
            ("ungroup", ungroup),
        ]
    )


def prepare_hetero_inputs(wrapper_plan, descriptors):
    os.makedirs(GENUS_TMP_DIR, exist_ok=True)
    os.makedirs(os.path.join(GENUS_TMP_DIR, "hetero"), exist_ok=True)
    shutil.copyfile(WRAPPER_V, GENUS_INPUT_V)
    assert_verilog_readback_with_libs(GENUS_INPUT_V, WRAPPER_TOP_MODULE_NAME, all_hetero_lib_files())
    timing_constraints = write_hetero_genus_sdc(wrapper_plan)
    d2d_extra_rc_model = write_d2d_extra_rc_artifacts(wrapper_plan)
    for desc in descriptors.values():
        paths = desc["paths"]
        os.makedirs(paths["pass_dir"], exist_ok=True)
        os.makedirs(paths["report_dir"], exist_ok=True)
        os.makedirs(paths["db_dir"], exist_ok=True)
        shutil.copyfile(GENUS_SDC, paths["sdc"])
    shutil.copyfile(GENUS_INPUT_V, descriptors["upper_first"]["paths"]["input_v"])
    return timing_constraints, d2d_extra_rc_model


def run_hetero_pass(desc, wrapper_design, wrapper_plan, upper_lib_cells, bottom_lib_cells):
    paths = desc["paths"]
    emit_verilog_to_json(paths["input_v"], WRAPPER_TOP_MODULE_NAME, paths["input_json"], all_hetero_lib_files())
    input_design = load_design(paths["input_json"])
    validate_design(input_design)
    db_file = write_hetero_pass_tcl(desc)
    print("[06] running hetero Genus pass {} ...".format(desc["pass_name"]))
    return_code, cmd = run_genus_with_tcl(paths["tcl"], paths["log_prefix"])
    assert return_code == 0, "Genus pass {} failed with exit code {}".format(desc["pass_name"], return_code)
    assert_hetero_pass_output_files(desc, db_file)
    emit_verilog_to_json(paths["output_v"], WRAPPER_TOP_MODULE_NAME, paths["output_json"], all_hetero_lib_files())
    output_design = load_design(paths["output_json"])
    normalized_ports = normalize_genus_primary_interface(output_design, wrapper_design, paths["output_json"])
    top_checks = assert_hetero_top_shell_contract(output_design, wrapper_plan)
    top_checks["normalized_primary_port_count"] = len(normalized_ports)
    top_checks["normalized_primary_ports"] = normalized_ports
    wrong_lib_checks = assert_no_wrong_lib_cells(output_design, upper_lib_cells, bottom_lib_cells)
    active_boundary_checks = assert_active_tier_internal_boundaries_removed(
        output_design, desc, upper_lib_cells, bottom_lib_cells
    )
    frozen_checks = assert_frozen_reachable_modules_exact_match(
        input_design, output_design, desc["frozen_module"], upper_lib_cells | bottom_lib_cells
    )
    report_checks = analyze_hetero_pass_reports(desc)
    return OrderedDict(
        [
            ("pass_name", desc["pass_name"]),
            ("active_tier", desc["active_tier"]),
            ("frozen_tier", desc["frozen_tier"]),
            ("active_module", desc["active_module"]),
            ("frozen_module", desc["frozen_module"]),
            ("active_instance", desc["active_instance"]),
            ("frozen_instance", desc["frozen_instance"]),
            ("paths", desc["paths"]),
            ("reports", desc["reports"]),
            ("genus_return_code", return_code),
            ("genus_cmd", cmd),
            ("db_file", db_file),
            ("dont_use_pattern", desc["dont_use_pattern"]),
            ("dont_use_cell_count", desc["dont_use_cell_count"]),
            ("protected_top_name_count", len(desc["protected_top_names"])),
            ("output_load_status", desc["output_load_status"]),
            ("top", top_checks),
            ("wrong_lib", wrong_lib_checks),
            ("active_internal_boundary", active_boundary_checks),
            ("frozen", frozen_checks),
            ("report", report_checks),
        ]
    )


def promote_hetero_final_outputs(final_desc):
    final_paths = final_desc["paths"]
    os.makedirs(GENUS_REPORT_DIR, exist_ok=True)
    os.makedirs(GENUS_DB_DIR, exist_ok=True)
    shutil.copyfile(final_paths["output_v"], GENUS_OUTPUT_V)
    shutil.copyfile(final_paths["output_json"], GENUS_OUTPUT_JSON)
    shutil.copyfile(final_paths["output_sdc"], GENUS_POST_SDC)
    shutil.copyfile(final_paths["tcl"], GENUS_TCL)
    for suffix in [".log", ".cmd"]:
        src = final_paths["log_prefix"] + suffix
        if os.path.isfile(src):
            shutil.copyfile(src, GENUS_LOG_PREFIX + suffix)
    for name in os.listdir(final_paths["report_dir"]):
        src = os.path.join(final_paths["report_dir"], name)
        if os.path.isfile(src):
            shutil.copyfile(src, os.path.join(GENUS_REPORT_DIR, name))
    for name in os.listdir(final_paths["db_dir"]):
        src = os.path.join(final_paths["db_dir"], name)
        if os.path.isfile(src):
            shutil.copyfile(src, os.path.join(GENUS_DB_DIR, name))
    assert os.path.isfile(GENUS_OUTPUT_V), "Failed to promote hetero GENUS_OUTPUT_V"
    assert os.path.isfile(GENUS_OUTPUT_JSON), "Failed to promote hetero GENUS_OUTPUT_JSON"


def build_hetero_genus_plan(liberty_checks, timing_constraints, d2d_extra_rc_model, descriptors, pass_results, final_checks):
    return OrderedDict(
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
                        ("wrapper_json", WRAPPER_JSON),
                        ("wrapper_v", WRAPPER_V),
                        ("wrapper_plan_json", WRAPPER_PLAN_JSON),
                        ("design_sdc", DESIGN_SDC_FILE),
                        ("clock_port_map_json", CLOCK_PORT_MAP_JSON),
                        ("cell_mapping_plan_json", CELL_MAPPING_PLAN_JSON),
                        ("map_json", MAP_JSON),
                        ("upper_lib_dir", UPPER_LIB_DIR),
                        ("upper_lib_files", list(UPPER_LIB_FILES)),
                        ("bottom_lib_dir", BOTTOM_LIB_DIR),
                        ("bottom_lib_files", list(BOTTOM_LIB_FILES)),
                    ]
                ),
            ),
            (
                "outputs",
                OrderedDict(
                    [
                        ("genus_input_v", GENUS_INPUT_V),
                        ("genus_sdc", GENUS_SDC),
                        ("genus_tcl", GENUS_TCL),
                        ("d2d_extra_rc_tcl", D2D_EXTRA_RC_TCL),
                        ("d2d_extra_rc_json", D2D_EXTRA_RC_JSON),
                        ("genus_output_v", GENUS_OUTPUT_V),
                        ("genus_output_json", GENUS_OUTPUT_JSON),
                        ("genus_post_sdc", GENUS_POST_SDC),
                        ("genus_plan_json", GENUS_PLAN_JSON),
                        ("log_prefix", GENUS_LOG_PREFIX),
                        ("report_dir", GENUS_REPORT_DIR),
                        ("db_dir", GENUS_DB_DIR),
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
            (
                "synthesis_strategy",
                OrderedDict(
                    [
                        ("name", "heterogeneous_sequential_freeze"),
                        ("pass_order", ["upper_first", "bottom_final"]),
                        ("final_pass", "bottom_final"),
                        ("auto_ungroup", "both"),
                        ("kept_boundaries", [UPPER_COARSE_MODULE_NAME, BOTTOM_COARSE_MODULE_NAME]),
                        ("top_shell_protection", "enabled"),
                        ("boundary_settings_applied", True),
                        ("timing_constraints", timing_constraints),
                        ("hbt_model", d2d_extra_rc_model),
                    ]
                ),
            ),
            ("liberty_checks", liberty_checks),
            ("pass_descriptors", descriptors),
            ("passes", pass_results),
            (
                "checks",
                OrderedDict(
                    [
                        ("pass_return_codes", OrderedDict((name, result["genus_return_code"]) for name, result in pass_results.items())),
                        ("final", final_checks),
                        ("unsupported_count", 0),
                    ]
                ),
            ),
        ]
    )


def assert_hetero_genus_plan_matches_outputs(plan):
    assert plan["identity"]["synth_mode"] == "genus_hetero"
    assert plan["checks"]["unsupported_count"] == 0
    assert plan["checks"]["pass_return_codes"] == OrderedDict([("upper_first", 0), ("bottom_final", 0)])
    assert plan["synthesis_strategy"]["timing_constraints"]["output_load_status"] == "disabled_by_policy"
    assert plan["outputs"]["d2d_extra_rc_tcl"] == D2D_EXTRA_RC_TCL
    assert os.path.isfile(plan["outputs"]["d2d_extra_rc_tcl"])
    assert plan["outputs"]["d2d_extra_rc_json"] == D2D_EXTRA_RC_JSON
    assert os.path.isfile(plan["outputs"]["d2d_extra_rc_json"])
    assert os.path.isfile(plan["outputs"]["genus_output_v"])
    assert os.path.isfile(plan["outputs"]["genus_output_json"])
    assert plan["liberty_checks"]["upper_bottom_overlap_count"] == 0
    assert plan["liberty_checks"]["initial_upper_missing_cell_count"] == 0
    assert plan["liberty_checks"]["initial_bottom_missing_cell_count"] == 0


def run_heterogeneous_genus():
    wrapper_design, wrapper_plan, clock_port_map, cell_mapping_plan = load_inputs()
    assert_hetero_wrapper_input_contract(wrapper_design, wrapper_plan, clock_port_map, cell_mapping_plan)
    liberty_checks, upper_lib_cells, bottom_lib_cells = assert_hetero_lib_coverage(wrapper_design)
    descriptors = build_hetero_pass_descriptors(upper_lib_cells, bottom_lib_cells, wrapper_plan)
    timing_constraints, d2d_extra_rc_model = prepare_hetero_inputs(wrapper_plan, descriptors)

    pass_results = OrderedDict()
    pass_results["upper_first"] = run_hetero_pass(
        descriptors["upper_first"], wrapper_design, wrapper_plan, upper_lib_cells, bottom_lib_cells
    )
    shutil.copyfile(descriptors["upper_first"]["paths"]["output_v"], descriptors["bottom_final"]["paths"]["input_v"])
    pass_results["bottom_final"] = run_hetero_pass(
        descriptors["bottom_final"], wrapper_design, wrapper_plan, upper_lib_cells, bottom_lib_cells
    )

    promote_hetero_final_outputs(descriptors["bottom_final"])
    final_design = load_design(GENUS_OUTPUT_JSON)
    normalized_ports = normalize_genus_primary_interface(final_design, wrapper_design, GENUS_OUTPUT_JSON)
    final_checks = assert_hetero_top_shell_contract(final_design, wrapper_plan)
    final_checks["normalized_primary_port_count"] = len(normalized_ports)
    final_checks["normalized_primary_ports"] = normalized_ports
    final_checks.update(assert_no_wrong_lib_cells(final_design, upper_lib_cells, bottom_lib_cells))
    final_checks["internal_boundaries"] = assert_final_tier_internal_boundaries_removed(
        final_design, upper_lib_cells, bottom_lib_cells
    )
    final_checks["direct_constants"] = assert_no_direct_constants_in_synthesized_design(
        final_design, upper_lib_cells | bottom_lib_cells
    )

    plan = build_hetero_genus_plan(
        liberty_checks=liberty_checks,
        timing_constraints=timing_constraints,
        d2d_extra_rc_model=d2d_extra_rc_model,
        descriptors=descriptors,
        pass_results=pass_results,
        final_checks=final_checks,
    )
    write_json_file(GENUS_PLAN_JSON, plan)
    assert_hetero_genus_plan_matches_outputs(load_json_file(GENUS_PLAN_JSON))
    print("[06] done")
    print("       genus_v    -> {}".format(GENUS_OUTPUT_V))
    print("       genus_json -> {}".format(GENUS_OUTPUT_JSON))
    print("       genus_plan -> {}".format(GENUS_PLAN_JSON))


def main():
    if SYNTH_MODE == "genus_homo":
        run_homogeneous_genus()
        return
    if SYNTH_MODE == "genus_hetero":
        run_heterogeneous_genus()
        return
    raise AssertionError("Unsupported SYNTH_MODE: {}".format(SYNTH_MODE))


if __name__ == "__main__":
    main()
