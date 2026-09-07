[CmdletBinding()]
param(
    [Parameter()]
    [string]$RunsGitDir = "d:\cifar-10-CNN_NEAT\runs",
    [Parameter()]
    [string]$Worktree = "d:\cifar-10-CNN_NEAT\runs_gh_migrate",
    [Parameter()]
    [string]$SourceRef = "gitverse/master",
    [Parameter()]
    [string]$Remote = "origin",
    [Parameter()]
    [string]$PushRef = "main",
    [Parameter()]
    [double]$MaxPushGB = 1.5,
    [Parameter()]
    [double]$MaxDownloadGB = 200,
    [Parameter()]
    [string]$StateFile = "",
    [Parameter()]
    [switch]$DryRun,
    [Parameter()]
    [switch]$ListOnly,
    [Parameter()]
    [string[]]$OnlyPaths = @()
)

# Full GitVerse -> GitHub migration (new history), resume-safe.
# - Downloads at most -MaxDownloadGB per run (default 200)
# - Each push pack is at most -MaxPushGB (default 1.5, hard cap < 2)
# - Progress: elapsed, ETA, downloaded, pushed, path counts
#
# Run yourself in a dedicated terminal (long-running):
#   powershell -NoProfile -ExecutionPolicy Bypass -File runs\tools\migrate_gitverse_full_to_github.ps1
#   powershell -File runs\tools\migrate_gitverse_full_to_github.ps1 -ListOnly
#   powershell -File runs\tools\migrate_gitverse_full_to_github.ps1 -DryRun
#   powershell -File runs\tools\migrate_gitverse_full_to_github.ps1 -OnlyPaths ablation/ova_study

$ErrorActionPreference = "Stop"
$GitExe = (Get-Command git.exe).Source

if ($MaxPushGB -ge 2.0) { throw "MaxPushGB must be < 2 (got $MaxPushGB). Use 1.5." }
if ($MaxPushGB -le 0) { throw "MaxPushGB must be > 0" }
if ($MaxDownloadGB -le 0) { throw "MaxDownloadGB must be > 0" }

$MaxPushBytes = [int64]([math]::Floor($MaxPushGB * 1GB))
$MaxDownloadBytes = [int64]([math]::Floor($MaxDownloadGB * 1GB))
$ScriptStarted = Get-Date

if (-not $StateFile) {
    $StateFile = Join-Path $RunsGitDir "tools\migrate_state.json"
}

function Format-Bytes([int64]$n) {
    if ($n -lt 0) { return "?" }
    if ($n -ge 1GB) { return ("{0:n2} GB" -f ($n / 1GB)) }
    if ($n -ge 1MB) { return ("{0:n1} MB" -f ($n / 1MB)) }
    if ($n -ge 1KB) { return ("{0:n0} KB" -f ($n / 1KB)) }
    return "$n B"
}

function Format-Duration([TimeSpan]$ts) {
    if ($ts.TotalHours -ge 1) {
        return ("{0}h {1:D2}m {2:D2}s" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds)
    }
    if ($ts.TotalMinutes -ge 1) {
        return ("{0}m {1:D2}s" -f [int]$ts.TotalMinutes, $ts.Seconds)
    }
    return ("{0}s" -f [int]$ts.TotalSeconds)
}

