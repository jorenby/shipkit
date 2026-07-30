#!/usr/bin/env bash
# Tests for validate-prod-guard.sh — the PreToolUse hook that emits permissionDecision
# "ask" for prod-mutating commands and ABSTAINS (no output, exit 0) for everything else.
# It abstains rather than emitting "defer" because an explicit "defer" suppresses a
# co-matched hook's "allow" under headless dontAsk (see the hook header).
#
# Each case feeds a command via the {tool_input:{command}} JSON contract the hook reads
# on stdin and asserts either the emitted "ask" decision or an abstain (empty + exit 0).
# NO real prod mutation runs — we only assert the decision on sample command strings.
#
# Run with: bash scripts/tests/validate-prod-guard.test.sh
# Exits 0 on success, non-zero if any case fails.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/validate-prod-guard.sh"

PASS=0
FAIL=0
FAILED_CASES=()

# decision_for <command> — prints the emitted permissionDecision (or "PARSE_ERROR").
decision_for() {
  local cmd="$1" payload out
  payload=$(jq -nc --arg c "$cmd" '{tool_input: {command: $c}}')
  out=$(echo "$payload" | bash "$HOOK" 2>/dev/null)
  echo "$out" | jq -r '.hookSpecificOutput.permissionDecision // "PARSE_ERROR"' 2>/dev/null || echo "PARSE_ERROR"
}

# assert <label> <expected-decision> <command>
assert() {
  local label="$1" expected="$2" cmd="$3" got
  got=$(decision_for "$cmd")
  if [ "$got" = "$expected" ]; then
    printf "  PASS  %s\n" "$label"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %s\n" "$label"
    printf "        command:  %s\n" "$cmd"
    printf "        expected: %s  got: %s\n" "$expected" "$got"
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("$label")
  fi
}

# assert_exit0 <label> <command> — the hook must ALWAYS exit 0 (decision rides in JSON).
assert_exit0() {
  local label="$1" cmd="$2" payload code
  payload=$(jq -nc --arg c "$cmd" '{tool_input: {command: $c}}')
  echo "$payload" | bash "$HOOK" >/dev/null 2>&1
  code=$?
  if [ "$code" = "0" ]; then
    printf "  PASS  %s\n" "$label"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %s (exit %s, expected 0)\n" "$label" "$code"
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("$label")
  fi
}

# assert_abstain <label> <command> — the non-prod path ABSTAINS: emit NOTHING and exit 0
# (an explicit "defer" would suppress a co-matched hook's "allow"; see the hook header).
assert_abstain() {
  local label="$1" cmd="$2" payload out code
  payload=$(jq -nc --arg c "$cmd" '{tool_input: {command: $c}}')
  out=$(echo "$payload" | bash "$HOOK" 2>/dev/null); code=$?
  if [ -z "$out" ] && [ "$code" = "0" ]; then
    printf "  PASS  %s\n" "$label"; PASS=$((PASS + 1))
  else
    printf "  FAIL  %s (expected empty output + exit 0; got out=[%s] code=%s)\n" "$label" "$out" "$code"
    FAIL=$((FAIL + 1)); FAILED_CASES+=("$label")
  fi
}

# assert_raw_abstain <label> <raw-json-payload> — abstain (empty + exit 0) for an arbitrary
# payload shape (e.g. a non-Bash tool with no .tool_input.command).
assert_raw_abstain() {
  local label="$1" payload="$2" out code
  out=$(echo "$payload" | bash "$HOOK" 2>/dev/null); code=$?
  if [ -z "$out" ] && [ "$code" = "0" ]; then
    printf "  PASS  %s\n" "$label"; PASS=$((PASS + 1))
  else
    printf "  FAIL  %s (expected empty output + exit 0; got out=[%s] code=%s)\n" "$label" "$out" "$code"
    FAIL=$((FAIL + 1)); FAILED_CASES+=("$label")
  fi
}

