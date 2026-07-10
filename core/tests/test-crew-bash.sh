#!/bin/bash
# Test suite for validate-crew-bash.sh
# Usage: ./core/tests/test-crew-bash.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/validate-crew-bash.sh"
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

echo "=== Git read ops via -C <path> (ALLOW — multi-repo ships) ==="
check ALLOW 'git -C /path/to/repo status'
check ALLOW 'git -C ../other-repo log --oneline -5'
check ALLOW 'git -C /a/b diff HEAD~1'
check ALLOW 'git -C repo show HEAD'

echo "=== Git write ops via -C <path> (BLOCK — still hits default-deny) ==="
check BLOCK 'git -C /path/to/repo commit -m x'
check BLOCK 'git -C ../other push origin main'
check BLOCK 'git -C repo reset --hard'

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

echo "=== FALSE POSITIVES FIXED: trigger tokens as DATA (ALLOW) ==="
# Tokens inside quoted args of data-arg commands are prose/paths, not invocations.
check ALLOW 'grep -rn "git push" docs/'
check ALLOW 'grep -r "git commit -m" src/'
check ALLOW 'echo "git push is handled by the Mate"'
check ALLOW 'echo "rm -rf is blocked for crew"'
check ALLOW 'cat notes/git-push-runbook.md'
# Quoted alternation pipes no longer fragment the segment (reviewer instance #3 class)
check ALLOW 'grep -E "(activate|send_test)" ui/server.ts'
check ALLOW "rg 'activate|send_test|x-mcp-action' -n src/"
check ALLOW 'grep -E "a|b" file.txt | wc -l'
# Quoted separators stay one segment
check ALLOW 'echo "a && b; c"'
check ALLOW 'grep "foo; git push bar" README.md'

echo "=== TRUE POSITIVES PRESERVED: wrappers / env-prefix / substitution (BLOCK) ==="
check BLOCK "bash -c 'git push origin main'"
check BLOCK 'sh -c "git commit -m x"'
check BLOCK 'FOO=1 git push'
check BLOCK 'env FOO=1 git push origin feat'
check BLOCK 'echo ok; git push'
check BLOCK 'true && git -C /repo commit -m y'
check BLOCK 'xargs git push'
check BLOCK 'echo "$(git push)"'
check BLOCK 'echo `git commit -m x`'
check BLOCK 'git log | xargs rm -rf'
check BLOCK 'find . -name "*.txt" | xargs rm -r'

echo "=== TRUE POSITIVES PRESERVED: git writes behind options (BLOCK) ==="
check BLOCK 'git -C ../other-repo push origin feat'
check BLOCK 'git -c user.name=x commit -m y'
check BLOCK 'git --git-dir=/x/.git push origin feat'
check BLOCK 'git stash drop'
check BLOCK 'git stash pop'

echo "=== Recursive rm tightened (BLOCK — separated flags now caught) ==="
check BLOCK 'rm -v -r somedir'
check BLOCK 'rm -f -R somedir'
check BLOCK 'ls && rm -rf dir'
check ALLOW 'rm -f file.txt'
check ALLOW 'rm river.txt'

echo "=== queue.md still blocked ANYWHERE, even quoted ==="
check BLOCK 'echo "queue.md"'
check BLOCK 'grep foo queue.md'

echo "=== Edge cases: multiline / heredoc / unbalanced quotes / || chains ==="
# Multiline command — each line is a segment
check BLOCK 'git status
git push origin feat'
check ALLOW 'git status
git log --oneline'
# Heredoc-smuggled op still blocks (body lines are scanned; fail-closed)
check BLOCK 'bash <<EOF
git push origin main
EOF'
# Unbalanced quote → naive-split fallback → over-block (fail-closed)
check BLOCK 'echo "unclosed && git push'
# || chains split too
check BLOCK 'grep -q x file || git push'
check ALLOW 'grep -q x file || echo missing'
# Quoted separators + a REAL op after still block
check BLOCK 'echo "a;b" && git add .'

echo "=== W2 B1: pipe-into-interpreter stdin smuggles (BLOCK) ==="
# The payload rides as DATA in the producing segment; a bare interpreter
# segment triggers a raw deny scan of the WHOLE command.
check BLOCK "echo 'git push origin main' | sh"
check BLOCK "echo 'git commit -m x' | bash"
check BLOCK 'printf "rm -rf /tmp/x\n" | python3'
check BLOCK "echo 'git push origin main' | env bash"
check BLOCK "echo 'gh pr merge 5' | zsh"
# Interpreters stay usable when nothing hot rides the pipe
check ALLOW 'bash scripts/run_tests.sh'
check ALLOW 'echo hello | bash format.sh'
check ALLOW "bash -c 'ls -la'"
check ALLOW 'python3 test_scripts/check.py'

echo "=== W2 B2: backslash-newline continuations rejoin (BLOCK) ==="
check BLOCK 'git pu\
sh origin main'
check BLOCK 'rm -r\
f /tmp/x'
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

echo ""
echo "---"
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All tests passed." || exit 1
