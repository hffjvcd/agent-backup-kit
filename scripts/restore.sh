#!/usr/bin/env bash
# restore.sh - restore agent config from this repo to the live locations.
#
# Usage:
#   bash scripts/restore.sh --dry-run     # show what would be written, change nothing
#   bash scripts/restore.sh               # restore (existing files are backed up first)
#   bash scripts/restore.sh --force       # restore without per-file .pre-restore backup
#   bash scripts/restore.sh --skip-extra  # skip files outside HERMES_HOME/CLAUDE_HOME
#   bash scripts/restore.sh --no-mirror   # copy only, never delete local extras
#
# Pure ASCII output on purpose: non-ASCII paths are printed as-is, messages stay
# English.
#
# Mirroring: the subtrees this repo owns (custom skills, hooks, claude/memory/<slug>)
# are restored as mirrors, symmetric with backup.sh. A local file with no
# counterpart in the repo is moved to <dst>/.restore-trash-<ts>/ instead of being
# deleted. Only those owned subtrees are mirrored; the shared parents
# (HERMES_HOME/skills, CLAUDE_HOME/skills) are never mirrored, so builtin skills
# cannot be wiped by a restore.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

: "${HERMES_HOME:=$HOME/AppData/Local/hermes}"
: "${CLAUDE_HOME:=$HOME/.claude}"
: "${STATE_DIR:=$HOME/.agent-backup}"
CORE_FILES="${CORE_FILES:-config.yaml .env auth.json SOUL.md}"
CUSTOM_SKILLS="${CUSTOM_SKILLS:-}"
CLAUDE_SKILLS="${CLAUDE_SKILLS:-}"
EXTRA_FILES="${EXTRA_FILES:-}"

CONFIG_FILE="${CONFIG_FILE:-$REPO_DIR/config.sh}"
if [ -f "$CONFIG_FILE" ]; then . "$CONFIG_FILE"; fi

TS="$(date +%Y%m%dT%H%M%S)"

DRY=0
FORCE=0
SKIP_EXTRA=0
MIRROR=1
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --force) FORCE=1 ;;
    --skip-extra) SKIP_EXTRA=1 ;;
    --no-mirror) MIRROR=0 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

copied=0
backed=0
failed=0
trashed=0

# put <src> <dst>
put() {
  local src="$1" dst="$2"
  [ -f "$src" ] || { echo "  MISS  $src"; failed=$((failed+1)); return 1; }
  if [ "$DRY" = "1" ]; then
    echo "  PLAN  ${dst#$HOME/}"
    return 0
  fi
  mkdir -p "$(dirname "$dst")" || { failed=$((failed+1)); return 1; }
  if [ -e "$dst" ] && [ "$FORCE" = "0" ]; then
    cp -p "$dst" "$dst.pre-restore-$TS" 2>/dev/null && backed=$((backed+1))
  fi
  if cp -p "$src" "$dst"; then copied=$((copied+1)); else echo "  FAIL  $src -> $dst"; failed=$((failed+1)); fi
}

# put_tree <src_dir> <dst_dir>  (plain copy; symlinks are dereferenced by cp -rL)
put_tree() {
  local src="$1" dst="$2"
  [ -d "$src" ] || { echo "  MISS  $src"; failed=$((failed+1)); return 1; }
  if [ "$DRY" = "1" ]; then
    echo "  PLAN  ${dst#$HOME/}  ($(find "$src" -type f | wc -l) files)"
    return 0
  fi
  mkdir -p "$dst" || { failed=$((failed+1)); return 1; }
  if cp -rLp "$src/." "$dst/" 2>/dev/null; then
    copied=$((copied+1))
  else
    echo "  FAIL  $src -> $dst"; failed=$((failed+1))
  fi
}

