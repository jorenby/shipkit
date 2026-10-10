#!/bin/bash
# Records this session's ship role for the status line and for role-restore.sh after /clear.
# Usage: ship-role.sh <Mate|Navigator|Crew|Captain>
set -euo pipefail

ROLE="${1:-}"
case "$ROLE" in
  Mate|Navigator|Crew|Captain) ;;
  *) echo "usage: $(basename "$0") <Mate|Navigator|Crew|Captain>" >&2; exit 2 ;;
esac

ROLES_DIR="$HOME/.claude/ship-roles"
mkdir -p "$ROLES_DIR/by-cwd"

if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  SID=${CLAUDE_CODE_SESSION_ID//[^A-Za-z0-9-]/}
  printf '%s\n' "$ROLE" > "$ROLES_DIR/$SID"
fi
printf '%s\n' "$ROLE" > "$ROLES_DIR/by-cwd/$(printf '%s' "$PWD" | shasum | cut -c1-16)"
echo "ship role set: $ROLE"
