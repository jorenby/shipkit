#!/usr/bin/env bash
# Tests for compact-recover.sh (SessionStart[compact]) and compact-log.sh (PostCompact).
# Builds a throwaway ship repo with a bare remote and points the hooks at it by env var; the real ship
# repo and role records are never read or written.
#
# Run with: bash modules/session-ux/tests/compact-recover.test.sh
# Exits 0 on success, non-zero if any case fails.

set -u

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
RECOVER="$HOOKS_DIR/compact-recover.sh"
LOGGER="$HOOKS_DIR/compact-log.sh"

PASS=0
FAIL=0
FAILED_CASES=()

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export SHIP_ROOT="$TMP/ship"
export SHIP_ROLES_DIR="$TMP/roles"
export SHIP_COMPACT_LOG="$SHIP_ROOT/logs/compactions.jsonl"
export SHIP_COMPACT_SUMMARY_DIR="$TMP/summaries"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

repo() { git -C "$SHIP_ROOT" "$@"; }

build_ship() {
  rm -rf "$SHIP_ROOT" "$TMP/remote.git" "$SHIP_ROLES_DIR"
  git init -q --bare "$TMP/remote.git"
  git init -q "$SHIP_ROOT"
  mkdir -p "$SHIP_ROOT/scripts" "$SHIP_ROOT/projects" "$SHIP_ROOT/inbox" "$SHIP_ROOT/logs" "$SHIP_ROLES_DIR/by-cwd"
  echo x > "$SHIP_ROOT/scripts/tool.sh"
  echo q > "$SHIP_ROOT/queue.md"
  repo add -A && repo commit -qm init && repo remote add origin "$TMP/remote.git" && repo push -qu origin HEAD 2>/dev/null
}

set_role() { echo "$2" > "$SHIP_ROLES_DIR/$1"; }
set_cwd_role() { echo "$2" > "$SHIP_ROLES_DIR/by-cwd/$(printf '%s' "$1" | shasum | cut -c1-16)"; }

payload() { jq -nc --arg s "$1" --arg c "$2" '{session_id:$s, cwd:$c, transcript_path:"/t/x.jsonl", source:"compact", hook_event_name:"SessionStart"}'; }
context_for() { payload "$1" "$2" | bash "$RECOVER" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }

check() {
  local label="$1" ok="$2"
  if [ "$ok" = yes ]; then printf "  PASS  %s\n" "$label"; PASS=$((PASS+1))
  else printf "  FAIL  %s\n" "$label"; FAIL=$((FAIL+1)); FAILED_CASES+=("$label"); fi
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
lacks() { case "$1" in *"$2"*) echo no ;; *) echo yes ;; esac; }

echo "Role recovery"
build_ship
out=$(payload s0 /nowhere | bash "$RECOVER" 2>/dev/null)
check "no role record → nothing injected" "$([ -z "$out" ] && echo yes || echo no)"

set_cwd_role /cwd/a Mate
ctx=$(context_for s1 /cwd/a)
check "by-cwd fallback restores Mate" "$(has "$ctx" "You are the ship Mate.")"
check "points at the Mate role doc" "$(has "$ctx" "$SHIP_ROOT/core/mate.md")"
check "says mid-task, not a cold start" "$(has "$ctx" "do NOT run your start-of-session procedure")"
check "clean repo → no catch-up" "$(lacks "$ctx" "ship-checkpoint/SKILL.md")"

set_role sNav Navigator
ctx=$(context_for sNav /cwd/a)
check "session-id record beats a by-cwd Mate record" "$(has "$ctx" "You are the ship Navigator.")"
check "points at the navigator skill" "$(has "$ctx" "$SHIP_ROOT/modules/navigator/skills/navigator/SKILL.md")"
set_role sMate Mate
ctx=$(context_for sMate /cwd/a)
check "second seat on the same cwd keeps its own role" "$(has "$ctx" "You are the ship Mate.")"

set_role sBad Crew
ctx=$(payload sBad /nowhere | bash "$RECOVER" 2>/dev/null)
check "unknown role → nothing injected" "$([ -z "$ctx" ] && echo yes || echo no)"

echo "Unsaved-work check"
fires() {
  local label="$1"; local ctx; ctx=$(context_for sMate /cwd/a)
  check "$label → catch-up" "$(has "$ctx" "ship-checkpoint/SKILL.md against the full transcript JSONL at /t/x.jsonl")"
}
quiet() {
  local label="$1"; local ctx; ctx=$(context_for sMate /cwd/a)
  check "$label → no catch-up" "$(lacks "$ctx" "ship-checkpoint/SKILL.md")"
}

