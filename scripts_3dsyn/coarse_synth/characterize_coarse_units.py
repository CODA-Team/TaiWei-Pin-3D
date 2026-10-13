#!/usr/bin/env python3
import argparse
import json
import math
import os
import re
import shutil
import subprocess
from pathlib import Path


SUPPORTED_PLATFORMS = {"asap7_3D", "nangate45_3D", "asap7_nangate45_3D"}


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--flow-home", required=True, type=Path)
    parser.add_argument("--platform", required=True, choices=sorted(SUPPORTED_PLATFORMS))
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--source-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--yosys", required=True, type=Path)
    parser.add_argument("--genus", required=True)
    parser.add_argument("--genus-script", required=True, type=Path)
    parser.add_argument("--predict-util", required=True, type=Path)
    parser.add_argument("--python", required=True)
    parser.add_argument("--fixed-util", type=float)
    return parser.parse_args()


def require_file(path, label):
    path = Path(path)
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError("{} is missing or empty: {}".format(label, path))


def collect_libs(path):
    libs = sorted(
        lib for lib in Path(path).rglob("*.lib")
        if "fakeram" not in lib.parts and not lib.name.startswith("sram_")
    )
    if not libs:
        raise RuntimeError("no liberty files found under {}".format(path))
    return libs


def platform_config(flow_home, platform):
    common_root = flow_home / "platforms" / "asap7_nangate45_3D"
    platform_root = flow_home / "platforms" / platform
    if platform == "nangate45_3D":
        return {
            "primary_tier": "bottom",
            "common_libs": collect_libs(common_root / "lib_bottom"),
            "native_libs": collect_libs(platform_root / "lib_bottom"),
            "scale_factor": 1.0,
            "common_root": common_root,
        }
    if platform == "asap7_3D":
        return {
            "primary_tier": "upper",
            "common_libs": collect_libs(common_root / "lib_upper"),
            "native_libs": collect_libs(platform_root / "lib_upper"),
            "scale_factor": 1.0,
            "common_root": common_root,
        }
    return {
        "primary_tier": "bottom",
        "common_libs": collect_libs(common_root / "lib_bottom"),
        "native_libs": None,
        "scale_factor": 1.0 / 7.0,
        "common_root": common_root,
    }


def run(command, log_path, env=None):
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as log_file:
        result = subprocess.run(command, stdout=log_file, stderr=subprocess.STDOUT, env=env,
                                check=False)
    return result.returncode


def prepare_yosys_liberty(libs, output_path, flow_home, library_name):
    if len(libs) == 1:
        return libs[0]

    merge_tool = Path(flow_home) / "util" / "mergeLib.pl"
    require_file(merge_tool, "TaiWei Liberty merge tool")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    log_path = output_path.with_suffix(".log")
    with output_path.open("w", encoding="utf-8") as output_file, \
            log_path.open("w", encoding="utf-8") as log_file:
        result = subprocess.run(
            ["perl", str(merge_tool), library_name] + [str(path) for path in libs],
            stdout=output_file,
            stderr=log_file,
            check=False,
        )
    if result.returncode != 0:
        raise RuntimeError("failed to merge Liberty files; see {}".format(log_path))
    require_file(output_path, "merged Yosys Liberty")
    return output_path


def yosys_map(unit_name, rtlil_path, liberty, output_path, work_dir, yosys):
    work_dir.mkdir(parents=True, exist_ok=True)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    script = work_dir / "map.ys"
    log_path = work_dir / "yosys.log"
    liberty_arg = " -liberty {}".format(liberty)
    script.write_text(
        "\n".join([
            "read_rtlil {}".format(rtlil_path),
            "hierarchy -check -top {}".format(unit_name),
            "techmap -map +/techmap.v",
            "techmap",
            "opt -fast",
            "abc{}".format(liberty_arg),
            "dfflibmap{}".format(liberty_arg),
            "abc{}".format(liberty_arg),
            "stat{}".format(liberty_arg),
            "write_verilog -noattr -noexpr {}".format(output_path),
            "",
        ]),
        encoding="utf-8",
    )
    if run([str(yosys), "-s", str(script)], log_path) != 0:
        raise RuntimeError("Yosys mapping failed for {}; see {}".format(unit_name, log_path))
    require_file(output_path, "Yosys mapped coarse-unit netlist")

    area = None
    for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "Chip area for module" in line:
            try:
                area = float(line.rsplit(":", 1)[1].strip())
            except (IndexError, ValueError):
                pass
    if area is None or area <= 0.0:
        raise RuntimeError("cannot parse mapped area for {} from {}".format(unit_name, log_path))
    return area


