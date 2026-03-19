#!/bin/bash
# Test suite for validate-crew-bash.sh
# Usage: ./tests/test-crew-bash.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../scripts/validate-crew-bash.sh"
PASS=0
FAIL=0

check() {
  local expected="$1" cmd="$2"
  local json
  json=$(jq -n --arg cmd "$cmd" '{"tool_input":{"command":$cmd}}')
  local result
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
check ALLOW 'git diff HEAD~1'
check ALLOW 'git log --oneline -5'
check ALLOW 'git show HEAD'
check ALLOW 'git branch -a'
check ALLOW 'git checkout -b test-branch'
check ALLOW 'git fetch origin'
check ALLOW 'git stash list'
check ALLOW 'git rev-parse HEAD'

echo "=== Git write ops (BLOCK) ==="
check BLOCK 'git commit -m "test"'
check BLOCK 'git push origin main'
check BLOCK 'git add .'
check BLOCK 'git add -A'
check BLOCK 'git reset --hard'
check BLOCK 'git revert HEAD'
check BLOCK 'git merge feature'
check BLOCK 'git rebase main'
check BLOCK 'git cherry-pick abc123'
check BLOCK 'git clean -fd'

echo "=== Dev tools (ALLOW) ==="
check ALLOW 'npm test'
check ALLOW 'npm run build'
check ALLOW 'npx jest'
check ALLOW 'make build'
check ALLOW 'rake spec'
check ALLOW 'bundle exec rspec'
check ALLOW 'yarn test'

echo "=== File ops (ALLOW) ==="
check ALLOW 'cat foo.txt'
check ALLOW 'ls -la'
check ALLOW 'head -20 file.txt'
check ALLOW 'find . -name "*.js"'
check ALLOW 'grep -r "pattern" src/'
check ALLOW 'mkdir -p test/dir'
check ALLOW 'rm foo.txt'
check ALLOW 'cp src/a.js src/b.js'
check ALLOW 'mv old.js new.js'

echo "=== Destructive rm (BLOCK) ==="
check BLOCK 'rm -rf /'
check BLOCK 'rm -rf src/'
check BLOCK 'rm -r foo'
check BLOCK 'rm -fr bar'
check BLOCK 'rm --recursive dir'

echo "=== queue.md (BLOCK) ==="
check BLOCK 'cat queue.md'
check BLOCK 'echo "test" > queue.md'

echo "=== gh ops (BLOCK — not on allow-list) ==="
check BLOCK 'gh pr list'
check BLOCK 'gh pr view 123'
check BLOCK 'gh issue list'
check BLOCK 'gh pr create --title "test"'
check BLOCK 'gh pr comment 123 --body "test"'
check BLOCK 'gh pr merge 123'
check BLOCK 'gh issue create --title "test"'
check BLOCK 'gh issue close 123'

echo "=== curl ==="
check ALLOW 'curl https://example.com'
check ALLOW 'curl -s https://api.example.com/data'
check BLOCK 'curl -X POST https://api.example.com/data'
check BLOCK 'curl -X DELETE https://api.example.com/resource'
check BLOCK 'curl --data "foo=bar" https://api.example.com'

echo "=== Pipes and chains (ALLOW) ==="
check ALLOW 'git log --oneline | head -5'
check ALLOW 'cat file.txt | grep pattern | wc -l'
check ALLOW 'ls -la && echo "done"'

echo "=== Pipes and chains (BLOCK) ==="
check BLOCK 'echo "test" && git push'
check BLOCK 'npm test && git commit -m "pass"'

echo ""
echo "---"
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All tests passed." || exit 1
