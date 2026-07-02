# Ship: Bounded-Context Orchestration for Claude Code

Ship is a system for coordinating multiple Claude Code agent sessions around your engineering work. It structures handoffs between fresh sessions so context rot doesn't eat your progress.

## How it works

You're the **Captain**. You set priorities, make decisions, and steer. Claude Code acts as your **First Mate** — it manages a work queue, dispatches background agents (**Crew**) for bounded tasks, and keeps you informed. Crew sessions write structured logs when they finish, so the next session can pick up cleanly without assuming any context persists.

Ship lives in a single directory on your machine (not inside any one repo). It coordinates work across whatever repos and projects you point it at.

## Your role as Captain

**Day-to-day you'll:**
- Start a Claude Code session and tell it to be your First Mate
- Drop tasks, ideas, and priorities into `captain.md` and `inbox/captain.md`
- Steer the Mate: approve dispatches, review findings, make calls on scope
- Commit and push when the Mate reports work is ready (crew can't push)
- Merge PRs and make external communications (comments, reviews, Slack)

**The Mate handles:**
- Reading ship state and reporting status
- Dispatching crew to work on tickets in the background
- Processing your inbox items into tickets
- Tracking progress across the queue

**You don't need to:**
- Manually manage logs or ticket formatting
- Write watch orders (the Mate does this)
- Remember what happened last session (that's what logs are for)

## Getting started

### 1. Have Claude Code bootstrap your ship

Tell Claude Code:

> Read the shipkit docs at `{path-to-this-repo}/` and bootstrap a new Ship for me.

Claude Code will read these docs, ask you a few questions (where to put the ship directory, what you're working on), and set everything up. The bootstrap section below is written for the coding agent to follow.

### 2. Start your first Mate session

Once bootstrapped, start a Claude Code session with your ship directory as a working directory (or as an additional context path), and tell it:

> You're First Mate on this ship. Read `ship/core/mate.md` for your standing orders.

The Mate will read ship state, report status, and ask for steering.

### 3. Start working

Drop work items into `inbox/captain.md` — the Mate will triage them into tickets. Or just tell the Mate what you want done. It'll dispatch crew, track progress, and report back.

---

## Bootstrap Instructions (for Claude Code)

**If you're a coding agent reading this:** the install + upgrade is driven by the
**`/shipkit-init`** skill, NOT by hand. Don't hand-copy hooks/agents — run the skill; it
carries the judgment and calls the deterministic apply step (`shipkit_init.py`).

### 1. Choose the ship directory

Ship is **per-machine, not per-project.** It lives in a single directory and coordinates work across repos. Ask the Captain where they'd like it, or default to somewhere alongside their repos (e.g., `~/dev/work/ship/` or `~/ship/`).

### 2. Create the directory structure

```
{ship-dir}/
  captain.md           # Captain's priorities (from core/templates/captain.md)
  queue.md             # Work queue (from core/templates/queue.md)
  CLAUDE.md            # System entry point (from this repo)
  core/mate.md         # First Mate standing orders (request/response base)
  core/crew.md         # Crew standing orders
  inbox/
    captain.md         # Captain's inbox for quick thoughts
    drops/             # Items from external processes
      .gitkeep
  projects/
    {area}/            # Organize by area (e.g., "main", "infra", "frontend")
      tickets/
  logs/
    {area}/            # Watch logs per ticket
    mate/              # Daily mate logs
  docs/
    knowledge/         # Accumulated knowledge (env config, patterns, etc.)
```

Initialize it as a git repo (`git init`). Ship state benefits from version control — it's the coordination substrate.

### 3. Run `/shipkit-init` (it installs hooks + agents + skills)

Run **`/shipkit-init`** in Claude Code from the ship dir. The skill interviews you for the
**tier** (core / autonomous / ui), ship-root, install method, and taste, then calls
`shipkit_init.py`, which: installs the selected tiers' agent defs (substituting `{SHIP_DIR}`
in each def's hook command paths), sets the hook +x bit, **asserts every hook command path
resolves and is executable** (a broken hook path fails OPEN = silent zero enforcement),
installs the skills, verifies the shared `lib/`, and seeds state. For an existing/older
install (incl. the pre-v2 "Mate-runs-/loop" shape), the skill detects how the machine has
diverged, cleans orphans, and migrates config — see the skill's STEP 2.

### 5. Set up captain.md

Create `{ship-dir}/captain.md` from `core/templates/captain.md`. If working interactively, ask the Captain:
- What's their current situation?
- What are the top priorities?
- Any constraints on how work should be done?
- Any standing orders (e.g., "always run tests", "commit frequently")?

### 6. Create initial project areas

Ask the Captain what repos or areas of work they manage. Create `projects/{area}/tickets/` and `logs/{area}/` for each. Common patterns:
- One area per repo (`drip/`, `frontend/`, `infra/`)
- One area per domain (`backend/`, `integrations/`, `devops/`)
- Just `main/` if they're focused on a single codebase

### 7. Verify

The Mate should be able to read ship state and report status. Tell Claude Code: "You're First Mate on this ship. Read `{ship-dir}/core/mate.md` for your standing orders." It should read the queue, captain.md, and inbox, then report that everything is empty and ready for work.

---

## What's in Shipkit

Shipkit is organized into **tiered module folders**. A preset (`presets.json`) selects a set
of folders; each folder is self-describing via its `module.json` (its files + tier + script
deps). Tiers are start-at OR progress-through — re-run `/shipkit-init` at a higher preset to
install the delta.

| Tier / dir | Contents | Purpose |
|-----------|----------|---------|
| **`core/`** (tier 1) | `mate.md` (request/response), `crew.md`, `agents/ship-{crew,lookout,reviewer,pilot}.md`, `hooks/validate-{crew,readonly}-bash.sh`, `templates/`, `mate.local.example.md` | The plain request/response Mate + worker agents + crew-safety hooks. No loop, no Bosun, no UI. |
| **`modules/autonomous/`** (tier 2) | `bosun.md`, `mate-event-driven.md`, `bosun-loop.md`, `agents/ship-{mate,bosun}.md`, `hooks/validate-{mate,mate-mcp,bosun}-*.sh`, `skills/{ship-watch-start,bosun-tick}`, `scripts/{bosun_emit.py,launch-bosun.sh,ship-up.sh,mate-lock.{rb,py}}` | The bg-Mate/Bosun heartbeat kernel. |
| **`modules/wake-monitor/`** (tier 2) | `wake-monitor.md`, `wake_monitor.py`, `wake_monitor_native.py` | The Mate's wake monitor (the one optional capability inside autonomous). |
| **`modules/{subagent-roster,pull-requests,review-cycle,dispatch-bands,sensors}/`** | a doc + `module.json` each | Depth-doctrine modules (roster/PR/review are tier 1; dispatch-bands/sensors tier 2). |
| **`ui/`** (tier 3) | `status-surface.md` + `module.json` (implementation vendored from a live, proven `ui/thread/` seed when the operator locks it) | The thread-first UI slot. |
| **`lib/`** (shared) | `status_writer.py`, `classify_input.py`, `status.schema.md` | Multi-consumer infra; pulled in by whichever module's `module.json` declares it in `lib[]`. |
| Root | `shipkit_init.py`, `presets.json`, `CLAUDE.md`, `README.md`, `loop.config.json`, `scripts/pull-upstream.sh` | The manifest-driven installer + the preset map + sync tooling. |

## Key Concepts

### Ship is per-machine

One ship directory coordinates all your work across repos. Crew agents work in whatever repo the ticket points to, but ship state (queue, tickets, logs) lives in the ship directory.

### Subagent types

Ship defines custom subagents with enforced tool restrictions. Two are long-running **role agents** (the autonomous shape); the rest are dispatched **worker agents**:

| Type | Purpose | Write access | Safety |
|------|---------|-------------|--------|
| `ship-mate` | The First Mate as a bg agent — event-driven coordination | Yes (broad) | Deny-list hook blocks the bright lines (merge/ready/comment/deploy/prod/push-to-main) + confirm-gates MCP writes |
| `ship-bosun` | Heartbeat-owner — runs its own `/loop`, surfaces findings to the Mate via drops | Read-only + `bosun_emit.py` | No Write/Edit/Task; allow-list hook (sole write path is `bosun_emit.py`) |
| `ship-crew` | Standard watches (research + implementation) | Yes | Allow-list hook blocks git writes, rm -rf, gh writes |
| `ship-lookout` | Quick read-only checks | No (enforced) | disallowedTools + allow-list hook for Bash |
| `ship-reviewer` | Independent (non-maker) PR/code review | No (enforced) | Read-only hook |
| `ship-pilot` | Browser interaction (Captain-authorized) | Yes + Chrome MCP | Same git safety as crew |

**Every hook must be executable (`chmod +x`)** — a non-exec hook fails OPEN (silent zero enforcement). `shipkit-init` and `ship-up.sh` set/self-heal the bit.

### Logs are the handoff

When a crew session ends, it writes a log with what was accomplished, current state, next steps, and handoff confidence (1-5). A fresh session reads the log and continues. No context persists between sessions — logs are the memory.

### Crew can't commit

Crew write code and logs, but destructive git operations (commit, push, reset) are blocked by a PreToolUse hook. The Mate or Captain handles commits. This keeps handoffs clean and prevents runaway agents from pushing broken code.

### Two modes: request/response, and the autonomous two-agent kernel

**Base mode is request/response** (tier 1 — `core`). The Captain drives the Mate turn by turn: the Mate checks inbox, checks active work, dispatches if capacity, stays present for steering. Crew run in the background. The Captain can steer at any time. `core/mate.md` alone is a complete doctrine for this.

**Autonomous mode is a two-agent split** (tier 2 — `autonomous`). A **Bosun** owns the heartbeat — it runs its own `/loop` (`bosun-tick`): periodic curate/reconcile/librarian sweeps, surfacing findings to the Mate via wake-class **drops** only when something needs Mate action (it's read-only; its sole write path is `modules/autonomous/scripts/bosun_emit.py`). The **Mate is event-driven** — it boots once via `/ship-watch-start` (re-anchor → mate-lock → arm the wake-monitor → bootstrap the Bosun → preflight → idle), then idles, waking only on events (Captain drops, Bosun drops, crew completions). The Mate does **not** run `/loop` or own a heartbeat tick.

The doctrine lives in `modules/autonomous/bosun.md` + `modules/autonomous/mate-event-driven.md`, paired with [`modules/autonomous/bosun-loop.md`](modules/autonomous/bosun-loop.md). Bring it up with `modules/autonomous/scripts/ship-up.sh` (the Mate) — which itself bootstraps the Bosun via `modules/autonomous/scripts/launch-bosun.sh`. **Running the agents in a sandbox is recommended** (defense-in-depth on top of the bright-line hooks); on macOS [agent-safehouse.dev](https://agent-safehouse.dev/) is a good option. Bare `claude` is the no-sandbox fallback. `/shipkit-init` installs the agent defs (substituting the ship path into the hook commands), sets the hook +x bit, and seeds state.

## Customization

Shipkit is a starting point. As you use it, you'll likely:

- Add knowledge docs for your environment (`docs/knowledge/env-config.md`)
- Create additional subagent types for specialized work
- Extend crew permissions with `core/hooks/crew-allow-local.sh` (see below)
- Add project-specific hooks for domain-specific safety rules
- Evolve the role docs as you learn what works for your team

The core mechanism (watches + logs + structured dispatch) stays stable while everything else adapts.

### Tracking the overlay (`mate.local.md`)

`mate.local.md` — your behavioral-prefs overlay — is **gitignored by default**: the shipkit
convention treats it as operator-private, and `pull-upstream.sh` never touches it. That's the
right default when the overlay holds machine-local or private taste.

But when **the ship directory itself is your durable, version-controlled record** — especially
if you run the autonomous Mate and its rotations hand off through git — you'll usually want to
**track** the overlay instead, so a fresh Mate rotation inherits the accumulated house notes and
dated decisions rather than starting blank. To track it, remove the `mate.local.md` line from
`.gitignore` and commit it. (`/shipkit-init` asks this explicitly during onboarding — STEP 1(e).)
Either way, keep real secrets out of the overlay: house notes are ship history, not a secret
store.

### Extending crew permissions

The crew bash allow-list (`core/hooks/validate-crew-bash.sh`) is synced from upstream. To add project-specific commands (e.g., `aws`, `kubectl`) without losing them on upstream pulls, copy `core/templates/crew-allow-local.sh` to `core/hooks/crew-allow-local.sh` (next to the hook) and add your rules. The validation script sources it automatically if present, and `pull-upstream.sh` never touches it.

## Staying up to date

`scripts/pull-upstream.sh` syncs framework files (role docs, agents, scripts, templates) from upstream shipkit into your ship directory. It never touches project-specific files (`captain.md`, `queue.md`, projects, logs). Dry run by default — run `./scripts/pull-upstream.sh --help` for options. Run it periodically (e.g., when starting a new project phase) to check for upstream improvements.
