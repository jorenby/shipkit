#!/bin/bash
# Sourced by the compaction hooks (compact-recover.sh, compact-log.sh). ROLES_DIR must be set by the caller.
# The records are written by scripts/ship-role.sh.

# Session-id record first: a compaction keeps the session id, and the by-cwd record is last-writer-wins
# across seats launched from the same cwd.
read_role() {
  local session_id="$1" cwd="$2" file
  if [ -n "$session_id" ] && [ -f "$ROLES_DIR/$session_id" ]; then
    file="$ROLES_DIR/$session_id"
  elif [ -n "$cwd" ]; then
    file="$ROLES_DIR/by-cwd/$(printf '%s' "$cwd" | shasum | cut -c1-16)"
  fi
  [ -n "${file:-}" ] && [ -f "$file" ] && tr -d '[:space:]' < "$file"
}
