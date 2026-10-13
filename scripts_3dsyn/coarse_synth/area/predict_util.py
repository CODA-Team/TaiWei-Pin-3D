#!/usr/bin/env python3
"""Run utilization inference for one synthesized coarse-unit netlist.

Usage:
    python predict_util.py <v_path> <wrapper_name> <tech> \
        --common-platform-dir <platform-dir>

    v_path       : path to the mapped Verilog netlist (.v)
    wrapper_name : RTLIL module name, e.g. _dffe_CLK1_D128_EN1_Q128
    tech         : "bottom" (NanGate45) | "upper" (ASAP7)

Output:
    A single float printed to stdout: predicted utilization in (0, 1].
    Exits with code 1 on any error (stderr gets the message).
"""

import sys
import re
import json
import argparse
from pathlib import Path

import networkx as nx
import torch

# ── paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR       = Path(__file__).parent                 # area_model/
RESOURCES_DIR    = SCRIPT_DIR / "resources"
PORT_SCHEMA_PATH = RESOURCES_DIR / "port_schema.json"
VOCAB_PATH       = RESOURCES_DIR / "cell_type_vocab.json"
CHECKPOINT_ROOT  = SCRIPT_DIR / "checkpoints"

LIB_UPPER_FILES = [
    "asap7sc7p5t_AO_RVT_FF_nldm_211120.upper.processed.lib",
    "asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.upper.processed.lib",
    "asap7sc7p5t_OA_RVT_FF_nldm_211120.upper.processed.lib",
    "asap7sc7p5t_SEQ_RVT_FF_nldm_220123.upper.processed.lib",
    "asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.upper.processed.lib",
]

# ── constants (must match dataset.py / 05_build_dataset.py) ───────────────────
MAX_BITWIDTH   = 32.0
VECTOR_LEN     = 5
CELL_TYPE_COL  = 8    # last column of x, skip normalization
NODE_FEAT_DIM  = 9
GRAPH_FEAT_DIM = 17
BW_VEC_DIM     = 5

NODE_FEAT_KEYS = [
    "cell_area", "cell_degree", "avg_neighbor_degree",
    "betweenness_centrality", "closeness_centrality",
    "degree_centrality", "clustering_coeff", "eccentricity",
]

GRAPH_FEAT_KEYS = [
    "n_cells", "n_nets", "n_pins",
    "n_nets_fanout_5_10", "n_nets_fanout_gt10",
    "n_internal_nets", "n_border_nets",
    "total_cell_area", "avg_cell_degree", "avg_net_degree",
    "avg_clustering_coeff", "density", "diameter", "radius",
    "edge_connectivity", "n_colors_greedy", "avg_global_efficiency",
]


# ── lib parsing — identical to 03_extract_features.py ─────────────────────────
def parse_lib_areas(lib_paths: list) -> dict:
    areas        = {}
    current_cell = None
    depth        = 0
    for lib_path in lib_paths:
        with open(lib_path) as f:
            for line in f:
                line = line.strip()
                if current_cell is None:
                    m = re.match(r'^cell\s*\(\s*(\S+?)\s*\)\s*\{', line)
                    if m:
                        current_cell = m.group(1)
                        depth = 1
                    continue
                depth += line.count("{") - line.count("}")
                m = re.match(r'^area\s*:\s*([0-9.eE+\-]+)\s*;', line)
                if m:
                    areas[current_cell] = float(m.group(1))
                if depth <= 0:
                    current_cell = None
                    depth = 0
    return areas


# ── netlist parsing — identical to 03_extract_features.py ─────────────────────
def parse_netlist(v_path: Path, cell_areas: dict) -> dict | None:
    src = v_path.read_text()
    src = re.sub(r'\(\*.*?\*\)', '', src, flags=re.DOTALL)
    src = re.sub(r'//[^\n]*', '', src)

    modules = {}
    for m in re.finditer(
        r'module\s+([\w\\$=\']+)\s*\((.*?)\)\s*;(.*?)endmodule', src, re.DOTALL
    ):
        mod_name = m.group(1)
        body     = m.group(3)

        ports = {}
        for direction in ("input", "output"):
            for pm in re.finditer(
                rf'\b{direction}\b\s+(?:\[(\d+):(\d+)\]\s+)?(\w+)\s*;', body
            ):
                hi = int(pm.group(1)) if pm.group(1) is not None else 0
                lo = int(pm.group(2)) if pm.group(2) is not None else 0
                ports[pm.group(3)] = {"dir": direction, "width": hi - lo + 1}

        port_nets = set(ports.keys())
        for pname, pinfo in ports.items():
            if pinfo["width"] > 1:
                for i in range(pinfo["width"]):
                    port_nets.add(f"{pname}[{i}]")

        instances = []
        for im in re.finditer(
            r'([\w\\$=\']+)\s+(\w+)\s*\((.*?)\)\s*;', body, re.DOTALL
        ):
            cell_type = im.group(1)
            if cell_type in ("module", "input", "output", "wire",
                             "assign", "reg", "parameter"):
                continue
            if cell_type == mod_name:
                continue
            pins = {
                pm.group(1): pm.group(2)
                for pm in re.finditer(
                    r'\.(\w+)\s*\(\s*([\w\[\]]+)\s*\)', im.group(3)
                )
            }
            instances.append({"cell": cell_type, "inst": im.group(2), "pins": pins})

        modules[mod_name] = {
            "ports": ports, "port_nets": port_nets, "instances": instances,
        }

    for mod in modules.values():
        if any(inst["cell"] in cell_areas for inst in mod["instances"]):
            return mod
    return None


