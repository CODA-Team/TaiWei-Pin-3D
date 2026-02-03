#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================
#  gen_hb_pitch_techlef.py
#
#  Generate a set of tech LEF files with different hb_layer pitch.
#
#  Key principle:
#    - DO NOT hard-code the adjacent metal layer names.
#    - Derive scaling factors from the input tech LEF itself.
#
#  What gets updated:
#    1) LAYER hb_layer: WIDTH / SPACING
#    2) VIA hb_layer_0..8: RECTs on hb_layer and the two adjacent layers
#       (adjacent layer names are taken from each VIA block)
#    3) VIARULE hb_layerArray-0: hb_layer RECT and SPACING ... BY ...
#       (other layer names in the rule are kept as-is)
#    4) SPACING section: SAMENET hb_layer hb_layer <val> ;
#       where <val> = (viarule_spacing - hb_layer_spacing)
#
#  Default pitch sweep: 1.6 -> 0.2 step 0.2
# ============================================================

import argparse
import re
from pathlib import Path
from decimal import Decimal, getcontext
from typing import Tuple, List

getcontext().prec = 28


# -----------------------------
# Formatting helpers
# -----------------------------
def fmt_num(x: Decimal) -> str:
    s = f"{x:.6f}"
    s = s.rstrip("0").rstrip(".")
    return s if s else "0"


def pitch_tag(p: Decimal) -> str:
    return fmt_num(p).replace(".", "p")


def rect_str(x_half: Decimal, y_half: Decimal) -> str:
    return f"{fmt_num(-x_half)} {fmt_num(-y_half)} {fmt_num(x_half)} {fmt_num(y_half)}"


# -----------------------------
# hb_layer via pattern table
# -----------------------------
# Each entry: (L1_x_mult, L1_y_mult, L2_x_mult, L2_y_mult)
# L1/L2 correspond to the two non-hb_layer layers in the VIA block,
# preserving the original order in that VIA definition.
VIA_MULT = {
    0: (1, 1, 1, 1),
    1: (2, 2, 1, 2),
    2: (2, 2, 2, 1),
    3: (1, 2, 2, 2),
    4: (1, 2, 1, 2),
    5: (1, 2, 2, 1),
    6: (2, 1, 2, 2),
    7: (2, 1, 1, 2),
    8: (2, 1, 2, 1),
}


# -----------------------------
# Parsers (derive everything from input)
# -----------------------------
def get_hb_layer_defaults(text: str) -> Tuple[Decimal, Decimal]:
    """
    Extract hb_layer WIDTH and SPACING from:
      LAYER hb_layer ... WIDTH <w> ; ... SPACING <s> ; ... END hb_layer
    """
    pat = re.compile(r"(LAYER\s+hb_layer\b.*?\nEND\s+hb_layer\b)", re.S)
    m = pat.search(text)
    if not m:
        raise RuntimeError("Cannot find 'LAYER hb_layer ... END hb_layer' block.")

    block = m.group(1)

    m_w = re.search(r"\n\s*WIDTH\s+([^;]+)\s*;", block)
    m_s = re.search(r"\n\s*SPACING\s+([^;]+)\s*;", block)
    if not m_w or not m_s:
        raise RuntimeError("Cannot parse WIDTH/SPACING in LAYER hb_layer block.")

    w0 = Decimal(m_w.group(1).strip())
    s0 = Decimal(m_s.group(1).strip())
    return w0, s0


def get_hb_via_rule_spacing0(text: str) -> Decimal:
    """
    Extract default SPACING from:
      VIARULE hb_layerArray-0 ... SPACING <x> BY <y> ;
    We use the first number (<x>) as spacing0.
    """
    rule_pat = re.compile(
        r"(VIARULE\s+hb_layerArray-0\s+GENERATE\b.*?\nEND\s+hb_layerArray-0\b)",
        re.S,
    )
    m = rule_pat.search(text)
    if not m:
        raise RuntimeError("Cannot find 'VIARULE hb_layerArray-0 ... END hb_layerArray-0' block.")
    block = m.group(1)

    ms = re.search(r"\n\s*SPACING\s+([0-9.+-Ee]+)\s+BY\s+([0-9.+-Ee]+)\s*;", block)
    if not ms:
        raise RuntimeError("Cannot parse SPACING ... BY ... in VIARULE hb_layerArray-0.")
    return Decimal(ms.group(1).strip())