# put_tree_mirror <src_dir> <dst_dir>
# Same as put_tree, then moves local files with no repo counterpart into
# <dst>/.restore-trash-<ts>/ so the restored tree matches the archive exactly.
put_tree_mirror() {
  local src="$1" dst="$2" rel
  put_tree "$src" "$dst"
  if [ "$DRY" = "1" ] || [ "$MIRROR" = "0" ]; then return 0; fi
  [ -d "$dst" ] || return 0
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    case "$rel" in
      .restore-trash-*|.restore-trash-*/*|*.pre-restore-*) continue ;;
    esac
    [ -e "$src/$rel" ] && continue
    mkdir -p "$dst/.restore-trash-$TS/$(dirname "$rel")"
    if mv "$dst/$rel" "$dst/.restore-trash-$TS/$rel" 2>/dev/null; then
      echo "  TRASH ${dst#$HOME/}/$rel"
      trashed=$((trashed+1))
    fi
  done < <(cd "$dst" && find . -type f | sed 's|^\./||' | sort)
  find "$dst" -mindepth 1 -type d -empty -delete 2>/dev/null
  return 0
}

echo "repo:        $REPO_DIR"
echo "HERMES_HOME: $HERMES_HOME"
echo "CLAUDE_HOME: $CLAUDE_HOME"
[ "$DRY" = "1" ] && echo "mode:        DRY RUN (nothing will be written)"
[ "$MIRROR" = "0" ] && echo "mode:        mirror disabled (--no-mirror)"
echo

echo "[1/4] core files"
for f in $CORE_FILES; do
  put "$REPO_DIR/hermes/$f" "$HERMES_HOME/$f"
done
for f in install_id channel_directory.json memories/MEMORY.md memories/USER.md cron/jobs.json; do
  [ -f "$REPO_DIR/hermes/$f" ] || continue
  put "$REPO_DIR/hermes/$f" "$HERMES_HOME/$f"
done

echo "[2/4] custom skills (mirrored)"
for s in $CUSTOM_SKILLS; do
  [ -d "$REPO_DIR/hermes/skills/$s" ] || continue
  put_tree_mirror "$REPO_DIR/hermes/skills/$s" "$HERMES_HOME/skills/$s"
done

echo "[3/4] claude core + skills + hooks + memory"
for f in CLAUDE.md settings.json settings.local.json; do
  [ -f "$REPO_DIR/claude/$f" ] || continue
  put "$REPO_DIR/claude/$f" "$CLAUDE_HOME/$f"
done
[ -d "$REPO_DIR/claude/hooks" ] && put_tree_mirror "$REPO_DIR/claude/hooks" "$CLAUDE_HOME/hooks"
for s in $CLAUDE_SKILLS; do
  [ -d "$REPO_DIR/claude/skills/$s" ] || continue
  put_tree_mirror "$REPO_DIR/claude/skills/$s" "$CLAUDE_HOME/skills/$s"
done
# memory is stored per slug: claude/memory/<slug> -> projects/<slug>/memory
if [ -d "$REPO_DIR/claude/memory" ]; then
  for d in "$REPO_DIR"/claude/memory/*/; do
    [ -d "$d" ] || continue
    slug="$(basename "$d")"
    put_tree_mirror "$d" "$CLAUDE_HOME/projects/$slug/memory"
  done
fi
[ "$DRY" = "0" ] && chmod +x "$CLAUDE_HOME"/hooks/*.sh 2>/dev/null
true

if [ "$SKIP_EXTRA" = "1" ]; then
  echo "[4/4] extra files SKIPPED"
elif [ -n "$EXTRA_FILES" ]; then
  echo "[4/4] extra files"
  while IFS='|' read -r src dst; do
    [ -n "$src" ] || continue
    put "$REPO_DIR/$dst" "$src"
  done <<< "$EXTRA_FILES"
else
  echo "[4/4] extra files: none configured"
fi

echo
echo "summary: copied=$copied backed_up=$backed trashed=$trashed failed=$failed"
[ "$DRY" = "1" ] && echo "(dry run - nothing written)"

cat <<'NEXT'

--- manual steps still required on a fresh machine ---
1. Install the runtimes this archive depends on (agent runtime, editor CLI).
2. Log in with each tool once and confirm the account is correct.
3. Reinstall external dependencies that are not shipped in the repo
   (browser extensions, large knowledge bases, GPU model files).
4. Proxy: .env may carry HTTP(S)_PROXY. On a machine without that proxy,
   unset those lines or point them at the new proxy port.
5. Do NOT run this script over a machine that is already configured unless you
   want it reverted to the archived state. Local extras removed by mirroring are
   kept under <dir>/.restore-trash-<timestamp>/.
NEXT

if [ "$failed" -gt 0 ]; then exit 1; fi
exit 0
