#!/usr/bin/env bash
# watchdog.sh - daily heartbeat check for the backup job.
#
# Two independent health questions, with separate alert wording:
#   LOCAL  - did the backup itself work?
#     A. the last N (=2) consecutive runs failed  (a single failure is tolerated:
#        a full disk or a flaky network should not page anyone)
#     B. no successful run for more than 36 hours (catches the silent cases:
#        scheduler disabled, machine off, credentials expired, job never installed)
#   SYNC   - is the snapshot off-machine?
#     C. push=failed or push=blocked: the local commit exists but never reached origin
#
# Alert channel: Telegram first (TELEGRAM_BOT_TOKEN in the env file), fallback to
# $STATE_DIR/ALERT.txt. Tokens are never printed; only a masked prefix.
#
# Configuration comes from the environment, config.sh, or the defaults below.
#
# Usage:
#   bash scripts/watchdog.sh
#   bash scripts/watchdog.sh --dry-run   # evaluate and print, do not send/write
# Exit: 0 healthy, 1 alert raised, 2 usage/IO error.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

: "${HERMES_HOME:=$HOME/AppData/Local/hermes}"
: "${STATE_DIR:=$HOME/.agent-backup}"

CONFIG_FILE="${CONFIG_FILE:-$REPO_DIR/config.sh}"
if [ -f "$CONFIG_FILE" ]; then . "$CONFIG_FILE"; fi

ENV_FILE="${ENV_FILE:-$HERMES_HOME/.env}"
LAST_RUN_FILE="${LAST_RUN_FILE:-$STATE_DIR/last-run.json}"
ALERT_FILE="${ALERT_FILE:-$STATE_DIR/ALERT.txt}"
HOURS_LIMIT="${HOURS_LIMIT:-36}"
CONSEC_LIMIT="${CONSEC_LIMIT:-2}"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

json_num() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\\([0-9]*\\).*/\\1/p" "$LAST_RUN_FILE" 2>/dev/null | head -1; }
json_str() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$LAST_RUN_FILE" 2>/dev/null | head -1; }

env_get() {
  # Reads KEY=value from .env without sourcing it (values may contain spaces/quotes).
  [ -f "$ENV_FILE" ] || return 1
  sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" 2>/dev/null | head -1 \
    | tr -d '\r' | sed 's/^"//; s/"$//; s/^'\''//; s/'\''$//'
}

mask() { local v="$1"; printf '%s...(%d chars)' "${v:0:6}" "${#v}"; }

NOW="$(date +%s)"
REASONS=""

if [ ! -f "$LAST_RUN_FILE" ]; then
  REASONS="last-run.json not found at $LAST_RUN_FILE - the backup job has never run or was never installed"
  STATUS="missing"; PUSH="missing"; CONSEC=""; AGE_H=""
else
  # local_status answers "did the backup itself work"; push is tracked separately.
  # Fall back to status so a file written by an older backup.sh still parses.
  STATUS="$(json_str local_status)"; [ -n "$STATUS" ] || STATUS="$(json_str status)"; [ -n "$STATUS" ] || STATUS="unknown"
  PUSH="$(json_str push)"; [ -n "$PUSH" ] || PUSH="unknown"
  CONSEC="$(json_num consecutive_fail)"; [ -n "$CONSEC" ] || CONSEC=0
  SUCCESS="$(json_num last_success_epoch)"; [ -n "$SUCCESS" ] || SUCCESS=0
  # Malformed numbers must fail closed: an unreadable counter is not "healthy".
  case "$CONSEC" in ''|*[!0-9]*) CONS_BAD=1; CONSEC=0 ;; *) CONS_BAD=0 ;; esac
  case "$SUCCESS" in ''|*[!0-9]*) SUCCESS=0 ;; esac
  if [ "$SUCCESS" -gt 0 ]; then
    AGE_H=$(( (NOW - SUCCESS) / 3600 ))
  else
    AGE_H=""
  fi
  if [ "$CONS_BAD" = "1" ]; then
    REASONS="last-run.json is unparsable (consecutive_fail missing or non-numeric)"
  fi
  if [ "$CONSEC" -ge "$CONSEC_LIMIT" ]; then
    REASONS="${REASONS:+$REASONS; }$CONSEC consecutive failed runs (local_status: $STATUS)"
  fi
  if [ -z "$AGE_H" ]; then
    REASONS="${REASONS:+$REASONS; }no successful run recorded yet"
  elif [ "$AGE_H" -gt "$HOURS_LIMIT" ]; then
    REASONS="${REASONS:+$REASONS; }last success was ${AGE_H}h ago (limit ${HOURS_LIMIT}h)"
  fi
  # Sync is a separate failure mode: the local backup can be healthy while nothing
  # has left the machine. Alert on it with its own wording.
  case "$PUSH" in
    failed|blocked) REASONS="${REASONS:+$REASONS; }SYNC stopped: push=$PUSH (local backup: $STATUS)" ;;
  esac
fi

echo "last-run:   $LAST_RUN_FILE"
echo "local:      ${STATUS:-?}  consecutive_fail=${CONSEC:-?}  last_success_age=${AGE_H:-?}h"
echo "push:       ${PUSH:-?}"
if [ -z "$REASONS" ]; then
  echo "result:     healthy"
  exit 0
fi

MSG="[backup watchdog] $(hostname) $(date '+%Y-%m-%d %H:%M')
$REASONS
last-run.json: $LAST_RUN_FILE"
echo "result:     ALERT - $REASONS"
if [ "$DRY" = "1" ]; then
  echo "dry run: not sending, not writing"
  exit 1
fi

SENT=0
TOKEN="$(env_get TELEGRAM_BOT_TOKEN || true)"
if [ -n "$TOKEN" ]; then
  CHAT="$(env_get TELEGRAM_CHAT_ID || true)"
  if [ -z "$CHAT" ]; then
    CHAT="$(env_get TELEGRAM_ALLOWED_USERS || true)"
    CHAT="${CHAT%%,*}"
  fi
  PROXY="$(env_get TELEGRAM_PROXY || true)"
  [ -n "$PROXY" ] || PROXY="$(env_get HTTPS_PROXY || true)"
  if [ -n "$CHAT" ] && command -v curl >/dev/null 2>&1; then
    echo "telegram:   sending with token $(mask "$TOKEN") chat=$CHAT"
    if curl -sS --max-time 20 ${PROXY:+-x "$PROXY"} \
         -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
         --data-urlencode "chat_id=$CHAT" \
         --data-urlencode "text=$MSG" >/dev/null 2>&1; then
      SENT=1
      echo "telegram:   sent"
    else
      echo "telegram:   send failed, falling back to ALERT.txt"
    fi
  else
    echo "telegram:   no chat id or curl, falling back to ALERT.txt"
  fi
else
  echo "telegram:   TELEGRAM_BOT_TOKEN not configured, falling back to ALERT.txt"
fi

if [ "$SENT" = "0" ]; then
  mkdir -p "$(dirname "$ALERT_FILE")"
  printf '%s\n\n' "$MSG" >> "$ALERT_FILE"
  echo "alert file: $ALERT_FILE"
fi

exit 1