def parse_hb_via_layers(text: str, idx: int) -> List[str]:
    """
    For VIA hb_layer_<idx>, return the LAYER names in order as they appear,
    e.g. ["hb_layer", "M9", "M8_m"] or ["hb_layer", "M10", "M9_m"].
    """
    via_pat = re.compile(
        rf"(VIA\s+hb_layer_{idx}\s+DEFAULT\b.*?\nEND\s+hb_layer_{idx}\b\s*\n)",
        re.S,
    )
    m = via_pat.search(text)
    if not m:
        raise RuntimeError(f"Cannot find 'VIA hb_layer_{idx} ... END hb_layer_{idx}' block.")

    block = m.group(1)
    layers = re.findall(r"\n\s*LAYER\s+(\S+)\s*;", block)
    if len(layers) < 3:
        raise RuntimeError(f"VIA hb_layer_{idx}: expected >=3 LAYER lines, got {layers}")

    # We only care first 3 layers (your pattern is exactly 3)
    layers = layers[:3]
    if layers[0] != "hb_layer":
        # Some techlefs might list metals before hb_layer; we still support it by reordering.
        # But your “关键位置”明确 hb_layer 在第一个，这里做个稳妥处理。
        if "hb_layer" not in layers:
            raise RuntimeError(f"VIA hb_layer_{idx}: cannot find hb_layer among first 3 LAYER lines: {layers}")
        # Reorder: hb_layer first, then others in original relative order
        hb_pos = layers.index("hb_layer")
        layers = [layers[hb_pos]] + [layers[i] for i in range(len(layers)) if i != hb_pos]

    return layers  # [hb_layer, L1, L2]


# -----------------------------
# Editors
# -----------------------------
def update_hb_layer_block(text: str, width: Decimal, spacing: Decimal) -> str:
    pat = re.compile(r"(LAYER\s+hb_layer\b.*?\nEND\s+hb_layer\b)", re.S)
    m = pat.search(text)
    if not m:
        raise RuntimeError("Cannot find 'LAYER hb_layer ... END hb_layer' block.")
    block = m.group(1)

    block2 = re.sub(r"(\n\s*WIDTH\s+)[^;]+( ;)", rf"\g<1>{fmt_num(width)}\2", block, count=1)
    block2 = re.sub(r"(\n\s*SPACING\s+)[^;]+( ;)", rf"\g<1>{fmt_num(spacing)}\2", block2, count=1)
    return text[: m.start(1)] + block2 + text[m.end(1) :]


def gen_hb_via_block(idx: int, half: Decimal, layers: List[str]) -> str:
    """
    layers is [hb_layer, L1, L2] with original names preserved.
    """
    if idx not in VIA_MULT:
        raise ValueError(f"Unsupported hb_layer via index: {idx}")
    if len(layers) != 3 or layers[0] != "hb_layer":
        raise ValueError(f"Invalid layers for hb_layer_{idx}: {layers}")

    l1, l2 = layers[1], layers[2]
    l1_xm, l1_ym, l2_xm, l2_ym = VIA_MULT[idx]

    hb_rect = rect_str(half, half)
    l1_rect = rect_str(half * Decimal(l1_xm), half * Decimal(l1_ym))
    l2_rect = rect_str(half * Decimal(l2_xm), half * Decimal(l2_ym))

    return (
        f"VIA hb_layer_{idx} DEFAULT\n"
        f"  LAYER hb_layer ;\n"
        f"    RECT {hb_rect} ;\n"
        f"  LAYER {l1} ;\n"
        f"    RECT {l1_rect} ;\n"
        f"  LAYER {l2} ;\n"
        f"    RECT {l2_rect} ;\n"
        f"END hb_layer_{idx}\n"
    )


def replace_hb_vias(text: str, half: Decimal) -> str:
    for i in range(9):
        layers = parse_hb_via_layers(text, i)

        via_pat = re.compile(
            rf"(VIA\s+hb_layer_{i}\s+DEFAULT\b.*?\nEND\s+hb_layer_{i}\b\s*\n)",
            re.S,
        )
        m = via_pat.search(text)
        if not m:
            raise RuntimeError(f"Cannot find 'VIA hb_layer_{i} ... END hb_layer_{i}' block.")

        new_block = gen_hb_via_block(i, half, layers)
        text = text[: m.start(1)] + new_block + text[m.end(1) :]
    return text


