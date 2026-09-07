param(
    [string]$RunsDir = (Join-Path $PSScriptRoot "..\.."),
    [string]$Ref = "origin/master",
    [string]$OutSite = "",
    # Comma-separated study path filters (matched against ova_results path).
    [string]$Studies = "",
    # Process all studies discovered on Ref (slow).
    [switch]$AllRemote,
    # Also extract local filesystem tree (e.g. in-progress script 15). KeepLocal implied.
    [string]$LocalStudyDir = "",
    [switch]$NoChampion,
    # Load champion .pt when epoch_*_weight_stats.json is missing (slow).
    [switch]$FetchWeights,
    # Before extract: write weight_stats JSON beside local .pt (or mirror via git show).
    [switch]$BackfillWeightStats,
    [switch]$WeightStatsChampionsOnly,
    [switch]$PushSite,
    [switch]$DryRun
)

# Incremental / timed dashboard backfill for CNN-NEAT-RUNS.
# Remote studies: git show only (no working-tree checkout of .pt).
# Local study: read JSON from disk; never deletes LocalStudyDir.

$ErrorActionPreference = "Stop"
$RunsDir = (Resolve-Path -LiteralPath $RunsDir).Path
$GitDir = Join-Path $RunsDir ".git"
if (-not (Test-Path -LiteralPath $GitDir)) { throw "No .git in $RunsDir" }
if (-not $OutSite) { $OutSite = Join-Path $RunsDir "site" }

$ToolDir = $PSScriptRoot
$LogDir = Join-Path $ToolDir "backfill_logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogPath = Join-Path $LogDir ("backfill_" + $stamp + ".jsonl")
$SummaryPath = Join-Path $LogDir ("backfill_" + $stamp + "_summary.json")

function Write-Log([hashtable]$row) {
    ($row | ConvertTo-Json -Compress) | Add-Content -LiteralPath $LogPath -Encoding utf8
    $msg = "[{0}] {1} sec={2} ok={3}" -f $row.phase, $row.name, $row.sec, $row.ok
    if ($row.detail) { $msg += " " + $row.detail }
    Write-Host $msg
}

function Invoke-Extract([string[]]$ExtraArgs, [string]$Name, [string]$Phase) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $true
    $detail = ""
    $err = ""
    try {
        if ($DryRun) {
            $detail = "dry-run: python extract.py " + ($ExtraArgs -join " ")
        } else {
            $out = & python (Join-Path $ToolDir "extract.py") @ExtraArgs 2>&1
            $code = $LASTEXITCODE
            $detail = (($out | Out-String).Trim() -replace '\s+', ' ')
            if ($detail.Length -gt 400) { $detail = $detail.Substring($detail.Length - 400) }
            if ($code -ne 0) {
                $ok = $false
                $err = "exit $code"
            }
        }
    } catch {
        $ok = $false
        $err = "$_"
    }
    $sw.Stop()
    $row = @{
        ts     = (Get-Date).ToString("o")
        phase  = $Phase
        name   = $Name
        sec    = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        ok     = $ok
        detail = $detail
        error  = $err
    }
    Write-Log $row
    return $row
}

function Invoke-WeightStats([string[]]$ExtraArgs, [string]$Name) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $true
    $detail = ""
    $err = ""
    try {
        if ($DryRun) {
            $detail = "dry-run: python backfill_weight_stats.py " + ($ExtraArgs -join " ")
        } else {
            $out = & python (Join-Path $ToolDir "backfill_weight_stats.py") @ExtraArgs 2>&1
            $code = $LASTEXITCODE
            $detail = (($out | Out-String).Trim() -replace '\s+', ' ')
            if ($detail.Length -gt 400) { $detail = $detail.Substring($detail.Length - 400) }
            if ($code -ne 0) {
                $ok = $false
                $err = "exit $code"
            }
        }
    } catch {
        $ok = $false
        $err = "$_"
    }
    $sw.Stop()
    $row = @{
        ts     = (Get-Date).ToString("o")
        phase  = "weight_stats_backfill"
        name   = $Name
        sec    = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        ok     = $ok
        detail = $detail
        error  = $err
    }
    Write-Log $row
    return $row
}

# Discover remote studies
$allResults = @(
    & git --git-dir $GitDir ls-tree -r --name-only $Ref |
        Where-Object { $_ -match 'ova_results\.json$' }
)

$filters = @()
if ($AllRemote) {
    $filters = $allResults
} elseif ($Studies) {
    $filters = $Studies.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
} else {
    # Default: smokes + gpu_ab (smoke test of pipeline), not the huge ones
    $filters = @(
        "analysis/script11_smoke_a2",
        "ablation/ova_gpu_ab"
    )
}

Write-Host "RunsDir=$RunsDir"
Write-Host "Ref=$Ref OutSite=$OutSite"
Write-Host "Remote ova_results=$($allResults.Count) selected_filters=$($filters.Count)"
Write-Host "Log=$LogPath"
Write-Host ""

