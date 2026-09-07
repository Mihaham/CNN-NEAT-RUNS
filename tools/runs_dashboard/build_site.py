#!/usr/bin/env python3
"""Copy static dashboard templates into site/ (keeps existing site/data/)."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
STATIC_DIR = SCRIPT_DIR / "static"


def build(site_root: Path) -> None:
    site_root.mkdir(parents=True, exist_ok=True)
    (site_root / "data").mkdir(parents=True, exist_ok=True)
    (site_root / ".nojekyll").write_text("", encoding="utf-8")

    for name in ("index.html", "study.html", "run.html"):
        src = STATIC_DIR / name
        if not src.is_file():
            raise FileNotFoundError(src)
        shutil.copy2(src, site_root / name)

    assets_src = STATIC_DIR / "assets"
    assets_dst = site_root / "assets"
    if assets_dst.exists():
        shutil.rmtree(assets_dst)
    shutil.copytree(assets_src, assets_dst)
    print(f"Built site templates -> {site_root}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True, help="site/ root")
    args = ap.parse_args()
    build(args.out.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
