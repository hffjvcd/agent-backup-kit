# config.example.sh - copy to config.sh and edit. config.sh is git-ignored.
#
# All values are optional; the defaults below are generic and portable.
# Every variable can also be set in the environment instead.

# Live trees to archive.
: "${HERMES_HOME:=$HOME/AppData/Local/hermes}"
: "${CLAUDE_HOME:=$HOME/.claude}"

# Where last-run.json and ALERT.txt live. Keep this OUTSIDE the repo.
: "${STATE_DIR:=$HOME/.agent-backup}"

# Top-level files copied verbatim from HERMES_HOME into hermes/ in the repo.
CORE_FILES="config.yaml .env auth.json SOUL.md"

# Subtrees of HERMES_HOME that are mirrored (add/remove is safe; empty = none).
# Example: CUSTOM_SKILLS="my-skill another-skill"
CUSTOM_SKILLS=""

# Claude Code skills under CLAUDE_HOME/skills that are mirrored.
CLAUDE_SKILLS=""

# Claude Code project slugs whose memory/ directory is archived.
# Find them under ~/.claude/projects/<slug>/memory
MEMORY_SLUGS=""

# Optional: a directory of legacy helper scripts mirrored into hermes/scripts/.
LEGACY_DIR=""

# Optional: extra files to snapshot, as "absolute source|path inside repo".
# Use "|" as the separator so Windows drive letters stay intact.
# Example: EXTRA_FILES="/c/notes/todo.md|collab/todo.md"
EXTRA_FILES=""

# Optional repo-relative paths that must never be committed (trashed if present).
EXCLUDE_PATHS=""
