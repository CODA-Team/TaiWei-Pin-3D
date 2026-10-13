#!/usr/bin/env python3
"""Validate an ORFS D3D assignment and export TaiWei partition.txt."""

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


SECTION_BEGIN = re.compile(r"^\s*([A-Z][A-Z0-9_]*)\s+(\d+)\s*;", re.IGNORECASE)
SECTION_END = re.compile(r"^\s*END\s+([A-Z][A-Z0-9_]*)\b", re.IGNORECASE)
COMPONENT = re.compile(r"^\s*-\s+(\S+)\s+(\S+)")
RECORD_NAME = re.compile(r"^\s*-\s+(\S+)")
DEF_CONNECTION = re.compile(r"\(\s+(\S+)\s+(\S+)\s*\)")
PORT_NET = re.compile(r"\+\s+NET\s+(\S+)", re.IGNORECASE)
PORT_DIRECTION = re.compile(r"\+\s+DIRECTION\s+(INPUT|OUTPUT|INOUT)\b", re.IGNORECASE)
PORT_USE = re.compile(r"\+\s+USE\s+(\S+)", re.IGNORECASE)
SUPPLY_USES = frozenset({"POWER", "GROUND"})
EXPECTED_SCHEMA = "orfs.d3d-partition.assignment"
DEFERRED_SCHEMA = "taiwei.d3d-partition.deferred-ties"
IO_ASSIGNMENT_POLICY = "unique_connected_component_majority_tie_to_tier1"


@dataclass(frozen=True)
class DefPort:
    name: str
    normalized_name: str
    net: str
    normalized_net: str
    direction: str
    use: str | None


@dataclass(frozen=True)
class DefNet:
    name: str
    normalized_name: str
    components: frozenset[str]
    ports: frozenset[str]


@dataclass(frozen=True)
class DefDesign:
    components: tuple[str, ...]
    normalized_components: frozenset[str]
    signal_ports: tuple[DefPort, ...]
    nets: dict[str, DefNet]


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


def find_section(lines: list[str], name: str) -> tuple[int, int]:
    wanted = name.upper()
    for header, line in enumerate(lines):
        match = SECTION_BEGIN.match(line)
        if not match or match.group(1).upper() != wanted:
            continue
        for section_end in range(header + 1, len(lines)):
            end_match = SECTION_END.match(lines[section_end])
            if end_match and end_match.group(1).upper() == wanted:
                return header + 1, section_end
        raise ValueError(f"DEF section {wanted} has no END {wanted}")
    raise ValueError(f"DEF has no {wanted} section")


def statement_ranges(lines: list[str], begin: int, end: int) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    start: int | None = None
    for index in range(begin, end):
        if start is None:
            if re.match(r"^\s*-\s+", lines[index]):
                start = index
        if start is not None and ";" in lines[index]:
            ranges.append((start, index + 1))
            start = None
    if start is not None:
        raise ValueError(f"unterminated DEF record beginning at line {start + 1}")
    return ranges


def require_unique(values: list[str], label: str) -> None:
    duplicate_count = len(values) - len(set(values))
    if duplicate_count:
        raise ValueError(f"DEF contains {duplicate_count} duplicate {label} names")


