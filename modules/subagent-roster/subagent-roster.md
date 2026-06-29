# Module: Subagent Roster (dispatch depth)

**Depth doc for crew dispatch.** Core `mate.md` → "Dispatch Details" carries the *act*
of dispatching (pop a unit of work → prepare orders → dispatch a background crew → never
block → update queue) plus the two types a minimal operator needs: **`ship-crew`** (a
standard background watch) and **`ship-lookout`** (a cheap read-only check). That inline
kernel is enough to dispatch and stay safe. This module holds the *depth*: the full
roster (including the two long-running agents that ARE the autonomous shape —
`ship-mate` + `ship-bosun`), the dispatch patterns, the per-type security model, the
watch-orders template, and agent teams.

## The roster

Ship defines custom subagent types (installed to `~/.claude/agents/ship-*.md` by
`shipkit-init`). These provide **enforced** tool restrictions and baked-in standing
orders. Two are long-running *role* agents (the autonomous shape); four are dispatched
*worker* agents.

### Role agents (the autonomous two-agent shape)

| Type | Role | Tools | Enforcement |
|------|------|-------|-------------|
| `ship-mate` | The First Mate as a managed/bg agent — event-driven coordination (queue, dispatch, reaps, status, ship commits). Boots via `/ship-watch-start`, then idles. | Broad (default-allow) | `validate-mate-bash.sh` (deny-list: no merge/ready/comment/deploy/prod/push-to-main) + `validate-mate-mcp.sh` (confirm-gated MCP writes) |
| `ship-bosun` | The heartbeat-owner — runs its own `/loop` (`bosun-tick`): curate/reconcile/librarian sweeps, wakes the Mate via a drop only on actionable deltas. | Read-only + `bosun_emit.py` | No Write/Edit/Task; `validate-bosun-bash.sh` (allow-list; sole write path is `bosun_emit.py`) |

These two only cohere together: the Bosun ticks the heartbeat, the Mate stays
event-driven and acts on the Bosun's drops + crew completions + Captain drops. See
`mate.md`, `bosun.md`, and `modules/{bosun-loop,mate-event-driven}.md`.

### Worker agents (dispatched per-watch)

| Type | When to use | Tools | Enforcement |
|------|-------------|-------|-------------|
| `ship-crew` | Standard watches (research + implementation) | All (with git safety hook) | Hook blocks git commit/push/reset, queue.md writes |
| `ship-pilot` | Browser interaction (screenshots, UI verification, form testing) | All + Chrome MCP | Same as crew + Chrome tools. **Only dispatch when the Captain explicitly authorizes browser work.** |
| `ship-lookout` | Quick checks, "does X exist?", lightweight read-only analysis | Read-only | disallowedTools Write/Edit; read-only Bash allow-list |
| `ship-reviewer` | Independent (non-maker) review of crew code or PRs | Read-only + Bash | Hook blocks `gh` approve/comment/merge + all git writes |

## Dispatch patterns

```
# Standard crew watch (research or implementation)
Task tool:
  subagent_type: "ship-crew"
  run_in_background: true
  model: "<your default crew model — mate.local.md>"
  prompt: |
    WATCH ORDERS: {ticket-id}
    ...

# Browser interaction (Captain must explicitly authorize)
Task tool:
  subagent_type: "ship-pilot"
  run_in_background: true
  prompt: |
    WATCH ORDERS: {ticket-id}
    ... (Chrome-specific guidance: pages to visit, what to screenshot)

# Quick lookout check (no log needed)
Task tool:
  subagent_type: "ship-lookout"
  run_in_background: true
  prompt: "Check if X exists in the codebase at /path/to/repo"

# Independent reviewer (the review cycle, or a PR-review agent team)
Task tool:
  subagent_type: "ship-reviewer"
  run_in_background: true
  prompt: "Review the uncommitted diff in /path/to/repo for correctness + standards"
```

The two role agents are NOT dispatched via Task — they're launched as their own
sessions (`modules/autonomous/scripts/ship-up.sh --launch-mate` for the Mate; the Mate
bootstraps the Bosun via `modules/autonomous/scripts/launch-bosun.sh --ensure`).

## Model selection

Pick the model to the task: a stronger model where wrong paths are expensive (most
code-writing watches), a faster/cheaper one for bounded, well-specified work and for
read-only lookouts/reviewers. Your concrete model roster — the default crew model and any
escalation tier — lives in `mate.local.md`. (Rate/cost-aware modulation of your appetite
and crew cap is the [dispatch-bands](dispatch-bands.md) module.)

## Security model (enforced per subagent by PreToolUse hooks)

- `ship-mate`: default-allow deny-list — blocks the autonomy bright lines (merge / ready
  / comment / review / approve, deploys, prod writes, push-to-main, force-push) + confirm-
  gates MCP writes. Everything else (edits, commit, feature-branch push, scripts, crew
  dispatch) allowed.
- `ship-bosun`: default-deny allow-list — read-only on everything; sole write path is
  `bosun_emit.py`.
- `ship-crew`: git safety — blocks commit, push, add, reset, revert, merge, rebase, clean,
  rm -rf, queue.md writes, `gh` write ops. Allows checkout, branch, status, diff, log,
  fetch, show, plus dev commands.
- `ship-pilot`: same git safety as crew, plus Chrome MCP. Only when the Captain authorizes.
- `ship-lookout`: cannot write/edit; Bash restricted to read-only.
- `ship-reviewer`: cannot write files; hook blocks `gh` approve/comment/merge + git writes.

**The execute bit on every hook is load-bearing** — a non-exec hook fails OPEN (silent
zero enforcement). `shipkit-init` and `ship-up.sh` set/self-heal it.

## Watch orders format

```
---
WATCH ORDERS: {ticket-id}

Ticket: projects/{project}/tickets/{id}.md
Branch: {branch-name}
Previous log: {path or "first watch"}
Goal: {one line}
Focus: {any specific guidance or constraints}
Chrome tools: {no | yes — only if Captain explicitly requested}
---

## Reference Docs
- {path-to-ship}/docs/knowledge/{relevant}.md
- {path-to-ship}/logs/{project}/{ticket}/ (previous logs)
```

**Chrome tools restriction:** by default crew do NOT use browser automation. Only enable
Chrome tools (the `ship-pilot` type) when the Captain explicitly requests a browser watch,
and say so in the orders.

## Agent teams (optional)

For coordinated parallel work where multiple agents share a task list or communicate
results — the canonical case is PR review — use agent teams (a team-creating call + Task
dispatches with a shared `team_name`). Standalone Task dispatches are fine for ordinary
parallel watches; teams are for when agents need to coordinate.