function Write-ProgressLine {
    param(
        [string]$Phase,
        [int64]$DoneBytes,
        [int64]$TotalBytesHint,
        [int]$DoneItems,
        [int]$TotalItems,
        [int64]$SessionDown,
        [int64]$SessionPush
    )
    $elapsed = (Get-Date) - $ScriptStarted
    $eta = "?"
    if ($TotalBytesHint -gt 0 -and $DoneBytes -gt 0) {
        $rate = $DoneBytes / [math]::Max(1.0, $elapsed.TotalSeconds)
        $left = [math]::Max(0, $TotalBytesHint - $DoneBytes)
        if ($rate -gt 0) { $eta = Format-Duration ([TimeSpan]::FromSeconds($left / $rate)) }
    } elseif ($TotalItems -gt 0 -and $DoneItems -gt 0) {
        $rate = $DoneItems / [math]::Max(1.0, $elapsed.TotalSeconds)
        $leftItems = [math]::Max(0, $TotalItems - $DoneItems)
        if ($rate -gt 0) { $eta = Format-Duration ([TimeSpan]::FromSeconds($leftItems / $rate)) }
    }
    $pct = if ($TotalItems -gt 0) { [int](100.0 * $DoneItems / $TotalItems) } else { 0 }
    $free = [math]::Round((Get-PSDrive D).Free / 1GB, 1)
    Write-Host ("" +
        ("[{0}] {1}% paths {2}/{3} | down {4} | push-session {5} | elapsed {6} | ETA {7} | free D:{8}GB" -f `
            $Phase, $pct, $DoneItems, $TotalItems, (Format-Bytes $SessionDown), (Format-Bytes $SessionPush), `
            (Format-Duration $elapsed), $eta, $free)
    ) -ForegroundColor Cyan
}

function Load-State {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        return [ordered]@{
            version        = 1
            done_paths     = @()
            failed_paths   = @{}
            bytes_pushed   = 0
            updated_at     = $null
        }
    }
    $raw = Get-Content -LiteralPath $StateFile -Raw -Encoding utf8 | ConvertFrom-Json
    $done = @()
    if ($raw.done_paths) { $done = @($raw.done_paths | ForEach-Object { [string]$_ }) }
    return [ordered]@{
        version      = 1
        done_paths   = $done
        failed_paths = @{}
        bytes_pushed = [int64]($raw.bytes_pushed)
        updated_at   = $raw.updated_at
    }
}

function Save-State($state) {
    $state.updated_at = (Get-Date).ToString("o")
    $dir = Split-Path $StateFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = $StateFile + ".tmp"
    ($state | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $StateFile -Force
}

function Invoke-Git([string[]]$GitArgs, [switch]$AllowFail, [switch]$Quiet) {
    if ($Quiet) {
        & $GitExe @GitArgs 1>$null 2>$null
    } else {
        & $GitExe @GitArgs
    }
    if (-not $AllowFail -and $LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed ($LASTEXITCODE)"
    }
    return [int]$LASTEXITCODE
}

function Get-TreePaths([string]$Ref, [string]$Prefix = "") {
    if ($Prefix) {
        $spec = "${Ref}:$($Prefix.TrimEnd('/'))"
        $out = & $GitExe @("ls-tree", "--name-only", $spec) 2>$null
    } else {
        $out = & $GitExe @("ls-tree", "--name-only", $Ref) 2>$null
    }
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($out | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim().Replace('\', '/') })
}

function Get-UnitPaths([string]$Ref) {
    # Top-level entries; expand ablation/* one level.
    $skip = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in @(
            '.git', '.gitignore', '.gitverse', '.github', '.git_upload_parts',
            'site', 'tools',
            '.push_runs.lock', '.push_runs_until_done.lock'
        )) {
        [void]$skip.Add($s)
    }
    $units = New-Object System.Collections.Generic.List[string]
    foreach ($name in (Get-TreePaths $Ref)) {
        if ($skip.Contains($name)) { continue }
        if ($name -like '.*') { continue }
        if ($name -eq 'ablation') {
            foreach ($child in (Get-TreePaths $Ref "ablation")) {
                if ($child -eq 'backups') { continue }
                $units.Add("ablation/$child")
            }
        } else {
            $units.Add($name)
        }
    }
    return @($units | Sort-Object -Unique)
}

function Measure-PathBytes([string]$Root, [string]$Rel) {
    $full = Join-Path $Root ($Rel -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $full)) { return [int64]0 }
    $item = Get-Item -LiteralPath $full -Force
    if ($item.PSIsContainer) {
        $sum = [int64]0
        Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $sum += $_.Length }
        return $sum
    }
    return [int64]$item.Length
}

