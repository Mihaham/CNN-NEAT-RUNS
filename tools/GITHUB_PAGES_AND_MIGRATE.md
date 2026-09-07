# GitHub: миграция с GitVerse + Pages + CI

Репозиторий: https://github.com/Mihaham/CNN-NEAT-RUNS

## 1. Полный перенос данных GitVerse → GitHub

Скрипт (запускай **сам** в отдельном терминале — долгий процесс с прогрессом):

```powershell
cd d:\cifar-10-CNN_NEAT

# Список путей (что осталось / что уже залито)
powershell -NoProfile -ExecutionPolicy Bypass -File runs\tools\migrate_gitverse_full_to_github.ps1 -ListOnly

# Боевой запуск: качает ≤200 GB за сессию, пушит пачками ≤1.5 GB
powershell -NoProfile -ExecutionPolicy Bypass -File runs\tools\migrate_gitverse_full_to_github.ps1

# Продолжение после остановки / лимита 200 GB — та же команда (resume по state-файлу)
powershell -NoProfile -ExecutionPolicy Bypass -File runs\tools\migrate_gitverse_full_to_github.ps1
```

Параметры:

| Параметр | Default | Смысл |
|----------|---------|--------|
| `-MaxPushGB` | `1.5` | потолок размера одного push (**строго &lt; 2**) |
| `-MaxDownloadGB` | `200` | сколько максимум скачать с GitVerse за один запуск |
| `-DryRun` | | только показать план |
| `-OnlyPaths a,b` | | ограничить путями |
| `-StateFile` | `runs\tools\migrate_state.json` | checkpoint для resume |

Прогресс в консоли: `%` путей, скачано / запушено за сессию, **elapsed**, **ETA**, свободно на D:.

История на GitHub **новая** (не зеркало SHA GitVerse). После успешного push файлы из worktree удаляются (освобождает диск); объекты коммитов остаются в `.git` worktree — при нехватке места пересоздай worktree от `origin/main`.

## 2. GitHub Pages (сайт)

1. https://github.com/Mihaham/CNN-NEAT-RUNS/settings/pages  
2. Source: **Deploy from a branch**  
3. Branch: **`pages`**, folder: **`/ (root)`** → Save  
4. URL: `https://mihaham.github.io/CNN-NEAT-RUNS/`

## 3. Workflows

### `Build dashboard` (`.github/workflows/build-dashboard.yml`)

- Manual (`workflow_dispatch`) или push в `tools/runs_dashboard/**`
- Partial clone (`blob:none`): `extract.py` читает только dashboard-JSON через `git show` (без выкачивания всех `.pt`)
- Собирает `site/`, валидирует, публикует ветку `pages`
- Inputs: `study_filter`, `publish_pages`, `fetch_weights`

Actions → **Build dashboard** → Run workflow.

### `Validate site` (`.github/workflows/validate-site.yml`)

- Проверка HTML/assets + валидность JSON в `site/` или на ветке `pages`
- Input `source`: `pages-branch` | `site-on-main`, флаг `strict`

Локально:

```powershell
python runs\tools\runs_dashboard\validate_site.py --site runs\site
```

## 4. Remotes

| remote | URL |
|--------|-----|
| `origin` | `git@github.com:Mihaham/CNN-NEAT-RUNS.git` |
| `gitverse` | `git@gitverse.ru:Mihaham/CNN-NEAT-RUNS.git` |

Cursor Origin — позже (import с GitHub).
