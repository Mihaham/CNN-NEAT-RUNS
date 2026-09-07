# Runs dashboard (CNN-NEAT-RUNS)

- `tools/runs_dashboard/` — extract + UI + publish scripts
- `site/` — local build (data from extract)
- branch `pages` — published site (root = contents of `site/`)
- `.gitverse/workflows/build-dashboard.yaml` — CI (tools compile + site shell)

## Commands (copy-paste)

```powershell
cd d:\cifar-10-CNN_NEAT\runs

# 1) Extract ALL remote studies (resume + ETA). Ctrl+C safe — re-run same line.
powershell -File tools/runs_dashboard/run_full_remote_dashboard.ps1

# 2) Push tools + updated CI workflow to master
powershell -File tools/runs_dashboard/seed_sparse.ps1

# 3) Push site to separate branch `pages` (GitVerse Pages: branch=pages, folder=/)
powershell -File tools/runs_dashboard/push_pages_branch.ps1
```

Resume / failures:

```powershell
powershell -File tools/runs_dashboard/run_full_remote_dashboard.ps1
powershell -File tools/runs_dashboard/run_full_remote_dashboard.ps1 -RetryFailedOnly
powershell -File tools/runs_dashboard/run_full_remote_dashboard.ps1 -Reset
```

One-shot extract + both pushes:

```powershell
powershell -File tools/runs_dashboard/run_full_remote_dashboard.ps1 -PushTools -PushPages
```

Local preview:

```powershell
python -m http.server 8765 --directory site
```

## CI

Sparse checkout of `tools/runs_dashboard` (+ optional `site`), `py_compile` of extract /
weight_stats / topology modules, `build_site.py`, artifact upload. Full remote extract
is **not** run in CI.

## Pages

Repo settings → Pages → branch **`pages`**, folder **`/`** (root).
