#!/bin/bash
# Ship crew Write/Edit path guard (PreToolUse, matcher "Write|Edit").
# Companion to validate-crew-bash.sh.
#
# WHY THIS EXISTS: crew agents carry the Write/Edit tools, and the bash hook only
# matches the Bash tool — so a direct Write/Edit call to queue.md never passed through
# any guard. This hook closes that gap for the indisputable shared-state boundaries:
#
#   BLOCKED (ship-root-relative):
#     - queue.md            (Mate-owned index; crew are read-only on it)
#     - captain.md          (the Captain's orders; crew read-only)
#     - inbox/**            (crew note blockers in their LOG, not the inbox)
#
#   ALLOWED: everything else — crew legitimately write code in target repos, watch
#   logs under logs/, and their assigned ticket's "Current state" / "Watch history".
#   Ticket single-ticket scope stays prompt-governed (the hook can't know the
#   assignment).
#
# Like all Ship hooks this is a fail-loud guardrail against accidental violations,
# not a sandbox. Invoked as `bash <abs-path>` by the installed def, so the exec bit
# is POSIX belt-and-suspenders, not load-bearing. Ship root is resolved from this
# script's own location (core/hooks/ → two up).

# jq DEPENDENCY GUARD (fail CLOSED): the path parse below uses jq. Without jq the
# parse yields empty and the hook exits 0 — SILENT ZERO ENFORCEMENT. Refuse to run
# instead: exit 2 with a loud message. shipkit_init.py's preflight asserts jq is on
# PATH at install, so a correctly-installed ship never reaches this.
if ! command -v jq >/dev/null 2>&1; then
  echo "Blocked: ${0##*/} requires jq, which is not on PATH. Install jq (brew install jq / apt-get install jq / winget install jqlang.jq) — failing CLOSED to avoid silent zero enforcement of the Ship hooks." >&2
  exit 2
fi

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')

# No path in the payload (not a file-writing call) — nothing to guard.
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

SHIP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Resolve a relative path against the tool call's cwd (Claude Code passes absolute
# paths for Write/Edit, but don't rely on it — a relative path must not dodge the
# guard). `realpath -m` normalizes ../ segments without requiring the file to exist;
# it ships with GNU coreutils and Git-Bash. If it's genuinely absent, fall back to
# textual normalization via the shell (still catches the plain cases) — and note the
# deny checks below run on the NORMALIZED path only.
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
case "$FILE_PATH" in
  /*) CANDIDATE="$FILE_PATH" ;;
  *)  CANDIDATE="${CWD:-$PWD}/$FILE_PATH" ;;
esac
if command -v realpath >/dev/null 2>&1; then
  NORM=$(realpath -m -- "$CANDIDATE" 2>/dev/null || printf '%s' "$CANDIDATE")
else
  NORM="$CANDIDATE"
fi

block() {
  echo "Blocked: crew don't write $1 — $2" >&2
  exit 2
}

case "$NORM" in
  "$SHIP_DIR/queue.md")
    block "queue.md" "the Mate owns the queue. Note needed changes in your watch log; the Mate applies them." ;;
  "$SHIP_DIR/captain.md")
    block "captain.md" "the Captain's orders are read-only for crew." ;;
  "$SHIP_DIR/inbox/"*|"$SHIP_DIR/inbox")
    block "inbox/" "note blockers in your watch log, not the inbox; the Mate processes the inbox." ;;
esac

exit 0