def genus_refine(unit_name, input_path, libs, output_path, work_dir, genus, genus_script):
    work_dir.mkdir(parents=True, exist_ok=True)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    area_report = work_dir / "area.rpt"
    area_value = work_dir / "area.txt"
    log_path = work_dir / "genus.log"
    env = os.environ.copy()
    env.update({
        "SYN3D_UNIT_NAME": unit_name,
        "SYN3D_UNIT_INPUT_NETLIST": str(input_path),
        "SYN3D_UNIT_OUTPUT_NETLIST": str(output_path),
        "SYN3D_UNIT_AREA_REPORT": str(area_report),
        "SYN3D_UNIT_AREA_VALUE": str(area_value),
        "SYN3D_UNIT_LIB_FILES": " ".join(str(path) for path in libs),
    })
    command = [genus, "-no_gui", "-batch", "-abort_on_error", "-overwrite",
               "-log", str(log_path), "-files", str(genus_script)]
    if run(command, work_dir / "launcher.log", env=env) != 0:
        return None
    try:
        area = float(area_value.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None
    if area <= 0.0 or not output_path.is_file() or output_path.stat().st_size == 0:
        return None
    return area


def normalize_gnn_netlist(source, output):
    declaration = re.compile(r"^(\s*)(input|output)\s+(\[[^]]+\]\s+)?([^;]+);\s*$")
    lines = []
    for line in source.read_text(encoding="utf-8", errors="replace").splitlines():
        match = declaration.match(line)
        if match and "," in match.group(4):
            indent, direction, width, names = match.groups()
            for name in names.split(","):
                lines.append("{}{} {}{};".format(indent, direction, width or "", name.strip()))
        else:
            lines.append(line)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")


def predict_utilization(args, cfg, unit_name, netlist_path, tier, work_dir):
    if args.fixed_util is not None:
        if not 0.0 < args.fixed_util <= 1.0:
            raise RuntimeError("--fixed-util must be in (0, 1]")
        return args.fixed_util, args.fixed_util, "fixed"

    gnn_netlist = work_dir / "gnn_input.v"
    normalize_gnn_netlist(netlist_path, gnn_netlist)
    command = [args.python, str(args.predict_util), str(gnn_netlist), unit_name, tier,
               "--common-platform-dir", str(cfg["common_root"])]
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False,
                            env=dict(os.environ, OMP_NUM_THREADS="1", MKL_NUM_THREADS="1",
                                     OPENBLAS_NUM_THREADS="1", NUMEXPR_NUM_THREADS="1"))
    (work_dir / "predict_util.log").write_text(
        result.stdout + result.stderr, encoding="utf-8")
    if result.returncode != 0:
        raise RuntimeError("utilization prediction failed for {}; see {}".format(
            unit_name, work_dir / "predict_util.log"))
    raw = float(result.stdout.strip().splitlines()[-1])
    used = round(max(0.3, min(1.0, raw)), 3)
    return raw, used, "gnn"


def synthesize(unit_name, rtlil_path, libs, yosys_liberty, root, yosys, genus, genus_script):
    yosys_netlist = root / "yosys" / "{}.v".format(unit_name)
    yosys_area = yosys_map(unit_name, rtlil_path, yosys_liberty, yosys_netlist,
                           root / "work" / "yosys" / unit_name, yosys)
    genus_netlist = root / "genus" / "{}.v".format(unit_name)
    genus_area = genus_refine(unit_name, yosys_netlist, libs, genus_netlist,
                              root / "work" / "genus" / unit_name, genus, genus_script)
    if genus_area is not None:
        return genus_netlist, genus_area, "genus_incremental"
    return yosys_netlist, yosys_area, "yosys_fallback"


def write_metric(path, metric):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(metric, indent=2) + "\n", encoding="utf-8")


