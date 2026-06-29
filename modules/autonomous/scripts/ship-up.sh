#!/bin/bash
# ship-up.sh — launch / verify the standalone background Ship agents.
#
# The bg-launch recipe is gotcha-laden (stdin-piped prompt, chmod +x hooks, MCP config,
# mate-lock handoff) — too easy to get wrong by hand each rotation. This is the substrate.
#
#   ship-up.sh                 # --check (DEFAULT, safe): preflight + report, NO launch
#   ship-up.sh --launch-mate   # cold-launch a bg Mate (lock must be free/stale)
#   ship-up.sh --rotate-mate   # launch a REPLACEMENT bg Mate, then release the outgoing
#                              #   lock (set SHIP_OUTGOING_LOCK_ID=<id> so it can release it)
#
# The Mate boots EVENT-DRIVEN via /ship-watch-start (which itself bootstraps the Bosun via
# launch-bosun.sh --ensure). It does NOT run /loop — the Bosun owns the heartbeat.
#
# SANDBOX: running the agent in a sandbox is recommended (defense-in-depth on top of the
# bright-line hooks). On macOS, agent-safehouse.dev is a good option — point SHIP_SANDBOX_RUN
# at its wrapper. Absent → bare `claude` (no sandbox).
#
# Must be run by the Captain (a fresh terminal) OR the Mate — the crew hook blocks `claude`.

set -uo pipefail
# This script lives at modules/autonomous/scripts/ -> ship root is 3 levels up.
SHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AUTO="$SHIP/modules/autonomous"
MCP_CFG="${SHIP_MATE_MCP:-$HOME/.config/ship/mate-mcp.json}"
MATE_PROMPT="/ship-watch-start"
SANDBOX_RUN="${SHIP_SANDBOX_RUN:-$HOME/.config/sandbox-exec/run-sandboxed.sh}"
sbx() { if [ -x "$SANDBOX_RUN" ]; then "$SANDBOX_RUN" claude "$@"; else claude "$@"; fi; }
# Hooks live in two tiers: autonomous-only + the always-on crew hook (core/hooks/).
# Each entry is "<hook-dir>/<file>" relative to $SHIP.
HOOKS=(
  modules/autonomous/hooks/validate-mate-bash.sh
  modules/autonomous/hooks/validate-mate-mcp.sh
  modules/autonomous/hooks/validate-bosun-bash.sh
  core/hooks/validate-crew-bash.sh
)
cd "$SHIP" || { echo "FATAL: no $SHIP"; exit 1; }

