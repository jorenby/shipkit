# Ship Roles

## Core Roles

Core roles live at the top level of your ship directory. They are the system — Captain, First Mate, and Crew participate in the dispatch-execute-log loop.

| Role | File | Purpose |
|------|------|---------|
| **Captain** (human) | `captain.md` | Strategic decisions, priorities, external communications |
| **First Mate** (Claude) | `mate.md` | Queue management, crew dispatch, status tracking |
| **Crew** (Claude, subagents) | `crew.md` | Bounded work sessions with structured handoffs |

## Extension Roles

Extension roles live in `roles/{name}/` and are opt-in. They add new capabilities without modifying core.

### Adding a Role

1. Create `roles/{name}/` directory
2. Add a `role.md` manifest (see `_template/role.md`)
3. Add standing orders and any supporting docs
