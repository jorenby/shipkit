#!/bin/bash
# Test suite for validate-bosun-bash.sh (the Bosun read-only allow-list hook).
# Usage: ./modules/autonomous/tests/test-bosun-bash.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/validate-bosun-bash.sh"
PASS=0
FAIL=0

check() {
  local want="$1" agent="$2" cmd="$3"
  local json got
  json=$(jq -n --arg a "$agent" --arg c "$cmd" '{agent_type:$a, tool_input:{command:$c}}')
  echo "$json" | bash "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "  FAIL want=$want got=$got [$agent] $cmd"
  fi
}

echo "=== Bosun writes blocked except bosun_emit.py (BLOCK = exit 2) ==="
check 2 ship-bosun 'git commit -m x'
check 2 ship-bosun 'gh pr comment 5 --body hi'
check 2 ship-bosun 'gh api -X POST /repos/o/r/issues/5/comments -f body=x'
check 2 ship-bosun 'gh api --method PUT /repos/o/r/pulls/5/merge'
check 2 ship-bosun 'rm somefile'
check 2 ship-bosun 'echo hi > state/foo.txt'
check 2 ship-bosun 'echo hi | tee state/foo.txt'
check 2 ship-bosun 'cat queue.md'
check 2 ship-bosun 'curl -X POST https://example.com'
check 2 ship-bosun 'sed -i s/a/b/ file'

echo "=== Bosun allow-list (ALLOW = exit 0) ==="
check 0 ship-bosun 'python3 modules/autonomous/scripts/bosun_emit.py heartbeat alive'
check 0 ship-bosun 'python3 modules/autonomous/scripts/bosun_emit.py drop t f a'
check 0 ship-bosun 'gh pr view 5'
check 0 ship-bosun 'gh pr checks 5'
check 0 ship-bosun 'gh search prs'
check 0 ship-bosun 'gh api /repos/o/r/pulls/5'
check 0 ship-bosun 'git log --oneline'
check 0 ship-bosun 'grep -r foo docs/'
check 0 ship-bosun 'cat state/status.json'
check 0 ship-bosun 'echo hi 2>/dev/null'
check 0 ship-bosun 'curl https://example.com'

echo "=== Non-Bosun agents pass through (ALLOW) ==="
check 0 ship-mate 'git commit -m x'
check 0 ''        'rm somefile'

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All bosun-bash tests passed." || { echo "FAILURES."; exit 1; }