GO=1
note() { printf '  %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; GO=0; }
ok()   { printf '  ✅ %s\n' "$*"; }

preflight() {
  echo "── ship-up preflight ─────────────────────────────"

  # 1. Hooks executable (SELF-HEAL — a non-exec hook fails OPEN = silent zero enforcement).
  echo "[hooks +x]"
  for h in "${HOOKS[@]}"; do
    f="$SHIP/$h"
    if [ ! -f "$f" ]; then bad "$h MISSING"; continue; fi
    if [ ! -x "$f" ]; then chmod +x "$f" && note "chmod +x $h (was non-exec — fixed)"; fi
    [ -x "$f" ] && ok "$h"
  done

  # 2. MCP config — optional. PR-1 can run empty-MCP; warn (don't fail) if absent.
  echo "[mcp config]"
  if [ -f "$MCP_CFG" ] && python3 -c "import json,sys; json.load(open('$MCP_CFG'))" 2>/dev/null; then
    n=$(python3 -c "import json; d=json.load(open('$MCP_CFG')); print(len(d.get('mcpServers',{})))" 2>/dev/null)
    ok "mate-mcp.json valid ($n servers)"
  else
    note "no MCP config at $MCP_CFG — launching empty-MCP (fine for PR-1 / a fresh ship)."
  fi

  # 3. Lock cycle works.
  echo "[lock]"
  if command -v ruby >/dev/null 2>&1 && [ -f "$AUTO/scripts/mate-lock.rb" ]; then
    LOCKER="ruby modules/autonomous/scripts/mate-lock.rb"
  else
    LOCKER="python3 modules/autonomous/scripts/mate-lock.py"
  fi
  if $LOCKER status >/dev/null 2>&1 || [ $? -eq 1 ]; then
    LOCKLINE=$($LOCKER status 2>&1 | grep -E "STATE|Holder|Freshness" | tr '\n' ' ')
    ok "mate-lock runs ($LOCKER) — $LOCKLINE"
  else
    bad "mate-lock errored ($LOCKER)"
  fi

  # 4. Sandbox launcher available (recommended, not required).
  echo "[launcher]"
  if [ -x "$SANDBOX_RUN" ]; then ok "sandbox wrapper $SANDBOX_RUN"
  elif command -v claude >/dev/null 2>&1; then note "no sandbox wrapper — falling back to bare 'claude' (sandbox recommended: agent-safehouse.dev)"
  else bad "no launcher (no sandbox wrapper + 'claude' not on PATH)"; fi

  echo "──────────────────────────────────────────────────"
  [ "$GO" -eq 1 ] && echo "PREFLIGHT: ✅ GO" || echo "PREFLIGHT: ❌ NO-GO (fix the ❌ above)"
}

mcp_args() { [ -f "$MCP_CFG" ] && printf '%s' "--strict-mcp-config --mcp-config $MCP_CFG"; }

launch_cmd() {
  echo "printf '%s' \"$MATE_PROMPT\" | claude --bg --agent ship-mate \\"
  echo "  --permission-mode bypassPermissions $(mcp_args)"
  echo "(wrap 'claude' in your sandbox wrapper for defense-in-depth — see SHIP_SANDBOX_RUN.)"
}

do_launch_mate() {
  echo "── launching bg Mate ─────────────────────────────"
  # shellcheck disable=SC2046
  printf '%s' "$MATE_PROMPT" | sbx --bg --agent ship-mate \
    --permission-mode bypassPermissions $(mcp_args)
  echo "launched (stdin-piped prompt). Verify with: claude agents"
}

MODE="${1:---check}"
case "$MODE" in
  --check)
    preflight
    echo; echo "Bosun: the MATE bootstraps it on boot (ship-watch-start → launch-bosun.sh --ensure)."
    "$AUTO/scripts/launch-bosun.sh" --check 2>/dev/null | sed 's/^/  /'
    echo; echo "Mate launch command (--launch-mate / --rotate-mate runs this):"
    launch_cmd
    ;;
  --launch-mate)
    preflight; [ "$GO" -eq 1 ] || { echo "Refusing to launch on NO-GO."; exit 1; }
    do_launch_mate
    ;;
  --rotate-mate)
    preflight; [ "$GO" -eq 1 ] || { echo "Refusing to rotate on NO-GO."; exit 1; }
    do_launch_mate
    echo "── rotation: outgoing lock ───────────────────────"
    LOCKER=$(command -v ruby >/dev/null 2>&1 && [ -f "$AUTO/scripts/mate-lock.rb" ] && echo "ruby modules/autonomous/scripts/mate-lock.rb" || echo "python3 modules/autonomous/scripts/mate-lock.py")
    if [ -n "${SHIP_OUTGOING_LOCK_ID:-}" ]; then
      sleep 8
      $LOCKER release "$SHIP_OUTGOING_LOCK_ID" --force 2>&1 | sed 's/^/  /'
      echo "  → outgoing lock released; the new Mate can now acquire."
    else
      echo "  SHIP_OUTGOING_LOCK_ID not set — the OUTGOING Mate must release its lock"
      echo "  ($LOCKER release <its-id>) so the new one can acquire."
    fi
    ;;
  *) echo "usage: ship-up.sh [--check|--launch-mate|--rotate-mate]"; exit 2 ;;
esac
