#!/bin/bash
# Scheduled wrapper around the read-only upstream-drift report. Runs the report and, only when
# there is something to review, drops a candidate into inbox/drops/ so the Mate's next inbox
# flush surfaces it. Read-only: never merges, never pushes, never writes queue.md. Bounded: one
# unconsumed drift drop at a time, so a persistent gap cannot flood the inbox.
#
# The report itself decides what counts as drift; this script only schedules it and routes the
# result. Pair it with com.ship.upstream-sync.plist (launchd) or any cron equivalent.
set -euo pipefail

SHIP_ROOT="${SHIP_ROOT:-$HOME/code/ship}"
REPORT="${UPSTREAM_SYNC_REPORT:-$SHIP_ROOT/scripts/upstream-sync-report.sh}"
LOG_DIR="${SHIP_SENSOR_LOG_DIR:-$HOME/.ship-sensors}"
DROPS_DIR="$SHIP_ROOT/inbox/drops"
LOG="$LOG_DIR/upstream-sync.log"

mkdir -p "$LOG_DIR"
stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ ! -x "$REPORT" ]; then
  echo "[$stamp] ERROR: report script not found or not executable at $REPORT" >> "$LOG"
  exit 0
fi

if out="$("$REPORT" 2>&1)"; then
  echo "[$stamp] $out" >> "$LOG"
else
  echo "[$stamp] ERROR: report exited nonzero:" >> "$LOG"
  echo "$out" >> "$LOG"
  exit 0
fi

# Surface only when the report says there is something to do (it prints a "Review:" line then).
if ! printf '%s\n' "$out" | grep -q '^Review:'; then
  exit 0
fi

# Bound the inbox: if an unconsumed drift drop is already pending, do not add another.
mkdir -p "$DROPS_DIR"
if compgen -G "$DROPS_DIR/*-upstream-sync-drift.md" > /dev/null; then
  echo "[$stamp] drift present but a candidate is already pending; not re-dropping" >> "$LOG"
  exit 0
fi

ts="$(date -u +%Y-%m-%d-%H%M%S)"
drop="$DROPS_DIR/${ts}-upstream-sync-drift.md"
{
  echo "---"
  echo "shipkit_input: v1"
  echo "source: upstream-sync-tick"
  echo "for: mate"
  echo "kind: steer"
  echo "wake_class: batch"
  echo "---"
  echo ""
  echo "# Upstream drift — something to review"
  echo ""
  echo '```'
  printf '%s\n' "$out"
  echo '```'
  echo ""
  echo "The upstream-sync report flags drift from upstream (commits behind and/or"
  echo "contribute-back candidates outstanding). Read-only surfacing — Navigator/Captain"
  echo "decides whether to pull small clean upstream changes or bundle a contribute-back PR."
  echo "Candidate curation list: notes/upstream-candidates.md."
} > "$drop"

echo "[$stamp] drift surfaced -> $drop" >> "$LOG"
exit 0