def read_def_design(path: Path) -> DefDesign:
    lines = path.read_text(encoding="utf-8", errors="strict").splitlines(keepends=True)

    component_begin, component_end = find_section(lines, "COMPONENTS")
    components: list[str] = []
    normalized_components: list[str] = []
    for start, end in statement_ranges(lines, component_begin, component_end):
        statement = "".join(lines[start:end])
        match = COMPONENT.match(statement)
        if not match:
            raise ValueError(f"cannot parse DEF component at line {start + 1}")
        components.append(match.group(1))
        normalized_components.append(normalize_def_name(match.group(1)))
    if not components:
        raise ValueError(f"DEF COMPONENTS section is empty: {path}")
    require_unique(components, "component")
    require_unique(normalized_components, "normalized component")
    component_set = frozenset(normalized_components)

    pin_begin, pin_end = find_section(lines, "PINS")
    all_ports: list[str] = []
    normalized_all_ports: list[str] = []
    signal_ports: list[DefPort] = []
    for start, end in statement_ranges(lines, pin_begin, pin_end):
        statement = "".join(lines[start:end])
        name_match = RECORD_NAME.match(statement)
        direction_match = PORT_DIRECTION.search(statement)
        if not name_match:
            raise ValueError(f"cannot parse DEF pin at line {start + 1}")
        name = name_match.group(1)
        normalized_name = normalize_def_name(name)
        all_ports.append(name)
        normalized_all_ports.append(normalized_name)
        use_match = PORT_USE.search(statement)
        use = use_match.group(1).upper() if use_match else None
        if use in SUPPLY_USES:
            continue
        if direction_match is None:
            raise ValueError(f"non-supply DEF pin {name!r} has no INPUT/OUTPUT/INOUT direction")
        net_match = PORT_NET.search(statement)
        if net_match is None:
            raise ValueError(f"signal DEF pin {name!r} has no NET")
        net = net_match.group(1)
        signal_ports.append(
            DefPort(
                name=name,
                normalized_name=normalized_name,
                net=net,
                normalized_net=normalize_def_name(net),
                direction=direction_match.group(1).upper(),
                use=use,
            )
        )
    require_unique(all_ports, "port")
    require_unique(normalized_all_ports, "normalized port")
    overlap = sorted(component_set & set(normalized_all_ports))
    if overlap:
        raise ValueError(
            "DEF component and port names overlap after normalization: "
            f"count={len(overlap)} first={overlap[:5]}"
        )

    net_begin, net_end = find_section(lines, "NETS")
    nets: dict[str, DefNet] = {}
    port_net_occurrences: dict[str, int] = {}
    for start, end in statement_ranges(lines, net_begin, net_end):
        statement = "".join(lines[start:end])
        name_match = RECORD_NAME.match(statement)
        if not name_match:
            raise ValueError(f"cannot parse DEF net at line {start + 1}")
        name = name_match.group(1)
        normalized_name = normalize_def_name(name)
        if normalized_name in nets:
            raise ValueError(f"duplicate DEF net after normalization: {name!r}")
        net_components: set[str] = set()
        net_ports: set[str] = set()
        # DEF connection tuples precede the first ``+`` property.  Restrict
        # endpoint parsing to that prefix so routed coordinates such as
        # ``( 100 200 )`` are never mistaken for instance/pin connections.
        connection_prefix = re.split(r"\s+\+\s+", statement, maxsplit=1)[0]
        for endpoint, pin in DEF_CONNECTION.findall(connection_prefix):
            if endpoint.upper() == "PIN":
                net_ports.add(normalize_def_name(pin))
            else:
                normalized_endpoint = normalize_def_name(endpoint)
                if normalized_endpoint not in component_set:
                    raise ValueError(
                        f"DEF net {name!r} references unknown component {endpoint!r}"
                    )
                net_components.add(normalized_endpoint)
        nets[normalized_name] = DefNet(
            name=name,
            normalized_name=normalized_name,
            components=frozenset(net_components),
            ports=frozenset(net_ports),
        )
        for port_name in net_ports:
            port_net_occurrences[port_name] = port_net_occurrences.get(port_name, 0) + 1

    known_ports = set(normalized_all_ports)
    for net in nets.values():
        unknown_ports = sorted(net.ports - known_ports)
        if unknown_ports:
            raise ValueError(
                f"DEF net {net.name!r} references unknown ports: {unknown_ports[:5]}"
            )
    for port in signal_ports:
        net = nets.get(port.normalized_net)
        if net is None:
            raise ValueError(f"signal DEF pin {port.name!r} references missing net {port.net!r}")
        if port.normalized_name not in net.ports:
            raise ValueError(
                f"signal DEF pin {port.name!r} is absent from NETS record {net.name!r}"
            )
        occurrences = port_net_occurrences[port.normalized_name]
        if occurrences != 1:
            raise ValueError(
                f"signal DEF pin {port.name!r} appears in {occurrences} NETS records"
            )

    return DefDesign(
        components=tuple(components),
        normalized_components=component_set,
        signal_ports=tuple(signal_ports),
        nets=nets,
    )


def d2d_sanitized_name(def_token: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.]", "_", normalize_def_name(def_token))