function Split-PathIntoPushChunks {
    param([string]$Root, [string]$Rel, [int64]$MaxBytes)
    $full = Join-Path $Root ($Rel -replace '/', [IO.Path]::DirectorySeparatorChar)
    $total = Measure-PathBytes $Root $Rel
    if ($total -le $MaxBytes) {
        return @([pscustomobject]@{ Path = $Rel; Bytes = $total })
    }
    if (-not (Test-Path -LiteralPath $full) -or -not (Get-Item $full).PSIsContainer) {
        Write-Host "WARN: single file/path larger than MaxPushGB: $Rel ($([math]::Round($total/1GB,2)) GB). Will push alone." -ForegroundColor Yellow
        return @([pscustomobject]@{ Path = $Rel; Bytes = $total })
    }
    # Split by immediate children; recurse if needed.
    $chunks = New-Object System.Collections.Generic.List[object]
    $children = Get-ChildItem -LiteralPath $full -Force | Sort-Object Name
    if ($children.Count -eq 0) {
        return @([pscustomobject]@{ Path = $Rel; Bytes = $total })
    }
    foreach ($ch in $children) {
        $childRel = ($Rel.TrimEnd('/') + '/' + $ch.Name).Replace('\', '/')
        foreach ($piece in (Split-PathIntoPushChunks -Root $Root -Rel $childRel -MaxBytes $MaxBytes)) {
            $chunks.Add($piece)
        }
    }
    return @($chunks)
}

function Ensure-Worktree {
    if (-not (Test-Path -LiteralPath (Join-Path $RunsGitDir '.git'))) {
        throw "Runs git dir missing: $RunsGitDir"
    }
    if (-not (Test-Path -LiteralPath $Worktree)) {
        Write-Host "Creating worktree $Worktree from origin/main (or origin-migrate)..." -ForegroundColor Yellow
        Push-Location $RunsGitDir
        try {
            $base = $null
            if ((& $GitExe rev-parse --verify origin/main 2>$null)) { $base = "origin/main" }
            elseif ((& $GitExe rev-parse --verify origin-migrate 2>$null)) { $base = "origin-migrate" }
            else { throw "Need origin/main or origin-migrate to seed worktree" }
            Invoke-Git @("worktree", "add", $Worktree, $base)
        } finally { Pop-Location }
    }
}

# --- main ---
Ensure-Worktree
Set-Location -LiteralPath $Worktree

# remotes
$remotes = @(& $GitExe remote)
if ($remotes -notcontains "gitverse") {
    Invoke-Git @("remote", "add", "gitverse", "git@gitverse.ru:Mihaham/CNN-NEAT-RUNS.git")
    Invoke-Git @("config", "remote.gitverse.promisor", "true")
    Invoke-Git @("config", "remote.gitverse.partialclonefilter", "tree:0")
}
if ($remotes -notcontains $Remote) {
    Invoke-Git @("remote", "add", $Remote, "git@github.com:Mihaham/CNN-NEAT-RUNS.git")
}

Write-Host "=== migrate GitVerse -> GitHub ===" -ForegroundColor Green
Write-Host "Worktree:   $Worktree"
Write-Host "Source:     $SourceRef"
Write-Host "Target:     $Remote/$PushRef"
Write-Host "MaxPush:    $MaxPushGB GB"
Write-Host "MaxDown:    $MaxDownloadGB GB / session"
Write-Host "State:      $StateFile"
Write-Host "DryRun:     $DryRun"

Write-Host "`n== fetch source tips ==" -ForegroundColor Cyan
Invoke-Git @("fetch", "gitverse", "master", "--no-tags")
Invoke-Git @("fetch", $Remote, $PushRef, "--no-tags") -AllowFail | Out-Null
# sync worktree tip to remote main when possible
$rc = Invoke-Git @("rev-parse", "--verify", "$Remote/$PushRef") -AllowFail
if ($rc -eq 0) {
    Invoke-Git @("checkout", "-B", "origin-migrate", "$Remote/$PushRef") -AllowFail | Out-Null
}

$state = Load-State
$doneSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($d in $state.done_paths) { [void]$doneSet.Add($d) }

# Paths already present on GitHub tip count as done (resume after partial manual pushes)
$rcTip = Invoke-Git @("rev-parse", "--verify", "$Remote/$PushRef") -AllowFail -Quiet
if ($rcTip -eq 0) {
    foreach ($name in (Get-TreePaths "$Remote/$PushRef")) {
        if ($name -eq 'ablation') {
            foreach ($child in (Get-TreePaths "$Remote/$PushRef" "ablation")) {
                [void]$doneSet.Add("ablation/$child")
            }
        } elseif ($name -notin @('site', 'tools', '.github', '.gitignore')) {
            [void]$doneSet.Add($name)
        }
    }
    $state.done_paths = @($doneSet)
    Save-State $state
}

$allUnits = Get-UnitPaths $SourceRef
if ($OnlyPaths -and $OnlyPaths.Count -gt 0) {
    $OnlyPaths = @(
        $OnlyPaths |
            ForEach-Object { $_ -split ',' } |
            ForEach-Object { $_.Trim().Replace('\', '/').TrimStart('/') } |
            Where-Object { $_ }
    )
    $filtered = New-Object System.Collections.Generic.List[string]
    foreach ($u in $allUnits) {
        foreach ($o in $OnlyPaths) {
            if ($u -eq $o -or $u.StartsWith($o.TrimEnd('/') + '/')) {
                $filtered.Add($u)
                break
            }
        }
    }
    foreach ($o in $OnlyPaths) {
        if (-not ($filtered -contains $o) -and -not ($allUnits -contains $o)) {
            $filtered.Add($o)  # allow explicit path even if not in unit list
        }
    }
    $allUnits = @($filtered | Sort-Object -Unique)
}

$pending = @($allUnits | Where-Object { -not $doneSet.Contains($_) })
Write-Host ("Units total={0} done={1} pending={2}" -f $allUnits.Count, $doneSet.Count, $pending.Count)

if ($ListOnly) {
    $pending | ForEach-Object { Write-Host "  PENDING $_" }
    $doneSet | Sort-Object | ForEach-Object { Write-Host "  DONE    $_" }
    exit 0
}

$sessionDown = [int64]0
$sessionPush = [int64]0
$completedThisRun = 0
$pushBatch = New-Object System.Collections.Generic.List[object]  # {Path, Bytes}
$pushBatchBytes = [int64]0

function Flush-PushBatch {
    if ($pushBatch.Count -eq 0) { return }
    $paths = @($pushBatch | ForEach-Object { $_.Path })
    $bytes = [int64]($pushBatch | Measure-Object -Property Bytes -Sum).Sum
    Write-Host ("`n== PUSH batch ({0} paths, {1}) ==" -f $paths.Count, (Format-Bytes $bytes)) -ForegroundColor Yellow
    foreach ($p in $paths) { Write-Host "   - $p" }

    if ($bytes -gt $MaxPushBytes -and $paths.Count -gt 1) {
        throw "Internal error: push batch $($bytes) exceeds MaxPushBytes (multi-path). Split logic bug."
    }
    if ($bytes -ge 2GB) {
        throw "Refusing push >= 2GB ($([math]::Round($bytes/1GB,2)) GB)."
    }

    if ($DryRun) {
        Write-Host "DryRun: skip commit/push" -ForegroundColor DarkYellow
        $script:pushBatch.Clear()
        $script:pushBatchBytes = 0
        return
    }

    Invoke-Git (@("add", "-A", "--") + $paths)
    $msgFile = Join-Path $env:TEMP ("mig_msg_" + [guid]::NewGuid().ToString("N") + ".txt")
    $msg = "migrate: " + ($paths -join ", ")
    Set-Content -LiteralPath $msgFile -Value $msg -Encoding utf8
    cmd /c "`"$GitExe`" commit --allow-empty-message -F `"$msgFile`""
    if ($LASTEXITCODE -ne 0) {
        # maybe nothing staged
        $st = & $GitExe status --porcelain -- @paths
        if (-not $st) {
            Write-Host "Nothing staged; marking done anyway" -ForegroundColor Yellow
        } else {
            throw "commit failed"
        }
    }
    Remove-Item $msgFile -Force -ErrorAction SilentlyContinue

    Write-Host "git push $Remote HEAD:$PushRef ..." -ForegroundColor Cyan
    $tPush = Get-Date
    Invoke-Git @("push", $Remote, "HEAD:$PushRef")
    Write-Host ("push ok in {0}" -f (Format-Duration ((Get-Date) - $tPush))) -ForegroundColor Green

    $script:sessionPush += $bytes
    $state.bytes_pushed = [int64]$state.bytes_pushed + $bytes
    foreach ($p in $paths) {
        if (-not $doneSet.Contains($p)) {
            [void]$doneSet.Add($p)
            $state.done_paths = @($doneSet)
        }
        # Free worktree space (objects remain in .git history)
        $full = Join-Path $Worktree ($p -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $full) {
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Save-State $state
    $script:completedThisRun += $paths.Count
    $script:pushBatch.Clear()
    $script:pushBatchBytes = 0
    Write-ProgressLine -Phase "after-push" -DoneBytes $state.bytes_pushed -TotalBytesHint 0 `
        -DoneItems $doneSet.Count -TotalItems $allUnits.Count -SessionDown $sessionDown -SessionPush $sessionPush
}

foreach ($unit in $pending) {
    if ($sessionDown -ge $MaxDownloadBytes) {
        Write-Host "`nSession download cap reached ($MaxDownloadGB GB). Re-run script to continue." -ForegroundColor Magenta
        break
    }

    Write-Host ("`n== DOWNLOAD {0} ==" -f $unit) -ForegroundColor Yellow
    Write-ProgressLine -Phase "download" -DoneBytes $sessionDown -TotalBytesHint $MaxDownloadBytes `
        -DoneItems $doneSet.Count -TotalItems $allUnits.Count -SessionDown $sessionDown -SessionPush $sessionPush

    if ($DryRun) {
        Write-Host "DryRun: would: git checkout $SourceRef -- $unit"
        [void]$doneSet.Add($unit)
        continue
    }

    $t0 = Get-Date
    try {
        Invoke-Git @("checkout", $SourceRef, "--", $unit)
    } catch {
        Write-Host "FAIL checkout $unit : $_" -ForegroundColor Red
        continue
    }
    $size = Measure-PathBytes $Worktree $unit
    $sessionDown += $size
    Write-Host ("   downloaded/measured {0} in {1}" -f (Format-Bytes $size), (Format-Duration ((Get-Date) - $t0)))

    if ($sessionDown -gt $MaxDownloadBytes -and $size -gt 0) {
        Write-Host "Note: this path crossed session download cap; still processing it, then stop." -ForegroundColor Magenta
    }

    $chunks = Split-PathIntoPushChunks -Root $Worktree -Rel $unit -MaxBytes $MaxPushBytes
    foreach ($ch in $chunks) {
        if ($pushBatchBytes -gt 0 -and ($pushBatchBytes + $ch.Bytes) -gt $MaxPushBytes) {
            Flush-PushBatch
        }
        if ($ch.Bytes -gt $MaxPushBytes -and $pushBatch.Count -eq 0) {
            Write-Host ("WARN: chunk {0} is {1} > MaxPushGB; pushing alone (GitHub may reject if > soft limits)." -f $ch.Path, (Format-Bytes $ch.Bytes)) -ForegroundColor Yellow
        }
        $pushBatch.Add($ch)
        $pushBatchBytes += $ch.Bytes
        if ($pushBatchBytes -ge $MaxPushBytes -or $ch.Bytes -ge $MaxPushBytes) {
            Flush-PushBatch
        }
    }
}

Flush-PushBatch

Write-Host "`n=== session done ===" -ForegroundColor Green
Write-Host ("Elapsed:     {0}" -f (Format-Duration ((Get-Date) - $ScriptStarted)))
Write-Host ("Downloaded:  {0}" -f (Format-Bytes $sessionDown))
Write-Host ("Pushed:      {0}" -f (Format-Bytes $sessionPush))
Write-Host ("Paths done:  {0} / {1}" -f $doneSet.Count, $allUnits.Count)
Write-Host ("Pending:     {0}" -f ($allUnits.Count - $doneSet.Count))
Write-Host ("State file:  {0}" -f $StateFile)
if ($doneSet.Count -lt $allUnits.Count) {
    Write-Host "Re-run the same command to continue." -ForegroundColor Cyan
} else {
    Write-Host "All unit paths migrated." -ForegroundColor Green
}
