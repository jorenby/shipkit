#!/bin/bash
# SessionStart[compact] hook: after a compaction, tells a Mate or Navigator session to re-read its role doc
# and continue mid-task, and adds a checkpoint catch-up only when the ship repo holds unsaved work.
# Fires on every compaction in every project; no-ops cleanly when no role record is found.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIP_ROOT="${SHIP_ROOT:-$(cd "$HOOK_DIR/../../.." && pwd)}"
ROLES_DIR="${SHIP_ROLES_DIR:-$HOME/.claude/ship-roles}"
COMPACT_LOG="${SHIP_COMPACT_LOG:-$SHIP_ROOT/logs/compactions.jsonl}"

source "$HOOK_DIR/read-role.sh"

main() {
  local payload session_id cwd transcript role doc reasons context
  payload=$(cat)
  session_id=$(echo "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)
  cwd=$(echo "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
  transcript=$(echo "$payload" | jq -r '.transcript_path // empty' 2>/dev/null || true)

  role=$(read_role "$session_id" "$cwd")
  case "$role" in
    Mate) doc="$SHIP_ROOT/core/mate.md" ;;
    Navigator) doc="$SHIP_ROOT/modules/navigator/skills/navigator/SKILL.md" ;;
    *) exit 0 ;;
  esac

  context="You are the ship $role. This session was just compacted and is MID-TASK: do NOT run your start-of-session procedure. Re-read $doc in full (a compaction keeps at most the opening of a role skill), then continue from the summary."

  reasons=$(unsaved_work)
  if [ -n "$reasons" ]; then
    context="$context Before anything else: the ship repo holds unsaved work ($reasons). Follow the checklist in $SHIP_ROOT/modules/session-ceremony/skills/ship-checkpoint/SKILL.md against the full transcript JSONL${transcript:+ at $transcript} (not the summary), write residue to its durable homes, then commit and push."
  fi

  jq -n --arg ctx "$context" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
}

# Prints a comma-separated list of reasons, empty when the ship repo is clean and pushed.
# A git error counts as unsaved: a missed catch-up costs more than an unneeded one.
unsaved_work() {
  local reasons=() out
  local repo=(git -C "$SHIP_ROOT")
  # Checkpoint files get their own reason below.
  local pathspec=(. ':(exclude)inbox/checkpoint-*.md')
  # The PostCompact logger appends to the compaction log just before this runs, so it would always fire.
  case "$COMPACT_LOG" in
    "$SHIP_ROOT"/*) pathspec+=(":(exclude)${COMPACT_LOG#"$SHIP_ROOT"/}") ;;
  esac

  out=$("${repo[@]}" status --porcelain --untracked-files=all -- "${pathspec[@]}" 2>/dev/null) || out="error"
  [ -n "$out" ] && reasons+=("uncommitted changes or new files")
  out=$(push_state "${repo[@]}") && reasons+=("$out")

  compgen -G "$SHIP_ROOT/inbox/checkpoint-*.md" > /dev/null && reasons+=("unabsorbed checkpoint files in inbox/")

  local joined="" r
  for r in ${reasons[@]+"${reasons[@]}"}; do joined="${joined:+$joined, }$r"; done
  echo "$joined"
}

# Succeeds and prints a reason when the repo is ahead of its upstream or its push state can't be read.
push_state() {
  local count
  count=$("$@" rev-list --count '@{u}..HEAD' 2>/dev/null) || { echo "push state unreadable"; return 0; }
  [ "$count" != "0" ] && echo "unpushed commits"
}

main
