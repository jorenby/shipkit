#!/bin/bash
# SessionStart[clear] hook: re-injects the ship role recorded for this cwd after /clear rotates the session id.
set -euo pipefail

BY_CWD_DIR="$HOME/.claude/ship-roles/by-cwd"

PAYLOAD=$(cat)
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -z "$CWD" ] && exit 0

CWD_HASH=$(printf '%s' "$CWD" | shasum | cut -c1-16)
ROLE_FILE="$BY_CWD_DIR/$CWD_HASH"
[ -f "$ROLE_FILE" ] || exit 0

ROLE=$(tr -d '[:space:]' < "$ROLE_FILE")
if [ "$ROLE" != "Mate" ] && [ "$ROLE" != "Navigator" ]; then
  exit 0
fi

jq -n --arg role "$ROLE" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ("You are the ship \($role). Run your Start-of-Watch / Starting-a-Session procedure now."),
    reloadSkills: true
  }
}'
