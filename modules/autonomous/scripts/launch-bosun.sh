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
# SHIP_ROOT env overrides (same seam as bosun_emit.py) — used by the test suite.
SHIP="${SHIP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
HB="$SHIP/state/bosun-heartbeat.log"
CURSOR="$SHIP/state/bosun-last-sweep.json"
BOSUN_MCP="${BOSUN_MCP:-$HOME/.config/ship/bosun-mcp.json}"

# STALENESS THRESHOLD — must comfortably EXCEED the Bosun's slowest self-pace.
# The heartbeat is only touched at tick time, so right before a quiet tick its age
# approaches the full scheduled delay. A threshold TIGHTER than the real cadence makes
# --ensure launch a duplicate at every Mate boot/rotation — TWO heartbeat owners,
# each clobbering the other's sweep cursor (seen live: an hourly-paced Bosun vs a
# ~45m threshold double-launched every morning rotation; see DECISIONS.md).
# Defense: the Bosun DECLARES its pace — bosun-tick writes the scheduled delay as
# `pace_secs` in the cursor JSON — and --ensure/--check use
#   effective threshold = max(BOSUN_STALE_SECS, 2 × declared pace_secs).
# The 2× margin absorbs a slow/hot tick. BOSUN_STALE_SECS stays the floor for a
# fresh ship with no cursor yet (default 2700s vs the doctrine's 1800s max quiet pace).
STALE_SECS="${BOSUN_STALE_SECS:-2700}"
declared_pace() {  # prints pace_secs from the cursor, or 0 (absent/unreadable/non-numeric)
  [ -f "$CURSOR" ] || { echo 0; return; }
  python3 - "$CURSOR" 2>/dev/null <<'PY' || echo 0
import json, sys
try:
    v = json.load(open(sys.argv[1])).get("pace_secs", 0)
    print(int(v) if isinstance(v, (int, float)) and v > 0 else 0)
except Exception:
    print(0)
PY
}
PACE=$(declared_pace)
[ "$PACE" -gt 0 ] 2>/dev/null && [ $(( PACE * 2 )) -gt "$STALE_SECS" ] && STALE_SECS=$(( PACE * 2 ))
# Point SANDBOX_RUN at your sandbox wrapper (e.g. agent-safehouse.dev's). Absent → bare claude.
SANDBOX_RUN="${SHIP_SANDBOX_RUN:-$HOME/.config/sandbox-exec/run-sandboxed.sh}"
cd "$SHIP" || { echo "FATAL: no $SHIP"; exit 1; }
sbx() { if [ -x "$SANDBOX_RUN" ]; then "$SANDBOX_RUN" claude "$@"; else claude "$@"; fi; }

hb_age() {
  [ -f "$HB" ] || { echo 999999; return; }
  # GNU-first (stat -c), BSD fallback (stat -f). Order matters: GNU `stat -f %m` prints a
  # filesystem-status block to STDOUT before failing, poisoning $( ... || ... ) capture — while
  # BSD stat has no -c and fails silently. GNU-first is the only order safe on both platforms
  # (Linux, Git Bash, macOS). Finding #9, Windows migration 2026-07-02: the reversed order made
  # hb_age() always-STALE on Git Bash → --ensure spawned a duplicate Bosun every Mate boot.
  # General rule: `$(a || b)` fallback chains are only safe when a's failure is stdout-silent.
  local now mt; now=$(date +%s); mt=$(stat -c %Y "$HB" 2>/dev/null || stat -f %m "$HB" 2>/dev/null || echo 0)
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
