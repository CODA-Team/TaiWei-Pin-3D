#!/usr/bin/env python3
"""Instantiate tier-local physical tie cells for deferred Verilog constants.

This runs after ``defer_tie_cells.py rewrite-netlist`` and before OpenROAD
reads the generated 3D Verilog.  Only endpoints recorded in the deferred-tie
manifest are changed; unrelated Verilog constants are left untouched.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from defer_tie_cells import (
    VERILOG_INSTANCE,
    atomic_write,
    find_named_port_expression,
    mask_verilog_comments,
    normalize_verilog_name,
    read_manifest,
    split_verilog_statements,
)


ASSIGN = re.compile(r"(?s)^\s*assign\s+(.+?)\s*=\s*(.+?)\s*;\s*$")
SIMPLE_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*$")


@dataclass(frozen=True)
class TieCell:
    cell: str
    port: str


@dataclass(frozen=True)
class InstantiatedEndpoint:
    polarity: int
    tier: str
    kind: str
    source_instance: str
    source_pin: str
    tie_cell: str
    tie_port: str
    tie_instance: str
    tie_net: str


def parse_tie_cell(value: str, option: str) -> TieCell:
    fields = value.split()
    if len(fields) != 2 or not all(SIMPLE_NAME.fullmatch(field) for field in fields):
        raise ValueError(f"{option} must contain exactly 'cell pin': {value!r}")
    return TieCell(fields[0], fields[1])


def instance_tier(master: str, instance: str) -> str:
    if master.endswith("_upper"):
        return "upper"
    if master.endswith("_bottom"):
        return "bottom"
    raise ValueError(
        f"constant consumer {instance!r} uses master {master!r} without an "
        "_upper/_bottom tier suffix"
    )


def replace_named_port_expression(statement: str, port: str, value: str) -> str:
    pattern = re.compile(
        rf"(\.\s*{re.escape(port)}\s*\(\s*)([^()]+?)(\s*\))"
    )
    replaced, count = pattern.subn(rf"\g<1>{value}\g<3>", statement)
    if count != 1:
        raise ValueError(f"expected one connection for port {port!r}, found {count}")
    return replaced


def unique_name(prefix: str, text: str, reserved: set[str]) -> str:
    index = 0
    while True:
        candidate = f"{prefix}_{index}"
        if candidate not in text and candidate not in reserved:
            reserved.add(candidate)
            return candidate
        index += 1


def instantiate_ties(
    input_path: Path,
    output_path: Path,
    manifest_path: Path,
    tie_cells: dict[tuple[str, int], TieCell],
    port_tier: str,
    summary_path: Path | None,
) -> dict[str, object]:
    manifest = read_manifest(manifest_path)
    records = manifest["deferred_instances"]
    assert isinstance(records, list)

    text = input_path.read_text(encoding="utf-8", errors="strict")
    masked = mask_verilog_comments(text)
    spans = split_verilog_statements(masked)

    instances: dict[str, tuple[str, tuple[int, int]]] = {}
    assignments: dict[str, tuple[str, tuple[int, int]]] = {}
    for start, end in spans:
        masked_statement = masked[start:end]
        instance_match = VERILOG_INSTANCE.match(masked_statement)
        if instance_match:
            master = normalize_verilog_name(instance_match.group(2))
            instance = normalize_verilog_name(instance_match.group(4))
            if instance in instances:
                raise ValueError(f"duplicate Verilog instance name: {instance!r}")
            instances[instance] = (master, (start, end))
            continue

        assign_match = ASSIGN.match(masked_statement)
        if assign_match:
            lhs = normalize_verilog_name(assign_match.group(1))
            rhs = assign_match.group(2).strip()
            if lhs in assignments:
                raise ValueError(f"multiple continuous assignments drive {lhs!r}")
            assignments[lhs] = (rhs, (start, end))

    replacements: dict[tuple[int, int], str] = {}
    anchor_spans: set[tuple[int, int]] = set()
    generated: list[InstantiatedEndpoint] = []
    reserved_names: set[str] = set()
    seen_endpoints: set[tuple[str, str]] = set()

    # The assign replacing each original singleton tie is only an intermediate
    # anchor.  All of its recorded endpoints receive physical tie drivers below.
    for record in records:
        if not isinstance(record, dict):
            raise ValueError("deferred tie record must be an object")
        polarity = record.get("polarity")
        if polarity not in (0, 1):
            raise ValueError(f"invalid deferred tie polarity: {polarity!r}")
        value = "1'b1" if polarity == 1 else "1'b0"
        net = normalize_verilog_name(str(record.get("normalized_net", "")))
        anchor = assignments.get(net)
        if anchor is None or anchor[0] != value:
            raise ValueError(
                f"deferred constant anchor {net!r} is missing or is not {value}"
            )
        anchor_spans.add(anchor[1])

        sinks = record.get("sinks")
        if not isinstance(sinks, list) or not sinks:
            raise ValueError(f"deferred constant net {net!r} has no recorded sinks")

        for sink in sinks:
            if not isinstance(sink, dict):
                raise ValueError(f"invalid sink record on deferred net {net!r}")
            source_instance = normalize_verilog_name(str(sink.get("instance", "")))
            source_pin = normalize_verilog_name(str(sink.get("pin", "")))
            endpoint_key = (source_instance, source_pin)
            if endpoint_key in seen_endpoints:
                raise ValueError(f"duplicate deferred endpoint: {endpoint_key!r}")
            seen_endpoints.add(endpoint_key)

            if source_instance == "PIN":
                tier = port_tier
                assignment = assignments.get(source_pin)
                if assignment is None or assignment[0] != value:
                    raise ValueError(
                        f"top-level constant endpoint {source_pin!r} is missing assign {value}"
                    )
                if assignment[1] in anchor_spans:
                    anchor_spans.remove(assignment[1])
                replacements[assignment[1]] = ""
                kind = "bterm"
                tie_net = source_pin
            else:
                instance_data = instances.get(source_instance)
                if instance_data is None:
                    raise ValueError(f"constant consumer instance not found: {source_instance!r}")
                master, span = instance_data
                tier = instance_tier(master, source_instance)
                statement = replacements.get(span, text[span[0] : span[1]])
                expression = find_named_port_expression(statement, source_pin)
                if expression != value:
                    raise ValueError(
                        f"constant endpoint {source_instance}/{source_pin} is {expression!r}, "
                        f"expected {value}"
                    )
                tie_net = unique_name("__d3d_tie_net", text, reserved_names)
                replacements[span] = replace_named_port_expression(
                    statement, source_pin, tie_net
                )
                kind = "iterm"

            tie = tie_cells[(tier, polarity)]
            tie_instance = unique_name("__d3d_tie_inst", text, reserved_names)
            generated.append(
                InstantiatedEndpoint(
                    polarity=polarity,
                    tier=tier,
                    kind=kind,
                    source_instance=source_instance,
                    source_pin=source_pin,
                    tie_cell=tie.cell,
                    tie_port=tie.port,
                    tie_instance=tie_instance,
                    tie_net=tie_net,
                )
            )

    for span in anchor_spans:
        replacements[span] = ""

    output_parts: list[str] = []
    cursor = 0
    for start, end in spans:
        output_parts.append(text[cursor:start])
        output_parts.append(replacements.get((start, end), text[start:end]))
        cursor = end
    output_parts.append(text[cursor:])
    rewritten = "".join(output_parts)

    endmodules = list(re.finditer(r"(?m)^\s*endmodule\b", rewritten))
    if len(endmodules) != 1:
        raise ValueError(
            f"expected one flattened Verilog module, found {len(endmodules)} endmodule statements"
        )

    instantiated_lines = [
        "\n // Instantiate tier-local tie cells for D3D deferred constants.\n"
    ]
    for endpoint in generated:
        if endpoint.kind == "iterm":
            instantiated_lines.append(f" wire {endpoint.tie_net};\n")
        instantiated_lines.append(
            f" {endpoint.tie_cell} {endpoint.tie_instance} "
            f"(.{endpoint.tie_port}({endpoint.tie_net}));\n"
        )
    insertion = "".join(instantiated_lines)
    endmodule_start = endmodules[0].start()
    rewritten = rewritten[:endmodule_start] + insertion + rewritten[endmodule_start:]
    atomic_write(output_path, rewritten)

    counts = {
        f"{tier}_{'tiehi' if polarity else 'tielo'}_{kind}": sum(
            endpoint.tier == tier
            and endpoint.polarity == polarity
            and endpoint.kind == kind
            for endpoint in generated
        )
        for tier in ("upper", "bottom")
        for polarity in (0, 1)
        for kind in ("iterm", "bterm")
    }
    summary: dict[str, object] = {
        "schema": "taiwei.d3d-partition.instantiated-ties",
        "schema_version": 1,
        "input": str(input_path.resolve()),
        "output": str(output_path.resolve()),
        "manifest": str(manifest_path.resolve()),
        "port_tier": port_tier,
        "instantiated_endpoint_count": len(generated),
        "counts": counts,
        "endpoints": [endpoint.__dict__ for endpoint in generated],
    }
    if summary_path is not None:
        atomic_write(summary_path, json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"instantiated_endpoint_count": len(generated), "counts": counts}, sort_keys=True))
    return summary


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--upper-tiehi", required=True)
    parser.add_argument("--upper-tielo", required=True)
    parser.add_argument("--bottom-tiehi", required=True)
    parser.add_argument("--bottom-tielo", required=True)
    parser.add_argument("--port-tier", choices=("upper", "bottom"), default="bottom")
    parser.add_argument("--summary", type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    tie_cells = {
        ("upper", 1): parse_tie_cell(args.upper_tiehi, "--upper-tiehi"),
        ("upper", 0): parse_tie_cell(args.upper_tielo, "--upper-tielo"),
        ("bottom", 1): parse_tie_cell(args.bottom_tiehi, "--bottom-tiehi"),
        ("bottom", 0): parse_tie_cell(args.bottom_tielo, "--bottom-tielo"),
    }
    instantiate_ties(
        args.input,
        args.output,
        args.manifest,
        tie_cells,
        args.port_tier,
        args.summary,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
