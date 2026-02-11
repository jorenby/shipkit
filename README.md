# Shipkit: Bounded-Context Orchestration for Claude Code

A specification for running multi-agent Claude Code sessions with structured handoffs. Ship uses a nautical metaphor for role-based orchestration:

- **Captain** (human): Sets priorities, resolves escalations, makes strategic decisions
- **First Mate** (Claude): Coordinates operations, dispatches crew, manages the queue
- **Crew** (Claude subagents): Execute bounded work sessions, write logs, terminate cleanly

## Bootstrap: Setting Up a New Ship

**This is designed to be executed by a Claude Code session.** Tell Claude Code:

> Read the shipkit docs at `{path-to-shipkit}/` and set up Ship for this project.

Claude Code should read this file, then the role docs, and execute the setup below. If you're a coding agent reading this: follow these steps, adapting paths and details to the current project.

### 1. Create the ship directory structure

```
{project}/ship/
  captain.md         # Captain's priorities (create from template)
  queue.md           # Work queue (create from template)
  inbox/
    captain.md       # Captain's inbox for quick thoughts
    drops/           # Items from external processes
      .gitkeep
  projects/
    {project-name}/
      tickets/       # Work tickets
  logs/
    {project-name}/  # Watch logs per ticket
    mate/            # Daily mate logs
  docs/
    knowledge/       # Accumulated project knowledge
  scripts/           # Hook scripts (copy from shipkit)
```

### 2. Install hook scripts

Copy `scripts/validate-crew-bash.sh` and `scripts/validate-reviewer-bash.sh` from shipkit to the project's `ship/scripts/` directory. Make them executable.

### 3. Install subagent definitions

Ship uses custom Claude Code subagents defined in `~/.claude/agents/`. Copy the files from `agents/` in this repo to `~/.claude/agents/`, **replacing the `{SHIP_DIR}` placeholder** in hook command paths with the absolute path to the project's `ship/` directory.

**Multi-project considerations:** The agent files are user-level (shared across all projects). If multiple Ship instances exist:
- The hook script paths in agent files will point to whichever project was last set up
- The hook scripts are functionally identical across projects (they enforce generic git safety, not project-specific rules), so this is usually fine
- If you need project-specific hooks, use project-level agents (`.claude/agents/`) instead of user-level
- Exercise judgment: if the existing agents look correct and the hooks are generic, you may not need to overwrite them

### 4. Copy role documents

Copy `mate.md`, `crew.md`, and `CLAUDE.md` from shipkit to the project's `ship/` directory. These are the generic standing orders. The project will customize them over time.

### 5. Set up captain.md

Create `ship/captain.md` from the template. This is where the human sets priorities and constraints. Ask the Captain what their current situation, priorities, and constraints are if working interactively.

### 6. Create queue.md

Create `ship/queue.md` from the template. Start empty — the Mate will populate it as work comes in.

### 7. Verify

After setup, the Mate should be able to read ship state and report status. Test by telling Claude Code: "You're First Mate on this ship. Read ship/mate.md for your standing orders."

## What's in Shipkit

| Directory | Contents | Purpose |
|-----------|----------|---------|
| `agents/` | `ship-crew.md`, `ship-lookout.md`, `ship-reviewer.md` | Custom subagent definitions (install to `~/.claude/agents/`) |
| `scripts/` | `validate-crew-bash.sh`, `validate-reviewer-bash.sh` | PreToolUse hook scripts for enforced safety |
| `templates/` | `ticket.md`, `captain.md`, `queue.md` | Templates for project-specific files |
| Root | `mate.md`, `crew.md`, `CLAUDE.md` | Role standing orders (copy to project) |

## Key Concepts

### Subagent Types

Crew are dispatched as custom subagents with enforced tool restrictions:

| Type | Purpose | Write access | Safety |
|------|---------|-------------|--------|
| `ship-crew` | Standard watches (research + implementation) | Yes | Hook blocks git commit/push/reset |
| `ship-lookout` | Quick read-only checks | No (enforced) | Cannot write or edit files |
| `ship-reviewer` | PR triage in agent teams | No (enforced) | Hook blocks gh approve/comment |

Standing orders are baked into each subagent's system prompt. The Mate dispatches using `subagent_type: "ship-crew"` (or lookout/reviewer) instead of `"general-purpose"`.

### Logs are the handoff mechanism

When a crew session ends, it writes a log with what was accomplished, current state, next steps, and handoff confidence (1-5). A fresh crew session reads the log and continues. No context is assumed to persist between sessions.

### Crew never touch queue.md

The queue is owned by the Mate. Crew only work on their assigned ticket and write logs. This is enforced by a PreToolUse hook.

### Bias toward checkpointing

If you'd be sad to lose it, commit it and write a log. Better to checkpoint too often than lose work to context limits.

### The Mate runs the loop

The Mate continuously: checks inbox, checks active work, dispatches if capacity, stays present for steering. This keeps the ship responsive while work progresses in background.

## Customization

Shipkit is a starting point. As you use it, you'll likely want to:

- Add project-specific knowledge docs (`ship/docs/knowledge/`)
- Add environment config for your dev setup
- Add PR triage workflows if you have a review tool
- Create additional subagent types for specialized work
- Add project-specific hooks for domain-specific safety rules

The system is designed to evolve. The core handoff mechanism (watches + logs + structured dispatch) stays stable while everything else adapts to your needs.