def update_hb_via_rule(text: str, half: Decimal, new_rule_spacing: Decimal) -> str:
    rule_pat = re.compile(
        r"(VIARULE\s+hb_layerArray-0\s+GENERATE\b.*?\nEND\s+hb_layerArray-0\b)",
        re.S,
    )
    m = rule_pat.search(text)
    if not m:
        raise RuntimeError("Cannot find 'VIARULE hb_layerArray-0 ... END hb_layerArray-0' block.")
    block = m.group(1)

    # Update hb_layer RECT inside this rule:
    # We specifically target the RECT after "LAYER hb_layer ;"
    # to avoid accidentally replacing other RECT lines.
    new_rect = rect_str(half, half)

    def _replace_rect_in_hb_layer_section(b: str) -> str:
        # Find "LAYER hb_layer ; ... RECT ... ;" within the rule block
        pat = re.compile(r"(LAYER\s+hb_layer\s*;\s*\n(?:[^\n]*\n)*?\s*RECT\s+)([^;]+)(\s*;)", re.S)
        mm = pat.search(b)
        if not mm:
            raise RuntimeError("Cannot find hb_layer RECT inside VIARULE hb_layerArray-0.")
        return b[: mm.start(2)] + new_rect + " " + b[mm.end(2) :]

    block2 = _replace_rect_in_hb_layer_section(block)

    sp_str = f"{fmt_num(new_rule_spacing)} BY {fmt_num(new_rule_spacing)}"
    block2 = re.sub(
        r"(\n\s*SPACING\s+)[^;]+( ;)",
        rf"\g<1>{sp_str}\2",
        block2,
        count=1,
    )

    return text[: m.start(1)] + block2 + text[m.end(1) :]


def update_samenet_hb_spacing(text: str, hb_samenet: Decimal) -> str:
    """
    Update line:
      SAMENET hb_layer hb_layer <val> ;
    """
    pat = re.compile(r"(\n\s*SAMENET\s+hb_layer\s+hb_layer\s+)[^;]+( ;)")
    if not pat.search(text):
        # Do not fail if absent; just leave unchanged.
        return text
    return pat.sub(rf"\g<1>{fmt_num(hb_samenet)}\2", text, count=1)


# -----------------------------
# Sweep
# -----------------------------
def frange_desc(start: Decimal, stop: Decimal, step: Decimal):
    x = start
    while x + Decimal("1e-12") >= stop:
        yield x
        x -= step


def main():
    ap = argparse.ArgumentParser(description="Generate multiple tech LEF files with different hb_layer pitch.")
    ap.add_argument("-i", "--input", required=True, help="Input tech LEF file.")
    ap.add_argument("-o", "--outdir", required=True, help="Output directory.")
    ap.add_argument("--pmax", default="1.0", help="Max pitch (default: 1.0).")
    ap.add_argument("--pmin", default="0.2", help="Min pitch (default: 0.2).")
    ap.add_argument("--pstep", default="0.1", help="Pitch step (default: 0.1).")
    args = ap.parse_args()

    in_path = Path(args.input).resolve()
    out_dir = Path(args.outdir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    base_text = in_path.read_text(encoding="utf-8", errors="ignore")

    # ---- derive defaults from input (no hard-code) ----
    hb_w0, hb_s0 = get_hb_layer_defaults(base_text)
    pitch0 = hb_w0 + hb_s0
    rule_sp0 = get_hb_via_rule_spacing0(base_text)
    factor_rule = rule_sp0 / pitch0  # e.g. 1.68 / 1.6 = 1.05

    pmax = Decimal(str(args.pmax))
    pmin = Decimal(str(args.pmin))
    pstep = Decimal(str(args.pstep))

    stem = in_path.stem
    suffix = in_path.suffix if in_path.suffix else ".lef"

    for pitch in frange_desc(pmax, pmin, pstep):
        hb_width = pitch / Decimal("2")
        hb_spacing = pitch / Decimal("2")
        half = hb_width / Decimal("2")  # = pitch/4

        # rule spacing derived from input ratio
        rule_spacing = factor_rule * pitch

        # your stated provenance: hb_samenet = rule_spacing - hb_layer_spacing
        hb_samenet = rule_spacing - hb_spacing

        text = base_text
        text = update_hb_layer_block(text, width=hb_width, spacing=hb_spacing)
        text = replace_hb_vias(text, half=half)
        text = update_hb_via_rule(text, half=half, new_rule_spacing=rule_spacing)
        text = update_samenet_hb_spacing(text, hb_samenet=hb_samenet)

        out_name = f"{stem}.hbPitch_{pitch_tag(pitch)}{suffix}"
        (out_dir / out_name).write_text(text, encoding="utf-8")

    print(f"[OK] Generated tech LEFs in: {out_dir}")


if __name__ == "__main__":
    main()
