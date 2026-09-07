#!/usr/bin/env python3
"""Validate dashboard site/ data for structural correctness.

Usage:
  python validate_site.py --site site
  python validate_site.py --site site --strict
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, List, Tuple


REQUIRED_HTML = ("index.html", "study.html", "run.html")
REQUIRED_ASSETS = (
    "assets/app.js",
    "assets/charts.js",
    "assets/style.css",
)


def _load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def validate(site: Path, *, strict: bool = False) -> List[str]:
    errors: List[str] = []
    warnings: List[str] = []

    if not site.is_dir():
        return [f"site root missing: {site}"]

    for name in REQUIRED_HTML:
        if not (site / name).is_file():
            errors.append(f"missing HTML: {name}")

    for name in REQUIRED_ASSETS:
        if not (site / name).is_file():
            errors.append(f"missing asset: {name}")

    nojekyll = site / ".nojekyll"
    if not nojekyll.exists():
        warnings.append("missing .nojekyll (GitHub Pages may run Jekyll)")

    data_dir = site / "data"
    studies_path = data_dir / "studies.json"
    if not studies_path.is_file():
        errors.append("missing data/studies.json")
        return _merge(errors, warnings, strict)

    try:
        studies_doc = _load_json(studies_path)
    except Exception as exc:  # noqa: BLE001
        errors.append(f"studies.json not valid JSON: {exc}")
        return _merge(errors, warnings, strict)

    if not isinstance(studies_doc, dict):
        errors.append("studies.json root must be an object")
        return _merge(errors, warnings, strict)

    if "studies" not in studies_doc or not isinstance(studies_doc["studies"], list):
        errors.append("studies.json must contain list field 'studies'")
        return _merge(errors, warnings, strict)

    studies = studies_doc["studies"]
    if len(studies) == 0:
        warnings.append("studies.json has zero studies")

    seen_ids: set[str] = set()
    for i, row in enumerate(studies):
        prefix = f"studies[{i}]"
        if not isinstance(row, dict):
            errors.append(f"{prefix}: must be object")
            continue
        sid = row.get("id") or row.get("study_id") or row.get("slug")
        if not sid or not isinstance(sid, str):
            errors.append(f"{prefix}: missing string id/study_id/slug")
            continue
        if sid in seen_ids:
            errors.append(f"{prefix}: duplicate study id {sid!r}")
        seen_ids.add(sid)

        # Optional but common pointers used by the UI.
        for key in ("data_file", "path", "json"):
            rel = row.get(key)
            if isinstance(rel, str) and rel.endswith(".json"):
                candidate = data_dir / rel
                if not candidate.is_file():
                    # also allow nested under data/
                    alt = site / rel
                    if not alt.is_file():
                        warnings.append(f"{prefix}: referenced file missing: {rel}")

    # Every *.json under data/ (except studies.json / mirrors) must parse.
    if data_dir.is_dir():
        for path in sorted(data_dir.rglob("*.json")):
            rel = path.relative_to(site).as_posix()
            if "_weight_stats_mirror" in rel.split("/"):
                continue
            try:
                _load_json(path)
            except Exception as exc:  # noqa: BLE001
                errors.append(f"invalid JSON {rel}: {exc}")

    return _merge(errors, warnings, strict)


def _merge(errors: List[str], warnings: List[str], strict: bool) -> List[str]:
    out = list(errors)
    if strict:
        out.extend(f"WARN→ERR: {w}" for w in warnings)
    else:
        for w in warnings:
            print(f"WARNING: {w}", file=sys.stderr)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--site", type=Path, required=True, help="site/ root")
    ap.add_argument(
        "--strict",
        action="store_true",
        help="Treat warnings as errors",
    )
    args = ap.parse_args()
    problems = validate(args.site.resolve(), strict=bool(args.strict))
    if problems:
        print(f"INVALID site ({len(problems)} issue(s)):", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1
    print(f"OK: site validated ({args.site})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
