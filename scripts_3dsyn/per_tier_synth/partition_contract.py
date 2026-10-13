"""Partition contract helpers for the per-tier synthesis frontend handoff.

This module prepares the effective partition consumed by per-tier synthesis.

Contract:
- Homogeneous source partition labels are raw TritonPart labels and must be
  normalized to the canonical 3D-Syn encoding:
    - 0 = bottom
    - 1 = upper
- Heterogeneous source partition is passed through unchanged to avoid changing
  the current per-tier synthesis behavior.
"""

import os
import re
import shutil
from typing import Dict, List, Tuple


PINS_BEGIN_RE = re.compile(r"^\s*PINS\b", re.I)
PINS_END_RE = re.compile(r"^\s*END\s+PINS\b", re.I)
PIN_FIRST_RE = re.compile(r"^\s*-\s+(\S+)")


def normalize_name(value: str) -> str:
    text = str(value).strip()
    if text.startswith("\\"):
        text = text[1:]
    return text.replace("\\[", "[").replace("\\]", "]")


def parse_partition_file(path: str) -> List[Tuple[str, int]]:
    assert os.path.isfile(path), "partition.txt not found: {}".format(path)
    entries = []
    seen = set()
    with open(path, "r", encoding="utf-8", errors="ignore") as fp:
        for lineno, raw in enumerate(fp, 1):
            line = raw.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue
            toks = line.split()
            assert len(toks) >= 2, "Malformed partition line {} in {}: {!r}".format(lineno, path, raw)
            die_s = toks[-1]
            assert die_s in {"0", "1"}, "Unsupported partition die on line {} in {}: {!r}".format(
                lineno, path, raw
            )
            name = normalize_name(toks[0])
            assert name not in seen, "Duplicate partition key {!r} in {}".format(name, path)
            seen.add(name)
            entries.append((name, int(die_s)))
    assert entries, "partition.txt is empty after parsing: {}".format(path)
    return entries


def collect_top_pins_from_def(path: str) -> List[str]:
    assert os.path.isfile(path), "2_2_floorplan_io.def not found: {}".format(path)
    pins = []
    in_pins = False
    with open(path, "r", encoding="utf-8", errors="ignore") as fp:
        for raw in fp:
            if not in_pins and PINS_BEGIN_RE.match(raw):
                in_pins = True
                continue
            if in_pins and PINS_END_RE.match(raw):
                break
            if not in_pins:
                continue
            match = PIN_FIRST_RE.match(raw)
            if match:
                pins.append(normalize_name(match.group(1)))
    return pins


def choose_homogeneous_partition_swap(partition_entries: List[Tuple[str, int]], def_path: str):
    top_pins = set(collect_top_pins_from_def(def_path))
    pin_count_0 = 0
    pin_count_1 = 0

    if top_pins:
        for name, die in partition_entries:
            if name not in top_pins:
                continue
            if die == 0:
                pin_count_0 += 1
            else:
                pin_count_1 += 1

    # Legacy Taiwei homogeneous interpretation keeps the original labels unless
    # partition 0 has more top-level pins. Since legacy rewrite semantics are
    # 0=upper/1=bottom, canonical 3D-Syn encoding needs:
    #   - no swap only when raw label 0 already means bottom
    #   - swap for all other cases, including tie / no matched pins
    should_swap = not (pin_count_0 > pin_count_1)
    return should_swap, {
        "partition0_pins": pin_count_0,
        "partition1_pins": pin_count_1,
        "matched_top_pin_count": pin_count_0 + pin_count_1,
        "def_top_pin_count": len(top_pins),
    }


def write_partition(entries: List[Tuple[str, int]], out_path: str) -> None:
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fp:
        for name, die in entries:
            fp.write("{} {}\n".format(name, die))


def build_effective_partition(
    library: str,
    source_partition_path: str,
    source_def_path: str,
    out_partition_path: str,
):
    assert library in {"asap7_3D", "nangate45_3D", "asap7_nangate45_3D"}, "Unsupported library: {}".format(library)
    assert os.path.isfile(source_partition_path), "source partition.txt not found: {}".format(source_partition_path)

    if library == "asap7_nangate45_3D":
        os.makedirs(os.path.dirname(out_partition_path), exist_ok=True)
        shutil.copy2(source_partition_path, out_partition_path)
        return {
            "mode": "heterogeneous_passthrough",
            "source_partition_path": source_partition_path,
            "effective_partition_path": out_partition_path,
            "swap_applied": False,
        }

    partition_entries = parse_partition_file(source_partition_path)
    should_swap, summary = choose_homogeneous_partition_swap(partition_entries, source_def_path)
    normalized_entries = [
        (name, 1 - die if should_swap else die)
        for name, die in partition_entries
    ]
    write_partition(normalized_entries, out_partition_path)
    return {
        "mode": "homogeneous_normalized",
        "source_partition_path": source_partition_path,
        "effective_partition_path": out_partition_path,
        "swap_applied": should_swap,
        "summary": summary,
    }
