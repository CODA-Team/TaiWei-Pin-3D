#!/usr/bin/env python3

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
STAGE_DIR = TEST_DIR.parent
FLOW_HOME = STAGE_DIR.parent.parent
TOOLKIT_ROOT = FLOW_HOME / "scripts_3dsyn" / "coarse_synth" / "common"
sys.path.insert(0, str(TOOLKIT_ROOT))

from yosys_json_toolkit import load_design, module_port_shape_signature  # noqa: E402


DEFAULT_YOSYS = (
    FLOW_HOME.parent / "ORFS-Research" / "tools" / "install" / "yosys" / "bin" / "yosys"
)


def resolve_executable(env_name, default):
    configured = os.environ.get(env_name)
    if configured:
        path = Path(configured)
    else:
        discovered = shutil.which(default)
        path = Path(discovered) if discovered else Path(default)
    if not path.is_file():
        raise RuntimeError("{} executable not found: {}".format(env_name, path))
    return path


def write_yosys_json(yosys, verilog, output_json):
    script = "read_verilog {}; hierarchy -top port_shapes; proc; write_json {}".format(
        verilog, output_json
    )
    subprocess.run([str(yosys), "-q", "-p", script], check=True)


def main():
    yosys = resolve_executable("YOSYS_EXE", str(DEFAULT_YOSYS))
    genus = resolve_executable("GENUS_EXE", "genus")
    library = (
        FLOW_HOME / "platforms" / "nangate45" / "lib" / "NangateOpenCellLibrary_typical.lib"
    )
    source = TEST_DIR / "data" / "port_shapes.v"
    if not library.is_file():
        raise RuntimeError("Test Liberty file not found: {}".format(library))

    with tempfile.TemporaryDirectory(prefix="syn3d_genus_port_interface_") as temp_dir:
        temp = Path(temp_dir)
        genus_v = temp / "genus.v"
        genus_tcl = temp / "genus.tcl"
        genus_tcl.write_text(
            "set lib_list [list {library}]\n"
            "set link_library $lib_list\n"
            "set target_library $lib_list\n"
            "set_db library $lib_list\n"
            "read_hdl -sv {source}\n"
            "elaborate port_shapes\n"
            "write_hdl > {output}\n"
            "exit\n".format(library=library, source=source, output=genus_v)
        )
        subprocess.run(
            [
                str(genus),
                "-legacy_ui",
                "-batch",
                "-files",
                str(genus_tcl),
                "-log",
                str(temp / "genus"),
            ],
            check=True,
        )

        source_json = temp / "source.json"
        genus_json = temp / "genus.json"
        write_yosys_json(yosys, source, source_json)
        write_yosys_json(yosys, genus_v, genus_json)
        source_top = load_design(str(source_json)).modules["port_shapes"]
        genus_top = load_design(str(genus_json)).modules["port_shapes"]
        assert module_port_shape_signature(source_top) == module_port_shape_signature(genus_top), (
            "Genus round-trip changed the semantic primary interface"
        )

    print("Genus port-interface round-trip passed")


if __name__ == "__main__":
    main()
