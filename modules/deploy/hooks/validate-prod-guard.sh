#!/bin/bash
# Prod-mutation guard: PreToolUse hook emitting permissionDecision "ask" for any command
# that could change prod state (interactive → live per-command approval; unattended → deny).
# For a non-prod command it ABSTAINS (exit 0, no JSON) rather than emitting an explicit
# "defer": when this guard shares a Bash matcher with another PreToolUse hook that emits
# "allow" (the janitor allow-list guard), an explicit "defer" from THIS hook SUPPRESSES the
# other hook's "allow" and the tool is deferred → never executed under headless `-p`
# --permission-mode dontAsk (empirically confirmed 2026-07-26; contradicts the documented
# defer<allow precedence, so we don't rely on it). Abstaining is the documented equivalent of
# "defer" ("default if omitted") for single-hook use, so no behavior change there. Always exit
# 0. Fails CLOSED (ask) on any tooling failure. Prod-verb set: any `aws` (read/write can't be
# told apart, so gate all — accepted broad tradeoff, deletes/DLQ-redrive included) + mutating
# `sam` subcommands.

FALLBACK_ASK='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"prod-guard: jq/perl unavailable or input unparseable, failing closed"}}'

emit() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}\n' \
    "$1" "$(printf '%s' "$2" | jq -Rs .)"
  exit 0
}

# abstain — no opinion; let the normal permission flow / other hooks decide. Emit NOTHING
# (an explicit "defer" would suppress a co-matched hook's "allow"; see header).
abstain() {
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "$FALLBACK_ASK"
  exit 0
fi

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [ $? -ne 0 ]; then
  printf '%s\n' "$FALLBACK_ASK"
  exit 0
fi

if [ -z "$COMMAND" ]; then
  abstain
fi

# Copied verbatim from SHIP-MATCH-LIB (core/hooks/validate-*-bash.sh); keep in sync. This hook
# must stay a single self-contained file, like those.
ship_collapse_continuations() {
  printf '%s\n' "$1" | perl -0777 -pe 's/(?<!\\)((?:\\\\)*)\\\n/$1/g'
}
ship_strip_quote_chars() {
  printf '%s\n' "$1" | tr -d "'\"" | tr -d '\\'
}

# Scan something closer to what bash runs: `a"w"s`, `aw\s` and `sam de"p"loy` run as aws /
# sam deploy. A `$` right before a quote is dropped first (hook-local, not in the shared lib):
# `a$'w's` and `a$"w"s` also run as aws, but plain stripping leaves `a$ws`. Then flatten
# newlines/tabs so a verb split across lines is one grep line. Stripping can only ADD matches
# (over-ask), never hide one. No perl → no normaliser → fail closed.
if ! command -v perl >/dev/null 2>&1; then
  printf '%s\n' "$FALLBACK_ASK"
  exit 0
fi
SCAN=$(ship_collapse_continuations "$COMMAND")
SCAN=$(printf '%s\n' "$SCAN" | perl -pe 's/\$(?=[\x27"])//g')
SCAN=$(ship_strip_quote_chars "$SCAN" | tr '\n\r\t' '   ')

# aws token anywhere → ask. This over-asks on aws in prose/paths/filenames (e.g. an
# aws-notes.md arg, `cd ~/aws`); that broad gate is an ACCEPTED tradeoff — do not narrow it
# without re-deciding the read/write split. Case-insensitive: `AWS` runs aws on a
# case-insensitive filesystem (the macOS default).
if echo "$SCAN" | grep -qiE '\baws\b'; then
  emit ask "aws invocation — prod state-change can't be ruled out; gate all aws (deletes/DLQ-redrive are aws subcommands). Confirm this is a live-authorized run."
fi

# Mutating sam subcommands. deploy/sync push to a live stack, delete tears one down,
# publish → Serverless App Repo, package writes to S3. build/validate/local/init abstain.
# Global flags between `sam` and the subcommand (`sam --debug deploy`) are skipped.
if echo "$SCAN" | grep -qiE '\bsam([[:space:]]+-[^[:space:]]*)*[[:space:]]+(deploy|sync|publish|delete|package)\b'; then
  emit ask "sam mutating subcommand (deploy/sync/publish/delete/package) — changes prod state. Confirm this is a live-authorized run."
fi

abstain  # no prod-mutating verb detected
