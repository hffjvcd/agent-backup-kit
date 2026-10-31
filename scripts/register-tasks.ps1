# register-tasks.ps1 - register the backup + watchdog scheduled tasks.
#
# Run this ONLY as Administrator, after a -DryRun pass.
#
# What it does:
#   1. AgentBackup_Daily    - daily at $BackupAt, runs scripts/backup.sh
#                             StartWhenAvailable, 30 min execution limit
#   2. AgentBackup_Watchdog - daily at $WatchdogAt, runs scripts/watchdog.sh
#                             StartWhenAvailable, 10 min execution limit
#
# It does NOT touch any other scheduled task on the machine.
#
# Logon type: S4U.
#   Interactive-logon tasks only run while the user is logged on, which is exactly
#   why "scheduled" backups mysteriously stop when nobody is at the keyboard.
#   S4U ("service for user") lets a task run whether or not the user is logged on
#   WITHOUT storing the password. S4U needs the account to hold SeBatchLogonRight.
#   If registration fails, this script prints the exact remedy. It does NOT
#   silently fall back to Interactive, because that would silently reintroduce the
#   bug we are fixing. Pass -AllowInteractiveFallback to opt in knowingly.
#
# Usage (elevated PowerShell):
#   powershell -NoProfile -ExecutionPolicy Bypass -File register-tasks.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File register-tasks.ps1 -DryRun
#   powershell -NoProfile -ExecutionPolicy Bypass -File register-tasks.ps1 -AllowInteractiveFallback
#
# ASCII only on purpose: PowerShell 5.1 reads BOM-less files as the ANSI codepage.

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$AllowInteractiveFallback
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- configuration
$ConfigPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config.ps1'
if (Test-Path -LiteralPath $ConfigPath) { . $ConfigPath }
if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.example.ps1'))) {
    Write-Host 'WARN: config.example.ps1 is missing next to config.ps1'
}

if (-not $BashExe)    { $BashExe    = 'C:\Program Files\Git\bin\bash.exe' }
if (-not $BackupTaskName)   { $BackupTaskName   = 'AgentBackup_Daily' }
if (-not $WatchdogTaskName) { $WatchdogTaskName = 'AgentBackup_Watchdog' }
if (-not $BackupAt)    { $BackupAt    = '22:10' }
if (-not $WatchdogAt)  { $WatchdogAt  = '12:00' }
if (-not $WorkDir)     { $WorkDir     = $env:USERPROFILE }

$ScriptsDir = $PSScriptRoot

# Convert C:\Users\you\dir to /c/Users/you/dir for the msys shell.
function ConvertTo-PosixPath([string]$Path) {
    $p = $Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):/(.*)$') {
        return '/' + $Matches[1].ToLower() + '/' + $Matches[2]
    }
    return $p
}

# Explicit environment for the child bash. Under S4U the session does not inherit
# the interactive profile, so $HOME-based defaults inside the scripts are not
# trusted. Spell every path out.
if (-not $BashEnv) {
    $posixHome = ConvertTo-PosixPath $env:USERPROFILE
    $BashEnv = "export HOME='$posixHome' " +
               "HERMES_HOME='$posixHome/AppData/Local/hermes' " +
               "CLAUDE_HOME='$posixHome/.claude' " +
               "STATE_DIR='$posixHome/.agent-backup'; "
}

$UserId = "$env:COMPUTERNAME\$env:USERNAME"

$results = New-Object System.Collections.ArrayList

function Report([string]$Step, [string]$Status, [string]$Detail) {
    $line = '{0,-28} {1,-10} {2}' -f $Step, $Status, $Detail
    Write-Host $line
    [void]$results.Add([pscustomobject]@{ Step = $Step; Status = $Status; Detail = $Detail })
}

function New-BashAction([string]$ScriptName) {
    $posixScript = (ConvertTo-PosixPath $ScriptsDir) + '/' + $ScriptName
    $cmd = $BashEnv + "exec bash '" + $posixScript + "'"
    New-ScheduledTaskAction -Execute $BashExe -Argument ('-lc "' + $cmd + '"') -WorkingDirectory $WorkDir
}

function Register-One {
    param(
        [string]$TaskName,
        [string]$ScriptName,
        [string]$At,
        [int]$LimitMinutes,
        [string]$Description
    )

    $action = New-BashAction $ScriptName
    $trigger = New-ScheduledTaskTrigger -Daily -At $At
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes $LimitMinutes) `
        -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries

    $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType S4U -RunLevel Highest

    if ($DryRun) {
        Report $TaskName 'DRY-RUN' ("would register: {0} daily at {1}, S4U, limit {2}m" -f $ScriptName, $At, $LimitMinutes)
        return $true
    }

    try {
        Register-ScheduledTask -TaskName $TaskName `
            -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
            -Description $Description -Force | Out-Null
        Report $TaskName 'OK' ("registered: {0} daily at {1}, S4U, limit {2}m" -f $ScriptName, $At, $LimitMinutes)
        return $true
    }
    catch {
        $msg = $_.Exception.Message
        Report $TaskName 'FAILED' ("S4U registration rejected: " + $msg)
        Write-Host ''
        Write-Host '  S4U needs SeBatchLogonRight for ' $UserId
        Write-Host '  Check the account right with:  whoami /priv  (and)  secedit /export /areas USER_RIGHTS'
        Write-Host '  Grant it with secpol.msc -> Local Policies -> User Rights Assignment'
        Write-Host '    -> "Log on as a batch job" -> add ' $UserId
        Write-Host '  Then re-run this script. Do NOT grant "Log on as a service".'
        Write-Host ''
        return $false
    }
}