def read_assignment(path: Path) -> tuple[dict[str, int], dict[str, object]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("assignment JSON must contain an object")
    if payload.get("schema") != EXPECTED_SCHEMA or payload.get("schema_version") != 1:
        raise ValueError(
            "unsupported assignment schema: "
            f"{payload.get('schema')!r} version={payload.get('schema_version')!r}"
        )
    records = payload.get("assignments")
    if not isinstance(records, list) or not records:
        raise ValueError("assignment JSON has no assignment records")

    assignments: dict[str, int] = {}
    for index, record in enumerate(records):
        if not isinstance(record, dict):
            raise ValueError(f"assignment record {index} is not an object")
        node = record.get("node")
        tier = record.get("tier")
        if not isinstance(node, str) or not node:
            raise ValueError(f"assignment record {index} has an invalid node name")
        if type(tier) is not int or tier not in (0, 1):
            raise ValueError(f"assignment record {index} has invalid tier {tier!r}")
        if node in assignments:
            raise ValueError(f"assignment JSON contains duplicate node {node!r}")
        assignments[node] = tier

    movable_count = payload.get("movable_count")
    if type(movable_count) is not int or movable_count != len(assignments):
        raise ValueError(
            "assignment movable_count does not match records: "
            f"{movable_count!r} != {len(assignments)}"
        )
    return assignments, payload


def read_deferred_ties(
    path: Path, def_path: Path
) -> tuple[set[str], set[str], dict[str, object]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("deferred tie manifest must contain an object")
    if payload.get("schema") != DEFERRED_SCHEMA or payload.get("schema_version") != 1:
        raise ValueError(
            "unsupported deferred tie manifest: "
            f"{payload.get('schema')!r} version={payload.get('schema_version')!r}"
        )
    if payload.get("source_def_sha256") != sha256(def_path):
        raise ValueError("deferred tie manifest does not match the source DEF")
    records = payload.get("deferred_instances")
    if not isinstance(records, list):
        raise ValueError("deferred tie manifest has no deferred_instances list")
    if payload.get("deferred_instance_count") != len(records):
        raise ValueError("deferred tie manifest instance count does not match records")

    names: set[str] = set()
    def_names: set[str] = set()
    for index, record in enumerate(records):
        if not isinstance(record, dict):
            raise ValueError(f"deferred tie record {index} is not an object")
        name = record.get("d2d_name")
        polarity = record.get("polarity")
        if not isinstance(name, str) or not name:
            raise ValueError(f"deferred tie record {index} has an invalid D2D name")
        if polarity not in (0, 1):
            raise ValueError(f"deferred tie record {index} has invalid polarity")
        if name in names:
            raise ValueError(f"deferred tie manifest contains duplicate node {name!r}")
        names.add(name)
        def_name = record.get("normalized_instance")
        if not isinstance(def_name, str) or not def_name:
            raise ValueError(
                f"deferred tie record {index} has an invalid normalized_instance"
            )
        if def_name in def_names:
            raise ValueError(
                f"deferred tie manifest contains duplicate DEF node {def_name!r}"
            )
        def_names.add(def_name)
    return names, def_names, payload


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--def", dest="def_path", required=True, type=Path)
    parser.add_argument("--assignment", required=True, type=Path)
    parser.add_argument("--deferred-ties", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    design = read_def_design(args.def_path)
    components = list(design.components)
    assignments, payload = read_assignment(args.assignment)
    deferred: set[str] = set()
    deferred_def_names: set[str] = set()
    deferred_payload: dict[str, object] = {}
    if args.deferred_ties is not None:
        deferred, deferred_def_names, deferred_payload = read_deferred_ties(
            args.deferred_ties,
            args.def_path,
        )

    normalized_names = [d2d_sanitized_name(name) for name in components]
    collision_count = len(normalized_names) - len(set(normalized_names))
    if collision_count:
        raise ValueError(
            f"DEF-to-D2D name normalization creates {collision_count} collision(s)"
        )
    all_components = set(normalized_names)
    unknown_deferred = sorted(deferred - all_components)
    if unknown_deferred:
        raise ValueError(
            "deferred tie manifest names are absent from DEF: "
            f"count={len(unknown_deferred)} first={unknown_deferred[:5]}"
        )
    overlap = sorted(deferred & set(assignments))
    if overlap:
        raise ValueError(
            "D2D assignment unexpectedly includes deferred tie components: "
            f"count={len(overlap)} first={overlap[:5]}"
        )

    expected = all_components - deferred
    actual = set(assignments)
    missing = sorted(expected - actual)
    unknown = sorted(actual - expected)
    if missing or unknown:
        raise ValueError(
            "D2D assignment does not cover DEF components exactly "
            "(excluding deferred ties): "
            f"missing={len(missing)} first={missing[:5]} "
            f"unknown={len(unknown)} first={unknown[:5]}"
        )

    partitioned_components = [
        (instance_name, normalized_name)
        for instance_name, normalized_name in zip(components, normalized_names)
        if normalized_name not in deferred
    ]
    tiers = [assignments[name] for _, name in partitioned_components]
    partition_lines = [
        f"{instance_name} {tier}\n"
        for (instance_name, _), tier in zip(partitioned_components, tiers)
    ]

    component_d2d_names = {
        normalize_def_name(instance): normalized
        for instance, normalized in zip(components, normalized_names)
    }
    port_assignments: list[dict[str, object]] = []
    port_tiers: list[int] = []
    port_tie_count = 0
    port_no_neighbor_count = 0
    for port in design.signal_ports:
        net = design.nets[port.normalized_net]
        upper_count = 0
        bottom_count = 0
        for component in net.components:
            if component in deferred_def_names:
                continue
            d2d_name = component_d2d_names[component]
            tier = assignments.get(d2d_name)
            if tier is None:
                raise ValueError(
                    f"DEF net {net.name!r} component {component!r} has no D3D assignment"
                )
            if tier == 0:
                upper_count += 1
            else:
                bottom_count += 1

        if upper_count > bottom_count:
            tier = 0
            reason = "upper_majority"
        elif bottom_count > upper_count:
            tier = 1
            reason = "bottom_majority"
        else:
            tier = 1
            port_tie_count += 1
            if upper_count == 0:
                reason = "no_partitioned_neighbor"
                port_no_neighbor_count += 1
            else:
                reason = "tie_to_bottom"

        partition_lines.append(f"{port.name} {tier}\n")
        port_tiers.append(tier)
        port_assignments.append(
            {
                "port": port.name,
                "net": net.name,
                "direction": port.direction,
                "upper_component_count": upper_count,
                "bottom_component_count": bottom_count,
                "tier": tier,
                "reason": reason,
            }
        )

    partition_text = "".join(partition_lines)
    atomic_write(args.output, partition_text)

    summary = {
        "schema": "taiwei.d3d-partition.summary",
        "schema_version": 1,
        "algorithm_assignment_path": str(args.assignment.resolve()),
        "algorithm_assignment_sha256": sha256(args.assignment),
        "algorithm_case_name": payload.get("case_name"),
        "component_count": len(components),
        "partitioned_component_count": len(partitioned_components),
        "deferred_tie_count": len(deferred),
        "deferred_tie_manifest_path": (
            str(args.deferred_ties.resolve()) if args.deferred_ties else None
        ),
        "deferred_tie_manifest_sha256": (
            sha256(args.deferred_ties) if args.deferred_ties else None
        ),
        "deferred_tie_instances": sorted(deferred),
        "deferred_tie_net_count": deferred_payload.get("deferred_net_count", 0),
        "def_path": str(args.def_path.resolve()),
        "def_sha256": sha256(args.def_path),
        "name_mapping": "DEF bracket/slash unescape then non-[A-Za-z0-9_.] to underscore",
        "normalized_name_collisions": collision_count,
        "output_path": str(args.output.resolve()),
        "output_sha256": sha256(args.output),
        "tier_contract": {"0": "upper", "1": "bottom"},
        "tier0_count": tiers.count(0),
        "tier1_count": tiers.count(1),
        "signal_port_count": len(design.signal_ports),
        "port_tier0_count": port_tiers.count(0),
        "port_tier1_count": port_tiers.count(1),
        "port_tie_count": port_tie_count,
        "port_no_partitioned_neighbor_count": port_no_neighbor_count,
        "total_partition_entry_count": len(partition_lines),
        "io_assignment_policy": IO_ASSIGNMENT_POLICY,
        "io_assignments": port_assignments,
    }
    atomic_write(args.summary, json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"error: {error}")
