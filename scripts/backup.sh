#!/usr/bin/env bash
# backup.sh - sync live agent config into this repo's working copy, commit it,
# and push only when every push gate passes.
#
# Design notes:
#   * MISS is a failure, not a silent no-op. The run exits non-zero so the
#     watchdog can see it.
#   * Mirrored subtrees are owned by this script. A file deleted at the source is
#     moved to .trash/<date>/ (soft delete) and purged only after a successful
#     commit. Everything outside those subtrees is copy-only and is never deleted.
#   * Push gate 1 refuses to push unless the repo is private, because the archive
#     contains .env and auth.json with live credentials.
#   * Push gate 2 caps a single file at MAX_FILE_MB. Checked BEFORE `git add`, so an
#     oversized blob never enters local history.
#   * A blocked gate only stops the push. The local commit is kept on purpose.
#
# Configuration: copy config.example.sh to config.sh (git-ignored) or export the
# variables. Nothing machine-specific lives in this file.
#
# Usage:
#   bash scripts/backup.sh --dry-run   # print the plan, change nothing
#   bash scripts/backup.sh             # sync + commit + push (when gates pass)
#   bash scripts/backup.sh --no-push   # sync + commit, never push
set -uo pipefail
set -e

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

# ---------------------------------------------------------------- configuration
: "${HERMES_HOME:=$HOME/AppData/Local/hermes}"
: "${CLAUDE_HOME:=$HOME/.claude}"
: "${STATE_DIR:=$HOME/.agent-backup}"
CORE_FILES="${CORE_FILES:-config.yaml .env auth.json SOUL.md}"
CUSTOM_SKILLS="${CUSTOM_SKILLS:-}"
CLAUDE_SKILLS="${CLAUDE_SKILLS:-}"
MEMORY_SLUGS="${MEMORY_SLUGS:-}"
LEGACY_DIR="${LEGACY_DIR:-}"
EXTRA_FILES="${EXTRA_FILES:-}"
EXCLUDE_PATHS="${EXCLUDE_PATHS:-}"

CONFIG_FILE="${CONFIG_FILE:-$REPO_DIR/config.sh}"
if [ -f "$CONFIG_FILE" ]; then . "$CONFIG_FILE"; fi

RUN_DATE="$(date +%Y%m%d)"
RUN_TS="$(date +%Y-%m-%dT%H:%M:%S%z)"
LAST_RUN_FILE="${LAST_RUN_FILE:-$STATE_DIR/last-run.json}"
TRASH_DIR="$REPO_DIR/.trash/$RUN_DATE"
MAX_FILE_MB="${MAX_FILE_MB:-40}"

DRY=0
NO_PUSH=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-push) NO_PUSH=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

OK=0
FAIL=0
WARN=0
COMMITTED=0
PUSH_STATE="skipped"
FAIL_LOG="$(mktemp)"
trap 'rm -f "$FAIL_LOG"' EXIT

count_ok()   { OK=$((OK+1)); }
warn_item()  { WARN=$((WARN+1)); echo "  WARN  $1"; }
fail_item()  { FAIL=$((FAIL+1)); printf '%s\n' "$1" >> "$FAIL_LOG"; echo "  FAIL  $1"; }

# cpf <src_file> <dst_file>
cpf() {
  local src="$1" dst="$2" rel="${2#$REPO_DIR/}"
  if [ ! -f "$src" ]; then fail_item "$rel (source missing: $src)"; return 0; fi
  if [ "$DRY" = "1" ]; then echo "  PLAN  $rel"; count_ok; return 0; fi
  if mkdir -p "$(dirname "$dst")" && cp -p "$src" "$dst"; then
    echo "  OK    $rel"; count_ok
  else
    fail_item "$rel (copy failed)"
  fi
  return 0
}

# cptree <src_dir> <dst_dir>  (copy only; symlinks dereferenced)
cptree() {
  local src="$1" dst="$2" rel="${2#$REPO_DIR/}" n
  if [ ! -d "$src" ]; then fail_item "$rel (source dir missing: $src)"; return 0; fi
  n="$(find "$src" -type f | wc -l)"
  if [ "$DRY" = "1" ]; then echo "  PLAN  $rel ($n files)"; count_ok; return 0; fi
  if mkdir -p "$dst" && cp -rLp "$src/." "$dst/"; then
    echo "  OK    $rel ($n files)"; count_ok
  else
    fail_item "$rel (copy failed)"
  fi
  return 0
}

# trash_path <path under REPO_DIR>  (soft delete, recoverable until the commit lands)
trash_path() {
  local p="$1" rel="${1#$REPO_DIR/}" dst="$TRASH_DIR/${1#$REPO_DIR/}"
  mkdir -p "$(dirname "$dst")"
  if mv "$p" "$dst"; then echo "  TRASH $rel"; else fail_item "$rel (trash failed)"; fi
  return 0
}

