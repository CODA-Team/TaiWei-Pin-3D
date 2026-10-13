#!/usr/bin/env python3
"""
area_model/model.py

GNN model for predicting post-route utilization of functional modules.

Architecture:
    x [n_nodes, 9]
         |
    InputProjection      Linear(9 -> hidden_dim) + LayerNorm + ReLU
         |
    GraphSAGE x L        message passing layers
         |
    GlobalPooling        mean + max pooling concatenated -> [hidden_dim * 2]
         |
    concat graph_feat [17] and bitwidth_vec [5], projected to 32-dim
         |
    MLPHead              FC layers + Sigmoid
         |
    y_hat (scalar)       predicted utilization in (0, 1]

Auxiliary heads (attached after the first SAGE layer):
    AuxDegreeHead        predict normalized node degree
    AuxAreaHead          predict node cell_area

Does not depend on PyTorch Geometric; message passing is implemented
manually using index_add_ and scatter_reduce_.
"""

import torch
import torch.nn as nn
import torch.nn.functional as F


class SAGEConv(nn.Module):
    """
    Single GraphSAGE layer.

    h_i^(l+1) = ReLU( LayerNorm( W * concat(h_i^(l), mean_{j in N(i)} h_j^(l)) ) )
    """

    def __init__(self, in_dim: int, out_dim: int):
        super().__init__()
        self.linear = nn.Linear(in_dim * 2, out_dim)
        self.norm   = nn.LayerNorm(out_dim)

    def forward(self, x: torch.Tensor, edge_index: torch.Tensor) -> torch.Tensor:
        n_nodes = x.shape[0]
        src = edge_index[0]
        dst = edge_index[1]

        # scatter-mean: aggregate neighbor features for each destination node
        neighbor_sum = torch.zeros_like(x)
        neighbor_sum.index_add_(0, dst, x[src])

        degree = torch.zeros(n_nodes, dtype=torch.float, device=x.device)
        degree.index_add_(0, dst, torch.ones(dst.shape[0], device=x.device))
        degree = degree.clamp(min=1.0)

        neighbor_mean = neighbor_sum / degree[:, None]

        combined = torch.cat([x, neighbor_mean], dim=1)
        out = self.linear(combined)
        out = self.norm(out)
        out = F.relu(out)
        return out


def global_mean_max_pool(
    x:           torch.Tensor,
    batch_index: torch.Tensor,
    batch_size:  int,
) -> torch.Tensor:
    """
    Per-graph mean and max pooling, results concatenated.
    Returns [batch_size, hidden_dim * 2].
    """
    hidden_dim = x.shape[1]

    mean_out = torch.zeros(batch_size, hidden_dim, device=x.device)
    mean_out.index_add_(0, batch_index, x)
    counts = torch.zeros(batch_size, device=x.device)
    counts.index_add_(0, batch_index, torch.ones(x.shape[0], device=x.device))
    mean_out = mean_out / counts.clamp(min=1.0)[:, None]

    max_out = torch.full((batch_size, hidden_dim), float('-inf'), device=x.device)
    idx_expanded = batch_index.unsqueeze(1).expand_as(x)
    max_out.scatter_reduce_(0, idx_expanded, x, reduce='amax', include_self=True)

    return torch.cat([mean_out, max_out], dim=1)


