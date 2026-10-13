#!/bin/bash
# Test suite for validate-mate-bash.sh (the Mate bright-line deny-list hook).
# Usage: ./modules/autonomous/tests/test-mate-bash.sh
#
# Extended for SHIP-HOOK-PATTERN-ANCHORING: the deny patterns are anchored to the
# actual invocation (per-segment, command-position), so trigger tokens inside quoted
# commit messages / paths / args no longer false-block — while every wrapper/compound/
# smuggle TRUE positive still blocks (raw substring scan for opaque segments).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/validate-mate-bash.sh"
PASS=0
FAIL=0

# jq is required — this suite builds the hook's stdin JSON with `jq -n`. Fail fast with a
# clear message instead of cascading per-case failures if jq is absent.
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to run this suite. Install jq (brew install jq / apt-get install jq) and re-run." >&2
  exit 2
fi

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
check 2 ship-mate 'gh pr edit 5 --add-reviewer someone'
check 2 ship-mate 'gh issue create --title x'
check 2 ship-mate 'gh api -X POST /repos/o/r/issues'
check 2 ship-mate 'gh api --method DELETE /repos/o/r/pulls/5'
check 2 ship-mate 'terraform apply'
check 2 ship-mate 'kubectl apply -f x.yaml'
check 2 ship-mate 'git push --force origin feat'
check 2 ship-mate 'git push origin main'

echo "=== Bright lines in compounds (BLOCK — op is genuinely invoked) ==="
check 2 ship-mate 'cd /repo && gh pr merge 5'
check 2 ship-mate 'echo ok; gh pr ready 5'
check 2 ship-mate 'git commit -m "wip" && git push origin main'
check 2 ship-mate 'git commit -m "wip" && git push --force origin feat'
check 2 ship-mate 'git commit -m "wip" && git push -f origin feat'
check 2 ship-mate 'cat plan.txt | kubectl apply -f -'
check 2 ship-mate 'echo done && terraform apply'
check 2 ship-mate 'git fetch origin && git push origin HEAD:main'

echo "=== Push-to-main / force-push variants (BLOCK) ==="
check 2 ship-mate 'git push origin master'
check 2 ship-mate 'git push origin "main"'
check 2 ship-mate "git push origin 'main'"
check 2 ship-mate 'git push origin feat:main'
check 2 ship-mate 'git push origin HEAD:refs/heads/main'
check 2 ship-mate 'git push --force-with-lease origin feat'
check 2 ship-mate 'git push origin +feat'
check 2 ship-mate 'git -C /path/to/repo push origin main'
check 2 ship-mate 'git -c push.default=simple push origin main'
check 2 ship-mate 'git push origin main && echo done'

echo "=== Wrapper / env-prefix smuggles (BLOCK — raw scan for opaque segments) ==="
check 2 ship-mate 'bash -c "gh pr merge 5"'
check 2 ship-mate "sh -c 'git push --force origin x'"
check 2 ship-mate "sh -c 'git push origin main'"
check 2 ship-mate 'env FOO=1 gh pr ready 5'
check 2 ship-mate 'FOO=1 gh pr merge 5'
check 2 ship-mate 'FOO=1 git push origin main'
check 2 ship-mate 'xargs gh pr merge'
check 2 ship-mate 'eval "gh pr comment 5 --body hi"'
check 2 ship-mate 'echo 5 | xargs -I{} gh pr merge {}'
check 2 ship-mate 'nohup terraform apply'
check 2 ship-mate 'timeout 60 kubectl delete pod x'

echo "=== Substitution-bearing segments stay raw-scanned (BLOCK) ==="
check 2 ship-mate 'echo "$(gh pr merge 5)"'
check 2 ship-mate 'echo `git push origin main`'

echo "=== gh pr create draft-only ==="
check 2 ship-mate 'gh pr create --title x'
check 2 ship-mate 'git commit -m "x" && gh pr create --title x'
check 0 ship-mate 'gh pr create --draft --title x'
check 0 ship-mate 'gh pr create -d --title x'
# --draft must be on the CREATE segment (tightened: a --draft elsewhere no longer satisfies)
check 2 ship-mate 'gh pr create --title x && echo "--draft"'

echo "=== Mate legitimate work (ALLOW = exit 0) ==="
check 0 ship-mate 'git commit -m "x"'
check 0 ship-mate 'git push origin feature-branch'
check 0 ship-mate 'gh pr view 5'
check 0 ship-mate 'gh pr list'
check 0 ship-mate 'gh api /repos/o/r/pulls/5'
check 0 ship-mate 'python3 lib/status_writer.py tick 3 boot'
check 0 ship-mate 'devbox run rails test'

