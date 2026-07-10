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
check 0 ship-bosun 'git -C /path/to/repo log --oneline'
check 0 ship-bosun 'git -C ../other-repo status'
check 2 ship-bosun 'git -C /path/to/repo commit -m x'
check 0 ship-bosun 'grep -r foo docs/'
check 0 ship-bosun 'cat state/status.json'
check 0 ship-bosun 'echo hi 2>/dev/null'
check 0 ship-bosun 'curl https://example.com'

echo "=== FALSE POSITIVES FIXED: trigger tokens as DATA (ALLOW = exit 0) ==="
# Quoted alternation pipes no longer fragment the segment (reviewer instance #3 class)
check 0 ship-bosun 'grep -E "(activate|send_test)" ui/server.ts'
check 0 ship-bosun "rg 'activate|send_test|x-mcp-action' -n ui/"
check 0 ship-bosun 'grep -rn "x-mcp-action" src/'
# Trigger tokens inside quoted args of data-arg commands are prose, not invocations
check 0 ship-bosun 'grep -n "git push" README.md'
check 0 ship-bosun 'echo "git commit is blocked for the bosun"'
check 0 ship-bosun 'grep "rm -rf" docs/runbook.md'
check 0 ship-bosun 'echo "a && b; c"'
check 0 ship-bosun 'grep "gh pr comment" logs/mate/2026-07-02.md'

echo "=== TRUE POSITIVES PRESERVED: compounds / wrappers / options (BLOCK) ==="
check 2 ship-bosun 'ls && git commit -m x'
check 2 ship-bosun 'echo ok; git push origin feat'
check 2 ship-bosun 'git -c user.name=x commit -m y'
check 2 ship-bosun 'git --git-dir=/x/.git push origin feat'
check 2 ship-bosun "bash -c 'git push origin main'"
check 2 ship-bosun 'sh -c "rm -rf /"'
check 2 ship-bosun 'FOO=1 git commit -m x'
check 2 ship-bosun 'env FOO=1 git push'
check 2 ship-bosun 'echo "$(git commit -m x)"'
check 2 ship-bosun 'echo `rm somefile`'
check 2 ship-bosun 'cat f | xargs rm'
check 2 ship-bosun 'ls; rm somefile'
check 2 ship-bosun 'gh pr view 5 && gh pr comment 5 --body hi'
check 2 ship-bosun 'gh api /repos/o/r/pulls && gh api -X POST /repos/o/r/issues'
check 2 ship-bosun 'echo hi > state/foo.txt && ls'
check 2 ship-bosun 'python3 modules/autonomous/scripts/bosun_emit.py drop t f a && rm state/x'
check 2 ship-bosun 'echo "queue.md"'

echo "=== Redirect/tee guards stay whole-command + quote-blind (BLOCK — by design) ==="
check 2 ship-bosun 'grep "a > b" file'
check 2 ship-bosun 'echo "x | tee f"'

echo "=== W2 B1 class: pipes into interpreters netted by default-deny (BLOCK) ==="
# The Bosun gets no bare-interpreter whole-scan — interpreters are not on the
# allow-list (only the path-locked bosun_emit.py form), so the sink segment
# itself dies (verified here per the W2 review: default-deny is the net).
check 2 ship-bosun "echo 'git push origin main' | bash"
check 2 ship-bosun "echo 'rm -rf /' | python3"
check 2 ship-bosun "echo 'gh pr comment 5 --body hi' | sh"

echo "=== W2 N1: gh api tightened (--method= and implicit-POST fields) ==="
check 2 ship-bosun 'gh api --method=POST /repos/o/r/issues'
check 2 ship-bosun 'gh api --method=PATCH /repos/o/r/pulls/5'
check 2 ship-bosun 'gh api repos/o/r/issues -f title=hi'
check 2 ship-bosun 'gh api repos/o/r/issues --field title=hi'
check 2 ship-bosun 'gh api graphql --raw-field query=@m.graphql'
check 2 ship-bosun 'gh api repos/o/r/issues --input body.json'
check 0 ship-bosun 'gh api repos/o/r/pulls/5 --paginate'

echo "=== W4: gh api pflag ATTACHED shorthand (-ftitle=... was a live bypass) ==="
check 2 ship-bosun 'gh api /repos/o/r/issues -ftitle=hello'
check 2 ship-bosun 'gh api /repos/o/r/issues -Fbody=@payload'
check 2 ship-bosun 'gh api graphql -fquery=mutation{m}'
check 2 ship-bosun 'gh api -ftitle=x /repos/o/r/issues'
check 2 ship-bosun 'gh api /repos/o/r/issues -f'
# pflag combined clusters: -i (--include) is gh api's ONLY boolean shorthand, so
# -i-prefixed clusters reach -f/-F/-X (verified live: gh 2.79.0 parses -iftitle=x
# as --include --raw-field title=x, -iXPOST as --include --method POST)
check 2 ship-bosun 'gh api /repos/o/r/issues -iftitle=pwn'
check 2 ship-bosun 'gh api /repos/o/r/issues -iFbody=@payload'
check 2 ship-bosun 'gh api /repos/o/r/issues -iiftitle=x'
check 2 ship-bosun 'gh api /repos/o/r/issues -if title=x'
check 2 ship-bosun 'gh api /repos/o/r/issues -if=title=x'
check 2 ship-bosun 'gh api -iXPOST /repos/o/r/issues'
check 2 ship-bosun 'gh api -iX POST /repos/o/r/issues'
# Reads stay allowed: bare -i, cluster ending in GET, non-gh -f usage
check 0 ship-bosun 'gh api /repos/o/r/pulls --method GET'
check 0 ship-bosun 'gh api -i /repos/o/r/pulls/5'
check 0 ship-bosun 'gh api -iX GET /repos/o/r/pulls'
check 0 ship-bosun 'gh pr view 12'
check 0 ship-bosun 'grep -f patterns file'

echo "=== W2 B2: backslash-newline continuations rejoin (BLOCK) ==="
check 2 ship-bosun 'git pu\
sh origin feat'
check 2 ship-bosun 'echo hi \
> state/foo.txt'
check 2 ship-bosun 'te\
e state/foo.txt'
# Escaped backslash before newline is a REAL boundary, not a continuation
check 0 ship-bosun 'echo foo\\
git status'

echo "=== W2 N2: \$'...' ANSI-C quoting forces the raw scan (BLOCK) ==="
check 2 ship-bosun "git push origin \$'main'"

echo "=== W2 N3: zero-segment commands fail CLOSED (BLOCK) ==="
check 2 ship-bosun ';'
check 2 ship-bosun ' ; ; '

echo "=== Non-Bosun agents pass through (ALLOW) ==="
check 0 ship-mate 'git commit -m x'
check 0 ''        'rm somefile'

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All bosun-bash tests passed." || { echo "FAILURES."; exit 1; }
