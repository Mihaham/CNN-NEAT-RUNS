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
#
# One run loops until everything is done (or Ctrl+C):
#   1) Download up to -MaxDownloadGB (default 200)
#   2) Commit in chunks of -MaxPushGB (default 1.5, hard < 2)
#   3) Push EACH commit separately
#   4) Delete the downloaded wave from the worktree
#   5) Repeat; state file resumes after stop
#
# Run yourself in a dedicated terminal:
#   powershell -NoProfile -ExecutionPolicy Bypass -File runs\tools\migrate_gitverse_full_to_github.ps1
#   powershell -File runs\tools\migrate_gitverse_full_to_github.ps1 -ListOnly

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


# =====================================================================
# Wave loop: download <= MaxDownloadGB -> commit/push <= MaxPushGB each
# -> delete wave files -> repeat until pending empty (resume via state)
# =====================================================================

function Get-TreeChildren([string]$Ref, [string]$Rel) {
    $kids = @(Get-TreePaths $Ref $Rel)
    return @($kids | ForEach-Object {
        if ($_ -match '/' ) { $_ } else { "$($Rel.TrimEnd('/'))/$_" }
    })
}

function Remove-WorktreePath([string]$Rel) {
    $full = Join-Path $Worktree ($Rel -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (Test-Path -LiteralPath $full) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Commit-AndPushChunk {
    param([string[]]$Paths, [int64]$Bytes)
    if ($Paths.Count -eq 0) { return }
    Write-Host ("`n== COMMIT+PUSH ({0} paths, {1}) ==" -f $Paths.Count, (Format-Bytes $Bytes)) -ForegroundColor Yellow
    foreach ($p in $Paths) { Write-Host "   - $p" }
    if ($Bytes -ge 2GB) { throw "Refusing push >= 2GB ($([math]::Round($Bytes/1GB,2)) GB)" }
    if ($DryRun) {
        Write-Host "DryRun: skip commit/push" -ForegroundColor DarkYellow
        return
    }
    Invoke-Git (@("add", "-A", "--") + $Paths)
    $msgFile = Join-Path $env:TEMP ("mig_msg_" + [guid]::NewGuid().ToString("N") + ".txt")
    Set-Content -LiteralPath $msgFile -Value ("migrate: " + ($Paths -join ", ")) -Encoding utf8
    cmd /c "`"$GitExe`" commit -F `"$msgFile`""
    $commitRc = $LASTEXITCODE
    Remove-Item $msgFile -Force -ErrorAction SilentlyContinue
    if ($commitRc -ne 0) {
        $st = & $GitExe status --porcelain -- @Paths
        if (-not $st) {
            Write-Host "Nothing to commit for chunk (already indexed?)" -ForegroundColor Yellow
        } else {
            throw "commit failed"
        }
    } else {
        Write-Host "git push $Remote HEAD:$PushRef (single commit) ..." -ForegroundColor Cyan
        $tPush = Get-Date
        Invoke-Git @("push", $Remote, "HEAD:$PushRef")
        Write-Host ("push ok in {0}" -f (Format-Duration ((Get-Date) - $tPush))) -ForegroundColor Green
        $script:totalPushedBytes += $Bytes
        $state.bytes_pushed = [int64]$state.bytes_pushed + $Bytes
        Save-State $state
    }
}

$totalPushedBytes = [int64]0
$waveIndex = 0
$pendingQueue = New-Object System.Collections.Generic.Queue[string]
foreach ($u in $pending) { $pendingQueue.Enqueue($u) }

Write-Host ("`nStarting wave loop. Pending={0} MaxDown={1} MaxPush={2}" -f `
    $pendingQueue.Count, (Format-Bytes $MaxDownloadBytes), (Format-Bytes $MaxPushBytes)) -ForegroundColor Green

while ($pendingQueue.Count -gt 0) {
    $waveIndex++
    $waveDownloaded = [int64]0
    $wavePaths = New-Object System.Collections.Generic.List[string]
    Write-Host ("`n######## WAVE {0} — DOWNLOAD (cap {1}) ########" -f $waveIndex, (Format-Bytes $MaxDownloadBytes)) -ForegroundColor Magenta

    while ($pendingQueue.Count -gt 0 -and $waveDownloaded -lt $MaxDownloadBytes) {
        $unit = $pendingQueue.Dequeue()
        Write-ProgressLine -Phase "wave-$waveIndex-dl" -DoneBytes $waveDownloaded -TotalBytesHint $MaxDownloadBytes `
            -DoneItems $doneSet.Count -TotalItems $allUnits.Count -SessionDown $waveDownloaded -SessionPush $totalPushedBytes

        if ($DryRun) {
            Write-Host "DryRun: would download $unit"
            $wavePaths.Add($unit)
            [void]$doneSet.Add($unit)
            continue
        }

        Write-Host ("== checkout {0} ==" -f $unit) -ForegroundColor Yellow
        $t0 = Get-Date
        try {
            Invoke-Git @("checkout", $SourceRef, "--", $unit)
        } catch {
            Write-Host "FAIL checkout $unit : $_ — skip" -ForegroundColor Red
            continue
        }
        $size = Measure-PathBytes $Worktree $unit
        Write-Host ("   size {0} in {1}" -f (Format-Bytes $size), (Format-Duration ((Get-Date) - $t0)))

        $remaining = $MaxDownloadBytes - $waveDownloaded
        if ($size -gt $remaining -and $size -gt ($MaxDownloadBytes / 4)) {
            $children = @(Get-TreeChildren $SourceRef $unit)
            if ($children.Count -gt 1) {
                Write-Host ("   too large for remaining budget — expand to {0} children" -f $children.Count) -ForegroundColor DarkYellow
                Remove-WorktreePath $unit
                $rest = New-Object System.Collections.Generic.List[string]
                while ($pendingQueue.Count -gt 0) { $rest.Add($pendingQueue.Dequeue()) }
                foreach ($c in $children) {
                    if (-not $doneSet.Contains($c)) { $pendingQueue.Enqueue($c) }
                }
                foreach ($r in $rest) { $pendingQueue.Enqueue($r) }
                continue
            }
        }

        $wavePaths.Add($unit)
        $waveDownloaded += $size
        Write-Host ("   wave download now {0} / {1}" -f (Format-Bytes $waveDownloaded), (Format-Bytes $MaxDownloadBytes))
    }

    if ($wavePaths.Count -eq 0) {
        Write-Host "Wave downloaded nothing; stopping to avoid loop." -ForegroundColor Red
        break
    }

    Write-Host ("`n######## WAVE {0} — COMMIT/PUSH chunks <={1} ########" -f $waveIndex, (Format-Bytes $MaxPushBytes)) -ForegroundColor Magenta

    $chunks = New-Object System.Collections.Generic.List[object]
    foreach ($wp in $wavePaths) {
        foreach ($ch in (Split-PathIntoPushChunks -Root $Worktree -Rel $wp -MaxBytes $MaxPushBytes)) {
            $chunks.Add($ch)
        }
    }

    $batch = New-Object System.Collections.Generic.List[object]
    $batchBytes = [int64]0
    $chunkI = 0
    foreach ($ch in $chunks) {
        if ($batchBytes -gt 0 -and ($batchBytes + $ch.Bytes) -gt $MaxPushBytes) {
            $chunkI++
            Write-ProgressLine -Phase "wave-$waveIndex-push-$chunkI" -DoneBytes $totalPushedBytes -TotalBytesHint 0 `
                -DoneItems $doneSet.Count -TotalItems $allUnits.Count -SessionDown $waveDownloaded -SessionPush $totalPushedBytes
            Commit-AndPushChunk -Paths @($batch | ForEach-Object { $_.Path }) -Bytes $batchBytes
            $batch.Clear()
            $batchBytes = 0
        }
        $batch.Add($ch)
        $batchBytes += $ch.Bytes
        if ($batchBytes -ge $MaxPushBytes) {
            $chunkI++
            Commit-AndPushChunk -Paths @($batch | ForEach-Object { $_.Path }) -Bytes $batchBytes
            $batch.Clear()
            $batchBytes = 0
        }
    }
    if ($batch.Count -gt 0) {
        $chunkI++
        Commit-AndPushChunk -Paths @($batch | ForEach-Object { $_.Path }) -Bytes $batchBytes
    }

    Write-Host ("`n######## WAVE {0} — DELETE downloaded files ({1}) ########" -f $waveIndex, (Format-Bytes $waveDownloaded)) -ForegroundColor Magenta
    foreach ($wp in $wavePaths) {
        if (-not $DryRun) { Remove-WorktreePath $wp }
        if (-not $doneSet.Contains($wp)) { [void]$doneSet.Add($wp) }
    }
    $state.done_paths = @($doneSet)
    Save-State $state

    if (-not $DryRun) {
        Invoke-Git @("reset", "--hard", "HEAD") -AllowFail | Out-Null
        Invoke-Git @("clean", "-fd") -AllowFail | Out-Null
    }

    Write-Host ("Wave {0} done. done={1}/{2} queue={3} freeD={4}GB elapsed={5}" -f `
        $waveIndex, $doneSet.Count, $allUnits.Count, $pendingQueue.Count, `
        [math]::Round((Get-PSDrive D).Free/1GB,1), (Format-Duration ((Get-Date) - $ScriptStarted))) -ForegroundColor Green
}

Write-Host "`n=== ALL WAVES FINISHED (or stopped) ===" -ForegroundColor Green
Write-Host ("Elapsed:     {0}" -f (Format-Duration ((Get-Date) - $ScriptStarted)))
Write-Host ("Pushed:      {0}" -f (Format-Bytes $totalPushedBytes))
Write-Host ("Paths done:  {0} / {1}" -f $doneSet.Count, $allUnits.Count)
Write-Host ("Queue left:  {0}" -f $pendingQueue.Count)
Write-Host ("State file:  {0}" -f $StateFile)
if ($pendingQueue.Count -gt 0) {
    Write-Host "Re-run the same command to continue from state." -ForegroundColor Cyan
} else {
    Write-Host "All pending paths migrated." -ForegroundColor Green
}