# mirror_tree <src_dir> <dst_dir> [exclude_glob]
# Copies the source, then trashes any file in dst whose source counterpart is gone.
mirror_tree() {
  local src="$1" dst="$2" excl="${3:-}" rel
  cptree "$src" "$dst"
  if [ "$DRY" = "1" ]; then return 0; fi
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    if [ -n "$excl" ]; then
      case "$rel" in $excl) echo "  SKIP  ${dst#$REPO_DIR/}/$rel (excluded)"; continue ;; esac
    fi
    if [ -e "$src/$rel" ]; then continue; fi
    trash_path "$dst/$rel"
  done < <(cd "$dst" && find . -type f | sed 's|^\./||' | sort)
  find "$dst" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  return 0
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

write_last_run() {
  # The first argument is the LOCAL backup verdict. Push state is reported in
  # its own field and never downgrades this one.
  local local_status="$1" prev_success="" prev_consec="" consec=0 success now
  if [ -f "$LAST_RUN_FILE" ]; then
    prev_success="$(sed -n 's/.*"last_success_epoch"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$LAST_RUN_FILE" 2>/dev/null | head -1)"
    prev_consec="$(sed -n 's/.*"consecutive_fail"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$LAST_RUN_FILE" 2>/dev/null | head -1)"
  fi
  now="$(date +%s)"
  if [ "$local_status" = "ok" ]; then
    consec=0
    success="$now"
  else
    consec=$(( ${prev_consec:-0} + 1 ))
    success="${prev_success:-0}"
  fi
  mkdir -p "$(dirname "$LAST_RUN_FILE")"
  {
    printf '{\n'
    printf '  "timestamp": "%s",\n' "$RUN_TS"
    printf '  "status": "%s",\n' "$local_status"
    printf '  "local_status": "%s",\n' "$local_status"
    printf '  "ok": %d,\n' "$OK"
    printf '  "fail": %d,\n' "$FAIL"
    printf '  "warn": %d,\n' "$WARN"
    printf '  "consecutive_fail": %d,\n' "$consec"
    printf '  "last_success_epoch": %d,\n' "$success"
    printf '  "committed": %s,\n' "$([ "$COMMITTED" = "1" ] && echo true || echo false)"
    printf '  "push": "%s",\n' "$PUSH_STATE"
    printf '  "failed_items": ['
    local first=1 line
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if [ "$first" = "1" ]; then printf '\n'; first=0; else printf ',\n'; fi
      printf '    "%s"' "$(json_escape "$line")"
    done < "$FAIL_LOG"
    [ "$first" = "0" ] && printf '\n  '
    printf ']\n}\n'
  } > "$LAST_RUN_FILE.tmp"
  mv "$LAST_RUN_FILE.tmp" "$LAST_RUN_FILE"
  echo "  OK    last-run.json -> $LAST_RUN_FILE"
}

# gitr - run git inside the repo. `git -C` is unusable on Windows when the path
# is in Cygwin form (/d/...): the Windows git binary cannot chdir into it, while
# the shell can. Changing directory first is the portable form.
gitr() { ( cd "$REPO_DIR" && git "$@" ); }

