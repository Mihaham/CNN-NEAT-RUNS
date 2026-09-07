param(
    [string]$RunsDir = (Join-Path $PSScriptRoot "..\.."),
    [string]$SiteDir = "",
    [string]$Branch = "pages",
    [string]$Remote = "origin",
    [switch]$NoBuild,
    [switch]$NoPush,
    [string]$Message = ""
)

# Publish local site/ to branch pages (files at branch root). Does not touch master.

$ErrorActionPreference = "Stop"
$RunsDir = (Resolve-Path -LiteralPath $RunsDir).Path
$GitExe = (Get-Command git.exe).Source
Set-Location -LiteralPath $RunsDir

if (-not $SiteDir) { $SiteDir = Join-Path $RunsDir "site" }
if (-not (Test-Path -LiteralPath $SiteDir)) { throw "SiteDir not found: $SiteDir" }

$ToolSrc = $PSScriptRoot
if (-not $NoBuild) {
    & python (Join-Path $ToolSrc "build_site.py") --out $SiteDir
    if ($LASTEXITCODE -ne 0) { throw "build_site.py failed" }
}

$studies = Join-Path $SiteDir "data\studies.json"
if (-not (Test-Path -LiteralPath $studies)) {
    throw "Missing site/data/studies.json - run extract / full remote pipeline first"
}

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

$env:GIT_INDEX_FILE = Join-Path $env:TEMP ("pages_index_" + [guid]::NewGuid().ToString("N"))
try {
    if (Test-Path -LiteralPath $env:GIT_INDEX_FILE) {
        Remove-Item -LiteralPath $env:GIT_INDEX_FILE -Force
    }

    $n = 0
    Get-ChildItem -LiteralPath $SiteDir -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($SiteDir.Length).TrimStart("\").Replace("\", "/")
        if ([string]::IsNullOrWhiteSpace($rel)) { return }
        if ($rel -match '(^|/)_weight_stats_mirror(/|$)|__pycache__|\.pyc$|\.tmp$') { return }
        $sha = (& cmd.exe /c "`"$GitExe`" hash-object -w -- `"$($_.FullName)`"").Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sha)) {
            throw "hash-object failed for $rel"
        }
        Invoke-Git @("update-index", "--add", "--cacheinfo", "100644,$sha,$rel")
        $n++
    }
    Write-Host "Indexed $n site files into pages tree"

    $treeOut = & cmd.exe /c "`"$GitExe`" write-tree 2>&1"
    $tree = ("$treeOut" -split "`r?`n" | Where-Object { $_ -match '^[0-9a-f]{40}$' } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($tree)) { throw "write-tree failed: $treeOut" }
    Write-Host "tree=$tree"

    $parentArgs = @()
    $parentRaw = & cmd.exe /c "`"$GitExe`" rev-parse --verify refs/heads/$Branch 2>nul"
    $parent = if ($null -eq $parentRaw) { "" } else { ("$parentRaw").Trim() }
    if ($LASTEXITCODE -eq 0 -and $parent -match '^[0-9a-f]{40}$') {
        $parentArgs = @("-p", $parent)
        Write-Host "parent=$parent"
    } else {
        Write-Host "No existing $Branch - creating orphan history"
    }

    if (-not $Message) {
        $headRaw = & cmd.exe /c "`"$GitExe`" rev-parse --short HEAD 2>nul"
        $head = if ($null -eq $headRaw) { "unknown" } else { ("$headRaw").Trim() }
        if ([string]::IsNullOrWhiteSpace($head)) { $head = "unknown" }
        $Message = "pages: publish dashboard site (from $head)"
    }
    $msgFile = Join-Path $env:TEMP ("pages_msg_" + [guid]::NewGuid().ToString("N") + ".txt")
    Set-Content -LiteralPath $msgFile -Value $Message -Encoding ascii

    $ctArgs = @("commit-tree", $tree) + $parentArgs + @("-F", $msgFile)
    $argLine = ($ctArgs | ForEach-Object {
            $a = "$_"
            if ($a -match '[\s"]') { '"' + ($a.Replace('"', '\"')) + '"' } else { $a }
        }) -join ' '
    $commitOut = & cmd.exe /c "`"$GitExe`" $argLine 2>&1"
    Remove-Item $msgFile -Force -ErrorAction SilentlyContinue
    $commit = ("$commitOut" -split "`r?`n" | Where-Object { $_ -match '^[0-9a-f]{40}$' } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($commit)) { throw "commit-tree failed: $commitOut" }

    Invoke-Git @("update-ref", "refs/heads/$Branch", $commit)
    Write-Host "commit=$commit refs/heads/$Branch"

    if (-not $NoPush) {
        $env:GIT_SSH_COMMAND = "ssh -o BatchMode=yes -o ConnectTimeout=30"
        Invoke-Git @("push", "--no-thin", $Remote, "${Branch}:${Branch}") -AllowFail
        if ($LASTEXITCODE -ne 0) {
            Write-Host "push failed once; retry..."
            Invoke-Git @("push", "--no-thin", $Remote, "${Branch}:${Branch}")
        }
        Write-Host "Pushed $Remote/$Branch (site at branch root)"
        Write-Host "GitVerse Pages: source = branch '$Branch', folder = / (root)"
    } else {
        Write-Host "NoPush set - local refs/heads/$Branch only"
    }
}
finally {
    if ($env:GIT_INDEX_FILE -and (Test-Path -LiteralPath $env:GIT_INDEX_FILE)) {
        Remove-Item -LiteralPath $env:GIT_INDEX_FILE -Force -ErrorAction SilentlyContinue
    }
    Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
}