$results = New-Object System.Collections.Generic.List[object]
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# 0) Materialize compact weight_stats JSON from .pt while they are still reachable
if ($BackfillWeightStats) {
    if ($LocalStudyDir) {
        $bf = @(
            "--runs-root", $RunsDir,
            "--study-filter", ($LocalStudyDir -replace '\\', '/')
        )
        if ($WeightStatsChampionsOnly) { $bf += "--champions-only" }
        $results.Add((Invoke-WeightStats $bf "local:$LocalStudyDir")) | Out-Null
    }
    foreach ($f in $filters) {
        $bf = @(
            "--git-dir", $GitDir,
            "--ref", $Ref,
            "--study-filter", $f,
            "--out-mirror", (Join-Path $OutSite "data\_weight_stats_mirror"),
            "--champions-only"
        )
        # Remote without checkout: champions-only via git show into site mirror
        $results.Add((Invoke-WeightStats $bf "remote:$f")) | Out-Null
    }
}

# 1) Local study first (script 15): keep on disk
if ($LocalStudyDir) {
    $localFull = if ([IO.Path]::IsPathRooted($LocalStudyDir)) {
        $LocalStudyDir
    } else {
        Join-Path $RunsDir $LocalStudyDir
    }
    if (-not (Test-Path -LiteralPath $localFull)) {
        throw "LocalStudyDir not found: $localFull"
    }
    # Extract via git filter on path if present remotely, else filesystem root.
    # Prefer filesystem for local in-progress tree.
    $args = @(
        "--runs-root", $RunsDir,
        "--out", $OutSite,
        "--study-filter", ($LocalStudyDir -replace '\\', '/')
    )
    if ($NoChampion) { $args += "--no-champion" }
    if ($FetchWeights) { $args += "--fetch-weights" }
    $results.Add((Invoke-Extract $args "local:$LocalStudyDir" "local_extract")) | Out-Null
}

# 2) Remote studies one-by-one via git show (no checkout of .pt)
foreach ($f in $filters) {
    $args = @(
        "--git-dir", $GitDir,
        "--ref", $Ref,
        "--out", $OutSite,
        "--study-filter", $f
    )
    if ($NoChampion) { $args += "--no-champion" }
    if ($FetchWeights) { $args += "--fetch-weights" }
    $results.Add((Invoke-Extract $args "remote:$f" "remote_extract")) | Out-Null
}

# 3) Build site shell
$sw = [System.Diagnostics.Stopwatch]::StartNew()
if (-not $DryRun) {
    & python (Join-Path $ToolDir "build_site.py") --out $OutSite
}
$sw.Stop()
$buildRow = @{
    ts = (Get-Date).ToString("o"); phase = "build_site"; name = "build_site"
    sec = [math]::Round($sw.Elapsed.TotalSeconds, 2); ok = ($LASTEXITCODE -eq 0 -or $DryRun)
    detail = ""; error = ""
}
Write-Log $buildRow
$results.Add($buildRow) | Out-Null

# 4) Optional push site/tools only (does not purge local runs)
if ($PushSite) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $DryRun) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ToolDir "seed_sparse.ps1")
        $pushOk = ($LASTEXITCODE -eq 0)
    } else {
        $pushOk = $true
    }
    $sw.Stop()
    $pushRow = @{
        ts = (Get-Date).ToString("o"); phase = "push_site"; name = "seed_sparse"
        sec = [math]::Round($sw.Elapsed.TotalSeconds, 2); ok = $pushOk
        detail = "site+tools only"; error = ""
    }
    Write-Log $pushRow
    $results.Add($pushRow) | Out-Null
}

$totalSw.Stop()
$okN = @($results | Where-Object { $_.ok }).Count
$failN = @($results | Where-Object { -not $_.ok }).Count
$byPhase = @{}
foreach ($r in $results) {
    $ph = [string]$r.phase
    if (-not $byPhase.ContainsKey($ph)) { $byPhase[$ph] = 0.0 }
    $byPhase[$ph] = [double]$byPhase[$ph] + [double]$r.sec
}

$summaryObj = [pscustomobject]@{
    started_log  = $LogPath
    total_sec    = [math]::Round($totalSw.Elapsed.TotalSeconds, 2)
    total_min    = [math]::Round($totalSw.Elapsed.TotalMinutes, 2)
    ok           = $okN
    fail         = $failN
    sec_by_phase = $byPhase
    steps        = @($results | ForEach-Object {
            [pscustomobject]@{
                ts = $_.ts; phase = $_.phase; name = $_.name
                sec = $_.sec; ok = $_.ok; detail = $_.detail; error = $_.error
            }
        })
    note = "Remote extract uses git show (no .pt checkout). LocalStudyDir is never deleted by this script."
}
$summaryObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SummaryPath -Encoding utf8

Write-Host ""
Write-Host "==== SUMMARY ===="
Write-Host ("total: {0} min ({1} sec)  ok={2} fail={3}" -f $summaryObj.total_min, $summaryObj.total_sec, $okN, $failN)
Write-Host "summary: $SummaryPath"
Write-Host "NOTE: This script never deletes pulled/local run trees. Purge is a separate explicit step."