build_ship; set_role sMate Mate
quiet "clean, pushed repo"
echo y >> "$SHIP_ROOT/scripts/tool.sh"; fires "uncommitted edit"

build_ship; set_role sMate Mate
echo new > "$SHIP_ROOT/scripts/new.sh"; fires "new untracked file"

build_ship; set_role sMate Mate
echo y >> "$SHIP_ROOT/scripts/tool.sh"; repo commit -qam local; fires "unpushed commit"

build_ship; set_role sMate Mate
echo t > "$SHIP_ROOT/projects/new-ticket.md"; fires "new untracked file under projects/"

build_ship; set_role sMate Mate
mkdir -p "$SHIP_ROOT/logs/p/1"; echo l > "$SHIP_ROOT/logs/p/1/log.md"; fires "new untracked file under logs/"

build_ship; set_role sMate Mate
echo c > "$SHIP_ROOT/inbox/checkpoint-x.md"
ctx=$(context_for sMate /cwd/a)
check "unabsorbed checkpoint file → catch-up" "$(has "$ctx" "unabsorbed checkpoint files in inbox/")"
check "checkpoint file not double-counted as a new file" "$(lacks "$ctx" "uncommitted changes or new files")"

build_ship; set_role sMate Mate
echo d > "$SHIP_ROOT/inbox/drop.md"; fires "new untracked file under inbox/"

build_ship; set_role sMate Mate
echo changed >> "$SHIP_ROOT/queue.md"
ctx=$(cd "$SHIP_ROOT/scripts" && context_for sMate /cwd/a)
check "edit seen when the hook runs from a ship subdirectory" "$(has "$ctx" "uncommitted changes or new files")"

build_ship; set_role sMate Mate
repo branch -q --unset-upstream
ctx=$(context_for sMate /cwd/a)
check "no upstream → reported as unreadable, not as unpushed" "$(has "$ctx" "push state unreadable")"

build_ship; set_role sMate Mate
echo '{}' > "$SHIP_COMPACT_LOG"; quiet "only the compaction log changed"

build_ship; set_role sMate Mate
echo '{}' > "$SHIP_COMPACT_LOG"; repo add logs/compactions.jsonl; repo commit -qm log; repo push -q 2>/dev/null
echo '{}' >> "$SHIP_COMPACT_LOG"; quiet "tracked compaction log modified"

build_ship; set_role sMate Mate
mv "$SHIP_ROOT/.git" "$TMP/moved.git"; fires "repo unreadable"
mv "$TMP/moved.git" "$SHIP_ROOT/.git"

echo "PostCompact logger"
build_ship; set_role sMate Mate
jq -nc '{session_id:"sMate", cwd:"/cwd/a", trigger:"auto", hook_event_name:"PostCompact", compact_summary:"You are the Mate. Awaiting the Captain on the deploy."}' | bash "$LOGGER"
line=$(tail -1 "$SHIP_COMPACT_LOG" 2>/dev/null)
check "logs the trigger" "$([ "$(echo "$line" | jq -r .trigger)" = auto ] && echo yes || echo no)"
check "role survived" "$([ "$(echo "$line" | jq -r .summary_names_role)" = true ] && echo yes || echo no)"
check "open gate survived" "$([ "$(echo "$line" | jq -r .summary_names_open_gate)" = true ] && echo yes || echo no)"
check "summary kept outside the repo" "$([ -f "$SHIP_COMPACT_SUMMARY_DIR/$(echo "$line" | jq -r .summary_file)" ] && echo yes || echo no)"
check "summary text not in the repo log" "$(lacks "$line" "deploy")"

jq -nc '{session_id:"sMate", cwd:"/cwd/a", trigger:"manual", compact_summary:"Approximate plan: automate the estimate."}' | bash "$LOGGER"
line=$(tail -1 "$SHIP_COMPACT_LOG")
check "role-like words (automate, estimate) and no gate read false" "$([ "$(echo "$line" | jq -r '.summary_names_role, .summary_names_open_gate' | tr '\n' ' ')" = "false false " ] && echo yes || echo no)"

before=$(wc -l < "$SHIP_COMPACT_LOG")
jq -nc '{session_id:"other", cwd:"/elsewhere", trigger:"auto", compact_summary:"x"}' | bash "$LOGGER"
check "no role → nothing logged" "$([ "$(wc -l < "$SHIP_COMPACT_LOG")" = "$before" ] && echo yes || echo no)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { printf '  - %s\n' "${FAILED_CASES[@]}"; exit 1; }