# ── graph builder — identical to 03_extract_features.py ───────────────────────
def build_cell_graph(module: dict):
    instances    = module["instances"]
    G            = nx.Graph()
    G.add_nodes_from(range(len(instances)))
    net_to_insts = {}

    for idx, inst in enumerate(instances):
        for net in inst["pins"].values():
            net_to_insts.setdefault(net, []).append(idx)

    for inst_list in net_to_insts.values():
        for i in range(len(inst_list)):
            for j in range(i + 1, len(inst_list)):
                G.add_edge(inst_list[i], inst_list[j])

    src, dst = [], []
    for u, v in G.edges():
        src += [u, v]
        dst += [v, u]

    return G, net_to_insts, [src, dst]


# ── feature extraction — identical to 03_extract_features.py ──────────────────
def extract_graph_features(module: dict, G: nx.Graph,
                            net_to_insts: dict, cell_areas: dict) -> dict:
    instances   = module["instances"]
    port_nets   = module["port_nets"]
    n_cells     = len(instances)
    net_degrees = []
    n_internal = n_border = fanout_5_10 = fanout_gt10 = 0

    for net, inst_list in net_to_insts.items():
        degree = len(inst_list)
        net_degrees.append(degree)
        if net in port_nets:
            n_border += 1
        else:
            n_internal += 1
        if 5 <= degree <= 10:
            fanout_5_10 += 1
        elif degree > 10:
            fanout_gt10 += 1

    total_cell_area = sum(cell_areas.get(inst["cell"], 0.0) for inst in instances)
    n_pins          = sum(len(inst["pins"]) for inst in instances)
    avg_cell_degree = sum(d for _, d in G.degree()) / n_cells if n_cells else 0.0
    avg_net_degree  = sum(net_degrees) / len(net_degrees) if net_degrees else 0.0
    avg_global_eff  = nx.global_efficiency(G)
    avg_clust_coeff = nx.average_clustering(G)
    density         = nx.density(G)
    coloring        = nx.coloring.greedy_color(G, strategy="largest_first")
    n_colors        = max(coloring.values()) + 1 if coloring else 0

    ref_G = G if nx.is_connected(G) else \
            G.subgraph(max(nx.connected_components(G), key=len)).copy()

    return {
        "n_cells":               n_cells,
        "n_nets":                len(net_to_insts),
        "n_pins":                n_pins,
        "n_nets_fanout_5_10":    fanout_5_10,
        "n_nets_fanout_gt10":    fanout_gt10,
        "n_internal_nets":       n_internal,
        "n_border_nets":         n_border,
        "total_cell_area":       round(total_cell_area, 6),
        "avg_cell_degree":       round(avg_cell_degree, 6),
        "avg_net_degree":        round(avg_net_degree, 6),
        "avg_clustering_coeff":  round(avg_clust_coeff, 6),
        "density":               round(density, 6),
        "diameter":              nx.diameter(ref_G),
        "radius":                nx.radius(ref_G),
        "edge_connectivity":     nx.edge_connectivity(ref_G),
        "n_colors_greedy":       n_colors,
        "avg_global_efficiency": round(avg_global_eff, 6),
    }


