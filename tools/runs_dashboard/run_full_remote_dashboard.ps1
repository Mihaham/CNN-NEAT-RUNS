param(
    [string]$RunsDir = (Join-Path $PSScriptRoot "..\.."),
    [string]$Ref = "origin/master",
    [string]$OutSite = "",
    [string]$StateName = "full_remote_state.json",
    [switch]$NoFetch,
    [switch]$NoWeightStats,
    [switch]$NoFetchWeights,
    [switch]$NoChampion,
    [switch]$SkipBuildSite,
    [switch]$PushTools,
    [switch]$PushPages,
    [switch]$Force,
    [switch]$Reset,
    [switch]$RetryFailedOnly,
    [switch]$DryRun
)

# Full remote dashboard: fetch -> champion weight_stats -> extract -> build_site.
# Checkpoint: backfill_logs/full_remote_state.json (resume = re-run this script).

$ErrorActionPreference = "Stop"
$RunsDir = (Resolve-Path -LiteralPath $RunsDir).Path
$GitDir = Join-Path $RunsDir ".git"
if (-not (Test-Path -LiteralPath $GitDir)) { throw "No .git in $RunsDir" }
if (-not $OutSite) { $OutSite = Join-Path $RunsDir "site" }

$ToolDir = $PSScriptRoot
$LogDir = Join-Path $ToolDir "backfill_logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutSite "data") | Out-Null

$StatePath = Join-Path $LogDir $StateName
$MirrorDir = Join-Path $OutSite "data\_weight_stats_mirror"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogPath = Join-Path $LogDir ("full_remote_" + $stamp + ".jsonl")

function Format-Duration([double]$sec) {
    if ($sec -lt 0 -or [double]::IsNaN($sec) -or [double]::IsInfinity($sec)) { return "?" }
    $ts = [TimeSpan]::FromSeconds([math]::Max(0, [math]::Round($sec)))
    if ($ts.TotalHours -ge 1) {
        return ("{0}h {1:D2}m {2:D2}s" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds)
    }
    if ($ts.TotalMinutes -ge 1) {
        return ("{0}m {1:D2}s" -f [int]$ts.TotalMinutes, $ts.Seconds)
    }
    return ("{0}s" -f [int]$ts.TotalSeconds)
}

function Write-Log([hashtable]$row) {
    ($row | ConvertTo-Json -Compress -Depth 6) | Add-Content -LiteralPath $LogPath -Encoding utf8
}

function Save-State($state) {
    $state.updated_at = (Get-Date).ToString("o")
    $json = $state | ConvertTo-Json -Depth 12
    $tmp = $StatePath + ".tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $StatePath -Force
}

function Load-State {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        return (Get-Content -LiteralPath $StatePath -Raw -Encoding utf8 | ConvertFrom-Json)
    } catch {
        Write-Host "WARN: corrupt state file, starting fresh: $StatePath"
        return $null
    }
}

function Step-Ok($entry, [string]$step) {
    if ($null -eq $entry) { return $false }
    $prop = $entry.PSObject.Properties[$step]
    if ($null -eq $prop) { return $false }
    $v = $prop.Value
    if ($null -eq $v) { return $false }
    return [bool]$v.ok
}

function Step-Failed($entry, [string]$step) {
    if ($null -eq $entry) { return $false }
    $prop = $entry.PSObject.Properties[$step]
    if ($null -eq $prop) { return $false }
    $v = $prop.Value
    if ($null -eq $v) { return $false }
    return -not [bool]$v.ok
}

