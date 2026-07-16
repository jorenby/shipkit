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
# MODEL: set SHIP_MATE_MODEL to pick the launched Mate's model (absent → the CLI default).
# This is the seam the night-economy module's day/night rotation uses (economy model
# overnight, day model on the morning rotation, self-escalation via a fresh rotation).
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
  LOCKER="python3 modules/autonomous/scripts/mate-lock.py"
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

  # 5. bg worktree isolation OFF for the Mate (SELF-HEAL — same spirit as the +x heal).
  # The harness's bg worktree-isolation guard forces a bg agent's Edit/Write into an isolated
  # git worktree. That is WRONG for the Mate role: the Mate writes LIVE shared state
  # (queue.md, status.json, mate log, drops) that the Bosun, wake-monitor, and any status UI
  # read in real time — isolated writes make the ship look frozen to every other component.
  # F11 (first Windows autonomous rotation, 2026-07-02): this blocked a foreign bg-Mate's
  # boot outright — the guard even blocked the settings Write that disables it (the guard
  # reads settings dynamically, so healing here takes effect without a session restart).
  echo "[bg isolation]"
  if RES=$(python3 - <<'PY'
import json, os, sys
p = os.path.join('.claude', 'settings.json')
try:
    d = json.load(open(p))
except FileNotFoundError:
    d = {}
if d.get('worktree', {}).get('bgIsolation') == 'none':
    print('already set'); sys.exit(0)
d.setdefault('worktree', {})['bgIsolation'] = 'none'
os.makedirs('.claude', exist_ok=True)
with open(p, 'w') as f:
    json.dump(d, f, indent=2); f.write('\n')
print('patched in')
PY
  ); then ok "worktree.bgIsolation=none ($RES)"
  else bad ".claude/settings.json unreadable/unwritable — bg Mate writes will be worktree-isolated (fix by hand: {\"worktree\":{\"bgIsolation\":\"none\"}})"; fi

  echo "──────────────────────────────────────────────────"
  [ "$GO" -eq 1 ] && echo "PREFLIGHT: ✅ GO" || echo "PREFLIGHT: ❌ NO-GO (fix the ❌ above)"
}

mcp_args() { [ -f "$MCP_CFG" ] && printf '%s' "--strict-mcp-config --mcp-config $MCP_CFG"; }
model_args() { [ -n "${SHIP_MATE_MODEL:-}" ] && printf '%s' "--model $SHIP_MATE_MODEL"; }

launch_cmd() {
  echo "printf '%s' \"$MATE_PROMPT\" | claude --bg --agent ship-mate \\"
  echo "  --permission-mode bypassPermissions $(mcp_args) $(model_args)"
  echo "(wrap 'claude' in your sandbox wrapper for defense-in-depth — see SHIP_SANDBOX_RUN;"
  echo " set SHIP_MATE_MODEL to pick the model — the night-economy rotation seam.)"
}

do_launch_mate() {
  echo "── launching bg Mate ─────────────────────────────"
  [ -n "${SHIP_MATE_MODEL:-}" ] && echo "  model: $SHIP_MATE_MODEL (SHIP_MATE_MODEL)"
  # shellcheck disable=SC2046
  printf '%s' "$MATE_PROMPT" | sbx --bg --agent ship-mate \
    --permission-mode bypassPermissions $(mcp_args) $(model_args)
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
    # F10: harness TaskStop halts a Monitor's session re-invocation but does NOT kill the
    # detached OS process it spawned — the OUTGOING Mate's wake-monitor survives rotation as
    # an orphan. The incoming Mate's step-4 sweep self-heals, but sweep here too
    # (belt-and-braces, BEFORE the new Mate boots so we can't kill its fresh monitor).
    echo "── rotation: sweep outgoing monitor orphans ──────"
    if command -v pkill >/dev/null 2>&1; then
      pkill -f wake_monitor.py 2>/dev/null && echo "  killed orphaned wake_monitor" || echo "  no orphaned monitors"
    elif command -v powershell.exe >/dev/null 2>&1; then
      powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object {\$_.CommandLine -match 'wake_monitor'} | ForEach-Object {Stop-Process -Id \$_.ProcessId -Force}" 2>/dev/null
      echo "  swept via PowerShell (pkill absent — Git-Bash)"
    else
      echo "  ⚠ no pkill/powershell — sweep monitor orphans by hand if any"
    fi
    do_launch_mate
    echo "── rotation: outgoing lock ───────────────────────"
    LOCKER="python3 modules/autonomous/scripts/mate-lock.py"
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
