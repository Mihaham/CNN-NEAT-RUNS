# GitHub: миграция с GitVerse + Pages + CI

Репозиторий: https://github.com/Mihaham/CNN-NEAT-RUNS

## 1. Полный перенос данных GitVerse → GitHub

Скрипт сам крутит волны до конца (или Ctrl+C → resume):

1. Скачал ≤ **200 GB** с GitVerse  
2. Нарезал коммиты ≤ **1.5 GB**  
3. Запушил **каждый** коммит отдельно  
4. Удалил скачанные файлы волны из worktree  
5. Повторил, пока всё не уйдёт; state = `runs\tools\migrate_state.json`

```powershell
cd d:\cifar-10-CNN_NEAT

powershell -NoProfile -ExecutionPolicy Bypass -File runs\tools\migrate_gitverse_full_to_github.ps1 -ListOnly

powershell -NoProfile -ExecutionPolicy Bypass -File runs\tools\migrate_gitverse_full_to_github.ps1
```

В консоли: номер волны, `%` путей, скачано/запушено, **elapsed**, **ETA**, свободно на D:.

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
