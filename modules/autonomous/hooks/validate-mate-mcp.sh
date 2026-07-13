#!/bin/bash
# Ship MATE agent MCP tool gate (PreToolUse, matcher "mcp__.*").
# Companion to validate-mate-bash.sh.
#
# WHY THIS EXISTS: validate-mate-bash.sh only matches the Bash tool. MCP tool calls
# (mcp__<chat>__*, mcp__<tracker>__*, …) bypass it entirely. Once the bg Mate is
# launched with a real MCP config (chat / docs / tracker / observability servers),
# nothing else gates an autonomous external write (a chat post, a tracker transition).
# This hook is that gate.
#
# POLICY (confirm-gated writes; DEFAULT: HARD-BLOCK):
#   - READS  → allowed silently (autonomous tier; the 99% case).
#   - WRITES → BLOCKED by default (fail-closed for fresh installs), and every attempt
#     is AUDIT-LOGGED to state/mate-mcp-writes.jsonl with a stderr advisory. The
#     authorization rule still governs either way: the Mate calls an MCP write tool
#     ONLY after the Captain authorizes it in conversation.
#
# RELAX KNOB: set SHIP_MATE_MCP_WRITE_BLOCK=0 to switch to audit-and-allow (writes are
# audit-logged + warned but permitted; the confirm-gate discipline rule carries it).
# An established ship whose operator trusts the discipline layer runs 0; strangers
# cloning the kit get the block until they consciously relax it.
#
# Self-scopes on agent_type == "ship-mate" (works in --bg). Invoked as `bash <abs-path>`
# by the installed def, so the exec bit is POSIX belt-and-suspenders, not load-bearing.

# Root is three up from modules/autonomous/hooks/ (one level short puts the audit log
# at modules/autonomous/state/, outside the gitignore).
SHIP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AUDIT_LOG="$SHIP_DIR/state/mate-mcp-writes.jsonl"

# jq DEPENDENCY GUARD (fail CLOSED): every gate below parses the PreToolUse stdin
# with jq. Without jq the parse yields empty, the agent-type/command checks no-op,
# and the hook exits 0 — SILENT ZERO ENFORCEMENT. Refuse to run instead: exit 2
# (fail CLOSED) with a loud message. shipkit_init.py's preflight asserts jq is on
# PATH at install, so a correctly-installed ship never reaches this.
if ! command -v jq >/dev/null 2>&1; then
  echo "Blocked: ${0##*/} requires jq, which is not on PATH. Install jq (brew install jq / apt-get install jq / winget install jqlang.jq) — failing CLOSED to avoid silent zero enforcement of the Ship hooks." >&2
  exit 2
fi

INPUT=$(cat)
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')
[ "$AGENT_TYPE" != "ship-mate" ] && exit 0

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
case "$TOOL" in
  mcp__*) : ;;
  *) exit 0 ;;
esac

# --- Read vs write classification (default-READ; only known write-verbs are writes) ---
WRITE_RE='(add_message|post|publish|send|react|reply|create|update|edit|delete|remove|append|insert|set_|archive|unarchive|transition|assign|comment|move|merge|close|reopen|upload|write|patch|put_|destroy|mute|resolve|rename|duplicate|share|invite|kick|rotate)'

if ! echo "$TOOL" | grep -qiE "$WRITE_RE"; then
  exit 0   # READ — allow silently.
fi

# --- WRITE: audit-log + advise, then allow (confirm-gated model) ---
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
SUMMARY=$(echo "$INPUT" | jq -c '{ts:"'"$TS"'", tool:.tool_name, input:(.tool_input // {})}' 2>/dev/null | cut -c1-2000)
mkdir -p "$SHIP_DIR/state" 2>/dev/null
[ -n "$SUMMARY" ] && echo "$SUMMARY" >> "$AUDIT_LOG" 2>/dev/null

if [ "${SHIP_MATE_MCP_WRITE_BLOCK:-1}" != "0" ]; then
  echo "Blocked (Mate MCP write-block ON): $TOOL is an external write. Surface it for the Captain." >&2
  exit 2
fi

echo "⚠️  MCP WRITE via $TOOL — audit-logged. Confirm the Captain authorized this write in-conversation (Mate discipline rule)." >&2
exit 0
