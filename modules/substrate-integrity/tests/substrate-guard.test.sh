#!/usr/bin/env bash
# Tests for ship-substrate-guard.sh -- the Edit|Write|MultiEdit PreToolUse hook that denies
# edits to the security substrate (bash guards, agent defs, tripwire + baseline, this hook).
# Feeds a {tool_input:{file_path}} payload and asserts exit code (0 allow / 2 deny).
# Run: bash scripts/tests/substrate-guard.test.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$SCRIPT_DIR/hooks/ship-substrate-guard.sh"
PASS=0; FAIL=0; FAILED=()

assert() {  # <label> <expected-exit> <file_path>
  local label="$1" expected="$2" fp="$3" got
  printf '{"tool_input":{"file_path":%s}}' "$(printf '%s' "$fp" | jq -R .)" | bash "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$expected" ]; then printf "  PASS  %s\n" "$label"; PASS=$((PASS+1))
  else printf "  FAIL  %s (expected %s got %s) fp=%s\n" "$label" "$expected" "$got" "$fp"; FAIL=$((FAIL+1)); FAILED+=("$label"); fi
}

echo "=== DENY: fully-qualified substrate paths ==="
assert "abs crew guard"        2 "/Users/x/code/ship/scripts/validate-crew-bash.sh"
assert "abs readonly guard"    2 "/Users/x/code/ship/scripts/validate-readonly-bash.sh"
assert "abs crew-allow-local"  2 "/Users/x/code/ship/scripts/crew-allow-local.sh"
assert "abs edit hook"         2 "/Users/x/.claude/hooks/ship-substrate-guard.sh"
assert "abs deployed agentdef" 2 "/Users/x/.claude/agents/ship-crew.md"
assert "abs repo agentdef"     2 "/Users/x/code/ship/agents/ship-lookout.md"
assert "abs tripwire script"   2 "/Users/x/code/ship/scripts/wake-monitor/substrate_tripwire.py"
assert "abs tripwire state"    2 "/Users/x/.claude/ship/substrate_tripwire_state.json"

echo ""
echo "=== DENY: non-canonical dodges (review finding 2A/2B) ==="
assert "repo-relative, no dir"  2 "scripts/validate-crew-bash.sh"
assert "bare basename"          2 "validate-crew-bash.sh"
assert "repo-relative agentdef" 2 "agents/ship-crew.md"
assert "embedded /./"           2 "/Users/x/code/ship/scripts/./validate-crew-bash.sh"
assert "double slash"           2 "/Users/x/code/ship/scripts//validate-crew-bash.sh"
assert "trailing slash"         2 "/Users/x/code/ship/scripts/validate-crew-bash.sh/"
assert "uppercase"              2 "/Users/x/code/ship/scripts/VALIDATE-CREW-BASH.SH"
assert "dot-relative prefix"    2 "./scripts/crew-allow-local.sh"

echo ""
echo "=== DENY: janitor control files (049 — Edit-path self-protection under dontAsk) ==="
assert "abs janitor bash guard"  2 "/Users/x/code/ship/scripts/validate-janitor-bash.sh"
assert "abs prod guard"          2 "/Users/x/code/ship/scripts/validate-prod-guard.sh"
assert "abs mate-mcp guard"      2 "/Users/x/code/ship/scripts/validate-mate-mcp-bash.sh"
assert "abs tick wrapper"        2 "/Users/x/code/ship/scripts/janitor/ship-janitor-tick.sh"
assert "abs terminal check"      2 "/Users/x/code/ship/scripts/janitor/janitor-terminal-check.sh"
assert "abs janitor goal"        2 "/Users/x/code/ship/scripts/janitor/janitor-goal.txt"
assert "abs janitor settings"    2 "/Users/x/code/ship/scripts/janitor/janitor-settings.json"
assert "bare janitor guard base" 2 "validate-janitor-bash.sh"
assert "repo-rel tick wrapper"   2 "scripts/janitor/ship-janitor-tick.sh"
assert "uppercase janitor guard" 2 "/Users/x/code/ship/scripts/VALIDATE-JANITOR-BASH.SH"
assert "abs launchd plist"       2 "/Users/x/code/ship/scripts/janitor/com.ship.janitor-tick.plist"
assert "plist in LaunchAgents"   2 "/Users/x/Library/LaunchAgents/com.ship.janitor-tick.plist"
assert "bare plist basename"     2 "com.ship.janitor-tick.plist"
assert "uppercase plist"         2 "/Users/x/Library/LaunchAgents/COM.SHIP.JANITOR-TICK.PLIST"

echo ""
echo "=== ALLOW: ordinary paths + edge inputs ==="
assert "ordinary dag file"     0 "/Users/x/code/myrepo/dags/foo.py"
assert "a ticket"              0 "/Users/x/code/ship/projects/ship/tickets/041-x.md"
assert "backup of guard"       0 "/Users/x/code/ship/scripts/validate-crew-bash.sh.bak"
assert "queue.md"              0 "/Users/x/code/ship/projects/ship/queue.md"

echo ""
echo "============================================"
printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf "Failed: %s\n" "${FAILED[*]}"; exit 1; }
exit 0
