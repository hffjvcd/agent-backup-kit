# Design notes

This kit has two halves that solve different problems. Mixing them up is the
most common way a "backup" turns out to be useless when you need it.

| | `scripts/data-backup.ps1` | `scripts/backup.sh` |
|---|---|---|
| Goal | a **runnable copy** of the data | a **versioned snapshot** of the config |
| Method | robocopy /MIR into a directory | copy + git commit + gated push |
| Size | gigabytes | megabytes |
| Restore | point the app at the copy | `restore.sh` into a fresh install |
| History | none (last-write-wins) | full git history |

They are not substitutes. Run both.

## 1. Mirror subtrees are owned; everything else is copy-only

A mirror operation has to delete files that disappeared at the source, otherwise
the archive grows forever. But deleting is the one operation you cannot undo by
re-running the script.

The rule used here:

- **Mirrored subtrees** (custom skills, hooks, per-project memory) are owned by
  the backup script. A file removed at the source is **moved** to
  `.trash/<date>/`, not deleted, and the trash is purged only after the commit
  lands.
- **Everything else** is copy-only. The script never removes a file it did not
  create.

Restore applies the same rule with `.restore-trash-<timestamp>/`. A restore into
a configured machine can therefore always be undone by moving files back.

## 2. Local status and sync status are different failures

The most expensive bug in the first version: a blocked push was reported as a
failed backup. The local copy was perfect; only the upload had stopped. The
watchdog then paged "2 consecutive failed runs" while nothing was actually
wrong locally — and, worse, `last_success_epoch` never advanced, so after 36
hours it also reported "no successful run".

`last-run.json` now carries two answers:

- `local_status` — did the copy itself work?
- `push` — did the snapshot leave the machine? (`ok` / `failed` / `blocked` /
  `skipped` / `uptodate`)

The process exit code follows `local_status` only. The watchdog alerts on each
separately, with different wording.

## 3. The size gate runs before `git add`

A push gate that runs after the commit is not a gate, it is a report. By then
the oversized blob is in local history, and history is not something you can
take back: every future clone carries it.

So the check walks `git ls-files -o -m --exclude-standard -z` — exactly what
`git add -A` is about to stage — and refuses to stage anything over the limit.
A second pass over `git ls-files -s` catches a file that grew between the check
and the add.

## 4. The four push gates

Any gate failing stops the **push only**. The local commit is kept on purpose:
losing an hour of history because a network check failed would be worse.

1. **Visibility** — refuse to push unless the remote is private. The archive
   contains `.env` and `auth.json`. With `gh` installed the check is automatic;
   without it, a manually created `.repo-private` file acts as an attestation.
   It is deliberately git-ignored: it is a statement about *this checkout*, not
   something that should travel with a clone.
2. **File size** — nothing over `MAX_FILE_MB` (default 40).
3. **Repository state** — no unmerged paths, no merge/rebase/cherry-pick in
   progress. Pushing mid-rebase publishes a tree nobody reviewed.
4. **Commit message** — must carry the run date and counters, so a commit in the
   history can be traced back to the run that produced it.

## 5. Push is decoupled from this run's commit

The first version only pushed when *this run* created a commit. A commit
stranded by an earlier blocked gate would sit locally forever, waiting for some
unrelated file to change. Now the script asks `git rev-list @{u}..HEAD`: if
anything is unpushed, it is retried and re-checked by gate 4.

## 6. The stale `index.lock` recovery is a filesystem workaround

On some Windows filesystems (notably certain virtualized or network-backed
volumes) git cannot unlink its own empty `index.lock`. Every later write then
fails with `File exists`. The script moves an **empty** lock, or one older than
10 minutes, aside. A non-empty, recent lock is treated as a real concurrent
writer and blocks the run.

## 7. Single-instance lock (PowerShell pipeline)

A daily task and an hourly catch-up task both call `data-backup.ps1`. The
script opens a lock file with `FileShare::None` and holds it for the process
lifetime. A second instance fails to open it and exits 0. Because the OS closes
the handle on process exit, a crash cannot leave a stale lock — which a
lock-file-with-PID scheme can.

## 8. What this kit does not do

- No encryption. Gate 1 assumes a private repository. If you want an encrypted
  off-site copy, put `restic`/`borg` in front of the target directory.
- No deduplication. Git handles the config half; robocopy handles the data half.
- No cloud API. Anything that can be a git remote works.