echo "=== FALSE POSITIVES FIXED: confirm-tier tokens in quoted messages (ALLOW) ==="
# Instance #2: commit message describing the gh pr edit rule — edit/comment are
# confirm-tier, so they stay segment-scoped (NOT in the W2 never-vary pre-pass).
check 0 ship-mate 'git commit -m "docs: explain the gh pr edit --add-reviewer guard"'
check 0 ship-mate 'git commit -m "add push guard + tests"'
check 0 ship-mate 'git commit -m "a && gh pr edit b"'

echo "=== W2 ACCEPTED FLIPS: never-vary tokens in prose re-BLOCK on the Mate ==="
# W2 decision (fable max-scrutiny review of SHIP-HOOK-PATTERN-ANCHORING): the
# Mate is default-allow with no allow-list net under the segment pass, so the
# NEVER-VARY ops get a raw whole-command pre-pass again (closes the
# `echo 'gh pr merge 5' | bash` stdin-smuggle class). These W1 false-positive
# fixes are deliberately traded back ON THE MATE ONLY — a blocked command just
# surfaces and is worked around; crew/readonly/bosun keep the anchored
# behavior. These were `check 0` in W1.
check 2 ship-mate 'git commit -m "note: gh pr merge is Captain-only" && git push origin docs-branch'
check 2 ship-mate 'git commit -m "block force push + main" && git push origin hook-fixes'
check 2 ship-mate 'git commit -m "kubectl apply notes; terraform apply is Captain-only"'
check 2 ship-mate 'echo "terraform apply is Captain-authorized"'
check 2 ship-mate 'echo "never run gh pr merge autonomously"'

echo "=== FALSE POSITIVES FIXED: Main.scala / main-ish tokens in args (ALLOW) ==="
# Instance #1: Main.scala matched \bmain\b in a push-containing compound
check 0 ship-mate 'git add Main.scala && git commit -m "x" && git push origin feature-scala'
check 0 ship-mate 'git push origin feature/main-menu'
check 0 ship-mate 'git commit -m "touch src/main/scala/Main.scala" && git push origin feat'
check 0 ship-mate 'grep -rn "push origin main" docs/'

echo "=== Edge cases: multiline / unbalanced quotes / escaped quotes ==="
# Multiline command — each line is a segment
check 2 ship-mate 'git add .
git push origin main'
check 0 ship-mate 'git add .
git push origin feat'
# Unbalanced quote → naive-split fallback → over-block (fail-closed)
check 2 ship-mate 'git commit -m "unclosed && gh pr edit 5'
# W2 flip (was check 0): a quoted MENTION of a never-vary op now re-blocks on
# the Mate — accepted pre-pass trade (see W2 flips section above).
check 2 ship-mate 'git commit -m "say \"gh pr merge\" nicely"'
# Escaped quotes around confirm-tier tokens still stay data (anchored path)
check 0 ship-mate 'git commit -m "say \"gh pr edit\" nicely"'
# Trailing tokens after the ref still block
check 2 ship-mate 'git push origin main --tags'
# Heredoc body lines are still scanned (over-block, fail-closed — body is data but
# a fragment invoking an op can't be distinguished cheaply)
check 2 ship-mate 'bash <<EOF
gh pr merge 5
EOF'

echo "=== W2 B1: pipe-into-interpreter stdin smuggles (BLOCK) ==="
# The payload rides as DATA in the producing segment; the interpreter segment is
# textually clean. Pre-pass + bare-interpreter whole-command raw scan close this.
check 2 ship-mate "echo 'gh pr merge 5' | bash"
check 2 ship-mate "echo 'git push origin main' | sh"
check 2 ship-mate 'printf "terraform apply\n" | python3'
check 2 ship-mate "echo 'gh pr review 5 --approve' | zsh"
check 2 ship-mate "echo 'git push --force origin x' | env bash"
# Confirm-tier ops through the pipe (proves the bare-interpreter whole-scan,
# independent of the never-vary pre-pass)
check 2 ship-mate "echo 'gh issue create --title x' | bash"
check 2 ship-mate "echo 'gh pr comment 5 --body hi' | node"
# Clean interpreter use stays allowed
check 0 ship-mate 'echo hello | bash format.sh'
check 0 ship-mate "bash -c 'ls -la'"

echo "=== W2 B2: backslash-newline continuations rejoin (BLOCK) ==="
check 2 ship-mate 'git push origin \
main'
check 2 ship-mate 'git pu\
sh origin main'
check 2 ship-mate 'gh pr mer\
ge 5'
# Escaped backslash before newline is a REAL boundary, not a continuation
check 0 ship-mate 'echo foo\\
git status'

