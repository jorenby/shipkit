# Ship Orchestration

A bounded-context orchestration system for Claude Code. Context rot is the enemy - this system structures handoffs between fresh agent sessions.

## Roles

**Captain (human)**: Strategic decisions. Sets priorities in `captain.md`, resolves escalations, merges code.

**First Mate (Claude, coordination)**: Operational coordination. Owns `queue.md`, dispatches crew, reviews logs. Read `mate.md` when told "you're First Mate".

**Crew (Claude, autonomous subagents)**: Bounded work sessions. Dispatched by Mate as custom subagents, execute work, write logs, terminate.

## Subagent Types

Crew are dispatched as custom subagents (`~/.claude/agents/ship-*.md`) with enforced tool restrictions:

| Type | Purpose | Write access | Safety |
|------|---------|-------------|--------|
| `ship-crew` | Standard watches (research + implementation) | Yes | Hook blocks commit/push/reset |
| `ship-lookout` | Quick read-only checks | No (enforced) | Cannot write or edit files |
| `ship-reviewer` | PR triage in agent teams | No (enforced) | Hook blocks gh approve/comment |

Standing orders are baked into each subagent's system prompt. See `mate.md` for dispatch patterns.

## Key Files

- `captain.md` - Captain's standing orders and priorities
- `queue.md` - Work queue (Mate-owned, crew read-only)
- `crew.md` - Standing orders for crew agents (also baked into ship-crew subagent)
- `mate.md` - Standing orders for First Mate
- `projects/{name}/tickets/` - Work tickets
- `logs/{project}/{ticket}/` - Watch logs (handoff mechanism)
- `inbox/` - Incoming items (captain.md for inbox, drops/ for external processes)
- `scripts/` - Hook scripts for subagent enforcement

## Critical Rules

- **Crew never touch queue.md** - Mate owns dispatch, enforced by hook
- **Crew are autonomous agents** - Not mode-switches within Mate's session
- **Crew can't commit/push** - Enforced by PreToolUse hook on ship-crew
- **Bias toward checkpointing** - If you'd be sad to lose it, commit and log
- **Logs are the handoff** - A fresh agent should continue from logs alone

## Getting Started

See `README.md` for bootstrap instructions.
