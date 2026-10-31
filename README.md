# agent-backup-kit

> Back up an AI agent's config into a private git repo, and its data into a runnable mirror — with push gates that fail closed.

A portable, Windows-first backup kit for people who run an AI agent (or any
app with a config directory) on their own machine.

It answers two separate questions: *"can I rebuild this setup on a new
machine?"* (config, versioned in git) and *"can I get my data back?"* (full
tree mirror via robocopy). It also answers the question most backup scripts
ignore: *"did the snapshot actually leave the machine?"*

## What it solves (in plain words)

1. Your agent's `.env`, `auth.json` and settings live in one folder and are
   never backed up — or are backed up *including* the secrets, to a public repo.
2. A scheduled task that only runs while you are logged on is not a backup.
3. A push that silently fails for a week looks exactly like a working backup.

## Quick start

```bash
git clone <this repo> && cd agent-backup-kit
cp config.example.sh config.sh && cp config.example.ps1 config.ps1
# edit both: live paths, repo to push to, bash.exe path
git init -b main && git remote add origin <your private repo>
bash scripts/backup.sh --dry-run      # plan only
bash scripts/backup.sh                # copy + commit + gated push
```

Then, in an **elevated** PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/register-tasks.ps1 -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/register-tasks.ps1
```

The data half is independent: `powershell -File scripts/data-backup.ps1`.

## Why it is built this way

These are the decisions that took the longest to get right. They are the reason
this is not a 20-line `cp -r` script.

**S4U, and no silent fallback to Interactive.** `-LogonType S4U` runs whether
or not anyone is logged on, without storing your password. Interactive logon is
what makes "scheduled" backups stop the moment you close the lid. If S4U
registration fails (missing `SeBatchLogonRight`), the script prints the exact
fix and stops. It does not quietly register an Interactive task, because that
would reinstall the bug while reporting success.

**S4U loses your environment.** A non-interactive session does not inherit the
interactive profile, so `$HOME`, `PATH` and `~/.bashrc` may be gone. The task
action therefore exports `HOME`, `HERMES_HOME`, `CLAUDE_HOME` and `STATE_DIR`
explicitly before `exec`-ing the script.

**Four push gates, and a blocked gate keeps the commit.** Visibility (private
remote), per-file size, repository state, commit message. Any failure stops the
push but leaves the local commit intact. A push failure is a *sync* failure, not
a *backup* failure — they are reported in separate fields and alerted separately.

**The size gate runs before `git add`.** Checking after the commit is checking
after the blob is already in local history. History cannot be rewritten away.

**Pushes are retried independently of new commits.** If a gate blocked last
night's commit, tonight's run sees `@{u}..HEAD` is non-empty, re-checks the
message and retries.

**Mirroring is soft-delete.** Files removed at the source go to `.trash/<date>/`
and are purged only after the commit lands. Restore uses the same idea in
reverse (`.restore-trash-<timestamp>/`).

**On a Chinese-locale Windows, `findstr "Result"` matches nothing.** Column
labels are localized, so the smoke-test command people copy from blogs returns
an empty screen and looks like "the task never ran". The script tells you to use
`Get-ScheduledTaskInfo` instead.

More detail: [`docs/design.md`](docs/design.md),
[`docs/troubleshooting.md`](docs/troubleshooting.md).

## Repository layout

```
agent-backup-kit/
├── README.md
├── LICENSE                 (MIT)
├── config.example.sh       # copy to config.sh (git-ignored)
├── config.example.ps1      # copy to config.ps1 (git-ignored)
├── scripts/
│   ├── backup.sh           # copy + commit + gated push
│   ├── restore.sh          # restore into a fresh machine
│   ├── watchdog.sh         # heartbeat: local health vs sync health
│   ├── register-tasks.ps1  # S4U scheduled tasks
│   └── data-backup.ps1   # robocopy data mirror + sqlite export
└── docs/
    ├── design.md
    └── troubleshooting.md
```

## Known limitations

- Windows-first. `backup.sh` / `restore.sh` / `watchdog.sh` are bash and run
  under Git Bash or msys2; the task registration is PowerShell/Windows only.
- Gate 1 trusts "private remote" rather than encrypting. If the remote is
  compromised, the archive is readable. Add `restic`/`borg` if that matters.
- No restore verification. The kit checks that a backup ran, not that a restore
  would succeed. Test one restore on a clean VM.
- The default thresholds (2 failures, 36 hours, 40 MB) are starting points, not
  tuned values.

## License

MIT. See [LICENSE](LICENSE).

Personal project: issues may go unanswered.
