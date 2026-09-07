"""Derive topology scalars + draw-friendly JSON from a genome dict (no .pt).

Used by extract.py so dashboards never need weight tensors — only epoch JSON
genomes (connections, node_sizes, node_channels, weight_scale signs, …).
"""

from __future__ import annotations

import math
from collections import defaultdict, deque
from typing import Any, Dict, List, Mapping, Optional, Sequence, Set, Tuple


def _hw(raw: Any, default: Tuple[int, int] = (32, 32)) -> Tuple[int, int]:
    if isinstance(raw, (list, tuple)) and len(raw) >= 2:
        return int(raw[0]), int(raw[1])
    return default


def _side(h: int, w: int) -> float:
    return float(math.sqrt(max(h, 1) * max(w, 1)))


def _mean(xs: Sequence[float]) -> Optional[float]:
    if not xs:
        return None
    return float(sum(xs) / len(xs))


def _std(xs: Sequence[float]) -> Optional[float]:
    if len(xs) < 2:
        return 0.0 if xs else None
    m = sum(xs) / len(xs)
    var = sum((x - m) ** 2 for x in xs) / len(xs)
    return float(math.sqrt(var))


def analyze_genome(genome: Optional[Mapping[str, Any]]) -> Dict[str, Any]:
    """Return {metrics: {...}, draw: {...}} from a genome JSON blob."""
    empty = {"metrics": {}, "draw": {"nodes": [], "edges": [], "order": []}}
    if not isinstance(genome, Mapping):
        return empty

    in_hw = _hw(genome.get("input_image_size"), (32, 32))
    out_hw = _hw(genome.get("output_image_size"), (1, 1))
    num_views = int(genome.get("num_input_views") or genome.get("num_input_cameras") or 1)
    input_nodes: Set[int] = set(range(num_views))

    raw_sizes = genome.get("node_sizes") or {}
    node_sizes: Dict[int, Tuple[int, int]] = {
        int(k): _hw(v, in_hw) for k, v in raw_sizes.items()
    }
    raw_ch = genome.get("node_channels") or {}
    node_channels: Dict[int, int] = {int(k): int(v) for k, v in raw_ch.items()}
    raw_acts = genome.get("node_activations") or {}
    node_acts: Dict[int, Any] = {int(k): v for k, v in raw_acts.items()}

    out_declared = genome.get("output_nodes")
    if out_declared:
        output_nodes = {int(x) for x in out_declared}
    else:
        output_nodes = {
            n for n, hw in node_sizes.items() if n not in input_nodes and hw == out_hw
        }
        if not output_nodes:
            # fallback: sinks
            dests: Set[int] = set()
            srcs: Set[int] = set()
            for conn in genome.get("connections") or []:
                if not conn.get("enabled", True):
                    continue
                srcs.add(int(conn["in_node"]))
                dests.add(int(conn["out_node"]))
            output_nodes = (dests - srcs) - input_nodes

    conns = list(genome.get("connections") or [])
    enabled = [c for c in conns if isinstance(c, dict) and c.get("enabled", True)]
    disabled = [c for c in conns if isinstance(c, dict) and not c.get("enabled", True)]

    nodes: Set[int] = set(input_nodes) | set(output_nodes) | set(node_sizes)
    graph: Dict[int, List[int]] = defaultdict(list)
    rev: Dict[int, List[int]] = defaultdict(list)
    indeg: Dict[int, int] = defaultdict(int)
    outdeg: Dict[int, int] = defaultdict(int)

    for conn in enabled:
        a, b = int(conn["in_node"]), int(conn["out_node"])
        nodes.add(a)
        nodes.add(b)
        graph[a].append(b)
        rev[b].append(a)
        indeg[b] += 1
        outdeg[a] += 1
        indeg.setdefault(a, 0)
        outdeg.setdefault(b, 0)
    for n in nodes:
        indeg.setdefault(n, 0)
        outdeg.setdefault(n, 0)
        graph.setdefault(n, [])
        rev.setdefault(n, [])

    # Kahn order
    q = deque(sorted(n for n in nodes if indeg[n] == 0))
    order: List[int] = []
    indeg_work = dict(indeg)
    while q:
        n = q.popleft()
        order.append(n)
        for m in sorted(graph[n]):
            indeg_work[m] -= 1
            if indeg_work[m] == 0:
                q.append(m)
    cyclic = len(order) != len(nodes)

    # Graph depth (longest path from inputs)
    depth: Dict[int, int] = {n: 0 for n in nodes}
    if not cyclic:
        for n in order:
            for m in graph[n]:
                depth[m] = max(depth[m], depth[n] + 1)
    graph_depth = max(depth.values()) if depth else 0

    # Edges on any path to an output (approx "executed")
    reach_out: Set[int] = set(output_nodes)
    stack = list(output_nodes)
    while stack:
        n = stack.pop()
        for p in rev[n]:
            if p not in reach_out:
                reach_out.add(p)
                stack.append(p)
    on_path_edges = 0
    dead_enabled = 0
    for conn in enabled:
        a, b = int(conn["in_node"]), int(conn["out_node"])
        if a in reach_out and b in reach_out:
            on_path_edges += 1
        else:
            dead_enabled += 1

    # weight_scale signs / stats
    scales: List[float] = []
    for conn in conns:
        if not isinstance(conn, dict):
            continue
        ws = conn.get("weight_scale")
        if isinstance(ws, (int, float)):
            scales.append(float(ws))
    pos = sum(1 for s in scales if s > 0)
    neg = sum(1 for s in scales if s < 0)
    zero = sum(1 for s in scales if s == 0)
    abs_scales = [abs(s) for s in scales]

    # kernels / strides / padding
    k_sides: List[float] = []
    k_areas: List[float] = []
    strides: List[float] = []
    pad_nonzero = 0
    kernel_keys: Set[Tuple[int, int]] = set()
    for conn in enabled:
        ks = conn.get("kernel_size")
        if isinstance(ks, (list, tuple)) and len(ks) >= 2:
            kh, kw = int(ks[0]), int(ks[1])
            kernel_keys.add((kh, kw))
            k_sides.append(_side(kh, kw))
            k_areas.append(float(kh * kw))
        st = conn.get("stride", 1)
        if isinstance(st, (list, tuple)):
            st = st[0] if st else 1
        if isinstance(st, (int, float)):
            strides.append(float(st))
        pad = conn.get("padding", 0)
        if isinstance(pad, (list, tuple)):
            if any(int(x) != 0 for x in pad):
                pad_nonzero += 1
        elif isinstance(pad, (int, float)) and pad != 0:
            pad_nonzero += 1

    def size_of(nid: int) -> Tuple[int, int]:
        if nid in node_sizes:
            return node_sizes[nid]
        if nid in input_nodes:
            return in_hw
        if nid in output_nodes:
            return out_hw
        return in_hw

    sides = [_side(*size_of(n)) for n in (order if order else sorted(nodes))]
    channels_seq = [
        int(node_channels.get(n, genome.get("input_channels") or 3 if n in input_nodes else 3))
        for n in (order if order else sorted(nodes))
    ]
    hidden = nodes - input_nodes - output_nodes

    in_side = _side(*in_hw)
    out_side = _side(*out_hw)
    reduction = (in_side / out_side) if out_side > 0 else None
    bottleneck = min(sides) if sides else None
    expansion = (max(sides) / min(sides)) if sides and min(sides) > 0 else None

    # edge_weight_values signs
    ewv = genome.get("edge_weight_values") or {}
    ewv_vals: List[float] = []
    if isinstance(ewv, dict):
        for v in ewv.values():
            if isinstance(v, (int, float)):
                ewv_vals.append(float(v))
    ewv_pos = sum(1 for v in ewv_vals if v > 0)

    # fan stats
    fan_ins = [indeg[n] for n in nodes]
    fan_outs = [outdeg[n] for n in nodes]

    innov = genome.get("innovation_numbers") or {}
    innov_vals = [int(v) for v in innov.values()] if isinstance(innov, dict) else []

    acts = set(str(v) for v in node_acts.values())
    if genome.get("activation") is not None:
        acts.add(str(genome.get("activation")))

    n_nodes = len(nodes)
    n_en = len(enabled)
    n_dis = len(disabled)
    n_tot = len(conns)

    metrics: Dict[str, Any] = {
        # counts
        "topo_n_nodes": n_nodes,
        "topo_n_input": len(input_nodes),
        "topo_n_output": len(output_nodes),
        "topo_n_hidden": len(hidden),
        "topo_n_edges_total": n_tot,
        "topo_n_edges_enabled": n_en,
        "topo_n_edges_disabled": n_dis,
        "topo_edge_enabled_frac": (n_en / n_tot) if n_tot else None,
        "topo_n_edges_on_output_path": on_path_edges,
        "topo_n_dead_enabled_edges": dead_enabled,
        "topo_compactness": (n_en / n_nodes) if n_nodes else None,
        "topo_cyclic": bool(cyclic),
        # fan
        "topo_max_fan_in": max(fan_ins) if fan_ins else 0,
        "topo_max_fan_out": max(fan_outs) if fan_outs else 0,
        "topo_mean_fan_in": _mean([float(x) for x in fan_ins]),
        "topo_mean_fan_out": _mean([float(x) for x in fan_outs]),
        "topo_graph_depth": int(graph_depth),
        # weight_scale signs
        "topo_weight_pos_count": pos,
        "topo_weight_neg_count": neg,
        "topo_weight_zero_count": zero,
        "topo_weight_pos_frac": (pos / len(scales)) if scales else None,
        "topo_weight_neg_frac": (neg / len(scales)) if scales else None,
        "topo_weight_scale_mean": _mean(scales),
        "topo_weight_scale_std": _std(scales),
        "topo_weight_scale_abs_mean": _mean(abs_scales),
        "topo_weight_scale_min": min(scales) if scales else None,
        "topo_weight_scale_max": max(scales) if scales else None,
        # kernels / strides
        "topo_kernel_unique_count": len(kernel_keys),
        "topo_kernel_max_side": max(k_sides) if k_sides else None,
        "topo_kernel_min_side": min(k_sides) if k_sides else None,
        "topo_kernel_mean_area": _mean(k_areas),
        "topo_stride_max": max(strides) if strides else None,
        "topo_stride_mean": _mean(strides),
        "topo_padding_nonzero_frac": (pad_nonzero / n_en) if n_en else None,
        # spatial reduction
        "topo_spatial_input_side": in_side,
        "topo_spatial_output_side": out_side,
        "topo_spatial_reduction_ratio": reduction,
        "topo_spatial_path_len": len(sides),
        "topo_spatial_mean_side": _mean(sides),
        "topo_spatial_min_side": bottleneck,
        "topo_spatial_max_side": max(sides) if sides else None,
        "topo_spatial_bottleneck_side": bottleneck,
        "topo_spatial_expansion_ratio": expansion,
        # channels
        "topo_channel_max": max(channels_seq) if channels_seq else None,
        "topo_channel_mean": _mean([float(c) for c in channels_seq]),
        "topo_channel_unique_count": len(set(channels_seq)),
        "topo_input_channels": int(genome.get("input_channels") or 3),
        "topo_allow_variable_channels": bool(genome.get("allow_variable_channels")),
        # edge weights / activations
        "topo_edge_weights_enabled": bool(genome.get("edge_weights")),
        "topo_edge_weight_values_count": len(ewv_vals),
        "topo_edge_weight_pos_frac": (ewv_pos / len(ewv_vals)) if ewv_vals else None,
        "topo_activation_unique_count": len(acts),
        "topo_global_activation": genome.get("activation"),
        # innov
        "topo_innov_count": len(innov_vals),
        "topo_innov_max": max(innov_vals) if innov_vals else None,
        "topo_next_innovation": genome.get("next_innovation"),
    }

    # Layout for drawing: depth layers on x, spread on y
    by_depth: Dict[int, List[int]] = defaultdict(list)
    for n in sorted(nodes):
        by_depth[depth.get(n, 0)].append(n)
    draw_nodes: List[dict] = []
    for d, group in sorted(by_depth.items()):
        for i, nid in enumerate(sorted(group)):
            h, w = size_of(nid)
            kind = "input" if nid in input_nodes else ("output" if nid in output_nodes else "hidden")
            draw_nodes.append(
                {
                    "id": nid,
                    "x": float(d),
                    "y": float(i) - (len(group) - 1) / 2.0,
                    "h": h,
                    "w": w,
                    "side": _side(h, w),
                    "c": int(node_channels.get(nid, genome.get("input_channels") or 3)),
                    "kind": kind,
                    "activation": node_acts.get(nid, genome.get("activation")),
                }
            )

    draw_edges: List[dict] = []
    for conn in conns:
        if not isinstance(conn, dict):
            continue
        ws = conn.get("weight_scale")
        sign = 0
        if isinstance(ws, (int, float)):
            sign = 1 if ws > 0 else (-1 if ws < 0 else 0)
        ks = conn.get("kernel_size")
        draw_edges.append(
            {
                "src": int(conn["in_node"]),
                "dst": int(conn["out_node"]),
                "enabled": bool(conn.get("enabled", True)),
                "kernel": list(ks) if isinstance(ks, (list, tuple)) else ks,
                "stride": conn.get("stride"),
                "padding": conn.get("padding"),
                "weight_scale": ws,
                "sign": sign,
                "on_output_path": (
                    int(conn["in_node"]) in reach_out and int(conn["out_node"]) in reach_out
                    if conn.get("enabled", True)
                    else False
                ),
            }
        )

    draw = {
        "nodes": draw_nodes,
        "edges": draw_edges,
        "order": order,
        "spatial_sides": sides,
        "channel_profile": channels_seq,
        "input_image_size": list(in_hw),
        "output_image_size": list(out_hw),
    }
    return {"metrics": metrics, "draw": draw}


