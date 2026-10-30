#!/bin/bash
# PostCompact hook: logs each compaction of a Mate or Navigator session — trigger, time, and whether the
# summary kept the role and any open Captain gate. The summary itself stays local; only the booleans reach
# the ship repo.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIP_ROOT="${SHIP_ROOT:-$(cd "$HOOK_DIR/../../.." && pwd)}"
ROLES_DIR="${SHIP_ROLES_DIR:-$HOME/.claude/ship-roles}"
LOG_FILE="${SHIP_COMPACT_LOG:-$SHIP_ROOT/logs/compactions.jsonl}"
SUMMARY_DIR="${SHIP_COMPACT_SUMMARY_DIR:-$HOME/.claude/ship-compactions}"

source "$HOOK_DIR/read-role.sh"

main() {
  local payload session_id cwd role summary ts summary_file
  payload=$(cat)
  session_id=$(echo "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)
  cwd=$(echo "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)

  role=$(read_role "$session_id" "$cwd")
  case "$role" in
    Mate|Navigator) ;;
    *) exit 0 ;;
  esac

  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  summary=$(echo "$payload" | jq -r '.compact_summary // empty' 2>/dev/null || true)
  if [ -n "$summary" ]; then
    mkdir -p "$SUMMARY_DIR"
    summary_file="$ts-$session_id.md"
    printf '%s\n' "$summary" > "$SUMMARY_DIR/$summary_file"
  fi

  mkdir -p "$(dirname "$LOG_FILE")"
  # payload_keys records the real input shape, since the hook docs are thin on PostCompact.
  # summary_file is a bare name, keeping $HOME out of the committed log.
  echo "$payload" | jq -c \
    --arg ts "$ts" --arg role "$role" --arg summary "$summary" --arg summary_file "${summary_file:-}" '{
      ts: $ts,
      session_id: (.session_id // null),
      role: $role,
      trigger: (.trigger // null),
      payload_keys: keys,
      summary_chars: ($summary | length),
      summary_names_role: ($summary | test("\\b" + $role + "\\b"; "i")),
      summary_names_open_gate: ($summary | test("live (captain )?go|awaiting (the )?captain|needs the captain|pending captain"; "i")),
      summary_file: (if $summary_file == "" then null else $summary_file end)
    }' >> "$LOG_FILE" 2>/dev/null
  exit 0
}

main
