#!/bin/bash
# Test suite for launch-bosun.sh — the --ensure/--check staleness logic.
# Usage: ./modules/autonomous/tests/test-launch-bosun.sh
#
# Live-fires the script's --check mode (report only, never launches) against a temp
# SHIP_ROOT with fabricated heartbeat ages + cursor pace declarations. Guards the
# double-launch class from DECISIONS.md ("The --ensure staleness threshold must
# outlast the Bosun's slowest pace"): a threshold tighter than the Bosun's real
# self-pace makes every Mate rotation spawn a duplicate heartbeat owner.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$SCRIPT_DIR/../scripts/launch-bosun.sh"
PASS=0
FAIL=0

# check <expected: FRESH|STALE> <hb-age-secs|none> <cursor-json|none> [BOSUN_STALE_SECS]
check() {
  local want="$1" hb_age="$2" cursor="$3" stale_env="${4:-}"
  local root out got
  root=$(mktemp -d -t launch-bosun-test.XXXXXX)
  mkdir -p "$root/state"
  if [ "$hb_age" != "none" ]; then
    echo "tick" > "$root/state/bosun-heartbeat.log"
    python3 - "$root/state/bosun-heartbeat.log" "$hb_age" <<'PY'
import os, sys, time
p, age = sys.argv[1], int(sys.argv[2])
t = time.time() - age
os.utime(p, (t, t))
PY
  fi
  if [ "$cursor" != "none" ]; then
    printf '%s\n' "$cursor" > "$root/state/bosun-last-sweep.json"
  fi
  if [ -n "$stale_env" ]; then
    out=$(SHIP_ROOT="$root" BOSUN_STALE_SECS="$stale_env" bash "$LAUNCHER" --check 2>&1)
  else
    out=$(SHIP_ROOT="$root" bash "$LAUNCHER" --check 2>&1)
  fi
  got="STALE"
  echo "$out" | grep -q "FRESH" && got="FRESH"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "  FAIL want=$want got=$got (hb_age=$hb_age cursor=$cursor env=${stale_env:-—})"
    echo "$out" | sed 's/^/    | /'
  fi
  rm -rf "$root"
}

echo "=== Default threshold (2700s), no pace declared ==="
check STALE none none                 # no heartbeat at all
check FRESH 60 none                   # just ticked
check FRESH 2000 none                 # inside the default window
check STALE 3000 none                 # past the default window

echo "=== Declared pace widens the threshold (max(default, 2*pace_secs)) ==="
# The double-launch class: hourly-paced Bosun (3600s), heartbeat legitimately ~1h old.
# A fixed 2700s threshold calls this dead; the declared pace must keep it FRESH.
check FRESH 3000 '{"prs":[1],"pace_secs":3600,"_updated":"x"}'
check FRESH 7000 '{"prs":[1],"pace_secs":3600,"_updated":"x"}'   # still < 2*3600
check STALE 7300 '{"prs":[1],"pace_secs":3600,"_updated":"x"}'   # past 2*pace — really dead
# A SHORT declared pace must not TIGHTEN the threshold below the default floor.
check FRESH 2000 '{"pace_secs":600}'
check STALE 3000 '{"pace_secs":600}'

echo "=== BOSUN_STALE_SECS env floor still respected ==="
check FRESH 3000 none 4000
check STALE 5000 none 4000
check FRESH 7000 '{"pace_secs":3600}' 4000    # max(4000, 7200) = 7200

echo "=== Degenerate cursors fall back to the default threshold (no crash) ==="
check STALE 3000 'not json at all'
check STALE 3000 '{"pace_secs":"abc"}'
check STALE 3000 '{"pace_secs":-5}'
check STALE 3000 '[1,2,3]'
check FRESH 2000 'not json at all'

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All launch-bosun tests passed." || { echo "FAILURES."; exit 1; }