# ------------------------------------------------------------------- preflight
Write-Host '=== backup task registration ==='
Write-Host ''
Write-Host ("user      : " + $UserId)
Write-Host ("bash      : " + $BashExe)
Write-Host ("scripts   : " + $ScriptsDir)
Write-Host ("mode      : " + $(if ($DryRun) { 'DRY RUN' } else { 'REGISTER' }))
Write-Host ''

$preflightOk = $true

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Report 'preflight: admin' 'OK' 'running elevated'
} else {
    Report 'preflight: admin' 'FAILED' 'not elevated - reopen PowerShell as Administrator'
    $preflightOk = $false
}

if (Test-Path -LiteralPath $BashExe) {
    Report 'preflight: bash' 'OK' $BashExe
} else {
    Report 'preflight: bash' 'FAILED' 'bash.exe not found - set $BashExe in config.ps1'
    $preflightOk = $false
}

foreach ($s in @('backup.sh', 'watchdog.sh')) {
    $p = Join-Path $ScriptsDir $s
    if (Test-Path -LiteralPath $p) {
        Report ('preflight: ' + $s) 'OK' $p
    } else {
        Report ('preflight: ' + $s) 'FAILED' ('missing: ' + $p)
        $preflightOk = $false
    }
}

if (-not $preflightOk) {
    Write-Host ''
    Write-Host 'Preflight failed. Nothing was registered.'
    exit 2
}

Write-Host ''
Write-Host '--- registering ---'

$okBackup = Register-One -TaskName $BackupTaskName -ScriptName 'backup.sh' `
    -At $BackupAt -LimitMinutes 30 `
    -Description 'Agent config backup: sync, commit, gated push.'

if (-not $okBackup -and $AllowInteractiveFallback -and -not $DryRun) {
    Write-Host ''
    Write-Host '  -AllowInteractiveFallback given: registering with LogonType=Interactive.'
    Write-Host '  WARNING: this task will only run while this user is logged on.'
    try {
        $action = New-BashAction 'backup.sh'
        $trigger = New-ScheduledTaskTrigger -Daily -At $BackupAt
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $BackupTaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings `
            -Description 'FALLBACK Interactive logon: runs only when the user is logged on.' -Force | Out-Null
        Report $BackupTaskName 'OK-FALLBACK' 'registered with Interactive logon (degraded)'
    }
    catch {
        Report $BackupTaskName 'FAILED' ('interactive fallback also failed: ' + $_.Exception.Message)
    }
}

$okWatchdog = Register-One -TaskName $WatchdogTaskName -ScriptName 'watchdog.sh' `
    -At $WatchdogAt -LimitMinutes 10 `
    -Description 'Backup watchdog: alerts on 2 consecutive failures or 36h without success.'

Write-Host ''
Write-Host '--- verification ---'

if (-not $DryRun) {
    foreach ($n in @($BackupTaskName, $WatchdogTaskName)) {
        try {
            $t = Get-ScheduledTask -TaskName $n -ErrorAction Stop
            $info = Get-ScheduledTaskInfo -TaskName $n
            Report ('verify: ' + $n) 'OK' ("state={0} logon={1} next={2}" -f $t.State, $t.Principal.LogonType, $info.NextRunTime)
        }
        catch {
            Report ('verify: ' + $n) 'FAILED' 'task not found after registration'
        }
    }
}

Write-Host ''
Write-Host '--- next steps ---'
Write-Host '  1. Smoke test without waiting for the scheduled time:'
Write-Host ('     schtasks /run /tn ' + $BackupTaskName)
Write-Host ('     powershell -NoProfile -Command "Get-ScheduledTaskInfo ' + $BackupTaskName + ' | fl LastRunTime,LastTaskResult,NextRunTime"')
Write-Host '     Expect LastTaskResult 0.'
Write-Host '     Do NOT use: schtasks /query ... | findstr "Result"'
Write-Host '     On a non-English Windows the localized column labels make findstr return nothing.'
Write-Host '  2. Watchdog smoke test:'
Write-Host ('     schtasks /run /tn ' + $WatchdogTaskName + '   (exit 0 healthy, 1 alert)')
Write-Host '  3. If the push gate blocks, inspect last-run.json under $STATE_DIR.'
Write-Host ''

$failCount = @($results | Where-Object { $_.Status -like 'FAILED*' }).Count
Write-Host ("summary: steps={0} failed={1}" -f $results.Count, $failCount)
if ($failCount -gt 0) { exit 1 }
exit 0