do_git() {
  # A stale index.lock blocks every git write. On some filesystems git cannot
  # unlink its own empty lock, so recover when the lock is empty or abandoned.
  if [ -f "$REPO_DIR/.git/index.lock" ]; then
    if [ ! -s "$REPO_DIR/.git/index.lock" ] || [ "$(find "$REPO_DIR/.git/index.lock" -mmin +10 | wc -l)" -eq 1 ]; then
      mv "$REPO_DIR/.git/index.lock" "$REPO_DIR/.git/index.lock.stale-$RUN_DATE" 2>/dev/null || true
      warn_item "git: moved aside stale .git/index.lock (empty or older than 10 min)"
    else
      fail_item "git: .git/index.lock is held by another process"; PUSH_STATE="blocked"; return 0
    fi
  fi

  # ---- size gate BEFORE anything enters local history ----
  # The gate used to run after the commit, by which time an oversized blob is
  # already unrecoverable in local history. Check exactly what `git add -A` is
  # about to stage.
  local limit_bytes=$(( MAX_FILE_MB * 1024 * 1024 )) rel sz big_list=""
  while IFS= read -r -d '' rel; do
    [ -n "$rel" ] || continue
    [ -f "$REPO_DIR/$rel" ] || continue
    sz="$(stat -c %s "$REPO_DIR/$rel" 2>/dev/null || echo 0)"
    if [ "$sz" -gt "$limit_bytes" ]; then
      big_list="${big_list}          $rel ($(( sz / 1024 / 1024 ))MB)"$'\n'
    fi
  done < <(gitr ls-files -o -m --exclude-standard -z)

  if [ -n "$big_list" ]; then
    echo "  FAIL  gate2 files over ${MAX_FILE_MB}MB (nothing staged, add skipped):"
    printf '%s' "$big_list"
    PUSH_STATE="blocked"; return 0
  fi
  echo "  OK    gate2 no pending file over ${MAX_FILE_MB}MB (pre-add)"

  if ! gitr add -A; then fail_item "git add failed"; PUSH_STATE="blocked"; return 0; fi

  if gitr diff --cached --quiet; then
    warn_item "git: nothing to commit"
  else
    OK=$((OK+1))
    local msg="backup: $RUN_DATE ok=$OK fail=$FAIL warn=$WARN"
    if gitr commit -q -m "$msg"; then
      COMMITTED=1; echo "  OK    commit: $msg"
    else
      fail_item "git commit failed"; PUSH_STATE="blocked"; return 0
    fi
  fi

  # ---- push gates (any failure stops the push, keeps the commit) ----
  local gate_ok=1 vis subj out ent post_big=""

  # gate2 backstop: the pre-add check is the real guard; this verifies the index
  # holds nothing oversized (e.g. a file that grew between the check and the add).
  while IFS= read -r -d '' ent; do
    rel="${ent#*$'\t'}"
    [ -n "$rel" ] || continue
    [ -f "$REPO_DIR/$rel" ] || continue
    sz="$(stat -c %s "$REPO_DIR/$rel" 2>/dev/null || echo 0)"
    if [ "$sz" -gt "$limit_bytes" ]; then
      post_big="${post_big}          $rel ($(( sz / 1024 / 1024 ))MB)"$'\n'
    fi
  done < <(gitr ls-files -s -z)
  if [ -n "$post_big" ]; then
    echo "  FAIL  gate2 post-add backstop: oversized entry in index:"
    printf '%s' "$post_big"; gate_ok=0
  else
    echo "  OK    gate2 post-add backstop clean"
  fi

  if command -v gh >/dev/null 2>&1; then
    vis="$(gh repo view --json visibility -q .visibility 2>/dev/null || true)"
    case "$vis" in
      PRIVATE|private) echo "  OK    gate1 visibility=private" ;;
      *) echo "  FAIL  gate1 visibility=${vis:-unknown}"; gate_ok=0 ;;
    esac
  elif [ -f "$REPO_DIR/.repo-private" ]; then
    echo "  OK    gate1 gh missing; manual attestation .repo-private present"
  else
    echo "  FAIL  gate1 cannot verify visibility (no gh CLI, no .repo-private attestation)"
    gate_ok=0
  fi

  if [ -n "$(gitr ls-files -u | head -1)" ]; then
    echo "  FAIL  gate3 unmerged paths present"; gate_ok=0
  elif [ -e "$REPO_DIR/.git/MERGE_HEAD" ] || [ -e "$REPO_DIR/.git/REBASE_HEAD" ] \
       || [ -d "$REPO_DIR/.git/rebase-apply" ] || [ -d "$REPO_DIR/.git/rebase-merge" ] \
       || [ -e "$REPO_DIR/.git/CHERRY_PICK_HEAD" ]; then
    echo "  FAIL  gate3 merge/rebase/cherry-pick in progress"; gate_ok=0
  else
    echo "  OK    gate3 working tree consistent"
  fi

  # Push is decoupled from this run's commit. A commit stranded by an earlier
  # blocked gate must still be retried, and gate4 must re-check it.
  local pending=0
  if [ -n "$(gitr rev-list '@{u}..HEAD' 2>/dev/null || true)" ]; then pending=1; fi

  if [ "$COMMITTED" = "1" ] || [ "$pending" = "1" ]; then
    subj="$(gitr log -1 --format=%s)"
    case "$subj" in
      "backup: $RUN_DATE "*) echo "  OK    gate4 commit message: $subj" ;;
      *) echo "  FAIL  gate4 commit message missing date/fail count: $subj"; gate_ok=0 ;;
    esac
  fi

  if [ "$NO_PUSH" = "1" ]; then
    echo "  SKIP  push disabled by --no-push"; PUSH_STATE="skipped"
  elif [ "$gate_ok" = "1" ] && { [ "$COMMITTED" = "1" ] || [ "$pending" = "1" ]; }; then
    if out="$(gitr push origin HEAD 2>&1)"; then
      echo "  OK    pushed to origin"; count_ok; PUSH_STATE="ok"
    else
      # A push failure is a sync failure, not a local backup failure: it must
      # not bump the local fail count or flip local_status.
      echo "  FAIL  push: $(printf '%s' "$out" | tail -2)"; PUSH_STATE="failed"
    fi
  elif [ "$COMMITTED" = "1" ] || [ "$pending" = "1" ]; then
    echo "  SKIP  push blocked by gate (local commit kept)"; PUSH_STATE="blocked"
  else
    echo "  OK    nothing to push (origin up to date)"; PUSH_STATE="uptodate"
  fi

  # Trash is purged only once the deletions are safely in a commit.
  if [ "$COMMITTED" = "1" ] && [ -d "$REPO_DIR/.trash" ]; then
    find "$REPO_DIR/.trash" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    echo "  OK    .trash purged (deletions are in the commit)"
  fi
  return 0
}

