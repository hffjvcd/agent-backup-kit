# Troubleshooting

Every entry here is a failure that actually happened in production, in the
order they tend to bite.

## The scheduled task runs, but nothing is backed up

Check `last-run.json` first, then the task's logon type.

```
Get-ScheduledTask -TaskName AgentBackup_Daily | Select-Object -ExpandProperty Principal
```

If `LogonType` is `Interactive`, the task only runs while the user is logged
on. This is the single most common reason a "daily" backup silently stops for
weeks. Register with S4U instead (see below).

## S4U registration fails

S4U needs `SeBatchLogonRight`. The error from `Register-ScheduledTask` is
usually generic, so check and grant it explicitly:

```
whoami /priv
secedit /export /areas USER_RIGHTS %TEMP%\rights.txt
```

Grant via `secpol.msc` → Local Policies → User Rights Assignment → **Log on as
a batch job**. Do **not** grant "Log on as a service"; that is a different and
broader right.

The script intentionally does not fall back to Interactive. A silent fallback
reintroduces the exact bug S4U is there to fix, and you would only find out
months later.

## Under S4U, bash cannot find `git` or `ssh`

A S4U session does not inherit the interactive profile, so `PATH`, `HOME` and
the user's `.bashrc` may be missing or different. Symptoms: `git: command not
found`, or SSH failing with `Could not resolve hostname`.

Fix: export every path the child shell needs, explicitly, before `exec`:

```
export HOME='/c/Users/you'
export HERMES_HOME='/c/Users/you/AppData/Local/hermes'
export STATE_DIR='/c/Users/you/.agent-backup'
exec bash '/d/backup/agent-backup-kit/scripts/backup.sh'
```

Use POSIX paths (`/c/Users/...`), not `C:\Users\...`, inside the msys shell.
A login shell (`bash -lc`) still sources the profile when one exists; the
explicit `export` lines cover the case where it does not.

## `schtasks /query ... | findstr "Result"` prints nothing

On a non-English Windows the column labels are localized, so
`findstr "Result"` matches zero lines. This looks like "the task never ran"
when it in fact ran fine.

Use the PowerShell cmdlet instead — it returns object properties, not
localized text:

```
powershell -NoProfile -Command "Get-ScheduledTaskInfo AgentBackup_Daily | fl LastRunTime,LastTaskResult,NextRunTime"
```

## `git -C /d/path ...` fails with "Invalid argument"

The Windows git binary cannot `chdir` into a Cygwin-style path (`/d/...`), even
though the msys shell can. Use a subshell instead:

```
( cd "$REPO_DIR" && git status )
```

## `index.lock` exists and will not go away

If git reports `Unable to create ... .git/index.lock: File exists` and the lock
is 0 bytes, it is stale. On filesystems where git cannot unlink, even
`git status` can leave one behind.

```
ls -l .git/index.lock
mv .git/index.lock .git/index.lock.stale
```

If `mv` is refused ("sensitive file"), do it from an elevated shell or let
`backup.sh` do it — it moves empty locks, and locks older than 10 minutes,
automatically. Never delete a **non-empty** lock: that is a live git process.

## A "successful" smoke test that proves nothing

Running `backup.sh` against a clean, up-to-date repository ends with
`push=uptodate` — which is correct, and which also means `git push` never ran.
If you are testing the push path, make sure there is at least one unpushed
commit first, then verify `push="ok"` **and** that `HEAD` equals `origin/main`.

`last-run.json` from a previous successful run can make a failed smoke test look
green. Compare its timestamp with the run you just triggered.

## robocopy returned 8, is that a failure?

robocopy exit codes are bit flags, not a severity scale:

- `0` — nothing to do
- `1` — files copied
- `2` — extra files present
- `4` — mismatched files
- `8` — **some files could not be copied** (usually locked)
- `16` — fatal error (bad path, no permission)

0–7 is success. For live application profiles, 8–15 is a partial copy: the
script counts it as WARN for trees listed in `$TolerantTrees`, and as FAIL
everywhere else.

## Chinese text in a `.ps1` turns into mojibake in the log

PowerShell 5.1 reads BOM-less files as the ANSI codepage (GBK on a Chinese
system). Keep helper scripts ASCII-only, or save with a UTF-8 BOM. This kit's
scripts are ASCII-only on purpose.

## The watchdog says "last-run.json is unparsable"

That is a real alert. A truncated or half-written state file used to be read as
"0 failures", i.e. healthy. The watchdog now fails closed when
`consecutive_fail` is missing or non-numeric. Check for a full disk or a killed
run.