function Invoke-PythonStep {
    param(
        [string]$Script,
        [string[]]$ExtraArgs,
        [string]$Phase,
        [string]$Name
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $true
    $detail = ""
    $err = ""
    try {
        if ($DryRun) {
            $detail = "dry-run: python $Script " + ($ExtraArgs -join " ")
        } else {
            $out = & python (Join-Path $ToolDir $Script) @ExtraArgs 2>&1
            $code = $LASTEXITCODE
            $detail = (($out | Out-String).Trim() -replace '\s+', ' ')
            if ($detail.Length -gt 500) { $detail = $detail.Substring($detail.Length - 500) }
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
    $row = [ordered]@{
        ts     = (Get-Date).ToString("o")
        phase  = $Phase
        name   = $Name
        sec    = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        ok     = $ok
        detail = $detail
        error  = $err
    }
    Write-Log $row
    return [pscustomobject]$row
}

function Show-Progress {
    param(
        [int]$Done,
        [int]$Total,
        [double]$ElapsedSec,
        [double[]]$SampleSecs,
        [string]$Current,
        [string]$LastStatus
    )
    $remaining = [math]::Max(0, $Total - $Done)
    $pct = if ($Total -gt 0) { [math]::Round(100.0 * $Done / $Total, 1) } else { 0 }
    $avg = $null
    if ($SampleSecs.Count -gt 0) {
        $avg = ($SampleSecs | Measure-Object -Average).Average
    }
    $eta = if ($null -ne $avg) { $avg * $remaining } else { $null }
    $barLen = 28
    $filled = if ($Total -gt 0) { [int]([math]::Floor($barLen * $Done / $Total)) } else { 0 }
    $bar = ("#" * $filled) + ("-" * ($barLen - $filled))

    Write-Host ""
    Write-Host ("==== [{0}/{1}] {2}% [{3}] ====" -f $Done, $Total, $pct, $bar)
    if ($Current) { Write-Host ("now: {0}" -f $Current) }
    if ($LastStatus) { Write-Host ("last: {0}" -f $LastStatus) }
    Write-Host ("elapsed: {0}" -f (Format-Duration $ElapsedSec))
    if ($null -ne $avg) {
        Write-Host ("avg/study: {0}  |  ETA remaining: ~{1}  |  left: {2}" -f (Format-Duration $avg), (Format-Duration $eta), $remaining)
        $totalEst = $ElapsedSec + $eta
        Write-Host ("estimated total: ~{0}" -f (Format-Duration $totalEst))
    } else {
        Write-Host ("avg/study: (warming up)  |  left: {0}" -f $remaining)
    }
}

if ($Reset -and (Test-Path -LiteralPath $StatePath)) {
    Remove-Item -LiteralPath $StatePath -Force
    Write-Host "Reset: removed $StatePath"
}

Write-Host "RunsDir=$RunsDir"
Write-Host "Ref=$Ref"
Write-Host "OutSite=$OutSite"
Write-Host "State=$StatePath"
Write-Host "Log=$LogPath"
Write-Host "Mirror=$MirrorDir"
Write-Host ""

if (-not $NoFetch) {
    Write-Host "git fetch origin ..."
    if (-not $DryRun) {
        & git --git-dir $GitDir fetch origin master
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed: $LASTEXITCODE" }
    }
}

$head = (& git --git-dir $GitDir rev-parse $Ref).Trim()
$allStudies = @(
    & git --git-dir $GitDir ls-tree -r --name-only $Ref |
        Where-Object { $_ -match 'ova_results\.json$' } |
        ForEach-Object {
            $p = $_.Replace("\", "/")
            $p.Substring(0, $p.Length - "/ova_results.json".Length)
        } |
        Sort-Object -Unique
)

if ($allStudies.Count -eq 0) {
    throw "No ova_results.json found on $Ref - check fetch/ref."
}

$doWeights = -not $NoWeightStats
$doFetchWeights = -not $NoFetchWeights

$state = Load-State
if ($null -eq $state) {
    $state = [pscustomobject]@{
        schema       = "cnn_neat_full_remote_v1"
        ref          = $Ref
        head         = $head
        started_at   = (Get-Date).ToString("o")
        updated_at   = (Get-Date).ToString("o")
        options      = [pscustomobject]@{
            weight_stats   = $doWeights
            fetch_weights  = $doFetchWeights
            no_champion    = [bool]$NoChampion
            champions_only = $true
        }
        studies      = [pscustomobject]@{}
        sample_secs  = @()
        build_site   = $null
    }
} else {
    $state.head = $head
    if ($null -eq $state.studies) { $state.studies = [pscustomobject]@{} }
    if ($null -eq $state.sample_secs) { $state.sample_secs = @() }
}

Save-State $state

$queue = New-Object System.Collections.Generic.List[string]
foreach ($s in $allStudies) {
    $entry = $null
    if ($state.studies.PSObject.Properties.Name -contains $s) {
        $entry = $state.studies.$s
    }
    $weightsDone = (-not $doWeights) -or (Step-Ok $entry "weight_stats")
    $extractDone = Step-Ok $entry "extract"
    $fullyDone = $weightsDone -and $extractDone

    if ($Force) {
        $queue.Add($s) | Out-Null
        continue
    }
    if ($RetryFailedOnly) {
        if ((Step-Failed $entry "weight_stats") -or (Step-Failed $entry "extract")) {
            $queue.Add($s) | Out-Null
        }
        continue
    }
    if (-not $fullyDone) {
        $queue.Add($s) | Out-Null
    }
}

$alreadyOk = $allStudies.Count - $queue.Count
Write-Host ("Remote studies: {0}  |  already done: {1}  |  queue: {2}" -f $allStudies.Count, $alreadyOk, $queue.Count)
Write-Host ("weight_stats={0} fetch_weights={1} champions={2}" -f $doWeights, $doFetchWeights, (-not $NoChampion))
Write-Host ""

if ($queue.Count -eq 0) {
    Write-Host "Nothing to extract - all studies complete for current options."
} else {
    $totalSw = [System.Diagnostics.Stopwatch]::StartNew()
    $samples = New-Object System.Collections.Generic.List[double]
    foreach ($x in @($state.sample_secs)) {
        if ($null -ne $x) { $samples.Add([double]$x) | Out-Null }
    }

    Show-Progress -Done $alreadyOk -Total $allStudies.Count -ElapsedSec 0 -SampleSecs $samples.ToArray() -Current "starting..." -LastStatus ""

    foreach ($study in $queue) {
        $studySw = [System.Diagnostics.Stopwatch]::StartNew()
        $entryObj = [pscustomobject]@{}
        if ($state.studies.PSObject.Properties.Name -contains $study) {
            $entryObj = $state.studies.$study
        }

        $needWeights = $doWeights -and ($Force -or -not (Step-Ok $entryObj "weight_stats"))
        $needExtract = $Force -or -not (Step-Ok $entryObj "extract")
        if ($needWeights) { $needExtract = $true }

        $statusParts = New-Object System.Collections.Generic.List[string]

        if ($needWeights) {
            Write-Host ("--- weight_stats  {0} ---" -f $study)
            $bf = @(
                "--git-dir", $GitDir,
                "--ref", $Ref,
                "--study-filter", $study,
                "--out-mirror", $MirrorDir,
                "--champions-only"
            )
            $wrow = Invoke-PythonStep -Script "backfill_weight_stats.py" -ExtraArgs $bf -Phase "weight_stats" -Name $study
            if (-not $DryRun) {
                $entryObj | Add-Member -NotePropertyName weight_stats -NotePropertyValue ([pscustomobject]@{
                        ok = [bool]$wrow.ok; sec = $wrow.sec; ts = $wrow.ts
                        detail = $wrow.detail; error = $wrow.error
                    }) -Force
            }
            $wlabel = if ($wrow.ok) { "ok" } else { "FAIL" }
            $statusParts.Add(("weights={0} {1}s" -f $wlabel, $wrow.sec)) | Out-Null
            if (-not $wrow.ok) {
                Write-Host "WARN: weight_stats failed; continuing with extract" -ForegroundColor Yellow
            }
        } else {
            $statusParts.Add("weights=skip") | Out-Null
        }

        if ($needExtract) {
            Write-Host ("--- extract       {0} ---" -f $study)
            $ex = @(
                "--git-dir", $GitDir,
                "--ref", $Ref,
                "--out", $OutSite,
                "--study-filter", $study
            )
            if ($NoChampion) { $ex += "--no-champion" }
            if ($doFetchWeights) { $ex += "--fetch-weights" }
            $erow = Invoke-PythonStep -Script "extract.py" -ExtraArgs $ex -Phase "extract" -Name $study
            if (-not $DryRun) {
                $entryObj | Add-Member -NotePropertyName extract -NotePropertyValue ([pscustomobject]@{
                        ok = [bool]$erow.ok; sec = $erow.sec; ts = $erow.ts
                        detail = $erow.detail; error = $erow.error
                    }) -Force
            }
            $elabel = if ($erow.ok) { "ok" } else { "FAIL" }
            $statusParts.Add(("extract={0} {1}s" -f $elabel, $erow.sec)) | Out-Null
        } else {
            $statusParts.Add("extract=skip") | Out-Null
        }

        if (-not $DryRun) {
            $state.studies | Add-Member -NotePropertyName $study -NotePropertyValue $entryObj -Force
            $studySw.Stop()
            $samples.Add([double]$studySw.Elapsed.TotalSeconds) | Out-Null
            while ($samples.Count -gt 30) { $samples.RemoveAt(0) }
            $state.sample_secs = @($samples)
            Save-State $state
        } else {
            $studySw.Stop()
            Write-Host "dry-run: state NOT saved for $study" -ForegroundColor DarkYellow
        }

        $completedTotal = 0
        foreach ($s2 in $allStudies) {
            $e2 = $null
            if ($state.studies.PSObject.Properties.Name -contains $s2) { $e2 = $state.studies.$s2 }
            $wOk = (-not $doWeights) -or (Step-Ok $e2 "weight_stats")
            $eOk = Step-Ok $e2 "extract"
            if ($wOk -and $eOk) { $completedTotal++ }
        }

        $last = ($statusParts -join " | ")
        Show-Progress -Done $completedTotal -Total $allStudies.Count -ElapsedSec $totalSw.Elapsed.TotalSeconds -SampleSecs $samples.ToArray() -Current $study -LastStatus $last
    }
    $totalSw.Stop()
}

if (-not $SkipBuildSite) {
    Write-Host ""
    Write-Host "=== build_site ==="
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $true
    $err = ""
    try {
        if (-not $DryRun) {
            & python (Join-Path $ToolDir "build_site.py") --out $OutSite
            if ($LASTEXITCODE -ne 0) { $ok = $false; $err = "exit $LASTEXITCODE" }
        }
    } catch {
        $ok = $false
        $err = "$_"
    }
    $sw.Stop()
    $state.build_site = [pscustomobject]@{
        ok = $ok; sec = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        ts = (Get-Date).ToString("o"); error = $err
    }
    Write-Log @{ phase = "build_site"; name = "build_site"; sec = $state.build_site.sec; ok = $ok; error = $err }
    Save-State $state
    Write-Host ("build_site ok={0} sec={1}" -f $ok, $state.build_site.sec)
}

if ($PushTools) {
    Write-Host ""
    Write-Host "=== seed_sparse (tools + CI -> master) ==="
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $true
    $err = ""
    try {
        if (-not $DryRun) {
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ToolDir "seed_sparse.ps1")
            if ($LASTEXITCODE -ne 0) { $ok = $false; $err = "exit $LASTEXITCODE" }
        }
    } catch {
        $ok = $false
        $err = "$_"
    }
    $sw.Stop()
    $state.push_tools = [pscustomobject]@{
        ok = $ok; sec = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        ts = (Get-Date).ToString("o"); error = $err
    }
    Write-Log @{ phase = "push_tools"; name = "seed_sparse"; sec = $state.push_tools.sec; ok = $ok; error = $err }
    Save-State $state
}

if ($PushPages) {
    Write-Host ""
    Write-Host "=== push_pages_branch (site -> origin/pages) ==="
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $true
    $err = ""
    try {
        if (-not $DryRun) {
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ToolDir "push_pages_branch.ps1")
            if ($LASTEXITCODE -ne 0) { $ok = $false; $err = "exit $LASTEXITCODE" }
        }
    } catch {
        $ok = $false
        $err = "$_"
    }
    $sw.Stop()
    $state.push_pages = [pscustomobject]@{
        ok = $ok; sec = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        ts = (Get-Date).ToString("o"); error = $err
    }
    Write-Log @{ phase = "push_pages"; name = "push_pages_branch"; sec = $state.push_pages.sec; ok = $ok; error = $err }
    Save-State $state
}

$okN = 0
$failN = 0
$pendingN = 0
foreach ($s in $allStudies) {
    $e = $null
    if ($state.studies.PSObject.Properties.Name -contains $s) { $e = $state.studies.$s }
    $wOk = (-not $doWeights) -or (Step-Ok $e "weight_stats")
    $eOk = Step-Ok $e "extract"
    if ($wOk -and $eOk) { $okN++ }
    elseif ((Step-Failed $e "weight_stats") -or (Step-Failed $e "extract")) { $failN++ }
    else { $pendingN++ }
}

Write-Host ""
Write-Host "======== FULL REMOTE SUMMARY ========"
Write-Host ("studies total={0}  complete={1}  failed={2}  pending={3}" -f $allStudies.Count, $okN, $failN, $pendingN)
Write-Host ("state: {0}" -f $StatePath)
Write-Host ("log:   {0}" -f $LogPath)
Write-Host ("site:  {0}" -f $OutSite)
if ($failN -gt 0 -or $pendingN -gt 0) {
    Write-Host ""
    Write-Host "Resume: re-run the same script (skips completed studies)." -ForegroundColor Cyan
    Write-Host "Retry failures only:  ... -RetryFailedOnly" -ForegroundColor Cyan
    Write-Host "Start over:           ... -Reset" -ForegroundColor Cyan
    exit 1
}
Write-Host "All studies complete." -ForegroundColor Green
exit 0
