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

> You're First Mate on this ship. Read `ship/mate.md` for your standing orders.

The Mate will read ship state, report status, and ask for steering.

### 3. Start working

Drop work items into `inbox/captain.md` — the Mate will triage them into tickets. Or just tell the Mate what you want done. It'll dispatch crew, track progress, and report back.

---

## Bootstrap Instructions (for Claude Code)

**If you're a coding agent reading this:** follow these steps to set up Ship on this machine. Adapt paths and details to the current environment. Ask the Captain questions where noted.

### 1. Choose the ship directory

Ship is **per-machine, not per-project.** It lives in a single directory and coordinates work across repos. Ask the Captain where they'd like it, or default to somewhere alongside their repos (e.g., `~/dev/work/ship/` or `~/ship/`).

### 2. Create the directory structure

```
{ship-dir}/
  captain.md           # Captain's priorities (from templates/captain.md)
  queue.md             # Work queue (from templates/queue.md)
  CLAUDE.md            # System entry point (from this repo)
  mate.md              # First Mate standing orders (from this repo)
  crew.md              # Crew standing orders (from this repo)
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
  scripts/             # Hook scripts for subagent enforcement
```

Initialize it as a git repo (`git init`). Ship state benefits from version control — it's the coordination substrate.

### 3. Install hook scripts

Copy `scripts/validate-crew-bash.sh` and `scripts/validate-readonly-bash.sh` from this repo to `{ship-dir}/scripts/`. Make them executable (`chmod +x`).

### 4. Install subagent definitions

Ship uses custom Claude Code subagents. Copy the files from `agents/` in this repo to `~/.claude/agents/`, **replacing `{SHIP_DIR}`** in hook command paths with the absolute path to the ship directory.

For example, if the ship directory is `/Users/will/dev/work/ship/`, then `{SHIP_DIR}/scripts/validate-crew-bash.sh` becomes `/Users/will/dev/work/ship/scripts/validate-crew-bash.sh`.

**If ship-* agents already exist at `~/.claude/agents/`:** This machine already has a Ship instance. The hook scripts are generic (git safety, not project-specific), so unless the existing agents point to a different ship directory with different hooks, they're probably fine as-is. Check the hook paths — if they point to a valid ship scripts directory, leave them alone. If they're stale or point to a removed directory, overwrite them.

### 5. Set up captain.md

Create `{ship-dir}/captain.md` from `templates/captain.md`. If working interactively, ask the Captain:
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

The Mate should be able to read ship state and report status. Tell Claude Code: "You're First Mate on this ship. Read `{ship-dir}/mate.md` for your standing orders." It should read the queue, captain.md, and inbox, then report that everything is empty and ready for work.

---

## What's in Shipkit

| Directory | Contents | Purpose |
|-----------|----------|---------|
| `agents/` | `ship-mate`, `ship-bosun`, `ship-crew`, `ship-lookout`, `ship-reviewer`, `ship-pilot` | Custom subagent definitions (`/shipkit-init` installs to `~/.claude/agents/`, substituting the ship path) |
| `skills/` | `ship-watch-start`, `bosun-tick`, `shipkit-init` | The boot / heartbeat-tick / onboarding skills |
| `scripts/` | `validate-{mate,bosun,crew,readonly}-bash.sh`, `validate-mate-mcp.sh`, `bosun_emit.py`, `status_writer.py`, `classify_input.py`, `wake_monitor.py`, `mate-lock.{rb,py}`, `ship-up.sh`, `launch-bosun.sh`, `shipkit_init.py` | Bright-line hooks + the autonomous kernel's tooling |
| `modules/` | `bosun-loop`, `mate-event-driven`, `subagent-roster`, `pull-requests`, `review-cycle`, `dispatch-bands`, `sensors`, `wake-monitor` | Optional/depth doctrine layered on the core docs |
| `examples/` | `status-surface/` | Reference browser PWA console (renders `status.json` + a steer box) |
| `templates/` | `ticket.md`, `captain.md`, `queue.md`, `crew-allow-local.sh`, `bosun-allow-local.sh` | Templates + per-deployment hook-extension stubs |
| Root | `mate.md`, `bosun.md`, `crew.md`, `mate.local.example.md`, `loop.config.json`, `CLAUDE.md` | Role standing orders + config seam |

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

**Base mode is request/response.** The Captain drives the Mate turn by turn: the Mate checks inbox, checks active work, dispatches if capacity, stays present for steering. Crew run in the background. The Captain can steer at any time. `mate.md` alone is a complete doctrine for this.

**Autonomous mode is a two-agent split** (the optional kernel this repo ships). A **Bosun** owns the heartbeat — it runs its own `/loop` (`bosun-tick`): periodic curate/reconcile/librarian sweeps, surfacing findings to the Mate via wake-class **drops** only when something needs Mate action (it's read-only; its sole write path is `bosun_emit.py`). The **Mate is event-driven** — it boots once via `/ship-watch-start` (re-anchor → mate-lock → arm the wake-monitor → bootstrap the Bosun → preflight → idle), then idles, waking only on events (Captain drops, Bosun drops, crew completions). The Mate does **not** run `/loop` or own a heartbeat tick.

The doctrine lives in `bosun.md` + `mate.md` (event-driven section) and the paired modules [`modules/bosun-loop.md`](modules/bosun-loop.md) + [`modules/mate-event-driven.md`](modules/mate-event-driven.md). Bring it up with `scripts/ship-up.sh` (the Mate) — which itself bootstraps the Bosun via `scripts/launch-bosun.sh`. **Running the agents in a sandbox is recommended** (defense-in-depth on top of the bright-line hooks); on macOS [agent-safehouse.dev](https://agent-safehouse.dev/) is a good option. Bare `claude` is the no-sandbox fallback. `/shipkit-init` installs the agent defs (substituting the ship path into the hook commands), sets the hook +x bit, and seeds state.

## Customization

Shipkit is a starting point. As you use it, you'll likely:

- Add knowledge docs for your environment (`docs/knowledge/env-config.md`)
- Create additional subagent types for specialized work
- Extend crew permissions with `scripts/crew-allow-local.sh` (see below)
- Add project-specific hooks for domain-specific safety rules
- Evolve the role docs as you learn what works for your team

The core mechanism (watches + logs + structured dispatch) stays stable while everything else adapts.

### Extending crew permissions

The crew bash allow-list (`scripts/validate-crew-bash.sh`) is synced from upstream. To add project-specific commands (e.g., `aws`, `kubectl`) without losing them on upstream pulls, copy `templates/crew-allow-local.sh` to `scripts/crew-allow-local.sh` in your ship directory and add your rules. The validation script sources it automatically if present, and `pull-upstream.sh` never touches it.

## Staying up to date

`scripts/pull-upstream.sh` syncs framework files (role docs, agents, scripts, templates) from upstream shipkit into your ship directory. It never touches project-specific files (`captain.md`, `queue.md`, projects, logs). Dry run by default — run `./scripts/pull-upstream.sh --help` for options. Run it periodically (e.g., when starting a new project phase) to check for upstream improvements.
