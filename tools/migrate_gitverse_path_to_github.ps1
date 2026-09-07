[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$Paths,
    [Parameter()]
    [string]$Worktree = "d:\cifar-10-CNN_NEAT\runs_gh_migrate",
    [Parameter()]
    [string]$SourceRef = "gitverse/master",
    [Parameter()]
    [string]$PushRef = "main",
    [Parameter()]
    [string]$Remote = "origin",
    [Parameter()]
    [string]$Message = ""
)

# Pull path(s) from GitVerse (partial clone / promisor OK) into the GitHub migration
# worktree, commit on top of current tip, push to GitHub.
# Usage:
#   .\migrate_gitverse_path_to_github.ps1 -Paths smoke_cnn_neat,tests
#   .\migrate_gitverse_path_to_github.ps1 -Paths ablation/ova_multiclass_evolve

$ErrorActionPreference = "Stop"
$GitExe = (Get-Command git.exe).Source
# -File passes "a,b" as one string; normalize to path list
$Paths = @(
    $Paths |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
)
if ($Paths.Count -eq 0) { throw "No paths given" }
if (-not (Test-Path -LiteralPath $Worktree)) {
    throw "Worktree missing: $Worktree (create with: git -C runs worktree add ..\runs_gh_migrate origin-migrate)"
}

Set-Location -LiteralPath $Worktree
Write-Host "== worktree = $Worktree ==" -ForegroundColor Cyan
Write-Host "HEAD=$( & $GitExe rev-parse --short HEAD )"
Write-Host "free D: $([math]::Round((Get-PSDrive D).Free/1GB,1)) GB"

# Ensure remotes
& $GitExe remote get-url gitverse 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    & $GitExe remote add gitverse "git@gitverse.ru:Mihaham/CNN-NEAT-RUNS.git"
    & $GitExe config remote.gitverse.promisor true
    & $GitExe config remote.gitverse.partialclonefilter tree:0
}
& $GitExe remote get-url origin 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    & $GitExe remote add origin "git@github.com:Mihaham/CNN-NEAT-RUNS.git"
}

Write-Host "== fetch $SourceRef tips (trees/commits; blobs on demand) ==" -ForegroundColor Cyan
& $GitExe fetch gitverse master --no-tags
if ($LASTEXITCODE -ne 0) { throw "git fetch gitverse failed" }

foreach ($p in $Paths) {
    $p = $p.Trim().TrimStart('/', '\').Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    Write-Host "== checkout $SourceRef -- $p (may download blobs from GitVerse) ==" -ForegroundColor Yellow
    $t0 = Get-Date
    & $GitExe checkout $SourceRef -- $p
    if ($LASTEXITCODE -ne 0) { throw "checkout failed for $p (path missing on $SourceRef or fetch error)" }
    $dt = (Get-Date) - $t0
    Write-Host ("   done in {0:n1} min; free D: {1} GB" -f $dt.TotalMinutes, [math]::Round((Get-PSDrive D).Free/1GB,1))
}

$status = & $GitExe status --porcelain
if (-not $status) {
    Write-Host "Nothing new to commit for paths: $($Paths -join ', ')" -ForegroundColor Yellow
    exit 0
}

if (-not $Message) {
    $Message = "migrate: $($Paths -join ', ') from GitVerse"
}

Write-Host "== commit ==" -ForegroundColor Cyan
& $GitExe add -A -- $Paths
# Use cmd to avoid tooling rewriting `git commit`
$msgFile = Join-Path $env:TEMP ("migrate_msg_" + [guid]::NewGuid().ToString("N") + ".txt")
Set-Content -LiteralPath $msgFile -Value $Message -Encoding utf8
cmd /c "`"$GitExe`" commit -F `"$msgFile`""
Remove-Item $msgFile -Force -ErrorAction SilentlyContinue
if ($LASTEXITCODE -ne 0) { throw "commit failed" }
Write-Host "commit=$( & $GitExe rev-parse --short HEAD )"

Write-Host "== push $Remote $PushRef ==" -ForegroundColor Cyan
& $GitExe push $Remote "HEAD:$PushRef"
if ($LASTEXITCODE -ne 0) { throw "push to $Remote/$PushRef failed" }

Write-Host "OK: $($Paths -join ', ') -> $Remote/$PushRef" -ForegroundColor Green
& $GitExe log -1 --oneline
& $GitExe ls-remote $Remote "refs/heads/$PushRef"
