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

echo "=== FALSE POSITIVES FIXED: reviewer tokens as DATA (ALLOW — instance #3) ==="
# Quoted alternation pipes no longer fragment the segment
check ALLOW 'grep -E "(activate|send_test)" ui/server.ts'
check ALLOW "rg 'activate|send_test|x-mcp-action' -n ui/"
check ALLOW 'grep -rn "x-mcp-action" src/'
check ALLOW 'grep -E "dispatch|activate" -n lib/'
check ALLOW 'cat docs/dispatch-bands.md'
check ALLOW 'curl -s "http://localhost:3888/api?action=send_test"'
# Trigger tokens inside quoted args of data-arg commands are prose, not invocations
check ALLOW 'grep -n "git push" README.md'
check ALLOW 'echo "git commit is blocked for reviewers"'
check ALLOW 'grep "rm -rf" docs/runbook.md'
check ALLOW 'echo "a && b; c"'

echo "=== TRUE POSITIVES PRESERVED: compounds / wrappers / options (BLOCK) ==="
check BLOCK 'ls && git commit -m x'
check BLOCK 'echo ok; git push origin feat'
check BLOCK 'git -c user.name=x commit -m y'
check BLOCK 'git --git-dir=/x/.git push origin feat'
check BLOCK "bash -c 'git push origin main'"
check BLOCK 'sh -c "rm -rf /"'
check BLOCK 'FOO=1 git commit -m x'
check BLOCK 'env FOO=1 git push'
check BLOCK 'echo "$(git commit -m x)"'
check BLOCK 'echo `rm somefile`'
check BLOCK 'cat f | xargs rm'
check BLOCK 'ls; rm somefile'
check BLOCK 'gh pr view 5 && gh pr comment 5 --body hi'
check BLOCK 'gh pr edit 5 --add-label x'

echo "=== queue.md still blocked ANYWHERE, even quoted ==="
check BLOCK 'echo "queue.md"'
check BLOCK 'grep foo queue.md'

echo "=== W2 B1 class: pipes into interpreters netted by default-deny (BLOCK) ==="
# Readonly agents get no bare-interpreter whole-scan — interpreters simply are
# not on the allow-list, so the sink segment itself dies (verified here per the
# W2 review: default-deny is the net).
check BLOCK "echo 'git push origin main' | bash"
check BLOCK "echo 'rm -rf /' | sh"
check BLOCK 'printf "gh pr merge 5\n" | python3'

echo "=== W2 B2: backslash-newline continuations rejoin (BLOCK) ==="
check BLOCK 'git pu\
sh origin main'
check BLOCK 'cat que\
ue.md'
# Escaped backslash before newline is a REAL boundary, not a continuation
check ALLOW 'echo foo\\
git status'

echo "=== W2 N2: \$'...' ANSI-C quoting forces the raw scan (BLOCK) ==="
check BLOCK "git push origin \$'main'"

echo "=== W2 N3: zero-segment commands fail CLOSED (BLOCK) ==="
check BLOCK ';'
check BLOCK ' ; ; '

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All readonly-bash tests passed." || { echo "FAILURES."; exit 1; }