def main():
    args = parse_args()
    for path, label in [(args.manifest, "coarse-unit manifest"),
                        (args.yosys, "Yosys executable"),
                        (args.genus_script, "coarse-unit Genus script"),
                        (args.predict_util, "utilization predictor")]:
        require_file(path, label)
    cfg = platform_config(args.flow_home.resolve(), args.platform)
    units = [line.strip() for line in args.manifest.read_text(encoding="utf-8").splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    args.output_dir.mkdir(parents=True, exist_ok=True)
    implementation_dir = args.output_dir / "implementation"
    library_dir = args.output_dir / "library"
    common_yosys_liberty = prepare_yosys_liberty(
        cfg["common_libs"], library_dir / "common.lib", args.flow_home.resolve(),
        "syn3d_common",
    )
    native_yosys_liberty = None
    if cfg["native_libs"] is not None:
        native_yosys_liberty = prepare_yosys_liberty(
            cfg["native_libs"], library_dir / "native.lib", args.flow_home.resolve(),
            "syn3d_native",
        )
    summary = {"platform": args.platform, "unit_count": len(units), "units": {}}

    for unit_name in units:
        rtlil_path = args.source_dir / "{}.rtlil".format(unit_name)
        require_file(rtlil_path, "canonical coarse-unit RTLIL")
        common_netlist, common_area, common_source = synthesize(
            unit_name, rtlil_path, cfg["common_libs"], common_yosys_liberty,
            args.output_dir / "common",
            args.yosys, args.genus, args.genus_script)
        raw_util, used_util, util_source = predict_utilization(
            args, cfg, unit_name, common_netlist, cfg["primary_tier"],
            args.output_dir / "common" / "work" / "gnn" / unit_name)

        final_netlist = common_netlist
        final_area = common_area
        final_source = common_source
        lib_role = "common"
        if cfg["native_libs"] is not None:
            final_netlist, final_area, final_source = synthesize(
                unit_name, rtlil_path, cfg["native_libs"], native_yosys_liberty,
                args.output_dir / "native",
                args.yosys, args.genus, args.genus_script)
            lib_role = "native"

        implementation_dir.mkdir(parents=True, exist_ok=True)
        hierarchy_netlist = implementation_dir / "{}.v".format(unit_name)
        shutil.copy2(final_netlist, hierarchy_netlist)
        primary_footprint = round(final_area / used_util, 3)
        other_footprint = round(primary_footprint * cfg["scale_factor"], 3)
        common_fields = {
            "schema_version": 1,
            "coarse_unit_type": unit_name,
            "platform": args.platform,
            "raw_predicted_utilization": raw_util,
            "predicted_utilization": used_util,
            "util_source": util_source,
            "common_cell_area": round(common_area, 3),
            "common_synthesis_source": common_source,
        }
        primary = dict(common_fields, tier=cfg["primary_tier"],
                       synthesis_lib_role=lib_role,
                       synthesis_source=final_source,
                       cell_area=round(final_area, 3),
                       footprint_area=primary_footprint,
                       footprint_source="cell_area / predicted_utilization")
        other_tier = "upper" if cfg["primary_tier"] == "bottom" else "bottom"
        other = dict(common_fields, tier=other_tier,
                     synthesis_lib_role="derived_from_{}".format(cfg["primary_tier"]),
                     synthesis_source="derived",
                     cell_area=None,
                     footprint_area=other_footprint,
                     footprint_source="scaled_from_{}".format(cfg["primary_tier"]),
                     scale_from_tier=cfg["primary_tier"],
                     scale_factor=round(cfg["scale_factor"], 6))
        metrics = {cfg["primary_tier"]: primary, other_tier: other}
        for tier, metric in metrics.items():
            write_metric(args.output_dir / "metrics" / tier / unit_name / "metrics.json", metric)
        summary["units"][unit_name] = {
            "common_cell_area": round(common_area, 3),
            "implementation_cell_area": round(final_area, 3),
            "predicted_utilization": used_util,
            "primary_footprint_area": primary_footprint,
            "implementation_netlist": str(hierarchy_netlist),
        }

    (args.output_dir / "summary.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print("Characterized {} coarse-unit types for {}".format(len(units), args.platform))


if __name__ == "__main__":
    main()
