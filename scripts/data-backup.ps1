# data-backup.ps1 - robocopy mirror backup for an agent data directory.
#
# This is the "data backup" half of the kit: it copies whole live trees, so the
# result is a runnable copy, not a config snapshot. Use it together with
# backup.sh (which versions the small, portable config files in git).
#
# NOTE: this file is intentionally ASCII-only. PowerShell 5.1 reads BOM-less
# files as the ANSI codepage, so a non-ASCII literal would be written to the log
# as mojibake.
#
# Configuration: config.ps1 next to this script's parent directory (see
# config.example.ps1). Nothing machine-specific lives in this file.
#
# Log format (ASCII, UTF-8 appended to $LogFile):
#   [yyyy-MM-dd HH:mm:ss] START
#   [OK] <name>            or   [FAIL] <name> rc=<robocopy exit code / 1 for copy>
#   [WARN] <name> rc=<n>   (tolerant trees only: partial copy, locked files skipped)
#   [yyyy-MM-dd HH:mm:ss] DONE ok=N fail=M warn=K     <- always the last line
# Exit code: 1 if any item failed, otherwise 0. WARN does not affect the exit code.

$ConfigPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config.ps1'
if (Test-Path -LiteralPath $ConfigPath) { . $ConfigPath }

if (-not $Source)   { $Source   = "$env:LOCALAPPDATA\hermes" }
if (-not $Target)   { $Target   = "$env:USERPROFILE\agent-backup\hermes" }
if (-not $LogFile)  { $LogFile  = "$env:USERPROFILE\agent-backup\backup.log" }
if (-not $PythonExe) { $PythonExe = 'python' }
if (-not $SqliteScript) { $SqliteScript = "$Source\scripts\sqlite_safe_backup.py" }
if ($null -eq $Trees) { $Trees = @('skills', 'plugins', 'memories', 'cron', 'sessions', 'attachments', 'scripts') }
if ($null -eq $Files) { $Files = @('config.yaml', '.env', 'auth.json', 'SOUL.md') }
if ($null -eq $TolerantTrees) { $TolerantTrees = @() }
if ($null -eq $ExtraTrees) { $ExtraTrees = @() }

$okCount = 0
$failCount = 0
$warnCount = 0

function Write-Log([string]$text) {
    $text | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

function Add-Ok([string]$name) {
    $script:okCount++
    Write-Log ("[OK] " + $name)
}

function Add-Warn([string]$name, [string]$detail) {
    $script:warnCount++
    Write-Log ("[WARN] " + $name + " rc=" + $detail)
}

function Add-Fail([string]$name, [string]$detail) {
    $script:failCount++
    Write-Log ("[FAIL] " + $name + " rc=" + $detail)
}

# Mirror one directory tree with robocopy.
# robocopy exit codes 0-7 = success (bits: copied / extra / mismatch / failed),
# 8 and above = at least one file or directory could not be copied.
function Copy-Tree {
    param(
        [string]$name,
        [string]$src,
        [string]$dst,
        [string[]]$xf = @(),
        [string[]]$xd = @()
    )
    if (-not (Test-Path -LiteralPath $src)) {
        Add-Fail $name "16 (source-missing)"
        return
    }
    $a = @($src, $dst, "/MIR", "/R:1", "/W:2", "/NP", "/NDL", "/NJH", "/NJS")
    if ($xf.Count -gt 0) { $a += "/XF"; $a += $xf }
    if ($xd.Count -gt 0) { $a += "/XD"; $a += $xd }
    & robocopy @a | Out-Null
    $rc = $LASTEXITCODE
    if ($TolerantTrees -contains $name) {
        # A live application can hold locks on a few profile DBs, so a partial
        # copy is expected and accepted for these trees.
        #   rc 0-7  -> OK
        #   rc 8-15 -> WARN  (some files locked/skipped; not a failure)
        #   rc >=16 -> FAIL  (hard error, nothing usable copied)
        if ($rc -ge 16) {
            Add-Fail $name "$rc"
        } elseif ($rc -ge 8) {
            Add-Warn $name ("$rc (some files locked by a running app, skipped)")
        } else {
            Add-Ok $name
        }
    } elseif ($rc -ge 8) {
        Add-Fail $name "$rc"
    } else {
        Add-Ok $name
    }
}

function Copy-One {
    param(
        [string]$name,
        [string]$src,
        [string]$dstDir
    )
    try {
        if (-not (Test-Path -LiteralPath $src)) { throw "source-missing" }
        Copy-Item -LiteralPath $src -Destination $dstDir -Force -ErrorAction Stop
        Add-Ok $name
    } catch {
        $why = $_.Exception.Message
        if ($why -eq "source-missing") { Add-Fail $name "1 (source-missing)" }
        else { Add-Fail $name "1 (copy-error)" }
    }
}

# Locks (*.lock) are held by the running app and are meaningless in a snapshot.
$lockOnly = @("*.lock")

# Single-instance lock. A daily run and an hourly catch-up run can converge on
# this script, so the lock lives here. Hold an exclusive handle on a lock file
# for the process lifetime: a second instance cannot open it and exits 0 instead
# of racing robocopy over the same target. The OS closes the handle on exit, so
# a crash leaves no stale lock behind.
New-Item -ItemType Directory -Path (Split-Path $LogFile -Parent) -Force | Out-Null
$lockPath = Join-Path (Split-Path $LogFile -Parent) '.backup.lock'
try {
    $lockStream = [System.IO.File]::Open(
        $lockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
} catch {
    Write-Log ("[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] SKIP another backup is already running")
    exit 0
}

if (-not (Test-Path -LiteralPath $Target)) {
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
}

Write-Log ("[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] START")

foreach ($t in $Trees) {
    $xf = $lockOnly
    if ($t -eq 'cron') {
        # SQLite files are handled by sqlite_safe_backup.py below, so exclude them
        # from the mirror. /XF also protects them from /MIR deletion on the target.
        $xf = @("*.lock", "*.db", "*.db-wal", "*.db-shm")
    }
    Copy-Tree $t "$Source\$t" "$Target\$t" $xf
}

foreach ($f in $Files) {
    Copy-One $f "$Source\$f" $Target
}

foreach ($e in $ExtraTrees) {
    Copy-Tree $e.Name $e.Src $e.Dst $lockOnly
}

# SQLite consistency export. Copying a live .db with robocopy can produce a
# torn file; the exporter uses SQLite's backup API instead. It prints
# "OK <name>" / "FAIL <name> <reason>".
if (Test-Path -LiteralPath $SqliteScript) {
    try {
        $pyOut = & $PythonExe $SqliteScript 2>&1
        $pyRc = $LASTEXITCODE
        foreach ($line in @($pyOut)) {
            Write-Log ("[sqlite] " + [string]$line)
        }
        if ($pyRc -ne 0) { Add-Fail "sqlite" "$pyRc" } else { Add-Ok "sqlite" }
    } catch {
        Add-Fail "sqlite" "1 (launch-error)"
    }
} else {
    Add-Warn "sqlite" "script-not-found (locked files still excluded, but no consistent export)"
}

$lockStream.Dispose()

Write-Log ("[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] DONE ok=" + $okCount + " fail=" + $failCount + " warn=" + $warnCount)

if ($failCount -gt 0) { exit 1 } else { exit 0 }