# assert_raw <label> <expected-decision> <raw-json-payload> — feed an arbitrary payload
# shape (e.g. a non-Bash tool with no .tool_input.command).
assert_raw() {
  local label="$1" expected="$2" payload="$3" got
  got=$(echo "$payload" | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // "PARSE_ERROR"' 2>/dev/null || echo "PARSE_ERROR")
  if [ "$got" = "$expected" ]; then
    printf "  PASS  %s\n" "$label"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %s (expected %s got %s)\n" "$label" "$expected" "$got"
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("$label")
  fi
}

# assert_valid_json <label> <raw-json-payload> — the hook output must parse as JSON and
# carry a permissionDecision field (never malformed like "reason":}).
assert_valid_json() {
  local label="$1" payload="$2" out
  out=$(echo "$payload" | bash "$HOOK" 2>/dev/null)
  if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision' >/dev/null 2>&1; then
    printf "  PASS  %s\n" "$label"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %s (output not valid JSON w/ decision: %s)\n" "$label" "$out"
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("$label")
  fi
}

# decision_no_jq <command> — runs the hook with jq removed from PATH, prints decision.
# A tmp dir holding shims of every tool the hook uses EXCEPT jq becomes the sole PATH.
decision_no_jq() {
  local cmd="$1" payload shimdir out
  payload=$(jq -nc --arg c "$cmd" '{tool_input: {command: $c}}')
  shimdir=$(mktemp -d)
  for t in bash cat tr grep printf command; do
    ln -s "$(command -v "$t" 2>/dev/null)" "$shimdir/$t" 2>/dev/null
  done
  out=$(echo "$payload" | PATH="$shimdir" "$shimdir/bash" "$HOOK" 2>/dev/null)
  rm -rf "$shimdir"
  printf '%s' "$out"
}

# assert_no_jq <label> <expected-decision> <command> — asserts the decision AND that the
# output is valid JSON, both under a jq-less PATH (the fail-closed tooling path).
assert_no_jq() {
  local label="$1" expected="$2" cmd="$3" out got
  out=$(decision_no_jq "$cmd")
  got=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision // "PARSE_ERROR"' 2>/dev/null || echo "PARSE_ERROR")
  if [ "$got" = "$expected" ] && echo "$out" | jq -e '.' >/dev/null 2>&1; then
    printf "  PASS  %s\n" "$label"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %s (expected %s got %s; out=%s)\n" "$label" "$expected" "$got" "$out"
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("$label")
  fi
}

echo "=== Plain prod verbs → ask ==="
assert "aws sqs start-message-move-task (DLQ redrive)" ask "aws sqs start-message-move-task --source-arn arn:aws:sqs:x"
assert "aws ec2 terminate-instances"                   ask "aws ec2 terminate-instances --instance-ids i-x"
assert "aws ec2 start-instances"                       ask "aws ec2 start-instances --instance-ids i-x"
assert "aws cloudformation delete-stack"               ask "aws cloudformation delete-stack --stack-name x"
assert "sam deploy"                                    ask "sam deploy --stack-name x"

echo ""
echo "=== Mutating sam subcommands → ask; non-mutating → abstain ==="
assert "sam deploy → ask"   ask   "sam deploy --stack-name x"
assert "sam sync → ask"     ask   "sam sync --stack-name x"
assert "sam publish → ask"  ask   "sam publish --template t.yaml"
assert "sam delete → ask"   ask   "sam delete --stack-name x"
assert "sam package → ask"  ask   "sam package --s3-bucket b --output-template-file o.yaml"
assert_abstain "sam build → abstain"        "sam build --template t.yaml"
assert_abstain "sam validate → abstain"     "sam validate"
assert_abstain "sam local invoke → abstain" "sam local invoke MyFn"
assert_abstain "sam init → abstain"         "sam init --runtime python3.11"

echo ""
echo "=== Prod READ also gated (documented tradeoff: gate all aws) ==="
assert "aws sts get-caller-identity (read, still ask)" ask "aws sts get-caller-identity"
assert "aws s3 ls (read, still ask)"                   ask "aws s3 ls s3://b"
assert "aws --version"                                 ask "aws --version"

echo ""
echo "=== Adversarial smuggle → must still ask ==="
assert "echo \$(aws ec2 start-instances)"      ask "echo \$(aws ec2 start-instances --instance-ids i-x)"
assert "printf %s \"\$(sam deploy)\""          ask "printf '%s' \"\$(sam deploy --stack-name x)\""
assert "nested \$( \$( aws ... ) )"            ask "echo \$( echo \$( aws ec2 terminate-instances ) )"
assert "backtick aws"                          ask "echo \`aws ec2 start-instances --instance-ids i-x\`"
assert "aws after ;"                           ask "true ; aws ec2 start-instances --instance-ids i-x"
assert "aws after &&"                          ask "cd /tmp && aws ec2 start-instances --instance-ids i-x"
assert "aws after |"                           ask "echo i-x | aws ec2 start-instances"
assert "xargs aws"                             ask "echo i-x | xargs aws ec2 start-instances"
assert "xargs -I{} aws"                        ask "cat ids | xargs -I{} aws ec2 terminate-instances --instance-ids {}"
assert "sam deploy after &&"                   ask "sam build --template t.yaml && sam deploy --stack-name x"

echo ""
echo "=== HIGH: sam deploy split across a newline (line-continuation) → ask ==="
# `sam \<newline>deploy` is `sam deploy` to the shell. grep is line-oriented, so the two
# tokens must be normalized onto one line before scanning or the two-token pattern is missed.
assert "sam<newline>deploy"        ask "$(printf 'sam\ndeploy --stack-name x')"
assert "sam \\<newline>deploy"     ask "$(printf 'sam \\\ndeploy --stack-name x')"
assert "sam<tab>deploy"            ask "$(printf 'sam\tdeploy --stack-name x')"
assert "sam sync split newline"    ask "$(printf 'sam\nsync --stack-name x')"

echo ""
echo "=== Non-prod → abstain (empty output, exit 0) ==="
assert_abstain "git status"        "git status"
assert_abstain "npm test"          "npm test"
assert_abstain "ls"                "ls -la"
assert_abstain "cat a file"        "cat notes.md"
assert_abstain "grep"              "grep -r foo ."
assert_abstain "echo plain"        "echo hello world"
# A word merely CONTAINING the substring but not the verb token must not trip \b matching.
assert_abstain "flaws.txt (no aws token)"  "cat flaws.txt"
assert_abstain "'sam deployment' prose"    "echo 'planning the sam deployment later'"

echo ""
echo "=== LOW (pinned tradeoff): aws token anywhere → ask, even in prose/path/filename ==="
# This over-ask is an ACCEPTED tradeoff (any aws token gates). These pin it so a future
# refactor can't silently narrow the aws rule without a failing test forcing the re-decision.
assert "aws in filename arg"   ask "grep foo aws-notes.md"
assert "aws in dir name (cd)"  ask "cd ~/aws"
assert "aws in prose echo"     ask "echo 'the aws migration is next week'"
assert "aws in comment"        ask "ls # remember to run aws later"

echo ""
echo "=== Edge: empty command / non-Bash tool input → abstain ==="
assert_abstain "empty command"           ""
assert_abstain "whitespace-only command" "   "
# A non-Bash tool payload carries no .tool_input.command → treated as nothing to inspect.
# jq IS present here, so this abstains (empty output, exit 0), distinct from the jq-absent
# fail-closed ask path below.
assert_raw_abstain "Edit-tool payload (no .command) → abstain" '{"tool_input":{"file_path":"/x/foo.py"}}'
assert_raw_abstain "empty JSON object → abstain"               '{}'

echo ""
echo "=== HIGH: jq unavailable → fail CLOSED (ask) with valid JSON, never defer/malformed ==="
assert_no_jq "jq-less: real prod cmd → ask"   ask "aws ec2 terminate-instances --instance-ids i-x"
assert_no_jq "jq-less: benign cmd → ask"      ask "ls -la"
assert_no_jq "jq-less: empty cmd → ask"       ask ""

echo ""
echo "=== HIGH: malformed input JSON → fail CLOSED (ask) with valid JSON ==="
assert_raw       "malformed input JSON → ask"        ask "not json at all { ["
assert_valid_json "malformed input still valid JSON" "not json at all { ["

echo ""
echo "=== Contract: hook always exits 0 (decision is in JSON, not exit code) ==="
assert_exit0 "exit0 on ask (aws)"      "aws ec2 terminate-instances --instance-ids i-x"
assert_exit0 "exit0 on abstain (ls)"   "ls -la"

echo ""
echo "============================================"
printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do
    printf "  - %s\n" "$c"
  done
  exit 1
fi
exit 0
