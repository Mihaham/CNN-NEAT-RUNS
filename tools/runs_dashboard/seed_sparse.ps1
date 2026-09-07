param(
    [string]$RunsDir = (Join-Path $PSScriptRoot "..\.."),
    [string]$Branch = "master",
    [switch]$IncludeSite,
    [switch]$NoPush
)

# Seed tools/runs_dashboard + GitVerse workflow into CNN-NEAT-RUNS master.
# Site publish: use push_pages_branch.ps1 (separate pages branch).

$ErrorActionPreference = "Stop"
$RunsDir = (Resolve-Path -LiteralPath $RunsDir).Path
$GitExe = (Get-Command git.exe).Source
Set-Location -LiteralPath $RunsDir

$ToolSrc = $PSScriptRoot
$WfDst = Join-Path $RunsDir ".gitverse\workflows\build-dashboard.yaml"
$SiteDir = Join-Path $RunsDir "site"

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $WfDst) | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $RunsDir "tools\runs_dashboard") | Out-Null

Copy-Item -Force (Join-Path $ToolSrc "gitverse_workflow.yaml") $WfDst

Set-Content -LiteralPath (Join-Path $ToolSrc ".gitignore") -Value "__pycache__/`n*.pyc`n_extract*.log`n_extract*.err`n_extract*.pid`nbackfill_logs/`n" -Encoding ascii

function Invoke-Git([string[]]$GitArgs, [switch]$AllowFail) {
    $argLine = ($GitArgs | ForEach-Object {
            $a = "$_"
            if ($a -match '[\s"]') { '"' + ($a.Replace('"', '\"')) + '"' } else { $a }
        }) -join ' '
    cmd.exe /c "`"$GitExe`" $argLine"
    if (-not $AllowFail -and $LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed: $LASTEXITCODE"
    }
}

function Add-Tree([string]$RelRoot) {
    $full = Join-Path $RunsDir $RelRoot
    if (-not (Test-Path -LiteralPath $full)) { return 0 }
    $n = 0
    Get-ChildItem -LiteralPath $full -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($RunsDir.Length).TrimStart("\").Replace("\", "/")
        if ($rel -match '/__pycache__/|\.pyc$|_extract|backfill_logs/|_weight_stats_mirror/|_rewrite_ps1\.py$') { return }
        $sha = (& cmd.exe /c "`"$GitExe`" hash-object -w -- `"$($_.FullName)`"").Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sha)) {
            throw "hash-object failed for $rel"
        }
        Invoke-Git @("update-index", "--add", "--cacheinfo", "100644,$sha,$rel")
        $n++
    }
    return $n
}

$added = 0
$added += Add-Tree "tools/runs_dashboard"
$added += Add-Tree ".gitverse/workflows"
if ($IncludeSite) {
    New-Item -ItemType Directory -Force -Path (Join-Path $SiteDir "data") | Out-Null
    Copy-Item -Force (Join-Path $ToolSrc "static\index.html") (Join-Path $SiteDir "index.html")
    Copy-Item -Force (Join-Path $ToolSrc "static\study.html") (Join-Path $SiteDir "study.html")
    Copy-Item -Force (Join-Path $ToolSrc "static\run.html") (Join-Path $SiteDir "run.html")
    Set-Content -LiteralPath (Join-Path $SiteDir ".nojekyll") -Value "" -Encoding ascii
    $assetsDst = Join-Path $SiteDir "assets"
    if (Test-Path $assetsDst) { Remove-Item $assetsDst -Recurse -Force }
    Copy-Item -Recurse (Join-Path $ToolSrc "static\assets") $assetsDst
    $added += Add-Tree "site"
    Write-Host "IncludeSite: indexed site/ into $Branch (prefer pages branch for publish)"
}
Write-Host "Indexed $added files"

$treeOut = & cmd.exe /c "`"$GitExe`" write-tree --missing-ok 2>&1"
$tree = ("$treeOut" -split "`r?`n" | Where-Object { $_ -match '^[0-9a-f]{40}$' } | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($tree)) { throw "write-tree failed: $treeOut" }
Write-Host "tree=$tree"

$parent = (& cmd.exe /c "`"$GitExe`" rev-parse HEAD").Trim()
$msgFile = Join-Path $env:TEMP ("dash_seed_" + [guid]::NewGuid().ToString("N") + ".txt")
Set-Content -LiteralPath $msgFile -Value "ci: dashboard tools + workflow (pages site via push_pages_branch)" -Encoding ascii
$commitOut = & cmd.exe /c "`"$GitExe`" commit-tree $tree -p $parent -F `"$msgFile`" 2>&1"
Remove-Item $msgFile -Force -ErrorAction SilentlyContinue
$commit = ("$commitOut" -split "`r?`n" | Where-Object { $_ -match '^[0-9a-f]{40}$' } | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($commit)) { throw "commit-tree failed: $commitOut" }
Invoke-Git @("update-ref", "refs/heads/$Branch", $commit)
Write-Host "commit=$commit"

if (-not $NoPush) {
    $env:GIT_SSH_COMMAND = "ssh -o BatchMode=yes -o ConnectTimeout=30"
    Invoke-Git @("push", "--no-thin", "origin", "HEAD:$Branch") -AllowFail
    if ($LASTEXITCODE -ne 0) {
        Write-Host "push failed once; retry..."
        Invoke-Git @("push", "--no-thin", "origin", "HEAD:$Branch")
    }
    Write-Host "Pushed to origin/$Branch"
} else {
    Write-Host "NoPush set - local commit only"
}