echo "=== W2 N2: \$'...' ANSI-C quoting forces the raw scan (BLOCK) ==="
check 2 ship-mate "git push origin \$'main'"
check 2 ship-mate "gh pr create --title \$'x'"

echo "=== W5: mid-token backslashes collapse before scanning (BLOCK) ==="
# bash collapses `\m` -> `m` at exec time, so every case below RUNS as the real op.
# Before the fix the scan saw the literal `\merge` and matched nothing — and this
# hook is default-ALLOW with no allow-list net, so they EXECUTED. Verified live on
# the operator's ship (gh pr \merge / \ready / c\omment / ap\prove all allowed).
check 2 ship-mate 'gh pr \merge 5'
check 2 ship-mate 'gh pr \ready 5'
check 2 ship-mate 'gh pr c\omment 5 --body hi'
check 2 ship-mate 'gh pr ap\prove 5'
check 2 ship-mate 'gh pr revie\w 5 --approve'
check 2 ship-mate 'gh pr cl\ose 5'
check 2 ship-mate 'gh issue cr\eate --title x'
check 2 ship-mate 'gh api -X PO\ST /repos/o/r/issues'
check 2 ship-mate 'git push origin ma\in'
check 2 ship-mate 'git push origin mast\er'
check 2 ship-mate 'git push \--force origin feat'
check 2 ship-mate 'terraform ap\ply'
check 2 ship-mate 'kubectl appl\y -f x.yaml'
check 2 ship-mate 'cd /repo && gh pr \merge 5'
check 2 ship-mate 'echo ok; git push origin ma\in'
# No new false positives: backslashes that are genuinely data/escapes stay ALLOWED.
check 0 ship-mate 'find . -name "*.md" -exec grep -l x {} \;'
check 0 ship-mate 'printf "a\nb"'
check 0 ship-mate 'echo done \&\& ls'
check 0 ship-mate 'echo "path\to\file"'
check 0 ship-mate 'grep -rn "\bmain\b" src/'
check 0 ship-mate 'git push origin feature-branch'

echo "=== W2 N1: gh api tightened (--method= and implicit-POST fields) ==="
check 2 ship-mate 'gh api --method=POST /repos/o/r/issues'
check 2 ship-mate 'gh api --method=DELETE /repos/o/r/pulls/5'
check 2 ship-mate 'gh api repos/o/r/issues -f title=hi'
check 2 ship-mate 'gh api repos/o/r/issues --field title=hi'
check 2 ship-mate 'gh api graphql -F query=@mutation.graphql'
check 2 ship-mate 'gh api repos/o/r/issues --input body.json'
check 0 ship-mate 'gh api repos/o/r/pulls/5'
check 0 ship-mate 'gh api repos/o/r/pulls --paginate'

echo "=== W4: gh api pflag ATTACHED shorthand (-ftitle=... was a live bypass) ==="
check 2 ship-mate 'gh api /repos/o/r/issues -ftitle=hello'
check 2 ship-mate 'gh api /repos/o/r/issues -Fbody=@payload'
check 2 ship-mate 'gh api graphql -fquery=mutation{m}'
check 2 ship-mate 'gh api -ftitle=x /repos/o/r/issues'
check 2 ship-mate 'gh api /repos/o/r/issues -f'
# pflag combined clusters: -i (--include) is gh api's ONLY boolean shorthand, so
# -i-prefixed clusters reach -f/-F/-X (verified live: gh 2.79.0 parses -iftitle=x
# as --include --raw-field title=x, -iXPOST as --include --method POST)
check 2 ship-mate 'gh api /repos/o/r/issues -iftitle=pwn'
check 2 ship-mate 'gh api /repos/o/r/issues -iFbody=@payload'
check 2 ship-mate 'gh api /repos/o/r/issues -iiftitle=x'
check 2 ship-mate 'gh api /repos/o/r/issues -if title=x'
check 2 ship-mate 'gh api /repos/o/r/issues -if=title=x'
check 2 ship-mate 'gh api -iXPOST /repos/o/r/issues'
check 2 ship-mate 'gh api -iX POST /repos/o/r/issues'
# Reads stay allowed: bare -i, cluster ending in GET, non-gh -f usage
check 0 ship-mate 'gh api /repos/o/r/pulls --method GET'
check 0 ship-mate 'gh api -i /repos/o/r/pulls/5'
check 0 ship-mate 'gh api -iX GET /repos/o/r/pulls'
check 0 ship-mate 'gh pr view 12'
check 0 ship-mate 'grep -f patterns file'

