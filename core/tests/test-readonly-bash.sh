#!/bin/bash
# Test suite for validate-readonly-bash.sh (the ship-lookout / ship-reviewer read-only hook).
# Usage: ./core/tests/test-readonly-bash.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/validate-readonly-bash.sh"
PASS=0
FAIL=0

check() {
  local expected="$1" cmd="$2"
  local json result
  json=$(jq -n --arg cmd "$cmd" '{"tool_input":{"command":$cmd}}')
  if echo "$json" | bash "$HOOK" >/dev/null 2>&1; then
    result="ALLOW"
  else
    result="BLOCK"
  fi
  if [ "$result" = "$expected" ]; then
    PASS=$((PASS + 1))
  else
    printf "  FAIL: expected %-5s got %-5s  %s\n" "$expected" "$result" "$cmd"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Git read ops (ALLOW) ==="
check ALLOW 'git status'
check ALLOW 'git log --oneline -5'
check ALLOW 'git diff HEAD~1'
check ALLOW 'git show HEAD'
check ALLOW 'git branch -a'
check ALLOW 'git rev-parse HEAD'

echo "=== Git read ops via -C <path> (ALLOW — multi-repo ships, Finding D) ==="
check ALLOW 'git -C /path/to/repo status'
check ALLOW 'git -C ../other-repo log --oneline -5'
check ALLOW 'git -C /a/b diff HEAD~1'
check ALLOW 'git -C repo show HEAD'

echo "=== Git write ops (BLOCK) ==="
check BLOCK 'git commit -m "test"'
check BLOCK 'git push origin main'
check BLOCK 'git add .'
check BLOCK 'git reset --hard'
check BLOCK 'git merge feature'

echo "=== Git write ops via -C <path> (BLOCK — still hits default-deny) ==="
check BLOCK 'git -C /path/to/repo commit -m x'
check BLOCK 'git -C ../other push origin main'
check BLOCK 'git -C repo reset --hard'

echo "=== PR triage read tools (ALLOW) ==="
check ALLOW 'gh pr view 5'
check ALLOW 'gh pr diff 5'
check ALLOW 'gh pr checks 5'
check ALLOW 'pr-buddy list'
check ALLOW 'gh api /repos/o/r/pulls/5'

echo "=== Mutations blocked (BLOCK) ==="
check BLOCK 'gh pr comment 5 --body hi'
check BLOCK 'gh pr approve 5'
check BLOCK 'gh pr merge 5'
check BLOCK 'rm somefile'
check BLOCK 'cat queue.md'
check BLOCK 'curl -X POST https://example.com'

echo "=== File inspection / search (ALLOW) ==="
check ALLOW 'ls -la'
check ALLOW 'cat state/status.json'
check ALLOW 'grep -r foo docs/'
check ALLOW 'rg pattern'
check ALLOW 'curl https://example.com'

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All readonly-bash tests passed." || { echo "FAILURES."; exit 1; }
