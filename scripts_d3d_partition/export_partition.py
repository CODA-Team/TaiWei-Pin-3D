#!/usr/bin/env python3
"""Validate an ORFS D3D assignment and export TaiWei partition.txt."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Sequence


COMPONENTS_BEGIN = re.compile(r"^\s*COMPONENTS\b", re.IGNORECASE)
COMPONENTS_END = re.compile(r"^\s*END\s+COMPONENTS\b", re.IGNORECASE)
COMPONENT = re.compile(r"^\s*-\s+(\S+)\s+\S+")
EXPECTED_SCHEMA = "orfs.d3d-partition.assignment"
DEFERRED_SCHEMA = "taiwei.d3d-partition.deferred-ties"


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


def read_def_components(path: Path) -> list[str]:
    components: list[str] = []
    in_components = False
    found_end = False
    with path.open("r", encoding="utf-8", errors="strict") as stream:
        for line in stream:
            if not in_components:
                if COMPONENTS_BEGIN.match(line):
                    in_components = True
                continue
            if COMPONENTS_END.match(line):
                found_end = True
                break
            match = COMPONENT.match(line)
            if match:
                components.append(match.group(1))

    if not in_components:
        raise ValueError(f"DEF has no COMPONENTS section: {path}")
    if not found_end:
        raise ValueError(f"DEF COMPONENTS section has no END COMPONENTS: {path}")
    if not components:
        raise ValueError(f"DEF COMPONENTS section is empty: {path}")
    duplicate_count = len(components) - len(set(components))
    if duplicate_count:
        raise ValueError(f"DEF contains {duplicate_count} duplicate component names")
    return components


def d2d_sanitized_name(def_token: str) -> str:
    canonical = def_token.replace("\\[", "[").replace("\\]", "]")
    return re.sub(r"[^A-Za-z0-9_.]", "_", canonical)


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


def read_deferred_ties(path: Path, def_path: Path) -> tuple[set[str], dict[str, object]]:
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
    return names, payload


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
    components = read_def_components(args.def_path)
    assignments, payload = read_assignment(args.assignment)
    deferred: set[str] = set()
    deferred_payload: dict[str, object] = {}
    if args.deferred_ties is not None:
        deferred, deferred_payload = read_deferred_ties(
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
    partition_text = "".join(
        f"{instance_name} {tier}\n"
        for (instance_name, _), tier in zip(partitioned_components, tiers)
    )
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
        "name_mapping": "DEF bracket unescape then non-[A-Za-z0-9_.] to underscore",
        "normalized_name_collisions": collision_count,
        "output_path": str(args.output.resolve()),
        "output_sha256": sha256(args.output),
        "tier_contract": {"0": "upper", "1": "bottom"},
        "tier0_count": tiers.count(0),
        "tier1_count": tiers.count(1),
    }
    atomic_write(args.summary, json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"error: {error}")
