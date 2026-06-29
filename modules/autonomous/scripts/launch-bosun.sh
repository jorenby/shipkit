#!/bin/bash
# launch-bosun.sh — (re)launch the standalone background Bosun.
#
# The MATE bootstraps the Bosun (more flexible, avoids races): ship-watch-start calls
# `launch-bosun.sh --ensure` on Mate boot. The Bosun owns the heartbeat — it runs
# `/loop`, its per-tick body lives in the ship-bosun agent def + bosun.md + the bosun-tick
# skill. It is read-only (disallowedTools Write/Edit/Task + validate-bosun-bash.sh).
#
# SANDBOX: running the agent in a sandbox is recommended (defense-in-depth on top of the
# read-only hook). On macOS, agent-safehouse.dev is a good option — point SANDBOX_RUN at
# its wrapper (a script that takes `claude <args>` and runs it sandboxed). If no wrapper
# is found, this falls back to bare `claude` (no sandbox).
#
# MCP: minimal/empty by default — the Bosun curates PRs via `gh` (bash, read-only). Set
# BOSUN_MCP to a config path if you give it read-MCP servers.
#
# Modes:
#   launch-bosun.sh --ensure   # launch ONLY if the heartbeat is stale/absent (idempotent)
#   launch-bosun.sh --force    # launch unconditionally
#   launch-bosun.sh --check    # report heartbeat freshness, no launch

set -uo pipefail
# This script lives at modules/autonomous/scripts/ -> ship root is 3 levels up.
SHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HB="$SHIP/state/bosun-heartbeat.log"
BOSUN_MCP="${BOSUN_MCP:-$HOME/.config/ship/bosun-mcp.json}"
STALE_SECS="${BOSUN_STALE_SECS:-2700}"   # 45m — Bosun cadence is ~25m, so >45m = not ticking
# Point SANDBOX_RUN at your sandbox wrapper (e.g. agent-safehouse.dev's). Absent → bare claude.
SANDBOX_RUN="${SHIP_SANDBOX_RUN:-$HOME/.config/sandbox-exec/run-sandboxed.sh}"
cd "$SHIP" || { echo "FATAL: no $SHIP"; exit 1; }
sbx() { if [ -x "$SANDBOX_RUN" ]; then "$SANDBOX_RUN" claude "$@"; else claude "$@"; fi; }

hb_age() {
  [ -f "$HB" ] || { echo 999999; return; }
  local now mt; now=$(date +%s); mt=$(stat -f %m "$HB" 2>/dev/null || stat -c %Y "$HB" 2>/dev/null || echo 0)
  echo $(( now - mt ))
}

mcp_args() { [ -f "$BOSUN_MCP" ] && printf '%s' "--strict-mcp-config --mcp-config $BOSUN_MCP"; }

do_launch() {
  echo "── launching bg Bosun ────────────────────────────"
  # shellcheck disable=SC2046
  printf '%s' "/loop" | sbx --bg --agent ship-bosun \
    --permission-mode bypassPermissions $(mcp_args)
  echo "launched (stdin-piped '/loop'). Verify: claude agents · tail state/bosun-heartbeat.log"
}

MODE="${1:---ensure}"
AGE=$(hb_age)
case "$MODE" in
  --check)
    if [ "$AGE" -lt "$STALE_SECS" ]; then echo "Bosun heartbeat FRESH (${AGE}s ago, <${STALE_SECS}s) — ticking."
    else echo "Bosun heartbeat STALE/absent (${AGE}s ago, >=${STALE_SECS}s) — NOT ticking."; fi
    [ -f "$HB" ] && tail -1 "$HB"
    ;;
  --ensure)
    if [ "$AGE" -lt "$STALE_SECS" ]; then
      echo "Bosun already ticking (heartbeat ${AGE}s ago) — no launch needed."
    else
      echo "Bosun heartbeat stale/absent (${AGE}s) — launching one."
      do_launch
    fi
    ;;
  --force) do_launch ;;
  *) echo "usage: launch-bosun.sh [--ensure|--force|--check]"; exit 2 ;;
esac
