# Ship: Bounded-Context Orchestration for Claude Code

Ship is a system for coordinating multiple Claude Code agent sessions around your engineering work. It structures handoffs between fresh sessions so context rot doesn't eat your progress.

**New here?** Read the [Glossary](GLOSSARY.md) for Ship's vocabulary, browse [`examples/`](examples/) to see a fully worked (synthetic) ship, and keep [QUICKSTART.md](QUICKSTART.md) handy for prerequisites and troubleshooting. The step-by-step setup is under [Getting started](#getting-started) below.

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

**The fast way — have Claude set it up for you.** Already in a Claude Code session? Paste
this and it does the rest:

> Clone `https://github.com/wstrinz/shipkit` into a directory named `ship` alongside my other repos — the clone
> IS the ship, don't create a separate ship dir. Then follow the clone's setup skill
> (`.claude/skills/shipkit-setup/SKILL.md`) to set the ship up, asking me its questions as
> you go.

Claude clones, checks prerequisites (it'll tell you if `jq` is missing), runs the setup
interview (or the three-question `--defaults` fast path), and verifies enforcement is
actually armed. Then pick up at [step 3](#3-restart-claude-code-then-run-your-first-watch)
for your first watch.

Prefer to drive it yourself, or want to see what the setup does? The same path, step by
step:

### 1. Clone shipkit — the clone IS your ship

Ship is **per-machine, not per-project**: one directory coordinates work across all your
repos. The shipkit clone itself is that directory — **don't create a separate "ship dir"**
(the enforcement hooks live in this repo, and the installed agents point back into it; a
separate dir disarms them, and the installer fails loudly if you try).

```
git clone https://github.com/wstrinz/shipkit ship
cd ship
```

Put it wherever you keep your repos (e.g. `~/dev/work/ship`). The clone already contains the
working skeleton — `captain.md`, `queue.md`, `inbox/`, `projects/`, `logs/`, the role docs
(`core/mate.md`, `core/crew.md`) — plus the installer.

**Prerequisites:** `git`, `python3`, `bash`, and **`jq`** (the enforcement hooks parse their
input with jq; the installer hard-fails without it — `brew install jq` / `apt-get install jq` /
`winget install jqlang.jq`). On Windows the hooks run under Git-Bash.

### 2. Run the setup

Open Claude Code in the clone and run:

> `/shipkit-setup`

The setup skill ships project-level (`.claude/skills/shipkit-setup/`), so the command
resolves immediately in a fresh clone — no install step first. It's always the version
your checkout carries, for first setup, tier bumps, and upgrades alike.

The fresh-machine default is three questions and one command (`python3 shipkit_init.py
--defaults`): the **core** tier — a request/response Mate + worker agents + safety hooks, no
background autonomy. Start there; bumping to `autonomous` later is a clean delta. The setup
verifies enforcement is actually armed and **fails loudly if it isn't**.

If you're a coding agent reading this: don't hand-copy hooks/agents — run the setup skill; it
carries the judgment and calls the deterministic apply step (`shipkit_init.py`).

### 3. Restart Claude Code, then run your first watch

Restart the session (Claude Code snapshots agent defs at session start), open it in the ship
dir, and run **one command**:

> `/ship-tour`

Lesson 1 takes the Mate role itself and walks one real cycle with you — read ship state,
fill in `captain.md` (the tour interviews you), run one real inbox item through the loop,
wind down. The other lessons (crew dispatch, the review gate, going autonomous, staying
current) are short and self-contained — take any of them, anytime. (Both skills are
project-level, so they resolve in any fresh clone.)

Driving without the tour? The manual boot line is:

> You're First Mate on this ship. Read `core/mate.md` for your standing orders.

The Mate reads ship state, reports status, and asks for steering; drop work into
`inbox/captain.md` and it triages into tickets, dispatches crew, and reports back.

### Upgrading an existing install?

Tier bumps and older (pre-v2) installs go through `/shipkit-setup` too — the upgrade judgment
lives in [`.claude/skills/shipkit-setup/upgrade.md`](.claude/skills/shipkit-setup/upgrade.md), and
[`UPGRADING.md`](UPGRADING.md) is the runnable runbook.

---

## What's in Shipkit

Shipkit is organized into **tiered module folders**. A preset (`presets.json`) selects a set
of folders; each folder is self-describing via its `module.json` (its files + tier + script
deps). Tiers are start-at OR progress-through — re-run `/shipkit-setup` at a higher preset to
install the delta.

| Tier / dir | Contents | Purpose |
|-----------|----------|---------|
| **`core/`** (tier 1) | `mate.md` (request/response), `crew.md`, `agents/ship-{crew,lookout}.md` (reviewer ships with `modules/review-cycle/`, pilot with opt-in `modules/pilot/`), `hooks/validate-{crew,readonly}-bash.sh`, `templates/`, `mate.local.example.md` | The plain request/response Mate + worker agents + crew-safety hooks. No loop, no Bosun, no UI. |
| **`modules/autonomous/`** (tier 2) | `bosun.md`, `mate-event-driven.md`, `bosun-loop.md`, `agents/ship-{mate,bosun}.md`, `hooks/validate-{mate,mate-mcp,bosun}-*.sh`, `skills/{ship-watch-start,bosun-tick}`, `scripts/{bosun_emit.py,launch-bosun.sh,ship-up.sh,mate-lock.{rb,py}}` | The bg-Mate/Bosun heartbeat kernel. |
| **`modules/wake-monitor/`** (tier 2) | `wake-monitor.md`, `wake_monitor.py`, `wake_monitor_native.py` | The Mate's wake monitor (the one optional capability inside autonomous). |
| **`modules/{session-ceremony,subagent-roster,pull-requests,review-cycle,dispatch-bands,sensors,night-economy}/`** | a doc + `module.json` each | Depth-doctrine modules (session-ceremony/roster/PR/review are tier 1; dispatch-bands/sensors/night-economy tier 2). |
| **`modules/peer-comms/`** (experimental, opt-in) | `peer-comms.md`, `peer_send.py`, `peer_envelope.py` | Cross-instance Mate↔Mate messaging (two ships coordinate via envelope-stamped drops). In **no preset** — opt in with `--modules peer-comms`. A peer message is input, never authority. |
| **`modules/navigator/`** (opt-in) | `navigator.md`, `skills/navigator/` | A second operating seat that advises and does not execute — research, ticket shaping, architecture review, queue *strategy*. Never writes `queue.md` (changes arrive as drops the Mate applies), never dispatches or commits product code. In **no preset** — opt in with `--modules navigator`; core is a complete ship without it. |
| **`lib/`** (shared) | `status_writer.py`, `classify_input.py`, `status.schema.md` | Multi-consumer infra; pulled in by whichever module's `module.json` declares it in `lib[]`. |
| Root | `shipkit_init.py`, `presets.json`, `CLAUDE.md`, `README.md`, `loop.config.example.json`, `scripts/pull-upstream.sh` | The manifest-driven installer + the preset map + sync tooling. (`loop.config.json` is generated on first install and gitignored.) |

## Key Concepts

### Ship is per-machine

One ship directory coordinates all your work across repos. Crew agents work in whatever repo the ticket points to, but ship state (queue, tickets, logs) lives in the ship directory.

**One ship per machine is a current limitation, not a virtue:** agent defs install globally (`~/.claude/agents`) with a single baked ship path in their hook commands, so a second ship-root would fight over them. If you need separate work/personal ships, that's the constraint to lift first.

### Subagent types

Ship defines custom subagents with enforced tool restrictions. Two are long-running **role agents** (the autonomous shape); the rest are dispatched **worker agents**:

| Type | Purpose | Write access | Safety |
|------|---------|-------------|--------|
| `ship-mate` | The First Mate as a bg agent — event-driven coordination | Yes (broad) | Deny-list hook blocks the bright lines (merge/ready/comment/deploy/prod/push-to-main) + confirm-gates MCP writes |
| `ship-bosun` | Heartbeat-owner — runs its own `/loop`, surfaces findings to the Mate via drops | Read-only + `bosun_emit.py` | No Write/Edit/Task; allow-list hook (sole write path is `bosun_emit.py`) |
| `ship-crew` | Standard watches (research + implementation) | Yes | Allow-list hook blocks git writes, rm -rf, gh writes; Write/Edit path guard on ship state (queue.md, captain.md, inbox/) |
| `ship-lookout` | Quick read-only checks | No (enforced) | disallowedTools + allow-list hook for Bash |
| `ship-reviewer` | Independent (non-maker) PR/code review | No (enforced) | Read-only hook |
| `ship-pilot` | Browser interaction (Captain-authorized) | Yes + Chrome MCP | Same git safety as crew |

**Hook commands invoke via an install-time-resolved bash interpreter**, so enforcement never depends on the exec bit or shebang resolution — it works on POSIX shells and Git-Bash on Windows alike, and the installer **fails loudly** if it can't resolve a working interpreter or if any installed def still carries a literal `{SHIP_DIR}` (an unenforced install must never exit green). The full mechanics live in `loop.config.example.json` (`_hooks`); the scars behind the design, in [`DECISIONS.md`](DECISIONS.md).

### Logs are the handoff

When a crew session ends, it writes a log with what was accomplished, current state, next steps, and handoff confidence (1-5). A fresh session reads the log and continues. No context persists between sessions — logs are the memory.

### Crew can't commit

Crew write code and logs, but destructive git operations (commit, push, reset) are blocked by a PreToolUse hook. The Mate or Captain handles commits. This keeps handoffs clean and prevents runaway agents from pushing broken code.

### Two modes: request/response, and the autonomous two-agent kernel

**Base mode is request/response** (tier 1 — `core`). The Captain drives the Mate turn by turn: the Mate checks inbox, checks active work, dispatches if capacity, stays present for steering. Crew run in the background. The Captain can steer at any time. `core/mate.md` alone is a complete doctrine for this.

**Autonomous mode is a two-agent split** (tier 2 — `autonomous`). A **Bosun** owns the heartbeat — it runs its own `/loop` (`bosun-tick`): periodic curate/reconcile/librarian sweeps, surfacing findings to the Mate via wake-class **drops** only when something needs Mate action (it's read-only; its sole write path is `modules/autonomous/scripts/bosun_emit.py`). The **Mate is event-driven** — it boots once via `/ship-watch-start` (re-anchor → mate-lock → arm the wake-monitor → bootstrap the Bosun → preflight → idle), then idles, waking only on events (Captain drops, Bosun drops, crew completions). The Mate does **not** run `/loop` or own a heartbeat tick.

The doctrine lives in `modules/autonomous/bosun.md` + `modules/autonomous/mate-event-driven.md`, paired with [`modules/autonomous/bosun-loop.md`](modules/autonomous/bosun-loop.md). Bring it up with `modules/autonomous/scripts/ship-up.sh` (the Mate) — which itself bootstraps the Bosun via `modules/autonomous/scripts/launch-bosun.sh`. **Running the agents in a sandbox is recommended** (defense-in-depth on top of the bright-line hooks); on macOS [agent-safehouse.dev](https://agent-safehouse.dev/) is a good option. Bare `claude` is the no-sandbox fallback. `/shipkit-setup` installs the agent defs (substituting the ship path into the hook commands), sets the hook +x bit, and seeds state.

## Customization

Shipkit is a starting point. As you use it, you'll likely:

- Add knowledge docs for your environment (`docs/knowledge/env-config.md`)
- Add a module for a new capability — including new agent types; a module can ship agent
  defs, skills, hooks, and scripts (see [modules/README.md](modules/README.md) → "Adding a module")
- Extend crew permissions with `core/hooks/crew-allow-local.sh` (see below)
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
`.gitignore` and commit it. (`/shipkit-setup` asks this explicitly in its full interview — item (e).)
Either way, keep real secrets out of the overlay: house notes are ship history, not a secret
store.

The same convention covers your ship's decisions log: **`DECISIONS.local.md`** (seed from
`DECISIONS.local.example.md`) holds *your* dated incidents and Captain rulings — gitignored by
default, trackable under the same reasoning. The tracked `DECISIONS.md` is the framework's own
design history and stays impersonal; if a local lesson would hold on any ship, upstream it there.

### Extending crew permissions

The crew bash allow-list (`core/hooks/validate-crew-bash.sh`) is synced from upstream. To add project-specific commands (e.g., `aws`, `kubectl`) without losing them on upstream pulls, copy `core/templates/crew-allow-local.sh` to `core/hooks/crew-allow-local.sh` (next to the hook) and add your rules. The validation script sources it automatically if present, and `pull-upstream.sh` never touches it.

## Staying up to date

`scripts/pull-upstream.sh` syncs framework files (role docs, agents, scripts, templates) from upstream shipkit into your ship directory. It never touches project-specific files (`captain.md`, `queue.md`, projects, logs). Dry run by default — run `./scripts/pull-upstream.sh --help` for options. Run it periodically (e.g., when starting a new project phase) to check for upstream improvements.

### Upgrading an existing / older install

For standing a **new machine** up, a **tier bump**, or **upgrading an older (pre-v2) install** with operator divergence, follow [`UPGRADING.md`](UPGRADING.md) — the runnable-verbatim runbook a foreign Ship instance's Mate uses: clone/fetch, `/shipkit-setup`, the reason-about-divergence conversation, the post-install verification checklist, rollback, and the platform assumptions (macOS / Linux / Windows-with-Git-Bash).