def lineage_metrics(lineage: Optional[Mapping[str, Any]]) -> Dict[str, Any]:
    if not isinstance(lineage, Mapping):
        return {}
    return {
        "lineage_origin": lineage.get("origin"),
        "lineage_mutation_type": lineage.get("mutation_type"),
        "lineage_parent_generation": lineage.get("parent_generation"),
        "lineage_parent_index": lineage.get("parent_index"),
        "lineage_parent_b_generation": lineage.get("parent_b_generation"),
        "lineage_parent_b_index": lineage.get("parent_b_index"),
        "lineage_gd": bool(lineage.get("gd_lineage")),
        "lineage_via_archive": bool(lineage.get("via_archive")),
    }


def epoch_series_extras(epochs: List[dict]) -> Dict[str, Any]:
    """Scalars derived from the full epoch summary series (no genome)."""
    if not epochs:
        return {}
    first = epochs[0]
    last = epochs[-1]
    best = max(epochs, key=lambda e: e.get("best_fitness") if isinstance(e.get("best_fitness"), (int, float)) else float("-inf"))

    def _g(e: dict, k: str) -> Optional[float]:
        v = e.get(k)
        return float(v) if isinstance(v, (int, float)) else None

    f0, f1 = _g(first, "best_fitness"), _g(last, "best_fitness")
    n0, n1 = _g(first, "best_nodes"), _g(last, "best_nodes")
    e0, e1 = _g(first, "best_edges"), _g(last, "best_edges")
    out: Dict[str, Any] = {
        "series_n_generations": len(epochs),
        "series_first_fitness": f0,
        "series_last_fitness": f1,
        "series_fitness_gain": (f1 - f0) if f0 is not None and f1 is not None else None,
        "series_peak_fitness": _g(best, "best_fitness"),
        "series_peak_generation": best.get("generation"),
        "series_first_nodes": n0,
        "series_last_nodes": n1,
        "series_nodes_delta": (n1 - n0) if n0 is not None and n1 is not None else None,
        "series_first_edges": e0,
        "series_last_edges": e1,
        "series_edges_delta": (e1 - e0) if e0 is not None and e1 is not None else None,
        "series_peak_bal_acc": _g(best, "best_bal_acc"),
        "series_peak_mcc": _g(best, "best_mcc"),
        "series_peak_roc_auc": _g(best, "best_roc_auc"),
        "series_last_tp": last.get("tp"),
        "series_last_tn": last.get("tn"),
        "series_last_fp": last.get("fp"),
        "series_last_fn": last.get("fn"),
    }
    # mean eval throughput
    gps = [e.get("eval_genomes_per_sec") for e in epochs if isinstance(e.get("eval_genomes_per_sec"), (int, float))]
    if gps:
        out["series_mean_eval_genomes_per_sec"] = _mean([float(x) for x in gps])
    te = [e.get("timing_eval_sec") for e in epochs if isinstance(e.get("timing_eval_sec"), (int, float))]
    if te:
        out["series_mean_timing_eval_sec"] = _mean([float(x) for x in te])
        out["series_sum_timing_eval_sec"] = float(sum(te))
    return out
