# Shipkit: Bounded-Context Orchestration for Claude Code

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
| `agents/` | `ship-crew.md`, `ship-lookout.md` | Custom subagent definitions (install to `~/.claude/agents/`) |
| `scripts/` | `validate-crew-bash.sh`, `validate-readonly-bash.sh` | PreToolUse hook scripts for enforced safety |
| `templates/` | `ticket.md`, `captain.md`, `queue.md` | Templates for ship-specific files |
| `roles/` | `README.md`, `_template/` | Extension roles directory (add custom roles here) |
| Root | `mate.md`, `crew.md`, `CLAUDE.md` | Role standing orders (copy to ship directory) |

## Key Concepts

### Ship is per-machine

One ship directory coordinates all your work across repos. Crew agents work in whatever repo the ticket points to, but ship state (queue, tickets, logs) lives in the ship directory.

### Subagent types

Crew are dispatched as custom subagents with enforced tool restrictions:

| Type | Purpose | Write access | Safety |
|------|---------|-------------|--------|
| `ship-crew` | Standard watches (research + implementation) | Yes | Allow-list hook blocks git writes, rm -rf, gh writes |
| `ship-lookout` | Quick read-only checks | No (enforced) | disallowedTools + allow-list hook for Bash |

### Logs are the handoff

When a crew session ends, it writes a log with what was accomplished, current state, next steps, and handoff confidence (1-5). A fresh session reads the log and continues. No context persists between sessions — logs are the memory.

### Crew can't commit

Crew write code and logs, but destructive git operations (commit, push, reset) are blocked by a PreToolUse hook. The Mate or Captain handles commits. This keeps handoffs clean and prevents runaway agents from pushing broken code.

### The Mate runs the loop

The Mate continuously: checks inbox, checks active work, dispatches if capacity, stays present for steering. Crew run in the background. The Captain can steer the Mate at any time without waiting for crew to finish.

## Customization

Shipkit is a starting point. As you use it, you'll likely:

- Add knowledge docs for your environment (`docs/knowledge/env-config.md`)
- Create additional subagent types for specialized work
- Add project-specific hooks for domain-specific safety rules
- Evolve the role docs as you learn what works for your team

The core mechanism (watches + logs + structured dispatch) stays stable while everything else adapts.