class AuxHead(nn.Module):
    """
    Lightweight auxiliary prediction head: node embedding -> non-negative scalar.
    Used for predicting normalized degree and cell_area per node.
    """

    def __init__(self, hidden_dim: int):
        super().__init__()
        self.mlp = nn.Sequential(
            nn.Linear(hidden_dim, hidden_dim // 2),
            nn.ReLU(),
            nn.Linear(hidden_dim // 2, 1),
            nn.Softplus(),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.mlp(x).squeeze(-1)


class UtilizationGNN(nn.Module):
    """
    GNN-based post-route utilization predictor.

    Args:
        node_feat_dim:   node feature dimension (default 9)
        graph_feat_dim:  graph-level feature dimension (default 17)
        bw_vec_dim:      bitwidth vector dimension (default 5)
        hidden_dim:      GNN hidden dimension (default 64)
        n_layers:        number of SAGE layers (default 3)
        mlp_dims:        MLP head layer sizes (default (128, 64))
        dropout:         dropout rate (default 0.1)
    """

    def __init__(
        self,
        node_feat_dim:  int   = 9,
        graph_feat_dim: int   = 17,
        bw_vec_dim:     int   = 5,
        hidden_dim:     int   = 64,
        n_layers:       int   = 3,
        mlp_dims:       tuple = (128, 64),
        dropout:        float = 0.1,
    ):
        super().__init__()

        self.hidden_dim = hidden_dim
        self.n_layers   = n_layers

        self.input_proj = nn.Sequential(
            nn.Linear(node_feat_dim, hidden_dim),
            nn.LayerNorm(hidden_dim),
            nn.ReLU(),
        )

        self.convs   = nn.ModuleList([SAGEConv(hidden_dim, hidden_dim)
                                      for _ in range(n_layers)])
        self.dropout = nn.Dropout(dropout)

        # auxiliary heads attached after the first SAGE layer
        self.aux_degree_head = AuxHead(hidden_dim)
        self.aux_area_head   = AuxHead(hidden_dim)

        # project graph_feat + bitwidth_vec to a fixed-size vector
        graph_feat_proj_dim = 32
        self.graph_feat_proj = nn.Sequential(
            nn.Linear(graph_feat_dim + bw_vec_dim, graph_feat_proj_dim),
            nn.ReLU(),
        )

        mlp_in_dim = hidden_dim * 2 + graph_feat_proj_dim
        layers = []
        prev_dim = mlp_in_dim
        for dim in mlp_dims:
            layers.extend([
                nn.Linear(prev_dim, dim),
                nn.LayerNorm(dim),
                nn.ReLU(),
                nn.Dropout(dropout),
            ])
            prev_dim = dim
        layers.append(nn.Linear(prev_dim, 1))
        layers.append(nn.Sigmoid())
        self.mlp_head = nn.Sequential(*layers)

    def forward(
        self,
        x:            torch.Tensor,
        edge_index:   torch.Tensor,
        graph_feat:   torch.Tensor,
        bitwidth_vec: torch.Tensor,
        batch_index:  torch.Tensor,
    ) -> dict:
        batch_size = graph_feat.shape[0]

        h = self.input_proj(x)

        h = self.convs[0](h, edge_index)
        h = self.dropout(h)
        h_aux = h  # snapshot for auxiliary heads

        for conv in self.convs[1:]:
            h = conv(h, edge_index)
            h = self.dropout(h)

        graph_embed    = global_mean_max_pool(h, batch_index, batch_size)
        global_context = self.graph_feat_proj(
            torch.cat([graph_feat, bitwidth_vec], dim=1)
        )
        combined  = torch.cat([graph_embed, global_context], dim=1)
        util_pred = self.mlp_head(combined).squeeze(-1)

        return {
            "util_pred":   util_pred,
            "degree_pred": self.aux_degree_head(h_aux),
            "area_pred":   self.aux_area_head(h_aux),
        }


def compute_loss(
    preds:         dict,
    y:             torch.Tensor,
    x_raw:         torch.Tensor,
    batch_index:   torch.Tensor,
    lambda_degree: float = 0.1,
    lambda_area:   float = 0.1,
) -> dict:
    """
    Compute total loss and its components.

    Main loss   : MSE on predicted utilization.
    Aux loss 1  : MSE on normalized node degree (from x_raw col 1).
    Aux loss 2  : MSE on log1p(cell_area) (from x_raw col 0).

    x_raw must be the un-normalized node feature matrix so that cell_area
    values are non-negative (Softplus output cannot represent negatives).
    """
    loss_util = F.mse_loss(preds["util_pred"], y)

    # degree label: x_raw col 1 is raw cell_degree, normalize to [0, 1]
    degree_label = x_raw[:, 1]
    degree_label_norm = degree_label / degree_label.max().clamp(min=1.0)
    loss_degree = F.mse_loss(preds["degree_pred"], degree_label_norm)

    # area label: x_raw col 0 is raw cell_area; use log1p to compress scale
    area_label_log = torch.log1p(x_raw[:, 0])
    area_pred_log  = torch.log1p(preds["area_pred"])
    loss_area = F.mse_loss(area_pred_log, area_label_log)

    total = loss_util + lambda_degree * loss_degree + lambda_area * loss_area

    return {
        "total":  total,
        "util":   loss_util,
        "degree": loss_degree,
        "area":   loss_area,
    }


if __name__ == "__main__":
    torch.manual_seed(42)

    n1, n2, n3  = 5, 8, 3
    total_nodes = n1 + n2 + n3
    batch_size  = 3

    x           = torch.randn(total_nodes, 9)
    x_raw       = x.clone().abs()
    graph_feat  = torch.randn(batch_size, 17)
    bw_vec      = torch.rand(batch_size, 5)
    y           = torch.rand(batch_size)
    batch_index = torch.tensor([0]*n1 + [1]*n2 + [2]*n3)

    edges = []
    for start, n in [(0, n1), (n1, n2), (n1+n2, n3)]:
        for _ in range(n * 2):
            s = torch.randint(start, start+n, (1,)).item()
            d = torch.randint(start, start+n, (1,)).item()
            if s != d:
                edges.append([s, d])
    edge_index = torch.tensor(edges, dtype=torch.long).T

    model = UtilizationGNN()
    print(f"Parameters: {sum(p.numel() for p in model.parameters()):,}")

    preds = model(x, edge_index, graph_feat, bw_vec, batch_index)
    print(f"\nForward pass output:")
    print(f"  util_pred:   {preds['util_pred'].shape}  values={preds['util_pred'].detach()}")
    print(f"  degree_pred: {preds['degree_pred'].shape}")
    print(f"  area_pred:   {preds['area_pred'].shape}")

    losses = compute_loss(preds, y, x_raw, batch_index)
    print(f"\nLoss:")
    for k, v in losses.items():
        print(f"  {k:8s}: {v.item():.4f}")

    print("\n[OK] model.py sanity check passed")