#!/usr/bin/env python3
"""Write ``epoch_*_weight_stats.json`` beside historical ``epoch_*_weights.pt``.

Use while old ``.pt`` are still on disk (or reachable via ``git show``). New runs
already emit these sidecars from ``cnn_neat.run_archive.write_epoch_weights``.

Usage:
  # Local checked-out study (script 15 etc.)
  python backfill_weight_stats.py --runs-root . --study-filter ova_mnist_gpu_only

  # Champion-only (faster): only peak / last weights alias + best-gen from archive
  python backfill_weight_stats.py --runs-root . --study-filter ova_mnist --champions-only

  # Remote blobs without checkout (writes JSON next to nothing — use --out-mirror)
  python backfill_weight_stats.py --git-dir . --ref origin/master \\
      --study-filter ova_gpu_only --out-mirror site/data/_weight_stats_mirror --champions-only
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple

from extract import Source, discover_studies
from weight_pt_stats import epoch_weight_stats_relpath, summarize_weights_store

_EPOCH_PT_RE = re.compile(r"epochs/epoch_(\d+)_weights\.pt$")


def _load_torch(path_or_bytes: Any) -> Any:
    import io

    import torch

    if isinstance(path_or_bytes, (bytes, bytearray)):
        return torch.load(io.BytesIO(path_or_bytes), map_location="cpu", weights_only=False)
    return torch.load(path_or_bytes, map_location="cpu", weights_only=False)


def _atomic_write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    tmp.replace(path)


def _best_gen_from_archive(archive: dict) -> Optional[int]:
    epochs = archive.get("epochs")
    best_gen = None
    best_fit = None
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
    for gen, entry in items:
        summary = entry.get("summary") if isinstance(entry.get("summary"), dict) else {}
        fit = summary.get("best_fitness")
        if isinstance(fit, (int, float)) and (best_fit is None or fit > best_fit):
            best_fit = fit
            best_gen = int(summary.get("generation", gen))
    return best_gen


def _iter_local_weight_pts(runs_root: Path, study_filter: Optional[str]) -> Iterable[Tuple[str, Path]]:
    for pt in runs_root.rglob("epoch_*_weights.pt"):
        if not pt.is_file():
            continue
        rel = pt.relative_to(runs_root).as_posix()
        if study_filter:
            sf = study_filter.replace("\\", "/")
            if sf not in rel:
                continue
        yield rel, pt


def _iter_git_weight_pts(src: Source, study_filter: Optional[str]) -> Iterable[str]:
    for rel in src.list_paths("_weights.pt"):
        if not rel.endswith("_weights.pt"):
            continue
        if "/epochs/" not in rel and not rel.endswith("run_archive_weights.pt"):
            continue
        if study_filter:
            sf = study_filter.replace("\\", "/")
            if sf not in rel:
                continue
        yield rel


def process_store(
    store: Any,
    *,
    include_per_edge: bool,
    out_path: Path,
    dry_run: bool,
    force: bool,
) -> str:
    if out_path.is_file() and not force:
        return "skip_exists"
    if not isinstance(store, dict):
        return "bad_store"
    stats = summarize_weights_store(store, include_per_edge=include_per_edge)
    if dry_run:
        return "dry_run"
    _atomic_write_json(out_path, stats)
    return "wrote"


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--runs-root", type=Path, default=None)
    ap.add_argument("--git-dir", type=Path, default=None)
    ap.add_argument("--ref", default="HEAD")
    ap.add_argument("--study-filter", default=None)
    ap.add_argument(
        "--out-mirror",
        type=Path,
        default=None,
        help="Write JSON under this mirror (relpath preserved) instead of beside .pt",
    )
    ap.add_argument(
        "--champions-only",
        action="store_true",
        help="Only backfill peak generation (from run_archive) + legacy alias",
    )
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-per-edge", action="store_true", help="Omit per-edge blobs (smaller JSON)")
    ap.add_argument("--max-files", type=int, default=0)
    args = ap.parse_args(argv)

    git_dir = args.git_dir
    if git_dir and git_dir.is_dir() and (git_dir / ".git").is_dir():
        git_dir = git_dir / ".git"

    if not args.runs_root and not git_dir:
        print("Need --runs-root and/or --git-dir", file=sys.stderr)
        return 2

    include_per_edge = not args.no_per_edge
    counts: Dict[str, int] = {}
    n_done = 0
    t0 = time.time()

    def bump(key: str) -> None:
        counts[key] = counts.get(key, 0) + 1

    # --- Filesystem mode (preferred while .pt are checked out) ---
    if args.runs_root is not None:
        root = args.runs_root.resolve()
        if args.champions_only:
            src_fs = Source(runs_root=root)
            for study_id, study_dir in discover_studies(src_fs, args.study_filter):
                for arch_rel in [
                    p
                    for p in src_fs.list_paths("run_archive.json")
                    if p.startswith(study_dir + "/") or p == f"{study_dir}/run_archive.json"
                ]:
                    archive = src_fs.read_json(arch_rel)
                    if not isinstance(archive, dict):
                        bump("bad_archive")
                        continue
                    run_dir = arch_rel.rsplit("/", 1)[0]
                    best_gen = _best_gen_from_archive(archive)
                    targets: List[Tuple[str, Path]] = []
                    if best_gen is not None:
                        rel = f"{run_dir}/epochs/epoch_{int(best_gen):04d}_weights.pt"
                        p = root / rel
                        if p.is_file():
                            targets.append((rel, p))
                    legacy = root / run_dir / "run_archive_weights.pt"
                    if legacy.is_file():
                        # Only if we don't already have that generation's epoch file
                        targets.append((f"{run_dir}/run_archive_weights.pt", legacy))
                    seen_out: Set[str] = set()
                    for rel, pt_path in targets:
                        if args.max_files and n_done >= args.max_files:
                            break
                        store = None
                        try:
                            store = _load_torch(pt_path)
                        except Exception as exc:  # noqa: BLE001
                            print(f"WARN load {rel}: {exc}", file=sys.stderr)
                            bump("load_fail")
                            continue
                        gen = store.get("generation") if isinstance(store, dict) else None
                        if gen is None and best_gen is not None and rel.endswith("_weights.pt") and "/epochs/" in rel:
                            m = _EPOCH_PT_RE.search(rel)
                            gen = int(m.group(1)) if m else best_gen
                        if gen is None:
                            bump("no_generation")
                            continue
                        stats_rel = f"{run_dir}/{epoch_weight_stats_relpath(int(gen))}"
                        if stats_rel in seen_out:
                            bump("dup")
                            continue
                        seen_out.add(stats_rel)
                        out = (
                            (args.out_mirror.resolve() / stats_rel)
                            if args.out_mirror
                            else (root / stats_rel)
                        )
                        status = process_store(
                            store,
                            include_per_edge=include_per_edge,
                            out_path=out,
                            dry_run=args.dry_run,
                            force=args.force,
                        )
                        bump(status)
                        n_done += 1
                        if status == "wrote":
                            print(f"OK {stats_rel}", flush=True)
        else:
            for rel, pt_path in _iter_local_weight_pts(root, args.study_filter):
                if args.max_files and n_done >= args.max_files:
                    break
                m = _EPOCH_PT_RE.search(rel)
                if not m:
                    bump("skip_name")
                    continue
                gen = int(m.group(1))
                run_dir = rel.rsplit("/epochs/", 1)[0]
                stats_rel = f"{run_dir}/{epoch_weight_stats_relpath(gen)}"
                out = (
                    (args.out_mirror.resolve() / stats_rel)
                    if args.out_mirror
                    else (root / stats_rel)
                )
                if out.is_file() and not args.force:
                    bump("skip_exists")
                    continue
                try:
                    store = _load_torch(pt_path)
                except Exception as exc:  # noqa: BLE001
                    print(f"WARN load {rel}: {exc}", file=sys.stderr)
                    bump("load_fail")
                    continue
                status = process_store(
                    store,
                    include_per_edge=include_per_edge,
                    out_path=out,
                    dry_run=args.dry_run,
                    force=args.force,
                )
                bump(status)
                n_done += 1
                if status == "wrote" and n_done % 25 == 0:
                    print(f"... {n_done} files ({time.time() - t0:.1f}s)", flush=True)

    # --- Git show mode (no working tree .pt) ---
    elif git_dir is not None:
        src = Source(git_dir=git_dir, ref=args.ref)
        if args.out_mirror is None:
            print("--git-dir mode requires --out-mirror (nowhere else to write)", file=sys.stderr)
            return 2
        mirror = args.out_mirror.resolve()
        if args.champions_only:
            for study_id, study_dir in discover_studies(src, args.study_filter):
                archives = [
                    p
                    for p in src.list_paths("run_archive.json")
                    if p.startswith(study_dir + "/") or p == f"{study_dir}/run_archive.json"
                ]
                for arch_rel in archives:
                    if args.max_files and n_done >= args.max_files:
                        break
                    archive = src.read_json(arch_rel)
                    if not isinstance(archive, dict):
                        bump("bad_archive")
                        continue
                    run_dir = arch_rel.rsplit("/", 1)[0]
                    best_gen = _best_gen_from_archive(archive)
                    if best_gen is None:
                        bump("no_best")
                        continue
                    rel = f"{run_dir}/epochs/epoch_{int(best_gen):04d}_weights.pt"
                    raw = src.read_bytes(rel)
                    if raw is None:
                        raw = src.read_bytes(f"{run_dir}/run_archive_weights.pt")
                        rel = f"{run_dir}/run_archive_weights.pt"
                    if raw is None:
                        bump("missing_pt")
                        continue
                    try:
                        store = _load_torch(raw)
                    except Exception as exc:  # noqa: BLE001
                        print(f"WARN load {rel}: {exc}", file=sys.stderr)
                        bump("load_fail")
                        continue
                    gen = store.get("generation") if isinstance(store, dict) else best_gen
                    stats_rel = f"{run_dir}/{epoch_weight_stats_relpath(int(gen))}"
                    out = mirror / stats_rel
                    status = process_store(
                        store,
                        include_per_edge=include_per_edge,
                        out_path=out,
                        dry_run=args.dry_run,
                        force=args.force,
                    )
                    bump(status)
                    n_done += 1
                    if status == "wrote":
                        print(f"OK {stats_rel}", flush=True)
        else:
            for rel in _iter_git_weight_pts(src, args.study_filter):
                if args.max_files and n_done >= args.max_files:
                    break
                m = _EPOCH_PT_RE.search(rel)
                if not m:
                    bump("skip_name")
                    continue
                gen = int(m.group(1))
                run_dir = rel.rsplit("/epochs/", 1)[0]
                stats_rel = f"{run_dir}/{epoch_weight_stats_relpath(gen)}"
                out = mirror / stats_rel
                if out.is_file() and not args.force:
                    bump("skip_exists")
                    continue
                raw = src.read_bytes(rel)
                if raw is None:
                    bump("missing_pt")
                    continue
                try:
                    store = _load_torch(raw)
                except Exception as exc:  # noqa: BLE001
                    print(f"WARN load {rel}: {exc}", file=sys.stderr)
                    bump("load_fail")
                    continue
                status = process_store(
                    store,
                    include_per_edge=include_per_edge,
                    out_path=out,
                    dry_run=args.dry_run,
                    force=args.force,
                )
                bump(status)
                n_done += 1
                if status == "wrote" and n_done % 10 == 0:
                    print(f"... {n_done} files ({time.time() - t0:.1f}s)", flush=True)

    elapsed = round(time.time() - t0, 2)
    print(json.dumps({"sec": elapsed, "n_done": n_done, "counts": counts}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
