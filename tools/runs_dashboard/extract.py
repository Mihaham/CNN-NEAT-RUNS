#!/usr/bin/env python3
"""Extract compact dashboard JSON from CNN-NEAT-RUNS.

Prefers JSON sidecars (including ``epoch_*_weight_stats.json``). With
``--fetch-weights``, falls back to loading champion ``.pt`` when stats JSON
is missing (slow; use for historical backfill while .pt are still reachable).

Usage examples:
  python extract.py --git-dir . --ref origin/master --out site --study-filter ova_gpu_only
  python extract.py --runs-root . --out site --full
  python extract.py --runs-root . --out site --study-filter ova_mnist --fetch-weights
  python extract.py --git-dir . --ref HEAD --out site --incremental
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple

from metrics import (
    CACHE_KEYS,
    CONE_KEYS,
    EPOCH_SUMMARY_KEYS,
    HISTORY_KEYS,
    HISTORY_MAX_POINTS,
    HOLDOUT_RESULT_KEYS,
    META_KEYS,
    RESULT_ROW_KEYS,
)
from topology_metrics import analyze_genome, epoch_series_extras, lineage_metrics
from weight_pt_stats import (
    champion_weight_scalars,
    epoch_weight_stats_relpath,
    summarize_weights_store,
)

SCRIPT_DIR = Path(__file__).resolve().parent


def _slug(value: str) -> str:
    s = re.sub(r"[^0-9a-zA-Z_.-]+", "_", str(value)).strip("_")
    return s or "x"


def _pick(d: Optional[dict], keys: Sequence[str]) -> Dict[str, Any]:
    if not isinstance(d, dict):
        return {}
    out: Dict[str, Any] = {}
    for k in keys:
        if k in d and d[k] is not None:
            out[k] = d[k]
    return out


def _thin_points(points: List[dict], max_points: int = HISTORY_MAX_POINTS) -> List[dict]:
    if len(points) <= max_points:
        return points
    if max_points < 2:
        return points[:max_points]
    step = (len(points) - 1) / (max_points - 1)
    idxs = sorted({int(round(i * step)) for i in range(max_points)})
    return [points[i] for i in idxs]


class Source:
    """Read JSON either from a filesystem root or via git show."""

    def __init__(
        self,
        *,
        runs_root: Optional[Path] = None,
        git_dir: Optional[Path] = None,
        ref: str = "HEAD",
        weight_stats_root: Optional[Path] = None,
    ) -> None:
        self.runs_root = runs_root.resolve() if runs_root else None
        self.git_dir = git_dir.resolve() if git_dir else None
        self.ref = ref
        self.weight_stats_root = weight_stats_root.resolve() if weight_stats_root else None
        self._all_paths: Optional[List[str]] = None
        if not self.runs_root and not self.git_dir:
            raise ValueError("Need --runs-root or --git-dir")

    def _git(self, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        assert self.git_dir is not None
        cmd = ["git", "--git-dir", str(self.git_dir), *args]
        return subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=check,
        )

    def all_paths(self) -> List[str]:
        if self._all_paths is not None:
            return self._all_paths
        if self.git_dir is not None:
            cp = self._git("ls-tree", "-r", "--name-only", self.ref)
            self._all_paths = [ln.strip() for ln in cp.stdout.splitlines() if ln.strip()]
        else:
            assert self.runs_root is not None
            # Only dashboard-relevant names — never walk every .pt under runs/.
            wanted = (
                "ova_results.json",
                "ova_status.json",
                "run_archive.json",
                "breeding_cone_history.json",
                "forward_hash_cache_history.json",
                "summary.json",
                "results.json",
            )
            paths: List[str] = []
            seen: Set[str] = set()
            for name in wanted:
                for p in self.runs_root.rglob(name):
                    if not p.is_file():
                        continue
                    rel = p.relative_to(self.runs_root).as_posix()
                    if rel not in seen:
                        seen.add(rel)
                        paths.append(rel)
            # Epoch shards only when champion fetch needs them — listed lazily via exists/read.
            # Still index epoch_*.json paths under runs that already have archives nearby would
            # be huge; champion fetch uses direct path construction instead.
            self._all_paths = paths
        return self._all_paths

    def list_paths(self, suffix: str = "") -> List[str]:
        paths = self.all_paths()
        if suffix:
            paths = [p for p in paths if p.endswith(suffix)]
        return paths

    def read_bytes(self, rel: str) -> Optional[bytes]:
        rel = rel.replace("\\", "/").lstrip("./")
        # Prefer local weight_stats mirror (from backfill_weight_stats --out-mirror).
        if self.weight_stats_root is not None and rel.endswith("_weight_stats.json"):
            mirrored = self.weight_stats_root / rel
            if mirrored.is_file():
                return mirrored.read_bytes()
        if self.git_dir is not None:
            assert self.git_dir is not None
            cmd = ["git", "--git-dir", str(self.git_dir), "show", f"{self.ref}:{rel}"]
            cp = subprocess.run(cmd, capture_output=True, check=False)
            if cp.returncode != 0:
                # Fall through to runs_root if both configured
                if self.runs_root is None:
                    return None
            else:
                return cp.stdout
        if self.runs_root is not None:
            path = self.runs_root / rel
            if path.is_file():
                return path.read_bytes()
        return None

    def read_json(self, rel: str) -> Any:
        raw = self.read_bytes(rel)
        if raw is None:
            return None
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            print(f"WARN: bad JSON {rel}: {exc}", file=sys.stderr)
            return None

    def exists(self, rel: str) -> bool:
        if self.git_dir is not None:
            cp = self._git("cat-file", "-e", f"{self.ref}:{rel}", check=False)
            return cp.returncode == 0
        assert self.runs_root is not None
        return (self.runs_root / rel).is_file()

    def head_sha(self) -> str:
        if self.git_dir is not None:
            return self._git("rev-parse", self.ref).stdout.strip()
        return "filesystem"


def discover_studies(src: Source, study_filter: Optional[str] = None) -> List[Tuple[str, str]]:
    """Return list of (study_id, study_rel_dir) for each ova_results.json."""
    found: List[Tuple[str, str]] = []
    for path in src.list_paths("ova_results.json"):
        parent = path.rsplit("/", 1)[0]
        study_id = _slug(parent.replace("/", "_"))
        if study_filter:
            sf = study_filter.replace("\\", "/")
            if sf not in path and sf not in parent and sf not in study_id:
                continue
        found.append((study_id, parent))
    found.sort(key=lambda x: x[1])
    return found


def strip_result_row(row: dict) -> dict:
    out = _pick(row, RESULT_ROW_KEYS)
    hc = row.get("history_compact")
    if isinstance(hc, list):
        out["history_compact"] = [_pick(p, HISTORY_KEYS) for p in hc if isinstance(p, dict)]
    return out


def _load_torch_store(raw: bytes) -> Any:
    import io

    import torch

    return torch.load(io.BytesIO(raw), map_location="cpu", weights_only=False)


def _champion_weight_stats(
    src: Source,
    run_dir: str,
    generation: int,
    model_idx: int,
    *,
    fetch_weights: bool,
) -> Tuple[Optional[dict], Dict[str, Any]]:
    """Return (full_stats_doc_or_none, flat_scalars)."""
    stats_rel = f"{run_dir}/{epoch_weight_stats_relpath(generation)}"
    stats = src.read_json(stats_rel)
    if isinstance(stats, dict):
        return stats, champion_weight_scalars(stats, model_idx)

    if not fetch_weights:
        return None, {}

    weights_rel = f"{run_dir}/epochs/epoch_{int(generation):04d}_weights.pt"
    raw = src.read_bytes(weights_rel)
    if raw is None:
        # legacy alias
        raw = src.read_bytes(f"{run_dir}/run_archive_weights.pt")
    if raw is None:
        return None, {}
    try:
        store = _load_torch_store(raw)
    except Exception as exc:  # noqa: BLE001
        print(f"WARN: torch.load failed {weights_rel}: {exc}", file=sys.stderr)
        return None, {}
    store_gen = store.get("generation") if isinstance(store, dict) else None
    if store_gen is not None and int(store_gen) != int(generation):
        return None, {}
    try:
        # Site extract keeps rollups only (per-edge lives in sidecar JSON on disk).
        stats = summarize_weights_store(store, include_per_edge=False)
    except Exception as exc:  # noqa: BLE001
        print(f"WARN: weight summarize failed {weights_rel}: {exc}", file=sys.stderr)
        return None, {}
    return stats, champion_weight_scalars(stats, model_idx)


def _weight_series_from_sidecars(
    src: Source,
    run_dir: str,
    epoch_rows: Sequence[dict],
) -> List[dict]:
    """Build per-generation weight curves from existing ``*_weight_stats.json`` only."""
    series: List[dict] = []
    for row in epoch_rows:
        gen = row.get("generation")
        if not isinstance(gen, (int, float)):
            continue
        gen_i = int(gen)
        stats = src.read_json(f"{run_dir}/{epoch_weight_stats_relpath(gen_i)}")
        if not isinstance(stats, dict):
            continue
        point: Dict[str, Any] = {"generation": gen_i}
        pop = stats.get("population") if isinstance(stats.get("population"), dict) else {}
        for k, v in pop.items():
            point[f"w_pop_{k}"] = v
        idx = row.get("best_idx")
        if isinstance(idx, (int, float)):
            for k, v in champion_weight_scalars(stats, int(idx)).items():
                if k.startswith("w_") and not k.startswith("w_pop_"):
                    point[k] = v
        series.append(point)
    return series


def _epochs_as_items(epochs: Any) -> List[Tuple[int, dict]]:
    items: List[Tuple[int, dict]] = []
    if isinstance(epochs, dict):
        for k, v in epochs.items():
            if not isinstance(v, dict):
                continue
            try:
                gen = int(k)
            except (TypeError, ValueError):
                gen = int((v.get("summary") or {}).get("generation") or 0)
            items.append((gen, v))
    elif isinstance(epochs, list):
        for i, v in enumerate(epochs):
            if not isinstance(v, dict):
                continue
            gen = int((v.get("summary") or {}).get("generation") or i)
            items.append((gen, v))
    items.sort(key=lambda t: t[0])
    return items


def extract_run_from_archive(
    src: Source,
    archive_rel: str,
    *,
    fetch_champion: bool = True,
    fetch_weights: bool = False,
) -> Optional[dict]:
    archive = src.read_json(archive_rel)
    if not isinstance(archive, dict):
        return None
    run_dir = archive_rel.rsplit("/", 1)[0]
    meta_raw = archive.get("meta") if isinstance(archive.get("meta"), dict) else {}
    meta = _pick(meta_raw, META_KEYS)
    # periodic_gd may live only inside study_signature.config
    cfg = ((meta_raw.get("study_signature") or {}).get("config") or {})
    if "periodic_gd_enabled" not in meta and isinstance(cfg, dict):
        if "periodic_gd_enabled" in cfg:
            meta["periodic_gd_enabled"] = cfg["periodic_gd_enabled"]

    topo = archive.get("topology_registry") or {}
    topo_count = topo.get("count") if isinstance(topo, dict) else None

    epoch_rows: List[dict] = []
    best_gen = None
    best_fitness = None
    best_idx = None
    for gen, entry in _epochs_as_items(archive.get("epochs")):
        summary = entry.get("summary") if isinstance(entry.get("summary"), dict) else {}
        row = _pick(summary, EPOCH_SUMMARY_KEYS)
        row["generation"] = int(summary.get("generation", gen))
        epoch_rows.append(row)
        fit = summary.get("best_fitness")
        if isinstance(fit, (int, float)) and (best_fitness is None or fit > best_fitness):
            best_fitness = fit
            best_gen = row["generation"]
            best_idx = summary.get("best_idx")

    champion = None
    weight_metrics: Dict[str, Any] = {}
    idx = int(best_idx) if isinstance(best_idx, (int, float)) else 0
    if fetch_champion and best_gen is not None:
        epoch_rel = f"{run_dir}/epochs/epoch_{int(best_gen):04d}.json"
        shard = src.read_json(epoch_rel)
        if isinstance(shard, dict):
            models = shard.get("models")
            m = None
            if isinstance(models, list):
                if 0 <= idx < len(models):
                    m = models[idx]
            elif isinstance(models, dict):
                m = models.get(str(idx))
                if m is None and idx in models:
                    m = models[idx]
                if m is None and models:
                    # fallback: first entry
                    try:
                        m = models[sorted(models.keys(), key=lambda x: int(x) if str(x).isdigit() else 0)[0]]
                    except Exception:  # noqa: BLE001
                        m = next(iter(models.values()), None)
            if isinstance(m, dict):
                genome = m.get("genome")
                lineage = m.get("lineage")
                topo = analyze_genome(genome if isinstance(genome, dict) else None)
                champion = {
                    "generation": int(best_gen),
                    "idx": idx,
                    "fitness": m.get("fitness"),
                    "genome": genome,
                    "lineage": lineage,
                    "topology_metrics": topo.get("metrics") or {},
                    "topology_draw": topo.get("draw") or {},
                    "lineage_metrics": lineage_metrics(lineage if isinstance(lineage, dict) else None),
                }

    if best_gen is not None and (fetch_champion or fetch_weights):
        # Prefer sidecar JSON; with --fetch-weights fall back to champion .pt.
        _full_ws, weight_metrics = _champion_weight_stats(
            src,
            run_dir,
            int(best_gen),
            idx,
            fetch_weights=fetch_weights,
        )
        if weight_metrics and champion is not None:
            champion["weight_metrics"] = weight_metrics

    weight_series = _weight_series_from_sidecars(src, run_dir, epoch_rows)
    # If champion .pt backfill produced scalars but no sidecars yet, seed one point.
    if weight_metrics and not any(p.get("generation") == best_gen for p in weight_series):
        seed: Dict[str, Any] = {"generation": int(best_gen)} if best_gen is not None else {}
        seed.update(weight_metrics)
        if seed.get("generation") is not None:
            weight_series.append(seed)
            weight_series.sort(key=lambda p: p.get("generation") or 0)

    cone = None
    cache = None
    cone_raw = src.read_json(f"{run_dir}/breeding_cone_history.json")
    if isinstance(cone_raw, dict) and isinstance(cone_raw.get("points"), list):
        cone = _thin_points([_pick(p, CONE_KEYS) for p in cone_raw["points"] if isinstance(p, dict)])
    cache_raw = src.read_json(f"{run_dir}/forward_hash_cache_history.json")
    if isinstance(cache_raw, dict) and isinstance(cache_raw.get("points"), list):
        cache = _thin_points([_pick(p, CACHE_KEYS) for p in cache_raw["points"] if isinstance(p, dict)])

    series = epoch_series_extras(epoch_rows)
    topo_metrics = (champion or {}).get("topology_metrics") or {}
    lineage_m = (champion or {}).get("lineage_metrics") or {}

    return {
        "archive_path": archive_rel,
        "run_dir": run_dir,
        "meta": meta,
        "topology_registry_count": topo_count,
        "epochs": epoch_rows,
        "series_metrics": series,
        "topology_metrics": topo_metrics,
        "lineage_metrics": lineage_m,
        "weight_metrics": weight_metrics,
        "weight_series": weight_series,
        "champion": champion,
        "cone_points": cone,
        "cache_points": cache,
    }


def run_key_from_path(run_dir: str, study_dir: str) -> str:
    rel = run_dir
    if rel.startswith(study_dir + "/"):
        rel = rel[len(study_dir) + 1 :]
    return _slug(rel.replace("/", "__"))


def extract_holdout(src: Source, study_dir: str) -> Optional[dict]:
    candidates = [
        f"{study_dir}/test_holdout/summary.json",
        f"{study_dir}/test_holdout_c/summary.json",
        f"{study_dir}/test_holdout_d/summary.json",
    ]
    # Also discover any test_holdout*/summary.json under study
    extras = [
        p
        for p in src.list_paths("summary.json")
        if p.startswith(study_dir + "/") and "/test_holdout" in p
    ]
    for p in candidates + extras:
        data = src.read_json(p)
        if isinstance(data, dict):
            parent = p.rsplit("/", 1)[0]
            results = src.read_json(f"{parent}/results.json")
            out: Dict[str, Any] = {"path": p, "summary": data}
            if isinstance(results, list):
                # Keep compact evaluated rows
                compact = []
                for row in results:
                    if not isinstance(row, dict):
                        continue
                    compact.append({k: row[k] for k in HOLDOUT_RESULT_KEYS if k in row})
                out["results"] = compact
            return out
    return None


def extract_study(
    src: Source,
    study_id: str,
    study_dir: str,
    out_dir: Path,
    *,
    fetch_champion: bool = True,
    fetch_weights: bool = False,
    archive_paths: Optional[Sequence[str]] = None,
) -> dict:
    t0 = time.time()
    study_out = out_dir / "studies" / study_id
    runs_out = study_out / "runs"
    if runs_out.is_dir():
        for old in runs_out.glob("*.json"):
            try:
                old.unlink()
            except OSError:
                pass
    runs_out.mkdir(parents=True, exist_ok=True)

    results_raw = src.read_json(f"{study_dir}/ova_results.json")
    rows = results_raw if isinstance(results_raw, list) else []
    stripped = [strip_result_row(r) for r in rows if isinstance(r, dict)]
    (study_out / "results.json").write_text(
        json.dumps(stripped, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )

    status = src.read_json(f"{study_dir}/ova_status.json")
    status_lite: Dict[str, Any] = {}
    if isinstance(status, dict):
        for k in (
            "script_id",
            "pipeline",
            "label",
            "updated_at",
            "finished",
            "completed_count",
            "context",
            "top_overall",
            "top_by_class",
            "errors",
            "capacity_alerts",
            "phases",
            "live",
        ):
            if k in status:
                status_lite[k] = status[k]

    holdout = extract_holdout(src, study_dir)
    if holdout:
        (study_out / "holdout.json").write_text(
            json.dumps(holdout, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )

    for name, keys, fname in (
        ("breeding_cone_history.json", CONE_KEYS, "cone.json"),
        ("forward_hash_cache_history.json", CACHE_KEYS, "cache.json"),
    ):
        raw = src.read_json(f"{study_dir}/{name}")
        if isinstance(raw, dict) and isinstance(raw.get("points"), list):
            pts = _thin_points([_pick(p, keys) for p in raw["points"] if isinstance(p, dict)])
            (study_out / fname).write_text(
                json.dumps({"points": pts}, ensure_ascii=False, separators=(",", ":")),
                encoding="utf-8",
            )

    if archive_paths is None:
        prefix = study_dir + "/"
        archive_paths = [
            p
            for p in src.list_paths("run_archive.json")
            if p.startswith(prefix) or p == f"{study_dir}/run_archive.json"
        ]

    run_index: List[dict] = []
    for arch in sorted(archive_paths):
        try:
            run = extract_run_from_archive(
                src,
                arch,
                fetch_champion=fetch_champion,
                fetch_weights=fetch_weights,
            )
        except Exception as exc:  # noqa: BLE001
            print(f"WARN: skip archive {arch}: {exc}", file=sys.stderr)
            continue
        if not run:
            continue
        key = run_key_from_path(run["run_dir"], study_dir)
        run["run_key"] = key
        run["study_id"] = study_id
        (runs_out / f"{key}.json").write_text(
            json.dumps(run, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
        peaks = {}
        if run["epochs"]:
            last = run["epochs"][-1]
            best = max(
                run["epochs"],
                key=lambda e: e.get("best_fitness") if isinstance(e.get("best_fitness"), (int, float)) else float("-inf"),
            )
            peaks = {
                "last_generation": last.get("generation"),
                "best_fitness": best.get("best_fitness"),
                "best_bal_acc": best.get("best_bal_acc"),
                "best_nodes": best.get("best_nodes"),
                "best_edges": best.get("best_edges"),
                "best_edges_executed": best.get("best_edges_executed"),
                "best_mcc": best.get("best_mcc"),
                "best_roc_auc": best.get("best_roc_auc"),
            }
        tm = run.get("topology_metrics") or {}
        sm = run.get("series_metrics") or {}
        wm = run.get("weight_metrics") or {}
        run_index.append(
            {
                "run_key": key,
                "run_dir": run["run_dir"],
                "meta": run.get("meta") or {},
                "n_epochs": len(run.get("epochs") or []),
                "has_champion": bool(run.get("champion")),
                "has_weight_stats": bool(wm) or bool(run.get("weight_series")),
                "topo_n_nodes": tm.get("topo_n_nodes"),
                "topo_weight_neg_frac": tm.get("topo_weight_neg_frac"),
                "topo_spatial_reduction_ratio": tm.get("topo_spatial_reduction_ratio"),
                "topo_graph_depth": tm.get("topo_graph_depth"),
                "series_fitness_gain": sm.get("series_fitness_gain"),
                "w_sign_neg_frac": wm.get("w_weight_sign_neg_frac"),
                "w_sparsity_eps": wm.get("w_weight_sparsity_eps"),
                "w_l2_mean": wm.get("w_weight_l2_mean"),
                **peaks,
            }
        )

    # Best bal_acc from results
    best_bal = None
    for r in stripped:
        v = r.get("best_bal_acc")
        if isinstance(v, (int, float)) and (best_bal is None or v > best_bal):
            best_bal = v

    summary = {
        "study_id": study_id,
        "source_path": study_dir,
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "extract_sec": round(time.time() - t0, 2),
        "n_results": len(stripped),
        "n_runs": len(run_index),
        "best_bal_acc": best_bal,
        "has_holdout": holdout is not None,
        "status": status_lite,
        "runs": run_index,
        "script_id": status_lite.get("script_id"),
        "label": status_lite.get("label") or study_dir,
        "finished": status_lite.get("finished"),
        "completed_count": status_lite.get("completed_count"),
    }
    (study_out / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(
        f"OK {study_id}: results={len(stripped)} archives={len(run_index)} "
        f"({summary['extract_sec']}s)",
        flush=True,
    )
    return summary


def write_studies_index(out_dir: Path, summaries: List[dict], head_sha: str) -> None:
    data_dir = out_dir
    data_dir.mkdir(parents=True, exist_ok=True)
    index = []
    for s in summaries:
        index.append(
            {
                "id": s["study_id"],
                "label": s.get("label") or s["study_id"],
                "source_path": s.get("source_path"),
                "script_id": s.get("script_id"),
                "finished": s.get("finished"),
                "completed_count": s.get("completed_count"),
                "n_results": s.get("n_results"),
                "n_runs": s.get("n_runs"),
                "best_bal_acc": s.get("best_bal_acc"),
                "has_holdout": s.get("has_holdout"),
                "updated_at": s.get("updated_at"),
            }
        )
    index.sort(key=lambda x: x.get("source_path") or x["id"])
    (data_dir / "studies.json").write_text(
        json.dumps(
            {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "head": head_sha, "studies": index},
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    (data_dir / "_last_sha.txt").write_text(head_sha + "\n", encoding="utf-8")


def touched_studies(src: Source, prev_sha: str, head_sha: str) -> Optional[Set[str]]:
    """Return study dirs touched between commits, or None for full rebuild."""
    if not src.git_dir or not prev_sha:
        return None
    cp = src._git("diff", "--name-only", f"{prev_sha}..{head_sha}", check=False)
    if cp.returncode != 0:
        return None
    studies: Set[str] = set()
    for line in cp.stdout.splitlines():
        p = line.strip().replace("\\", "/")
        if not p or p.startswith("site/") or p.startswith("tools/"):
            continue
        # Map path to study root = directory containing ova_results.json ancestor
        # Heuristic: ablation/<name>/... or analysis/<name>/...
        parts = p.split("/")
        if len(parts) >= 2 and parts[0] in ("ablation", "analysis"):
            # Prefer longest prefix that has ova_results
            for depth in range(len(parts), 1, -1):
                cand = "/".join(parts[:depth])
                if src.exists(f"{cand}/ova_results.json"):
                    studies.add(cand)
                    break
            else:
                studies.add("/".join(parts[:2]))
    return studies


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--runs-root", type=Path, default=None)
    ap.add_argument("--git-dir", type=Path, default=None, help="Path to .git (bare or worktree .git)")
    ap.add_argument("--ref", default="HEAD")
    ap.add_argument("--out", type=Path, required=True, help="Output site/ root (writes site/data)")
    ap.add_argument("--study-filter", default=None, help="Substring filter on study path")
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--incremental", action="store_true")
    ap.add_argument("--no-champion", action="store_true")
    ap.add_argument(
        "--fetch-weights",
        action="store_true",
        help="If epoch_*_weight_stats.json missing, load champion .pt (slow)",
    )
    ap.add_argument(
        "--weight-stats-root",
        type=Path,
        default=None,
        help="Optional mirror of epoch_*_weight_stats.json (from backfill_weight_stats --out-mirror)",
    )
    ap.add_argument("--max-studies", type=int, default=0)
    args = ap.parse_args(argv)

    git_dir = args.git_dir
    if git_dir and git_dir.is_dir() and (git_dir / ".git").is_dir():
        # worktree root passed
        git_dir = git_dir / ".git"
    elif git_dir and git_dir.is_dir() and git_dir.name != ".git" and (git_dir / "HEAD").is_file():
        pass  # bare or explicit git dir

    weight_stats_root = args.weight_stats_root
    if weight_stats_root is None:
        # Default: site/data/_weight_stats_mirror if present
        cand = args.out.resolve() / "data" / "_weight_stats_mirror"
        if cand.is_dir():
            weight_stats_root = cand

    src = Source(
        runs_root=args.runs_root,
        git_dir=git_dir,
        ref=args.ref,
        weight_stats_root=weight_stats_root,
    )
    site_root = args.out.resolve()
    data_dir = site_root / "data"
    data_dir.mkdir(parents=True, exist_ok=True)

    head = src.head_sha()
    studies = discover_studies(src, args.study_filter)
    if args.max_studies and args.max_studies > 0:
        studies = studies[: args.max_studies]

    only_dirs: Optional[Set[str]] = None
    if args.incremental and not args.full and not args.study_filter:
        prev_path = data_dir / "_last_sha.txt"
        prev = prev_path.read_text(encoding="utf-8").strip() if prev_path.is_file() else ""
        if prev and prev != head:
            only_dirs = touched_studies(src, prev, head)
            if only_dirs is not None:
                print(f"Incremental: {len(only_dirs)} study roots touched", flush=True)
                studies = [(sid, d) for sid, d in studies if d in only_dirs]
        elif not prev:
            print("No _last_sha.txt — doing full extract", flush=True)

    # Merge with existing summaries unless this is an unfiltered full rebuild
    existing: Dict[str, dict] = {}
    studies_json = data_dir / "studies.json"
    replace_all = bool(args.full and not args.study_filter and not args.max_studies)
    if (not replace_all) and studies_json.is_file():
        try:
            prev_idx = json.loads(studies_json.read_text(encoding="utf-8"))
            for s in prev_idx.get("studies") or []:
                sid = s.get("id")
                if not sid:
                    continue
                summary_path = data_dir / "studies" / sid / "summary.json"
                if summary_path.is_file():
                    existing[sid] = json.loads(summary_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            existing = {}

    summaries: Dict[str, dict] = {} if replace_all else dict(existing)
    for study_id, study_dir in studies:
        try:
            summaries[study_id] = extract_study(
                src,
                study_id,
                study_dir,
                data_dir,
                fetch_champion=not args.no_champion,
                fetch_weights=bool(args.fetch_weights),
            )
        except Exception as exc:  # noqa: BLE001
            print(f"ERROR study {study_dir}: {exc}", file=sys.stderr)
            continue

    write_studies_index(data_dir, list(summaries.values()), head)
    print(f"Wrote {data_dir / 'studies.json'} ({len(summaries)} studies, head={head[:12]})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
