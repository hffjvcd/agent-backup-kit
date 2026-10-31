# config.example.ps1 - copy to config.ps1 and edit. config.ps1 is git-ignored.
# Used by scripts/register-tasks.ps1 and scripts/data-backup.ps1.
# Keep this file ASCII-only: PowerShell 5.1 reads BOM-less files as ANSI.

# --- scheduled task registration -------------------------------------------
# Absolute path to a bash.exe (Git for Windows / msys2 / the one shipped with
# your agent runtime). Must exist; preflight fails otherwise.
$BashExe = 'C:\path\to\git\usr\bin\bash.exe'

# Task names and schedule. Pick anything unique on the machine.
$BackupTaskName   = 'AgentBackup_Daily'
$WatchdogTaskName = 'AgentBackup_Watchdog'
$BackupAt         = '22:10'
$WatchdogAt       = '12:00'

# Environment exported into the child bash before exec. Under S4U the session
# does not inherit the interactive profile, so spell every path out here.
# Use POSIX form (/c/Users/...), not C:\Users\...
$BashEnv = "export HOME='/c/Users/you' " +
           "HERMES_HOME='/c/Users/you/AppData/Local/hermes' " +
           "CLAUDE_HOME='/c/Users/you/.claude' " +
           "STATE_DIR='/c/Users/you/.agent-backup'; "

# Working directory for the task action.
$WorkDir = 'C:\Users\you'

# --- file-tree backup (data-backup.ps1) ----------------------------------
$Source       = "$env:LOCALAPPDATA\hermes"
$Target       = 'D:\backup\hermes'
$LogFile      = 'D:\backup\backup.log'
$PythonExe    = 'python'
$SqliteScript = "$Source\scripts\sqlite_safe_backup.py"

# Subtrees / files mirrored by the robocopy pipeline.
$Trees = @('skills', 'plugins', 'memories', 'cron', 'sessions', 'attachments', 'scripts')
$Files = @('config.yaml', '.env', 'auth.json', 'SOUL.md')

# Trees where locked files are tolerated (rc 8-15 counts as WARN, not FAIL).
# Useful for live application profiles that are open while the backup runs.
$TolerantTrees = @()

# Extra trees: @{ Name='label'; Src='C:\from'; Dst='D:\to' }
$ExtraTrees = @()
