"""Cheap weight-tensor aggregates from CNN state_dicts (no forward pass).

Used when saving epochs (new runs → JSON beside .pt) and when backfilling
dashboard data from historical ``epoch_*_weights.pt`` files.
"""

from __future__ import annotations

import math
import re
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

import torch

_CONV_RE = re.compile(r"^conv_(\d+)_(\d+)\.weight$")
_BIAS_RE = re.compile(r"^conv_(\d+)_(\d+)\.bias$")
_EDGE_W_RE = re.compile(r"^edge_w_(\d+)_(\d+)$")


def _safe_float(x: Any) -> Optional[float]:
    try:
        v = float(x)
    except (TypeError, ValueError):
        return None
    if math.isnan(v) or math.isinf(v):
        return None
    return v


def tensor_aggregates(t: Any, *, eps: float = 1e-8) -> Dict[str, float]:
    """O(N) stats for a single tensor (already on CPU preferred)."""
    if not isinstance(t, torch.Tensor) or t.numel() == 0:
        return {
            "numel": 0.0,
            "mean": 0.0,
            "std": 0.0,
            "l2": 0.0,
            "abs_mean": 0.0,
            "max_abs": 0.0,
            "sign_pos_frac": 0.0,
            "sign_neg_frac": 0.0,
            "zero_frac": 1.0,
            "sparsity_eps": 1.0,
        }
    x = t.detach().float().reshape(-1)
    abs_x = x.abs()
    n = float(x.numel())
    return {
        "numel": n,
        "mean": float(x.mean().item()),
        "std": float(x.std(unbiased=False).item()) if x.numel() > 1 else 0.0,
        "l2": float(torch.linalg.vector_norm(x, ord=2).item()),
        "abs_mean": float(abs_x.mean().item()),
        "max_abs": float(abs_x.max().item()),
        "sign_pos_frac": float((x > 0).float().mean().item()),
        "sign_neg_frac": float((x < 0).float().mean().item()),
        "zero_frac": float((x == 0).float().mean().item()),
        "sparsity_eps": float((abs_x <= eps).float().mean().item()),
    }


def summarize_state_dict(
    state_dict: Mapping[str, Any],
    *,
    eps: float = 1e-8,
) -> Dict[str, Any]:
    """Per-edge + rollup stats for one model ``state_dict``."""
    edges: Dict[str, Dict[str, Any]] = {}
    weight_stats: List[Dict[str, float]] = []
    bias_stats: List[Dict[str, float]] = []
    edge_w_vals: List[float] = []

    for key, tensor in state_dict.items():
        if not isinstance(tensor, torch.Tensor):
            continue
        m = _CONV_RE.match(key)
        if m:
            a, b = m.group(1), m.group(2)
            ek = f"{a}_{b}"
            agg = tensor_aggregates(tensor, eps=eps)
            edges.setdefault(ek, {"in_node": int(a), "out_node": int(b)})
            edges[ek]["weight"] = agg
            edges[ek]["shape"] = list(tensor.shape)
            weight_stats.append(agg)
            continue
        m = _BIAS_RE.match(key)
        if m:
            a, b = m.group(1), m.group(2)
            ek = f"{a}_{b}"
            agg = tensor_aggregates(tensor, eps=eps)
            edges.setdefault(ek, {"in_node": int(a), "out_node": int(b)})
            edges[ek]["bias"] = agg
            bias_stats.append(agg)
            continue
        m = _EDGE_W_RE.match(key)
        if m:
            a, b = m.group(1), m.group(2)
            ek = f"{a}_{b}"
            val = float(tensor.detach().float().reshape(-1)[0].item()) if tensor.numel() else 0.0
            edges.setdefault(ek, {"in_node": int(a), "out_node": int(b)})
            edges[ek]["edge_w"] = val
            edge_w_vals.append(val)

    def _mean_key(rows: Sequence[Mapping[str, float]], k: str) -> Optional[float]:
        xs = [float(r[k]) for r in rows if k in r]
        if not xs:
            return None
        return float(sum(xs) / len(xs))

    n_w = len(weight_stats)
    total_numel = float(sum(r["numel"] for r in weight_stats)) if weight_stats else 0.0
    # Weighted (by numel) means for global sign fracs
    if total_numel > 0:
        w_pos = sum(r["sign_pos_frac"] * r["numel"] for r in weight_stats) / total_numel
        w_neg = sum(r["sign_neg_frac"] * r["numel"] for r in weight_stats) / total_numel
        w_zero = sum(r["zero_frac"] * r["numel"] for r in weight_stats) / total_numel
        w_sparse = sum(r["sparsity_eps"] * r["numel"] for r in weight_stats) / total_numel
    else:
        w_pos = w_neg = w_zero = w_sparse = None

    rollup = {
        "n_conv_edges": n_w,
        "n_bias_tensors": len(bias_stats),
        "n_edge_w": len(edge_w_vals),
        "weight_numel_total": total_numel,
        "weight_l2_mean": _mean_key(weight_stats, "l2"),
        "weight_l2_sum": float(sum(r["l2"] for r in weight_stats)) if weight_stats else None,
        "weight_abs_mean": _mean_key(weight_stats, "abs_mean"),
        "weight_mean_of_means": _mean_key(weight_stats, "mean"),
        "weight_std_mean": _mean_key(weight_stats, "std"),
        "weight_max_abs": max((r["max_abs"] for r in weight_stats), default=None),
        "weight_sign_pos_frac": w_pos,
        "weight_sign_neg_frac": w_neg,
        "weight_zero_frac": w_zero,
        "weight_sparsity_eps": w_sparse,
        "bias_l2_mean": _mean_key(bias_stats, "l2"),
        "bias_abs_mean": _mean_key(bias_stats, "abs_mean"),
        "edge_w_mean": float(sum(edge_w_vals) / len(edge_w_vals)) if edge_w_vals else None,
        "edge_w_pos_frac": (
            float(sum(1 for v in edge_w_vals if v > 0) / len(edge_w_vals)) if edge_w_vals else None
        ),
        "edge_w_neg_frac": (
            float(sum(1 for v in edge_w_vals if v < 0) / len(edge_w_vals)) if edge_w_vals else None
        ),
    }
    return {"rollup": rollup, "edges": edges}