def extract_node_features(module: dict, G: nx.Graph, cell_areas: dict) -> list:
    instances = module["instances"]
    n_cells   = len(instances)
    ref_G     = G if nx.is_connected(G) else \
                G.subgraph(max(nx.connected_components(G), key=len)).copy()
    ecc         = nx.eccentricity(ref_G)
    closeness   = nx.closeness_centrality(G)
    betweenness = nx.betweenness_centrality(G)
    clustering  = nx.clustering(G)
    avg_nbr_deg = nx.average_neighbor_degree(G)

    nodes = []
    for idx, inst in enumerate(instances):
        degree = G.degree(idx)
        nodes.append({
            "cell_type":              inst["cell"],
            "cell_area":              round(cell_areas.get(inst["cell"], 0.0), 6),
            "cell_degree":            degree,
            "avg_neighbor_degree":    round(avg_nbr_deg.get(idx, 0.0), 6),
            "betweenness_centrality": round(betweenness.get(idx, 0.0), 6),
            "closeness_centrality":   round(closeness.get(idx, 0.0), 6),
            "degree_centrality":      round(degree / (n_cells - 1), 6) if n_cells > 1 else 0.0,
            "clustering_coeff":       round(clustering.get(idx, 0.0), 6),
            "eccentricity":           ecc.get(idx, -1),
        })
    return nodes


# ── wrapper name -> canonical type ─────────────────────────────────────────────
def canonical_type(wrapper_name: str) -> str:
    """
    Extract the canonical module type from RTLIL wrapper name.

    Examples:
        _dffe_CLK1_D128_EN1_Q128  ->  DFFE
        _add_A8_B8_Y16            ->  ADD
        _fa_A4_B4_CI4_CO4_S4      ->  FA

    The RTLIL name always starts with an underscore; the type token is
    the first non-empty segment when split on underscores.
    """
    # RTLIL escaped identifiers start with '\', e.g. \_adff_CLK1_D2_Q2
    # Strip both leading backslash and underscores before splitting.
    parts = [p for p in wrapper_name.lstrip("\\_").split("_") if p]
    assert parts, f"Cannot extract canonical type from wrapper name: {wrapper_name!r}"
    return parts[0].upper()


# ── bitwidth vector from port_schema ──────────────────────────────────────────
def build_bitwidth_vec(ctype: str, netlist_ports: dict, schema: dict) -> list:
    """
    Build a VECTOR_LEN-dim bitwidth vector using slot_idx ordering from
    port_schema.json.  Asserts that netlist port names exactly match the
    union of parameterized_ports and fixed_ports names in the schema.

    Args:
        ctype         : canonical module type, e.g. "DFFE"
        netlist_ports : {port_name: {"dir": ..., "width": int}} from parse_netlist
        schema        : loaded port_schema.json dict

    Returns:
        list of ints, length VECTOR_LEN, zero-padded
    """
    assert ctype in schema, \
        f"Canonical type '{ctype}' not found in port_schema.json"
    entry = schema[ctype]

    param_ports = sorted(entry["parameterized_ports"], key=lambda p: p["slot_idx"])
    fixed_names = {p["name"] for p in entry.get("fixed_ports", [])}

    schema_port_names  = {p["name"] for p in param_ports} | fixed_names
    netlist_port_names = set(netlist_ports.keys())

    assert schema_port_names == netlist_port_names, (
        f"Port mismatch for {ctype} — schema and netlist ports do not match.\n"
        f"  schema : {sorted(schema_port_names)}\n"
        f"  netlist: {sorted(netlist_port_names)}"
    )

    vec = [0] * VECTOR_LEN
    for p in param_ports:
        idx  = p["slot_idx"]
        name = p["name"]
        assert idx < VECTOR_LEN, \
            f"slot_idx {idx} out of range (VECTOR_LEN={VECTOR_LEN}) for {ctype}.{name}"
        vec[idx] = netlist_ports[name]["width"]

    return vec


# ── normalization — mirrors dataset.py __getitem__ ────────────────────────────
def apply_norm(x: torch.Tensor, graph_feat: torch.Tensor,
               bitwidth_vec: torch.Tensor, norm_stats: dict):
    x_mean = norm_stats["x_mean"]
    x_std  = norm_stats["x_std"]
    x = x.clone()
    for col in range(NODE_FEAT_DIM):
        if col == CELL_TYPE_COL:
            continue
        std = x_std[col].item()
        if std < 1e-8:
            x[:, col] = x[:, col] - x_mean[col]
        else:
            x[:, col] = (x[:, col] - x_mean[col]) / std

    gf_mean = norm_stats["gf_mean"]
    gf_std  = norm_stats["gf_std"]
    graph_feat = graph_feat.clone()
    for i in range(GRAPH_FEAT_DIM):
        std = gf_std[i].item()
        if std < 1e-8:
            graph_feat[i] = graph_feat[i] - gf_mean[i]
        else:
            graph_feat[i] = (graph_feat[i] - gf_mean[i]) / std

    bitwidth_vec = bitwidth_vec / MAX_BITWIDTH
    return x, graph_feat, bitwidth_vec


