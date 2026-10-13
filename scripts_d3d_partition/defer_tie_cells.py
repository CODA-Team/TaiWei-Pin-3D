#!/usr/bin/env python3
"""Defer configured tie cells around D3D partitioning.

``prepare`` writes a partition-only DEF with tie instances and their constant
nets removed.  ``rewrite-def`` removes the deferred objects from the generated
3D DEF, while ``rewrite-netlist`` expresses their connections as Verilog
constants.  The functional source artifacts are never modified; the manifest
joins all three operations.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


SCHEMA = "taiwei.d3d-partition.deferred-ties"
SCHEMA_VERSION = 1
SECTION_BEGIN = re.compile(r"^\s*([A-Z][A-Z0-9_]*)\s+(\d+)\s*;", re.IGNORECASE)
SECTION_END = re.compile(r"^\s*END\s+([A-Z][A-Z0-9_]*)\b", re.IGNORECASE)
COMPONENT = re.compile(r"^\s*-\s+(\S+)\s+(\S+)")
NET_NAME = re.compile(r"^\s*-\s+(\S+)")
DEF_CONNECTION = re.compile(r"\(\s+(\S+)\s+(\S+)\s*\)")
VERILOG_INSTANCE = re.compile(
    r"""^(\s*)((?:\\\S+)|(?:[A-Za-z_][\w$]*))(\s*)
         (?:\#\s*\(.*?\)\s*)?
         ((?:\\\S+)|(?:[A-Za-z_][\w$]*))\s*\(""",
    re.VERBOSE | re.DOTALL,
)


@dataclass(frozen=True)
class TieSpec:
    polarity: int
    cell: str
    port: str


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    )
    temporary = Path(handle.name)
    try:
        with handle:
            handle.write(text)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_def_name(name: str) -> str:
    return name.replace(r"\[", "[").replace(r"\]", "]").replace(r"\/", "/")


def normalize_verilog_name(name: str) -> str:
    value = name.strip()
    if value.startswith("\\"):
        value = value[1:].rstrip()
    return normalize_def_name(value)


def d2d_sanitized_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.]", "_", normalize_def_name(name))


def mask_verilog_comments(text: str) -> str:
    output = list(text)
    index = 0
    while index < len(output):
        if index + 1 < len(output) and output[index : index + 2] == ["/", "/"]:
            end = index
            while end < len(output) and output[end] != "\n":
                output[end] = " "
                end += 1
            index = end
        elif index + 1 < len(output) and output[index : index + 2] == ["/", "*"]:
            output[index] = output[index + 1] = " "
            index += 2
            while index + 1 < len(output) and output[index : index + 2] != ["*", "/"]:
                output[index] = " "
                index += 1
            if index + 1 < len(output):
                output[index] = output[index + 1] = " "
                index += 2
        else:
            index += 1
    return "".join(output)


def split_verilog_statements(text: str) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    depth = 0
    in_string = False
    escaped = False
    start = 0
    for index, character in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == '"':
            in_string = True
        elif character == "(":
            depth += 1
        elif character == ")" and depth:
            depth -= 1
        elif character == ";" and depth == 0:
            spans.append((start, index + 1))
            start = index + 1
    if start < len(text):
        spans.append((start, len(text)))
    return spans


def statement_ranges(lines: list[str], begin: int, end: int) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    start: int | None = None
    for index in range(begin, end):
        if start is None:
            if re.match(r"^\s*-\s+", lines[index]):
                start = index
                if ";" in lines[index]:
                    ranges.append((start, index + 1))
                    start = None
            continue
        if ";" in lines[index]:
            ranges.append((start, index + 1))
            start = None
    if start is not None:
        raise ValueError(f"unterminated DEF record beginning at line {start + 1}")
    return ranges


def find_section(lines: list[str], name: str) -> tuple[int, int, int]:
    wanted = name.upper()
    for header, line in enumerate(lines):
        match = SECTION_BEGIN.match(line)
        if not match or match.group(1).upper() != wanted:
            continue
        for section_end in range(header + 1, len(lines)):
            end_match = SECTION_END.match(lines[section_end])
            if end_match and end_match.group(1).upper() == wanted:
                return header, header + 1, section_end
        raise ValueError(f"DEF section {wanted} has no END {wanted}")
    raise ValueError(f"DEF has no {wanted} section")


def replace_section_count(line: str, section: str, count: int) -> str:
    pattern = re.compile(rf"^(\s*{re.escape(section)}\s+)\d+(\s*;.*)$", re.IGNORECASE)
    match = pattern.match(line.rstrip("\n"))
    if not match:
        raise ValueError(f"cannot update {section} count: {line.rstrip()}")
    suffix = "\n" if line.endswith("\n") else ""
    return f"{match.group(1)}{count}{match.group(2)}{suffix}"


def prepare_def(
    source: Path,
    output: Path,
    manifest_path: Path,
    specs: tuple[TieSpec, TieSpec],
) -> dict[str, object]:
    lines = source.read_text(encoding="utf-8", errors="strict").splitlines(keepends=True)
    component_header, component_begin, component_end = find_section(lines, "COMPONENTS")
    net_header, net_begin, net_end = find_section(lines, "NETS")

    by_master = {spec.cell: spec for spec in specs}
    deferred: dict[str, dict[str, object]] = {}
    removed_component_ranges: set[tuple[int, int]] = set()
    component_ranges = statement_ranges(lines, component_begin, component_end)
    for start, end in component_ranges:
        statement = "".join(lines[start:end])
        match = COMPONENT.match(statement)
        if not match:
            raise ValueError(f"cannot parse DEF component at line {start + 1}")
        instance, master = match.groups()
        spec = by_master.get(master)
        if spec is None:
            continue
        key = normalize_def_name(instance)
        if key in deferred:
            raise ValueError(f"duplicate configured tie instance in DEF: {instance}")
        deferred[key] = {
            "instance": instance,
            "normalized_instance": key,
            "d2d_name": d2d_sanitized_name(instance),
            "master": master,
            "output_pin": spec.port,
            "polarity": spec.polarity,
        }
        removed_component_ranges.add((start, end))

    removed_net_ranges: set[tuple[int, int]] = set()
    net_ranges = statement_ranges(lines, net_begin, net_end)
    for start, end in net_ranges:
        statement = "".join(lines[start:end])
        name_match = NET_NAME.match(statement)
        if not name_match:
            raise ValueError(f"cannot parse DEF net at line {start + 1}")
        connections = DEF_CONNECTION.findall(statement)
        drivers: list[str] = []
        for instance, pin in connections:
            record = deferred.get(normalize_def_name(instance))
            if record is not None and normalize_def_name(pin) == record["output_pin"]:
                drivers.append(normalize_def_name(instance))
        if not drivers:
            continue
        if len(drivers) != 1:
            raise ValueError(
                f"constant net {name_match.group(1)!r} has {len(drivers)} configured tie drivers"
            )
        driver = drivers[0]
        record = deferred[driver]
        if "net" in record:
            raise ValueError(f"tie instance {record['instance']!r} drives multiple DEF nets")
        record["net"] = name_match.group(1)
        record["normalized_net"] = normalize_def_name(name_match.group(1))
        record["sinks"] = [
            {"instance": instance, "pin": pin}
            for instance, pin in connections
            if normalize_def_name(instance) != driver
        ]
        removed_net_ranges.add((start, end))

    missing_nets = [record["instance"] for record in deferred.values() if "net" not in record]
    if missing_nets:
        raise ValueError(f"configured tie instances have no output net: {missing_nets}")

    for start, end in net_ranges:
        if (start, end) in removed_net_ranges:
            continue
        statement = "".join(lines[start:end])
        for instance, _ in DEF_CONNECTION.findall(statement):
            if normalize_def_name(instance) in deferred:
                raise ValueError(
                    f"configured tie instance {instance!r} remains on a non-constant DEF net"
                )

    skip_lines: set[int] = set()
    for start, end in removed_component_ranges | removed_net_ranges:
        skip_lines.update(range(start, end))
    output_lines = [line for index, line in enumerate(lines) if index not in skip_lines]

    # Headers precede all removed records, so their indices are unchanged.
    output_lines[component_header] = replace_section_count(
        output_lines[component_header],
        "COMPONENTS",
        len(component_ranges) - len(removed_component_ranges),
    )
    removed_before_net_header = sum(1 for index in skip_lines if index < net_header)
    adjusted_net_header = net_header - removed_before_net_header
    output_lines[adjusted_net_header] = replace_section_count(
        output_lines[adjusted_net_header],
        "NETS",
        len(net_ranges) - len(removed_net_ranges),
    )
    atomic_write(output, "".join(output_lines))

    records = sorted(deferred.values(), key=lambda item: str(item["normalized_instance"]))
    manifest: dict[str, object] = {
        "schema": SCHEMA,
        "schema_version": SCHEMA_VERSION,
        "source_def": str(source.resolve()),
        "source_def_sha256": sha256(source),
        "partition_def": str(output.resolve()),
        "partition_def_sha256": sha256(output),
        "source_component_count": len(component_ranges),
        "partition_component_count": len(component_ranges) - len(records),
        "source_net_count": len(net_ranges),
        "partition_net_count": len(net_ranges) - len(removed_net_ranges),
        "tie_specs": [
            {"cell": spec.cell, "output_pin": spec.port, "polarity": spec.polarity}
            for spec in specs
        ],
        "deferred_instances": records,
        "deferred_instance_count": len(records),
        "deferred_net_count": len(removed_net_ranges),
    }
    atomic_write(manifest_path, json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def read_manifest(path: Path) -> dict[str, object]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("deferred tie manifest must contain an object")
    if payload.get("schema") != SCHEMA or payload.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(
            f"unsupported deferred tie manifest: {payload.get('schema')!r} "
            f"version={payload.get('schema_version')!r}"
        )
    records = payload.get("deferred_instances")
    if not isinstance(records, list):
        raise ValueError("deferred tie manifest has no deferred_instances list")
    if payload.get("deferred_instance_count") != len(records):
        raise ValueError("deferred tie manifest instance count does not match records")
    return payload


def rewrite_deferred_def(input_path: Path, output_path: Path, manifest_path: Path) -> dict[str, int]:
    manifest = read_manifest(manifest_path)
    records = manifest["deferred_instances"]
    assert isinstance(records, list)
    deferred_instances = {
        str(record["normalized_instance"])
        for record in records
        if isinstance(record, dict)
    }
    deferred_nets = {
        str(record["normalized_net"])
        for record in records
        if isinstance(record, dict)
    }

    lines = input_path.read_text(encoding="utf-8", errors="strict").splitlines(keepends=True)
    component_header, component_begin, component_end = find_section(lines, "COMPONENTS")
    net_header, net_begin, net_end = find_section(lines, "NETS")
    component_ranges = statement_ranges(lines, component_begin, component_end)
    net_ranges = statement_ranges(lines, net_begin, net_end)

    removed_components: set[tuple[int, int]] = set()
    found_instances: set[str] = set()
    for start, end in component_ranges:
        match = COMPONENT.match("".join(lines[start:end]))
        if not match:
            raise ValueError(f"cannot parse generated DEF component at line {start + 1}")
        instance = normalize_def_name(match.group(1))
        if instance in deferred_instances:
            removed_components.add((start, end))
            found_instances.add(instance)

    removed_nets: set[tuple[int, int]] = set()
    found_nets: set[str] = set()
    for start, end in net_ranges:
        statement = "".join(lines[start:end])
        match = NET_NAME.match(statement)
        if not match:
            raise ValueError(f"cannot parse generated DEF net at line {start + 1}")
        net = normalize_def_name(match.group(1))
        if net in deferred_nets:
            removed_nets.add((start, end))
            found_nets.add(net)
            continue
        for instance, _ in DEF_CONNECTION.findall(statement):
            if normalize_def_name(instance) in deferred_instances:
                raise ValueError(
                    f"deferred tie instance {instance!r} remains on generated DEF net {match.group(1)!r}"
                )

    missing_instances = sorted(deferred_instances - found_instances)
    missing_nets = sorted(deferred_nets - found_nets)
    if missing_instances or missing_nets:
        raise ValueError(
            "generated DEF does not contain all deferred objects: "
            f"instances={missing_instances[:5]} nets={missing_nets[:5]}"
        )

    skip_lines: set[int] = set()
    for start, end in removed_components | removed_nets:
        skip_lines.update(range(start, end))
    output_lines = [line for index, line in enumerate(lines) if index not in skip_lines]
    output_lines[component_header] = replace_section_count(
        output_lines[component_header],
        "COMPONENTS",
        len(component_ranges) - len(removed_components),
    )
    removed_before_net_header = sum(1 for index in skip_lines if index < net_header)
    adjusted_net_header = net_header - removed_before_net_header
    output_lines[adjusted_net_header] = replace_section_count(
        output_lines[adjusted_net_header],
        "NETS",
        len(net_ranges) - len(removed_nets),
    )
    atomic_write(output_path, "".join(output_lines))
    result = {
        "removed_tie_instances": len(removed_components),
        "removed_constant_nets": len(removed_nets),
    }
    print(json.dumps(result, sort_keys=True))
    return result


def find_named_port_expression(statement: str, port: str) -> str | None:
    pattern = re.compile(rf"\.\s*{re.escape(port)}\s*\(\s*([^()]+?)\s*\)")
    match = pattern.search(statement)
    return match.group(1).strip() if match else None


def replace_named_port_net(statement: str, net: str, value: str) -> tuple[str, int]:
    pattern = re.compile(r"(\.\s*[A-Za-z_][\w$]*\s*\(\s*)([^()]+?)(\s*\))")
    count = 0

    def replacement(match: re.Match[str]) -> str:
        nonlocal count
        if normalize_verilog_name(match.group(2)) != normalize_verilog_name(net):
            return match.group(0)
        count += 1
        return f"{match.group(1)}{value}{match.group(3)}"

    return pattern.sub(replacement, statement), count


def replace_assign_rhs(statement: str, constants: dict[str, str]) -> tuple[str, int]:
    match = re.match(r"(?s)^(\s*assign\s+.+?=)(.*)(;\s*)$", statement)
    if not match:
        return statement, 0
    rhs = match.group(2)
    stripped = rhs.strip()
    normalized = normalize_verilog_name(stripped)
    if normalized not in constants:
        return statement, 0
    leading = rhs[: len(rhs) - len(rhs.lstrip())]
    trailing = rhs[len(rhs.rstrip()) :]
    return f"{match.group(1)}{leading}{constants[normalized]}{trailing}{match.group(3)}", 1


def rewrite_netlist(input_path: Path, output_path: Path, manifest_path: Path) -> dict[str, int]:
    manifest = read_manifest(manifest_path)
    records = manifest["deferred_instances"]
    assert isinstance(records, list)
    by_instance = {
        str(record["normalized_instance"]): record
        for record in records
        if isinstance(record, dict)
    }

    text = input_path.read_text(encoding="utf-8", errors="strict")
    masked = mask_verilog_comments(text)
    spans = split_verilog_statements(masked)
    tie_statement_spans: set[tuple[int, int]] = set()
    tie_statement_replacements: dict[tuple[int, int], str] = {}
    constants: dict[str, str] = {}
    found_instances: set[str] = set()

    for start, end in spans:
        statement = text[start:end]
        masked_statement = masked[start:end]
        match = VERILOG_INSTANCE.match(masked_statement)
        if not match:
            continue
        instance = normalize_verilog_name(match.group(4))
        record = by_instance.get(instance)
        if record is None:
            continue
        master = normalize_verilog_name(match.group(2))
        if master != str(record["master"]):
            raise ValueError(
                f"deferred instance {instance!r} uses unexpected master {master!r}; "
                f"expected {record['master']!r}"
            )
        net = find_named_port_expression(statement, str(record["output_pin"]))
        if net is None:
            raise ValueError(
                f"deferred tie instance {instance!r} has no output port {record['output_pin']!r}"
            )
        normalized_net = normalize_verilog_name(net)
        expected_net = str(record["normalized_net"])
        if normalized_net != expected_net:
            raise ValueError(
                f"deferred tie instance {instance!r} drives {normalized_net!r} in Verilog; "
                f"manifest records {expected_net!r}"
            )
        value = "1'b1" if record["polarity"] == 1 else "1'b0"
        previous = constants.get(normalized_net)
        if previous is not None and previous != value:
            raise ValueError(f"conflicting constants for Verilog net {normalized_net!r}")
        constants[normalized_net] = value
        tie_statement_spans.add((start, end))
        found_instances.add(instance)
        indent = match.group(1)
        tie_statement_replacements[(start, end)] = (
            f"{indent}assign {net} = {value};"
        )

    missing_instances = sorted(set(by_instance) - found_instances)
    if missing_instances:
        raise ValueError(f"deferred tie instances not found in generated Verilog: {missing_instances}")

    output: list[str] = []
    cursor = 0
    replaced_connections = 0
    replaced_assignments = 0
    for start, end in spans:
        output.append(text[cursor:start])
        statement = text[start:end]
        cursor = end
        if (start, end) in tie_statement_spans:
            output.append(tie_statement_replacements[(start, end)])
            continue
        for net, value in constants.items():
            statement, count = replace_named_port_net(statement, net, value)
            replaced_connections += count
        statement, count = replace_assign_rhs(statement, constants)
        replaced_assignments += count
        output.append(statement)
    output.append(text[cursor:])
    atomic_write(output_path, "".join(output))

    result = {
        "removed_tie_instances": len(tie_statement_spans),
        "constantized_port_connections": replaced_connections,
        "constantized_assignments": replaced_assignments,
    }
    print(json.dumps(result, sort_keys=True))
    return result


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare = subparsers.add_parser("prepare", help="create the tie-free partition DEF")
    prepare.add_argument("--def", dest="def_path", required=True, type=Path)
    prepare.add_argument("--output-def", required=True, type=Path)
    prepare.add_argument("--manifest", required=True, type=Path)
    prepare.add_argument("--tiehi-cell", required=True)
    prepare.add_argument("--tiehi-port", required=True)
    prepare.add_argument("--tielo-cell", required=True)
    prepare.add_argument("--tielo-port", required=True)

    rewrite = subparsers.add_parser(
        "rewrite-netlist",
        help="replace deferred singleton tie drivers with Verilog constants",
    )
    rewrite.add_argument("--input", required=True, type=Path)
    rewrite.add_argument("--output", required=True, type=Path)
    rewrite.add_argument("--manifest", required=True, type=Path)

    rewrite_def = subparsers.add_parser(
        "rewrite-def",
        help="remove deferred tie objects from the generated 3D DEF",
    )
    rewrite_def.add_argument("--input", required=True, type=Path)
    rewrite_def.add_argument("--output", required=True, type=Path)
    rewrite_def.add_argument("--manifest", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    if args.command == "prepare":
        for path, label in ((args.def_path, "source DEF"),):
            if not path.is_file():
                raise ValueError(f"{label} is not a file: {path}")
        specs = (
            TieSpec(1, args.tiehi_cell, args.tiehi_port),
            TieSpec(0, args.tielo_cell, args.tielo_port),
        )
        if specs[0].cell == specs[1].cell:
            raise ValueError("tiehi and tielo cell names must be different")
        manifest = prepare_def(
            args.def_path,
            args.output_def,
            args.manifest,
            specs,
        )
        print(
            "D3D_TIE_DEFER_COMPLETE "
            f"instances={manifest['deferred_instance_count']} "
            f"nets={manifest['deferred_net_count']} "
            f"output={args.output_def.resolve()}"
        )
        return 0

    if not args.input.is_file():
        raise ValueError(f"generated 3D view is not a file: {args.input}")
    if not args.manifest.is_file():
        raise ValueError(f"deferred tie manifest is not a file: {args.manifest}")
    if args.command == "rewrite-def":
        rewrite_deferred_def(args.input, args.output, args.manifest)
    else:
        rewrite_netlist(args.input, args.output, args.manifest)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"error: {error}")