def summarize_weights_store(
    store: Mapping[str, Any],
    *,
    model_indices: Optional[Sequence[int]] = None,
    eps: float = 1e-8,
    include_per_edge: bool = True,
) -> Dict[str, Any]:
    """Summarize a full ``epoch_*_weights.pt`` payload (or just its ``models`` dict)."""
    models = store.get("models") if isinstance(store.get("models"), dict) else store
    if not isinstance(models, dict):
        return {"schema": "cnn_neat_weight_stats_v1", "models": {}, "population": {}}

    if model_indices is None:
        keys = sorted(models.keys(), key=lambda x: int(x) if str(x).isdigit() else 0)
    else:
        keys = [str(i) for i in model_indices if str(i) in models]

    out_models: Dict[str, Any] = {}
    rollups: List[Dict[str, Any]] = []
    for k in keys:
        sd = models[k]
        if not isinstance(sd, Mapping):
            continue
        summary = summarize_state_dict(sd, eps=eps)
        rollups.append(summary["rollup"])
        entry: Dict[str, Any] = {"rollup": summary["rollup"]}
        if include_per_edge:
            entry["edges"] = summary["edges"]
        out_models[str(k)] = entry

    def _mean_field(field: str) -> Optional[float]:
        xs = [float(r[field]) for r in rollups if r.get(field) is not None]
        return float(sum(xs) / len(xs)) if xs else None

    population = {
        "n_models": len(out_models),
        "weight_sign_neg_frac_mean": _mean_field("weight_sign_neg_frac"),
        "weight_sign_pos_frac_mean": _mean_field("weight_sign_pos_frac"),
        "weight_sparsity_eps_mean": _mean_field("weight_sparsity_eps"),
        "weight_l2_mean": _mean_field("weight_l2_mean"),
        "weight_abs_mean": _mean_field("weight_abs_mean"),
        "weight_numel_total_sum": float(
            sum(float(r["weight_numel_total"]) for r in rollups if r.get("weight_numel_total") is not None)
        )
        if rollups
        else None,
        "n_conv_edges_mean": _mean_field("n_conv_edges"),
        "edge_w_neg_frac_mean": _mean_field("edge_w_neg_frac"),
    }
    return {
        "schema": "cnn_neat_weight_stats_v1",
        "generation": store.get("generation"),
        "policy": store.get("policy"),
        "model_indices": list(store.get("model_indices") or [int(k) for k in keys if str(k).isdigit()]),
        "population": population,
        "models": out_models,
    }


def epoch_weight_stats_relpath(generation: int) -> str:
    return f"epochs/epoch_{int(generation):04d}_weight_stats.json"


def champion_weight_scalars(stats: Mapping[str, Any], model_idx: int) -> Dict[str, Any]:
    """Flat scalars for dashboard run JSON from a weight_stats document."""
    models = stats.get("models") if isinstance(stats, Mapping) else None
    if not isinstance(models, dict):
        return {}
    entry = models.get(str(model_idx))
    if not isinstance(entry, dict):
        return {}
    rollup = entry.get("rollup") if isinstance(entry.get("rollup"), dict) else {}
    out: Dict[str, Any] = {}
    for k, v in rollup.items():
        out[f"w_{k}"] = v
    pop = stats.get("population") if isinstance(stats.get("population"), dict) else {}
    for k, v in pop.items():
        out[f"w_pop_{k}"] = v
    return out