# ── entry point ───────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="Predict post-route utilization for a single mapped netlist.")
    parser.add_argument("v_path",       type=Path,
                        help="Path to mapped Verilog netlist (.v)")
    parser.add_argument("wrapper_name", type=str,
                        help="RTLIL module name, e.g. _dffe_CLK1_D128_EN1_Q128")
    parser.add_argument("tech",         choices=["bottom", "upper"],
                        help="bottom = NanGate45, upper = ASAP7")
    parser.add_argument("--common-platform-dir", required=True, type=Path,
                        help="Path to platforms/asap7_nangate45_3D")
    args = parser.parse_args()

    v_path       = args.v_path
    wrapper_name = args.wrapper_name
    is_upper     = (args.tech == "upper")
    common_platform_dir = args.common_platform_dir.resolve()

    # ── load lib areas ────────────────────────────────────────────────────────
    lib_paths = (
        [common_platform_dir / "lib_upper" / "NLDM" / f for f in LIB_UPPER_FILES]
        if is_upper else [common_platform_dir / "lib_bottom" /
                          "NangateOpenCellLibrary_typical.bottom.processed.lib"]
    )
    missing_libs = [str(path) for path in lib_paths if not path.is_file()]
    if missing_libs:
        raise FileNotFoundError("missing GNN common liberty: " + ", ".join(missing_libs))
    cell_areas = parse_lib_areas(lib_paths)

    # ── load resources ────────────────────────────────────────────────────────
    schema = json.loads(PORT_SCHEMA_PATH.read_text())
    vocab  = json.loads(VOCAB_PATH.read_text())

    # ── load checkpoint ───────────────────────────────────────────────────────
    ckpt_dir   = CHECKPOINT_ROOT / ("asap7_run1" if is_upper else "nangate45_run1")
    norm_stats = torch.load(ckpt_dir / "norm_stats.pt",  weights_only=True,
                            map_location=torch.device("cpu"))
    config     = json.loads((ckpt_dir / "config.json").read_text())

    sys.path.insert(0, str(SCRIPT_DIR))
    from model import UtilizationGNN

    model = UtilizationGNN(
        node_feat_dim  = config.get("node_feat_dim",  NODE_FEAT_DIM),
        graph_feat_dim = config.get("graph_feat_dim", GRAPH_FEAT_DIM),
        bw_vec_dim     = config.get("bw_vec_dim",     BW_VEC_DIM),
        hidden_dim     = config.get("hidden_dim",     64),
        n_layers       = config.get("n_layers",       3),
        mlp_dims       = tuple(config.get("mlp_dims", [128, 64])),
        dropout        = config.get("dropout",        0.1),
    )
    state_dict = torch.load(ckpt_dir / "best_model.pt", weights_only=True,
                            map_location=torch.device("cpu"))
    model.load_state_dict(state_dict)
    model.eval()

    # ── parse netlist ─────────────────────────────────────────────────────────
    module = parse_netlist(v_path, cell_areas)
    assert module is not None, \
        f"No standard-cell module found in {v_path}"

    # ── canonical type & bitwidth vector ──────────────────────────────────────
    ctype       = canonical_type(wrapper_name)
    bw_vec_list = build_bitwidth_vec(ctype, module["ports"], schema)

    # ── graph & features ──────────────────────────────────────────────────────
    G, net_to_insts, edge_index = build_cell_graph(module)
    graph_feat_dict = extract_graph_features(module, G, net_to_insts, cell_areas)
    node_list       = extract_node_features(module, G, cell_areas)

    # ── assemble tensors ──────────────────────────────────────────────────────
    node_matrix = []
    for node in node_list:
        row   = [float(node[k]) for k in NODE_FEAT_KEYS]
        ct_id = vocab.get(node["cell_type"], -1)
        if ct_id == -1:
            print(f"[WARN] unknown cell type in vocab: {node['cell_type']}",
                  file=sys.stderr)
        row.append(float(ct_id))
        node_matrix.append(row)

    x           = torch.tensor(node_matrix,  dtype=torch.float)
    ei          = torch.tensor(edge_index,   dtype=torch.long)
    gf          = torch.tensor([graph_feat_dict[k] for k in GRAPH_FEAT_KEYS],
                               dtype=torch.float)
    bw          = torch.tensor(bw_vec_list,  dtype=torch.float)
    batch_index = torch.zeros(x.shape[0],   dtype=torch.long)

    # ── normalize ─────────────────────────────────────────────────────────────
    x, gf, bw = apply_norm(x, gf, bw, norm_stats)

    # ── inference ─────────────────────────────────────────────────────────────
    with torch.no_grad():
        preds = model(x, ei, gf.unsqueeze(0), bw.unsqueeze(0), batch_index)

    util = preds["util_pred"].item()

    # Keep stdout machine-readable for the coarse_synth driver.
    print(f"{util:.6f}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"[ERROR] predict_util: {e}", file=sys.stderr)
        sys.exit(1)
