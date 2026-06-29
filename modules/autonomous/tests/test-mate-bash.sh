#!/bin/bash
# Test suite for validate-mate-bash.sh (the Mate bright-line deny-list hook).
# Usage: ./modules/autonomous/tests/test-mate-bash.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/validate-mate-bash.sh"
PASS=0
FAIL=0

# check <expected-exit> <agent_type> <command>
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

# 2 = blocked, 0 = allowed
echo "=== Mate bright lines (BLOCK = exit 2) ==="
check 2 ship-mate 'gh pr merge 5'
check 2 ship-mate 'gh pr ready 5'
check 2 ship-mate 'gh pr comment 5 --body hi'
check 2 ship-mate 'gh pr review 5 --approve'
check 2 ship-mate 'gh issue create --title x'
check 2 ship-mate 'gh api -X POST /repos/o/r/issues'
check 2 ship-mate 'terraform apply'
check 2 ship-mate 'kubectl apply -f x.yaml'
check 2 ship-mate 'git push --force origin feat'
check 2 ship-mate 'git push origin main'

echo "=== Mate legitimate work (ALLOW = exit 0) ==="
check 0 ship-mate 'git commit -m "x"'
check 0 ship-mate 'git push origin feature-branch'
check 0 ship-mate 'gh pr create --draft --title x'
check 0 ship-mate 'gh pr view 5'
check 0 ship-mate 'gh pr list'
check 0 ship-mate 'python3 lib/status_writer.py tick 3 boot'
check 0 ship-mate 'devbox run rails test'

echo "=== Non-Mate agents pass through (ALLOW) ==="
check 0 ship-crew 'gh pr merge 5'
check 0 ''        'git push origin main'

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All mate-bash tests passed." || { echo "FAILURES."; exit 1; }
