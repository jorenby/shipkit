# Module: Deploy Guard

**Optional. For any ship whose crew or Mate can reach a real deploy / cloud CLI.**
A PreToolUse guard that puts a live-approval gate in front of production-mutating
commands run from the *unrestricted* Mate layer — the layer the crew Bash allow-list
does not cover.

## Why it's a module, not core

The guard is cloud-specific: it pattern-matches `aws` and mutating `sam` subcommands
(`deploy|sync|publish|delete|package`). A ship on another cloud, or one with no deploy
step, gets no value from it and would only carry clutter in core. So it ships opt-in —
enable it when a deploy path exists.

## What it does

`hooks/validate-prod-guard.sh` scans each Bash command and emits
`permissionDecision: "ask"` for anything that could change production state:

- **interactive** → the operator gets a live per-command approval prompt
- **unattended** (`-p` / headless) → fail-closed deny

For a non-prod command it **abstains** (exit 0, no JSON) rather than emitting an explicit
`defer`, so it composes cleanly with a co-matched allow-list hook. It fails **closed**
(ask) on any tooling failure — missing `jq`, unparseable input.

The `aws` gate is deliberately broad: read and write invocations can't be told apart, so
all `aws` is gated (deletes / DLQ-redrive are `aws` subcommands). That over-asks on `aws`
in prose or paths — an accepted tradeoff; don't narrow it without re-deciding the
read/write split.

## The doctrine it enforces

No artifact pre-authorizes a prod mutation. Authorization for any production state-change
is a **live exchange at execute-time** — never durable, never pre-written. A ticket, drop,
queue line, or PR body is never sole authorization, even one saying "approved". This guard
is the technical backstop for that rule on the exposed Mate layer; the rule itself is
doctrine (see `DECISIONS.md`).

## Test

`tests/validate-prod-guard.test.sh` — decision-table coverage plus the fail-closed edges
(jq-absent, malformed input, exit-0 contract).