echo "=== W2 N3: zero-segment commands fail CLOSED (BLOCK) ==="
check 2 ship-mate ';'
check 2 ship-mate ' ; ; '

echo "=== Push-to-main carve-out seam: DEFAULT OFF (explicit-URL pushes still BLOCK) ==="
# The seam ships EMPTY (MATE_PUSH_MAIN_CARVEOUT='') — until a deployment populates
# it, the explicit-URL form is just another push to main.
check 2 ship-mate 'git push git@github.com:YourOrg/your-publish-repo.git main'
check 2 ship-mate 'git push https://github.com/YourOrg/your-publish-repo.git main'

echo "=== Push-to-main carve-out seam: POPULATED (live-fire on a temp copy) ==="
# Live-fire the seam mechanics without touching the shipped default: copy the hook,
# populate the seam with the documented example regex, run the case matrix from the
# pattern's origin ship. check_c mirrors check() against the temp copy.
CARVE_HOOK=$(mktemp -t carve-hook.XXXXXX)
sed "s|^MATE_PUSH_MAIN_CARVEOUT=''$|MATE_PUSH_MAIN_CARVEOUT='\\\\bpush[[:space:]]+(git@github\\\\.com:\|https://github\\\\.com/)YourOrg/your-publish-repo(\\\\.git)?([[:space:]]\|$)'|" "$HOOK" > "$CARVE_HOOK"
if ! grep -q "MATE_PUSH_MAIN_CARVEOUT='.bpush" "$CARVE_HOOK"; then
  FAIL=$((FAIL+1)); echo "  FAIL: sed did not populate the carve-out seam in the temp copy"
fi
check_c() {
  local want="$1" agent="$2" cmd="$3"
  local json got
  json=$(jq -n --arg a "$agent" --arg c "$cmd" '{agent_type:$a, tool_input:{command:$c}}')
  echo "$json" | bash "$CARVE_HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "  FAIL(carve) want=$want got=$got [$agent] $cmd"
  fi
}
# ALLOWS: the exact explicit-URL forms only
check_c 0 ship-mate 'git push git@github.com:YourOrg/your-publish-repo.git main'
check_c 0 ship-mate 'git push https://github.com/YourOrg/your-publish-repo.git main'
check_c 0 ship-mate 'git push git@github.com:YourOrg/your-publish-repo main'
check_c 0 ship-mate 'cd /path/to/your-publish-repo && git push git@github.com:YourOrg/your-publish-repo.git main'
# Still BLOCKED: every other main-touching push shape
check_c 2 ship-mate 'git push origin main'
check_c 2 ship-mate 'cd /path/to/your-publish-repo && git push origin main'
check_c 2 ship-mate 'git push git@github.com:YourOrg/other-repo.git main'
check_c 2 ship-mate 'git push git@github.com:YourOrg/your-publish-repo-evil.git main'
# FORCE-PUSH stays blocked unconditionally (checked before the ref deny)
check_c 2 ship-mate 'git push --force git@github.com:YourOrg/your-publish-repo.git main'
check_c 2 ship-mate 'git push -f git@github.com:YourOrg/your-publish-repo.git main'
check_c 2 ship-mate 'git push git@github.com:YourOrg/your-publish-repo.git +main'
# Sibling-segment smuggle: the carve-out push must NOT unlock a second push
check_c 2 ship-mate 'git push git@github.com:YourOrg/your-publish-repo.git main && git -C /path/to/other push origin main'
check_c 2 ship-mate 'git push git@github.com:YourOrg/your-publish-repo.git main; git push origin main'
# Interpreter-sink smuggle (gate finding 2026-07-14): a carved URL anywhere in the
# command must NOT unlock a push riding as DATA into an interpreter; and the raw
# path never consults the carve-out, so even the legit push wrapped in an
# interpreter is blocked (carve-out = direct invocation only).
check_c 2 ship-mate 'git push git@github.com:YourOrg/your-publish-repo.git main; echo "git push origin main" | bash'
check_c 2 ship-mate 'echo "git push git@github.com:YourOrg/your-publish-repo.git main" | bash'
check_c 2 ship-mate 'bash -c "git push git@github.com:YourOrg/your-publish-repo.git main"'
# Normal work: unaffected
check_c 0 ship-mate 'git status'
check_c 0 ship-mate 'git push origin feature-branch'
check_c 2 ship-mate 'gh pr merge 5'
rm -f "$CARVE_HOOK"

echo "=== Non-Mate agents pass through (ALLOW) ==="
check 0 ship-crew 'gh pr merge 5'
check 0 ''        'git push origin main'

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All mate-bash tests passed." || { echo "FAILURES."; exit 1; }
