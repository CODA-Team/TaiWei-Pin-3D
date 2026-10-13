"""Central configuration for the 3D-Syn per-tier synthesis stage.

All paths are supplied by the TaiWei Makefile.  The stage consumes the current
variant's coarse-partition results and coarse-synthesis handoff, keeps temporary
artifacts under ``OBJECTS_DIR``, and publishes only its stable outputs to
``RESULTS_DIR``.
"""

import os
import re
import shlex


def _norm(path: str) -> str:
    return os.path.normpath(path)


def _env_or_default(name: str, default: str) -> str:
    value = os.getenv(name)
    return value if value else default


def _env_flag(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if not value:
        return default
    return value.lower() in {"1", "true", "yes", "on"}


def _required_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError("Required environment variable is not set: {}".format(name))
    return value


def _repo_path(*parts: str) -> str:
    return _norm(os.path.join(REPO_ROOT, *parts))


def _script_path(*parts: str) -> str:
    return _norm(os.path.join(SCRIPT_DIR, *parts))


def _platform_path(library: str, *parts: str) -> str:
    return _repo_path("platforms", library, *parts)


def _design_path(library: str, design: str, *parts: str) -> str:
    return _repo_path("designs", library, design, *parts)


def _platform_paths(library: str, rel_dir: str, filenames: list) -> list:
    return [_platform_path(library, rel_dir, name) for name in filenames]


def _read_sdc_var(sdc_path: str, var_name: str) -> str:
    pattern = re.compile(r"set\s+" + re.escape(var_name) + r"\s+(\S+)")
    with open(sdc_path) as fp:
        for line in fp:
            match = pattern.match(line.strip())
            if match:
                return match.group(1)
    raise AssertionError("{} not found in {}".format(var_name, sdc_path))


def _read_clk_period_raw(sdc_path: str) -> str:
    env_clk_period = os.getenv("CLK_PERIOD")
    if env_clk_period:
        return env_clk_period
    return _read_sdc_var(sdc_path, "clk_period")


def _clk_period_unit_for_library(library: str) -> str:
    unit_by_library = {
        "asap7_3D": "ps",
        "nangate45_3D": "ns",
        "asap7_nangate45_3D": "ns",
    }
    assert library in unit_by_library, "Unsupported SDC clk_period unit for library: {}".format(library)
    return unit_by_library[library]


def _clk_period_raw_to_ps(raw_value: str, unit: str):
    value = float(raw_value)
    if unit == "ps":
        value_ps = value
    elif unit == "ns":
        value_ps = value * 1000.0
    else:
        raise AssertionError("Unsupported clk_period unit: {}".format(unit))
    rounded = round(value_ps)
    if abs(value_ps - rounded) < 1e-9:
        return int(rounded)
    return value_ps


def _resolve_abc_clk_period_ps(explicit_period_ps, sdc_path: str, library: str):
    if explicit_period_ps is not None:
        return explicit_period_ps
    raw_value = _read_clk_period_raw(sdc_path)
    unit = _clk_period_unit_for_library(library)
    return _clk_period_raw_to_ps(raw_value, unit)


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FLOW_HOME = _norm(_required_env("FLOW_HOME"))
REPO_ROOT = FLOW_HOME

# Flow identity is inherited from the active TaiWei design configuration.
DESIGN = _required_env("DESIGN_NAME")
LIBRARY = _required_env("SYN3D_PLATFORM")
FLOW_VARIANT = _required_env("FLOW_VARIANT")

# Optional debug artifact switches
OUTPUT_VERILOG = _env_flag("OUTPUT_VERILOG", True)
_default_synth_mode = "genus_hetero" if LIBRARY == "asap7_nangate45_3D" else "genus_homo"
SYNTH_MODE = _env_or_default("SYN3D_PER_TIER_SYNTH_MODE", _default_synth_mode).lower()
SUPPORTED_SYNTH_MODES = {"genus_homo", "genus_hetero"}
assert SYNTH_MODE in SUPPORTED_SYNTH_MODES, "Unsupported SYNTH_MODE: {}".format(SYNTH_MODE)

GENUS_OPT_MODE = _env_or_default("SYN3D_GENUS_OPT_MODE", "normal").lower()
SUPPORTED_GENUS_OPT_MODES = {"normal", "low_effort"}
assert GENUS_OPT_MODE in SUPPORTED_GENUS_OPT_MODES, (
    "Unsupported SYN3D_GENUS_OPT_MODE: {}".format(GENUS_OPT_MODE)
)

# TritonPart partition encoding
PARTITION_BOTTOM_VALUE = "0"
PARTITION_TOP_VALUE = "1"

# Directory layout.  Inputs and outputs belong to the same TaiWei variant.
RESULTS_DIR = _norm(_required_env("RESULTS_DIR"))
OBJECTS_DIR = _norm(_required_env("OBJECTS_DIR"))
LOG_DIR = _norm(_required_env("LOG_DIR"))
REPORTS_DIR = _norm(_required_env("REPORTS_DIR"))

COARSE_SYNTH_DIR = _norm(_required_env("SYN3D_COARSE_SYNTH_DIR"))
PER_TIER_SYNTH_DIR = _norm(
    _env_or_default(
        "SYN3D_PER_TIER_SYNTH_DIR",
        os.path.join(OBJECTS_DIR, "3dsyn", "per_tier_synth"),
    )
)
TMP_DIR = os.path.join(PER_TIER_SYNTH_DIR, "work")

PLATFORM_DIR = _repo_path("platforms", LIBRARY)
PLATFORMS_DIR = PLATFORM_DIR
DESIGN_DIR = _repo_path("designs", LIBRARY, DESIGN)

# Inputs: TritonPart netlist + partition result
NETLIST_V = os.path.join(RESULTS_DIR, "2_2_floorplan_io.v")
SOURCE_DEF = os.path.join(RESULTS_DIR, "2_2_floorplan_io.def")
SOURCE_PARTITION_TXT = os.path.join(RESULTS_DIR, "partition.txt")
PARTITION_TXT = _norm(os.getenv("PARTITION_TXT") or SOURCE_PARTITION_TXT)

COARSE_HANDOFF_DIR = os.path.join(COARSE_SYNTH_DIR, "handoff")
COARSE_2D_LEF_FILE = os.path.join(COARSE_HANDOFF_DIR, "lef", "2d", "coarse_units.lef")
COARSE_LEF_BOT = os.path.join(COARSE_HANDOFF_DIR, "lef", "bottom", "coarse_units.lef")
COARSE_LEF_UPPER = os.path.join(COARSE_HANDOFF_DIR, "lef", "upper", "coarse_units.lef")
COARSE_2D_LIB_DIR = os.path.join(COARSE_HANDOFF_DIR, "lib", "2d")
COARSE_SYNTH_BOT = os.path.join(COARSE_HANDOFF_DIR, "coarse_units", "bottom")
COARSE_SYNTH_UPPER = os.path.join(COARSE_HANDOFF_DIR, "coarse_units", "upper")

YOSYS = _norm(_required_env("YOSYS_EXE"))
GENUS = _norm(_required_env("GENUS_EXE"))

ASAP7_LIB_BASENAMES = [
    "asap7sc7p5t_AO_RVT_FF_nldm_211120",
    "asap7sc7p5t_INVBUF_RVT_FF_nldm_220122",
    "asap7sc7p5t_OA_RVT_FF_nldm_211120",
    "asap7sc7p5t_SEQ_RVT_FF_nldm_220123",
    "asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120",
]

LIBRARY_CONFIGS = {
    "asap7_3D": {
        "map_json": None,
        "tech_lef_file": _platform_path("asap7_3D", "lef", "asap7_tech_1x_2A6M7M.lef"),
        "adder_map_file": _platform_path("asap7_3D", "yoSys", "cells_adders_R.v"),
        "latch_map_file": _platform_path("asap7_3D", "yoSys", "cells_latch_R.v"),
        "synthesis_2d_platform_dir": _platform_path("asap7"),
        "synthesis_2d_lib_dir": _platform_path("asap7", "lib", "NLDM"),
        "synthesis_2d_lib_files": _platform_paths(
            "asap7",
            os.path.join("lib", "NLDM"),
            [f"{name}.lib" for name in ASAP7_LIB_BASENAMES],
        ),
        "bottom_tier": {
            "lef_dir": _platform_path("asap7_3D", "lef_bottom"),
            "standard_cell_lef": _platform_path("asap7_3D", "lef_bottom", "asap7sc7p5t_28_R_1x_220121a.bottom.lef"),
            "lib_dir": _platform_path("asap7_3D", "lib_bottom", "NLDM"),
            "lib_files": _platform_paths(
                "asap7_3D",
                os.path.join("lib_bottom", "NLDM"),
                [f"{name}.bottom.lib" for name in ASAP7_LIB_BASENAMES],
            ),
            "abc_clk_period_ps": None,
            "abc_driver_cell": "BUFx2_ASAP7_75t_R_bottom",
            "abc_load": 3.898,
            "tiehi_cell": "TIEHIx1_ASAP7_75t_R_bottom",
            "tiehi_pin": "H",
            "tielo_cell": "TIELOx1_ASAP7_75t_R_bottom",
            "tielo_pin": "L",
            "latch_pos_cell": "DHLx1_ASAP7_75t_R_bottom",
            "latch_pos_enable_pin": "CLK",
            "latch_neg_cell": "DLLx1_ASAP7_75t_R_bottom",
            "latch_neg_enable_pin": "CLK",
        },
        "upper_tier": {
            "lef_dir": _platform_path("asap7_3D", "lef_upper"),
            "standard_cell_lef": _platform_path("asap7_3D", "lef_upper", "asap7sc7p5t_28_R_1x_220121a.upper.lef"),
            "lib_dir": _platform_path("asap7_3D", "lib_upper", "NLDM"),
            "lib_files": _platform_paths(
                "asap7_3D",
                os.path.join("lib_upper", "NLDM"),
                [f"{name}.upper.lib" for name in ASAP7_LIB_BASENAMES],
            ),
            "abc_clk_period_ps": None,
            "abc_driver_cell": "BUFx2_ASAP7_75t_R_upper",
            "abc_load": 3.898,
            "tiehi_cell": "TIEHIx1_ASAP7_75t_R_upper",
            "tiehi_pin": "H",
            "tielo_cell": "TIELOx1_ASAP7_75t_R_upper",
            "tielo_pin": "L",
            "latch_pos_cell": "DHLx1_ASAP7_75t_R_upper",
            "latch_pos_enable_pin": "CLK",
            "latch_neg_cell": "DLLx1_ASAP7_75t_R_upper",
            "latch_neg_enable_pin": "CLK",
        },
    },
    "nangate45_3D": {
        "map_json": None,
        "tech_lef_file": _platform_path("nangate45_3D", "lef", "NangateOpenCellLibrary.tech.lef"),
        "adder_map_file": _platform_path("nangate45_3D", "cells_adders.v"),
        "latch_map_file": _platform_path("nangate45_3D", "cells_latch.v"),
        "synthesis_2d_platform_dir": _platform_path("nangate45"),
        "synthesis_2d_lib_dir": _platform_path("nangate45", "lib"),
        "synthesis_2d_lib_files": [
            _platform_path("nangate45", "lib", "NangateOpenCellLibrary_typical.lib"),
        ],
        "bottom_tier": {
            "lef_dir": _platform_path("nangate45_3D", "lef_bottom"),
            "standard_cell_lef": _platform_path("nangate45_3D", "lef_bottom", "NangateOpenCellLibrary.macro.mod.bottom.lef"),
            "lib_dir": _platform_path("nangate45_3D", "lib_bottom"),
            "lib_files": [
                _platform_path("nangate45_3D", "lib_bottom", "NangateOpenCellLibrary_typical.bottom.lib"),
            ],
            "abc_clk_period_ps": None,
            "abc_driver_cell": "BUF_X1_bottom",
            "abc_load": 3.898,
            "tiehi_cell": "LOGIC1_X1_bottom",
            "tiehi_pin": "Z",
            "tielo_cell": "LOGIC0_X1_bottom",
            "tielo_pin": "Z",
            "latch_pos_cell": "DLH_X1_bottom",
            "latch_pos_enable_pin": "G",
            "latch_neg_cell": "DLL_X1_bottom",
            "latch_neg_enable_pin": "GN",
        },
        "upper_tier": {
            "lef_dir": _platform_path("nangate45_3D", "lef_upper"),
            "standard_cell_lef": _platform_path("nangate45_3D", "lef_upper", "NangateOpenCellLibrary.macro.mod.upper.lef"),
            "lib_dir": _platform_path("nangate45_3D", "lib_upper"),
            "lib_files": [
                _platform_path("nangate45_3D", "lib_upper", "NangateOpenCellLibrary_typical.upper.lib"),
            ],
            "abc_clk_period_ps": None,
            "abc_driver_cell": "BUF_X1_upper",
            "abc_load": 3.898,
            "tiehi_cell": "LOGIC1_X1_upper",
            "tiehi_pin": "Z",
            "tielo_cell": "LOGIC0_X1_upper",
            "tielo_pin": "Z",
            "latch_pos_cell": "DLH_X1_upper",
            "latch_pos_enable_pin": "G",
            "latch_neg_cell": "DLL_X1_upper",
            "latch_neg_enable_pin": "GN",
        },
    },
    "asap7_nangate45_3D": {
        "map_json": _platform_path("asap7_nangate45_3D", "map.json"),
        "tech_lef_file": _platform_path("asap7_nangate45_3D", "lef", "asap7_nangate45_2A6M10M.lef"),
        "adder_map_file": _repo_path("platforms", "asap7_nangate45", "cells_adders.v"),
        "latch_map_file": _repo_path("platforms", "asap7_nangate45", "cells_latch.v"),
        "synthesis_2d_platform_dir": _platform_path("asap7_nangate45"),
        "synthesis_2d_lib_dir": _platform_path("asap7_nangate45", "lib"),
        "synthesis_2d_lib_files": [
            _platform_path("asap7_nangate45", "lib", "NangateOpenCellLibrary_typical.processed.lib"),
        ],
        "bottom_tier": {
            "lef_dir": _platform_path("asap7_nangate45_3D", "lef_bottom"),
            "standard_cell_lef": _platform_path("asap7_nangate45_3D", "lef_bottom", "NangateOpenCellLibrary.macro.mod.bottom.processed.lef"),
            "lib_dir": _platform_path("asap7_nangate45_3D", "lib_bottom"),
            "lib_files": [
                _platform_path("asap7_nangate45_3D", "lib_bottom", "NangateOpenCellLibrary_typical.bottom.processed.lib"),
            ],
            "abc_clk_period_ps": None,
            "abc_driver_cell": "BUF_X1_bottom",
            "abc_load": 3.898,
            "tiehi_cell": "LOGIC1_X1_bottom",
            "tiehi_pin": "Z",
            "tielo_cell": "LOGIC0_X1_bottom",
            "tielo_pin": "Z",
            "latch_pos_cell": "DLH_X1_bottom",
            "latch_pos_enable_pin": "G",
            "latch_neg_cell": "DLL_X1_bottom",
            "latch_neg_enable_pin": "GN",
        },
        "upper_tier": {
            "lef_dir": _platform_path("asap7_nangate45_3D", "lef_upper"),
            "standard_cell_lef": _platform_path("asap7_nangate45_3D", "lef_upper", "asap7sc7p5t_28_R_1x_220121a.upper.processed.lef"),
            "lib_dir": _platform_path("asap7_nangate45_3D", "lib_upper", "NLDM"),
            "lib_files": _platform_paths(
                "asap7_nangate45_3D",
                os.path.join("lib_upper", "NLDM"),
                [f"{name}.upper.processed.lib" for name in ASAP7_LIB_BASENAMES],
            ),
            "abc_clk_period_ps": None,
            "abc_driver_cell": "BUFx2_ASAP7_75t_R_upper",
            "abc_load": 3.898,
            "tiehi_cell": "TIEHIx1_ASAP7_75t_R_upper",
            "tiehi_pin": "H",
            "tielo_cell": "TIELOx1_ASAP7_75t_R_upper",
            "tielo_pin": "L",
            "latch_pos_cell": "DHLx1_ASAP7_75t_R_upper",
            "latch_pos_enable_pin": "CLK",
            "latch_neg_cell": "DLLx1_ASAP7_75t_R_upper",
            "latch_neg_enable_pin": "CLK",
        },
    },
}

if LIBRARY not in LIBRARY_CONFIGS:
    raise ValueError(f"Unsupported LIBRARY: {LIBRARY}")

LIBRARY_CONFIG = LIBRARY_CONFIGS[LIBRARY]
BOTTOM_TIER_CONFIG = LIBRARY_CONFIG["bottom_tier"]
UPPER_TIER_CONFIG = LIBRARY_CONFIG["upper_tier"]

MAP_JSON_RAW = LIBRARY_CONFIG["map_json"]
MAP_JSON = MAP_JSON_RAW or ""
MAP_JSON_STATUS = "configured" if MAP_JSON_RAW else "pending_homogeneous_map"
CELL_NAME_MAPPING_MODE = (
    "heterogeneous_map_json" if MAP_JSON_RAW else "homogeneous_base"
)
BOTTOM_CELL_SUFFIX = "_bottom"
UPPER_CELL_SUFFIX = "_upper"
TECH_LEF_FILE = LIBRARY_CONFIG["tech_lef_file"]
ADDER_MAP_FILE = LIBRARY_CONFIG["adder_map_file"]
LATCH_MAP_FILE = LIBRARY_CONFIG["latch_map_file"]
SYNTHESIS_2D_PLATFORM_DIR = LIBRARY_CONFIG["synthesis_2d_platform_dir"]
SYNTHESIS_2D_LIB_DIR = LIBRARY_CONFIG["synthesis_2d_lib_dir"]
DESIGN_ADDITIONAL_LIB_FILES = shlex.split(os.getenv("ADDITIONAL_LIBS", ""))
DESIGN_BOTTOM_ADDITIONAL_LIB_FILES = shlex.split(
    os.getenv("SYN3D_BOTTOM_ADDITIONAL_LIBS", "")
)
DESIGN_UPPER_ADDITIONAL_LIB_FILES = shlex.split(
    os.getenv("SYN3D_UPPER_ADDITIONAL_LIBS", "")
)
DESIGN_MACRO_LIB_FILES = list(
    dict.fromkeys(
        DESIGN_ADDITIONAL_LIB_FILES
        + DESIGN_BOTTOM_ADDITIONAL_LIB_FILES
        + DESIGN_UPPER_ADDITIONAL_LIB_FILES
    )
)
SYNTHESIS_2D_LIB_FILES = list(
    dict.fromkeys(
        list(LIBRARY_CONFIG["synthesis_2d_lib_files"])
        + DESIGN_ADDITIONAL_LIB_FILES
    )
)

DESIGN_SDC_FILE = _norm(_required_env("SDC_FILE"))

TOP_MODULE_NAME = DESIGN
BOTTOM_COARSE_MODULE_NAME = TOP_MODULE_NAME + "_coarse_bottom"
UPPER_COARSE_MODULE_NAME = TOP_MODULE_NAME + "_coarse_upper"
WRAPPER_TOP_MODULE_NAME = TOP_MODULE_NAME + "_per_tier_wrapper"
WRAPPER_UPPER_INSTANCE_NAME = "inst_upper"
WRAPPER_BOTTOM_INSTANCE_NAME = "inst_bottom"

LEF_BOT_DIR = BOTTOM_TIER_CONFIG["lef_dir"]
LEF_UPPER_DIR = UPPER_TIER_CONFIG["lef_dir"]
STANDARD_CELL_LEF_BOTTOM = BOTTOM_TIER_CONFIG["standard_cell_lef"]
STANDARD_CELL_LEF_UPPER = UPPER_TIER_CONFIG["standard_cell_lef"]

BOTTOM_LIB_DIR = BOTTOM_TIER_CONFIG["lib_dir"]
UPPER_LIB_DIR = UPPER_TIER_CONFIG["lib_dir"]
LIB_BOT_DIR = BOTTOM_LIB_DIR
LIB_UPPER_DIR = UPPER_LIB_DIR
BOTTOM_LIB_FILES = list(
    dict.fromkeys(
        list(BOTTOM_TIER_CONFIG["lib_files"])
        + DESIGN_BOTTOM_ADDITIONAL_LIB_FILES
    )
)
UPPER_LIB_FILES = list(
    dict.fromkeys(
        list(UPPER_TIER_CONFIG["lib_files"])
        + DESIGN_UPPER_ADDITIONAL_LIB_FILES
    )
)

SDC_CLK_PERIOD_RAW = _read_clk_period_raw(DESIGN_SDC_FILE)
SDC_CLK_PERIOD_UNIT = _clk_period_unit_for_library(LIBRARY)
SDC_CLK_PERIOD_PS = _clk_period_raw_to_ps(SDC_CLK_PERIOD_RAW, SDC_CLK_PERIOD_UNIT)
ABC_DRV_CELL_BOTTOM = BOTTOM_TIER_CONFIG["abc_driver_cell"]
ABC_LOAD_BOTTOM = BOTTOM_TIER_CONFIG["abc_load"]
ABC_DRV_CELL_UPPER = UPPER_TIER_CONFIG["abc_driver_cell"]
ABC_LOAD_UPPER = UPPER_TIER_CONFIG["abc_load"]

TIEHI_CELL_BOTTOM = BOTTOM_TIER_CONFIG["tiehi_cell"]
TIEHI_PIN_BOTTOM = BOTTOM_TIER_CONFIG["tiehi_pin"]
TIELO_CELL_BOTTOM = BOTTOM_TIER_CONFIG["tielo_cell"]
TIELO_PIN_BOTTOM = BOTTOM_TIER_CONFIG["tielo_pin"]
TIEHI_CELL_UPPER = UPPER_TIER_CONFIG["tiehi_cell"]
TIEHI_PIN_UPPER = UPPER_TIER_CONFIG["tiehi_pin"]
TIELO_CELL_UPPER = UPPER_TIER_CONFIG["tielo_cell"]
TIELO_PIN_UPPER = UPPER_TIER_CONFIG["tielo_pin"]

LATCH_POS_CELL_BOTTOM = BOTTOM_TIER_CONFIG["latch_pos_cell"]
LATCH_POS_ENABLE_PIN_BOTTOM = BOTTOM_TIER_CONFIG["latch_pos_enable_pin"]
LATCH_NEG_CELL_BOTTOM = BOTTOM_TIER_CONFIG["latch_neg_cell"]
LATCH_NEG_ENABLE_PIN_BOTTOM = BOTTOM_TIER_CONFIG["latch_neg_enable_pin"]
LATCH_POS_CELL_UPPER = UPPER_TIER_CONFIG["latch_pos_cell"]
LATCH_POS_ENABLE_PIN_UPPER = UPPER_TIER_CONFIG["latch_pos_enable_pin"]
LATCH_NEG_CELL_UPPER = UPPER_TIER_CONFIG["latch_neg_cell"]
LATCH_NEG_ENABLE_PIN_UPPER = UPPER_TIER_CONFIG["latch_neg_enable_pin"]

# Pin direction tables
PIN_DIR_JSON = os.path.join(TMP_DIR, "pin_dir.json")
COARSE_PIN_DIR_JSON = os.path.join(TMP_DIR, "coarse_pin_dir.json")

# Main intermediate handoff files kept in tmp/
SOURCE_JSON = os.path.join(TMP_DIR, f"02_{DESIGN}_source.json")
SOURCE_V = os.path.join(TMP_DIR, f"02_{DESIGN}_source.v")
BOTTOM_COARSE_JSON = os.path.join(TMP_DIR, f"02_{DESIGN}_bottom_coarse.json")
BOTTOM_COARSE_V = os.path.join(TMP_DIR, f"02_{DESIGN}_bottom_coarse.v")
UPPER_COARSE_JSON = os.path.join(TMP_DIR, f"02_{DESIGN}_upper_coarse.json")
UPPER_COARSE_V = os.path.join(TMP_DIR, f"02_{DESIGN}_upper_coarse.v")
SPLIT_PLAN_JSON = os.path.join(TMP_DIR, f"02_{DESIGN}_split_plan.json")
CLOCK_PORT_MAP_JSON = os.path.join(TMP_DIR, f"02_{DESIGN}_clock_port_map.json")
BOTTOM_COARSE_FULL_JSON = os.path.join(TMP_DIR, f"03_{DESIGN}_bottom_coarse_full.json")
BOTTOM_COARSE_FULL_V = os.path.join(TMP_DIR, f"03_{DESIGN}_bottom_coarse_full.v")
UPPER_COARSE_FULL_JSON = os.path.join(TMP_DIR, f"03_{DESIGN}_upper_coarse_full.json")
UPPER_COARSE_FULL_V = os.path.join(TMP_DIR, f"03_{DESIGN}_upper_coarse_full.v")
BOTTOM_REMAPPED_JSON = os.path.join(TMP_DIR, f"04_{DESIGN}_bottom_remapped.json")
BOTTOM_REMAPPED_V = os.path.join(TMP_DIR, f"04_{DESIGN}_bottom_remapped.v")
UPPER_REMAPPED_JSON = os.path.join(TMP_DIR, f"04_{DESIGN}_upper_remapped.json")
UPPER_REMAPPED_V = os.path.join(TMP_DIR, f"04_{DESIGN}_upper_remapped.v")
CELL_MAPPING_PLAN_JSON = os.path.join(TMP_DIR, f"04_{DESIGN}_cell_mapping_plan.json")

WRAPPER_JSON = os.path.join(TMP_DIR, f"05_{DESIGN}_wrapper.json")
WRAPPER_V = os.path.join(TMP_DIR, f"05_{DESIGN}_wrapper.v")
WRAPPER_PLAN_JSON = os.path.join(TMP_DIR, f"05_{DESIGN}_wrapper_plan.json")

GENUS_TMP_DIR = os.path.join(TMP_DIR, "06_synthesize_tiers")
GENUS_INPUT_V = os.path.join(GENUS_TMP_DIR, f"06_{DESIGN}_genus_input.v")
GENUS_TCL = os.path.join(GENUS_TMP_DIR, f"06_{DESIGN}_genus.tcl")
GENUS_SDC = os.path.join(GENUS_TMP_DIR, f"06_{DESIGN}_genus.sdc")
GENUS_OUTPUT_V = os.path.join(GENUS_TMP_DIR, f"06_{DESIGN}_genus_out.v")
GENUS_OUTPUT_JSON = os.path.join(GENUS_TMP_DIR, f"06_{DESIGN}_genus_out.json")
GENUS_POST_SDC = os.path.join(GENUS_TMP_DIR, f"06_{DESIGN}_genus_post.sdc")
GENUS_PLAN_JSON = os.path.join(GENUS_TMP_DIR, f"06_{DESIGN}_genus_plan.json")
GENUS_LOG_PREFIX = os.path.join(LOG_DIR, "3dsyn_per_tier_synth_genus")
GENUS_REPORT_DIR = os.path.join(REPORTS_DIR, "3dsyn", "per_tier_synth")
GENUS_DB_DIR = os.path.join(GENUS_TMP_DIR, f"06_{DESIGN}_db")

FLAT_JSON = os.path.join(TMP_DIR, f"07_{DESIGN}_flat.json")
FLAT_V = os.path.join(TMP_DIR, f"07_{DESIGN}_flat.v")
PARTITION_SEED_JSON = os.path.join(TMP_DIR, f"07_{DESIGN}_partition_seed.json")
RESTORED_BASE_JSON = os.path.join(TMP_DIR, f"08_{DESIGN}_base.json")
RESTORED_BASE_V = os.path.join(TMP_DIR, f"08_{DESIGN}_base.v")

# Final outputs
FINAL_BASE_V = os.path.join(RESULTS_DIR, "base.v")
FINAL_PARTITION = os.path.join(RESULTS_DIR, "partition_from_flow.txt")


def _assert_file(path: str, label: str) -> None:
    assert path and os.path.isfile(path), "{} not found or not a file: {}".format(label, path)


def _assert_dir(path: str, label: str) -> None:
    assert path and os.path.isdir(path), "{} not found or not a directory: {}".format(label, path)


def assert_required_source_inputs() -> None:
    """Check source artifacts shared by 01-04 before a flow run starts."""
    _assert_file(NETLIST_V, "NETLIST_V")
    _assert_file(PARTITION_TXT, "PARTITION_TXT")
    _assert_file(DESIGN_SDC_FILE, "DESIGN_SDC_FILE")
    _assert_file(SOURCE_DEF, "SOURCE_DEF")
    _assert_file(COARSE_2D_LEF_FILE, "COARSE_2D_LEF_FILE")
    _assert_file(COARSE_LEF_BOT, "COARSE_LEF_BOT")
    _assert_file(COARSE_LEF_UPPER, "COARSE_LEF_UPPER")
    _assert_dir(COARSE_2D_LIB_DIR, "COARSE_2D_LIB_DIR")
    _assert_dir(COARSE_SYNTH_BOT, "COARSE_SYNTH_BOT")
    _assert_dir(COARSE_SYNTH_UPPER, "COARSE_SYNTH_UPPER")
    _assert_file(STANDARD_CELL_LEF_BOTTOM, "STANDARD_CELL_LEF_BOTTOM")
    _assert_file(STANDARD_CELL_LEF_UPPER, "STANDARD_CELL_LEF_UPPER")
    _assert_dir(LEF_BOT_DIR, "LEF_BOT_DIR")
    _assert_dir(LEF_UPPER_DIR, "LEF_UPPER_DIR")
    if CELL_NAME_MAPPING_MODE == "heterogeneous_map_json":
        _assert_file(MAP_JSON, "MAP_JSON")
    else:
        assert CELL_NAME_MAPPING_MODE == "homogeneous_base", (
            "Unsupported CELL_NAME_MAPPING_MODE: {}".format(CELL_NAME_MAPPING_MODE)
        )


def ensure_output_dirs() -> None:
    os.makedirs(RESULTS_DIR, exist_ok=True)
    os.makedirs(TMP_DIR, exist_ok=True)
    os.makedirs(LOG_DIR, exist_ok=True)
    os.makedirs(GENUS_REPORT_DIR, exist_ok=True)