echo "live hermes: $HERMES_HOME"
echo "live claude: $CLAUDE_HOME"
echo "repo:        $REPO_DIR"
[ "$DRY" = "1" ] && echo "mode:        DRY RUN (nothing will be written)"
echo

echo "[1/6] core files"
for f in $CORE_FILES; do
  cpf "$HERMES_HOME/$f" "$REPO_DIR/hermes/$f"
done
# Optional well-known extras: copied only when present at the source.
for f in install_id channel_directory.json memories/MEMORY.md memories/USER.md cron/jobs.json; do
  [ -f "$HERMES_HOME/$f" ] || continue
  cpf "$HERMES_HOME/$f" "$REPO_DIR/hermes/$f"
done

echo "[2/6] custom skills (mirrored)"
if [ -n "$CUSTOM_SKILLS" ]; then
  for s in $CUSTOM_SKILLS; do
    mirror_tree "$HERMES_HOME/skills/$s" "$REPO_DIR/hermes/skills/$s"
  done
else
  echo "  SKIP  CUSTOM_SKILLS is empty"
fi

echo "[3/6] claude core + skills (mirrored) + hooks"
for f in CLAUDE.md settings.json settings.local.json; do
  [ -f "$CLAUDE_HOME/$f" ] || continue
  cpf "$CLAUDE_HOME/$f" "$REPO_DIR/claude/$f"
done
[ -d "$CLAUDE_HOME/hooks" ] && mirror_tree "$CLAUDE_HOME/hooks" "$REPO_DIR/claude/hooks"
if [ -n "$CLAUDE_SKILLS" ]; then
  for s in $CLAUDE_SKILLS; do
    mirror_tree "$CLAUDE_HOME/skills/$s" "$REPO_DIR/claude/skills/$s"
  done
else
  echo "  SKIP  CLAUDE_SKILLS is empty"
fi

echo "[4/6] claude memory (whitelist: ${MEMORY_SLUGS:-none})"
if [ -n "$MEMORY_SLUGS" ]; then
  for slug in $MEMORY_SLUGS; do
    src="$CLAUDE_HOME/projects/$slug/memory"
    dst="$REPO_DIR/claude/memory/$slug"
    if [ ! -d "$src" ]; then fail_item "claude/memory/$slug (source missing: $src)"; continue; fi
    n="$(find "$src" -maxdepth 1 -type f -name '*.md' | wc -l)"
    [ "$n" -eq 0 ] && warn_item "claude/memory/$slug is empty (0 fact files)"
    mirror_tree "$src" "$dst" '*.bak* *.lock *.tmp *.db'
  done
fi

echo "[5/6] legacy scripts (mirrored)"
if [ -n "$LEGACY_DIR" ] && [ -d "$LEGACY_DIR" ]; then
  mirror_tree "$LEGACY_DIR" "$REPO_DIR/hermes/scripts"
else
  echo "  SKIP  LEGACY_DIR not set"
fi

echo "[6/6] extra files + git"
if [ -n "$EXTRA_FILES" ]; then
  while IFS='|' read -r src dst; do
    [ -n "$src" ] || continue
    [ -z "$dst" ] && dst="collab/$(basename "$src")"
    cpf "$src" "$REPO_DIR/$dst"
  done <<< "$EXTRA_FILES"
fi

# Repo-relative paths that must never be committed. Trashed after they are
# mirrored, so a large local-only artifact cannot end up in the archive.
if [ -n "$EXCLUDE_PATHS" ] && [ "$DRY" = "0" ]; then
  for p in $EXCLUDE_PATHS; do
    [ -e "$REPO_DIR/$p" ] && trash_path "$REPO_DIR/$p"
  done
fi

if [ "$DRY" = "1" ]; then
  echo "  PLAN  git add/commit/push (skipped in dry run)"
else
  do_git
fi

# local_status answers "did the backup itself work"; push answers "is the
# snapshot off-machine". A blocked or failed push no longer makes the run fail.
LOCAL_STATUS="ok"
if [ "$FAIL" -gt 0 ]; then LOCAL_STATUS="fail"; fi

echo
echo "summary: ok=$OK fail=$FAIL warn=$WARN local_status=$LOCAL_STATUS push=$PUSH_STATE"

if [ "$DRY" = "0" ]; then
  write_last_run "$LOCAL_STATUS"
fi

if [ "$LOCAL_STATUS" = "fail" ]; then exit 1; fi
exit 0
