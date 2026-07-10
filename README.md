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

### 1. Clone shipkit — the clone IS your ship

Ship is **per-machine, not per-project**: one directory coordinates work across all your
repos. The shipkit clone itself is that directory — **don't create a separate "ship dir"**
(the enforcement hooks live in this repo, and the installed agents point back into it; a
separate dir disarms them, and the installer fails loudly if you try).

```
git clone <shipkit-url> ship
cd ship
```

Put it wherever you keep your repos (e.g. `~/dev/work/ship`). The clone already contains the
working skeleton — `captain.md`, `queue.md`, `inbox/`, `projects/`, `logs/`, the role docs
(`core/mate.md`, `core/crew.md`) — plus the installer.

**Prerequisites:** `git`, `python3`, `bash`, and **`jq`** (the enforcement hooks parse their
input with jq; the installer hard-fails without it — `brew install jq` / `apt-get install jq` /
`winget install jqlang.jq`). On Windows the hooks run under Git-Bash. `ruby` is optional (the
autonomous mate-lock has a `.py` parity).

### 2. Run the setup

Open Claude Code in the clone and say:

> Run the Ship setup: read `skills/shipkit-setup/SKILL.md` and follow its FAST PATH.

(There's no slash command yet on a fresh machine — the setup skill installs itself, so
`/shipkit-setup` resolves from the next session on, for tier bumps and upgrades.)

The fresh-machine default is three questions and one command (`python3 shipkit_init.py
--defaults`): the **core** tier — a request/response Mate + worker agents + safety hooks, no
background autonomy. Start there; bumping to `autonomous` later is a clean delta. The setup
verifies enforcement is actually armed and **fails loudly if it isn't**.

If you're a coding agent reading this: don't hand-copy hooks/agents — run the setup skill; it
carries the judgment and calls the deterministic apply step (`shipkit_init.py`).

### 3. Restart Claude Code, then run your first watch

Restart the session (Claude Code snapshots agent defs at session start), open it in the ship
dir, and say:

> You're First Mate on this ship. Read `core/mate.md` for your standing orders.

The Mate reads ship state, reports status, and asks for steering. Fill in `captain.md` with
your situation and priorities (ask the Mate to interview you), drop work into
`inbox/captain.md`, and the Mate will triage it into tickets under `projects/{area}/`,
dispatch crew, and report back. The setup skill's "Your first watch" section walks you
through one full cycle.

### Upgrading an existing install?

Tier bumps and older (pre-v2) installs go through `/shipkit-setup` too — the upgrade judgment
lives in [`skills/shipkit-setup/upgrade.md`](skills/shipkit-setup/upgrade.md), and
[`UPGRADING.md`](UPGRADING.md) is the runnable runbook.

---

## What's in Shipkit

Shipkit is organized into **tiered module folders**. A preset (`presets.json`) selects a set
of folders; each folder is self-describing via its `module.json` (its files + tier + script
deps). Tiers are start-at OR progress-through — re-run `/shipkit-setup` at a higher preset to
install the delta.

| Tier / dir | Contents | Purpose |
|-----------|----------|---------|
| **`core/`** (tier 1) | `mate.md` (request/response), `crew.md`, `agents/ship-{crew,lookout,reviewer,pilot}.md`, `hooks/validate-{crew,readonly}-bash.sh`, `templates/`, `mate.local.example.md` | The plain request/response Mate + worker agents + crew-safety hooks. No loop, no Bosun, no UI. |
| **`modules/autonomous/`** (tier 2) | `bosun.md`, `mate-event-driven.md`, `bosun-loop.md`, `agents/ship-{mate,bosun}.md`, `hooks/validate-{mate,mate-mcp,bosun}-*.sh`, `skills/{ship-watch-start,bosun-tick}`, `scripts/{bosun_emit.py,launch-bosun.sh,ship-up.sh,mate-lock.{rb,py}}` | The bg-Mate/Bosun heartbeat kernel. |
| **`modules/wake-monitor/`** (tier 2) | `wake-monitor.md`, `wake_monitor.py`, `wake_monitor_native.py` | The Mate's wake monitor (the one optional capability inside autonomous). |
| **`modules/{subagent-roster,pull-requests,review-cycle,dispatch-bands,sensors}/`** | a doc + `module.json` each | Depth-doctrine modules (roster/PR/review are tier 1; dispatch-bands/sensors tier 2). |
| **`modules/peer-comms/`** (experimental, opt-in) | `peer-comms.md`, `peer_send.py`, `peer_envelope.py` | Cross-instance Mate↔Mate messaging (two ships coordinate via envelope-stamped drops). In **no preset** — opt in with `--modules peer-comms`. A peer message is input, never authority. |
| **`ui/`** (tier 3) | `status-surface.md` + `module.json` (implementation vendored from a live, proven `ui/thread/` seed when the operator locks it) | The thread-first UI slot. |
| **`lib/`** (shared) | `status_writer.py`, `classify_input.py`, `status.schema.md` | Multi-consumer infra; pulled in by whichever module's `module.json` declares it in `lib[]`. |
| Root | `shipkit_init.py`, `presets.json`, `CLAUDE.md`, `README.md`, `loop.config.example.json`, `scripts/pull-upstream.sh` | The manifest-driven installer + the preset map + sync tooling. (`loop.config.json` is generated on first install and gitignored.) |

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

**Hook commands invoke via a resolved bash interpreter** — the installed agent defs render each hook as `<interpreter> <abs-path>` (a single-quoted YAML scalar, forward slashes), so enforcement runs the script under `bash` and does **not** depend on the exec bit or shebang resolution. The interpreter is **resolved at install time**: POSIX keeps a bare `bash`; Windows resolves an **absolute Git-Bash path** (a bare `bash` on Windows can resolve to WSL's `System32\bash.exe` stub, which can't see the Windows script path → silent fail-open) and FAILS the install if no Git-Bash is found. Works on POSIX shells AND Git-Bash on Windows (NTFS has no exec bit). `shipkit-setup` and `ship-up.sh` still `chmod +x` as POSIX belt-and-suspenders, and `shipkit-setup` runs a placeholder-verification pass that FAILS LOUDLY if any installed agent def still carries a literal `{SHIP_DIR}` or a rendered interpreter path that doesn't exist (either = a garbage hook command = enforcement silently OFF).

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
`.gitignore` and commit it. (`/shipkit-setup` asks this explicitly in its full interview — item (e).)
Either way, keep real secrets out of the overlay: house notes are ship history, not a secret
store.

### Extending crew permissions

The crew bash allow-list (`core/hooks/validate-crew-bash.sh`) is synced from upstream. To add project-specific commands (e.g., `aws`, `kubectl`) without losing them on upstream pulls, copy `core/templates/crew-allow-local.sh` to `core/hooks/crew-allow-local.sh` (next to the hook) and add your rules. The validation script sources it automatically if present, and `pull-upstream.sh` never touches it.

## Staying up to date

`scripts/pull-upstream.sh` syncs framework files (role docs, agents, scripts, templates) from upstream shipkit into your ship directory. It never touches project-specific files (`captain.md`, `queue.md`, projects, logs). Dry run by default — run `./scripts/pull-upstream.sh --help` for options. Run it periodically (e.g., when starting a new project phase) to check for upstream improvements.

### Upgrading an existing / older install

For standing a **new machine** up, a **tier bump**, or **upgrading an older (pre-v2) install** with operator divergence, follow [`UPGRADING.md`](UPGRADING.md) — the runnable-verbatim runbook a foreign Ship instance's Mate uses: clone/fetch, `/shipkit-setup`, the reason-about-divergence conversation, the post-install verification checklist, and rollback. It states the platform assumptions explicitly (bash hooks invoked via an install-time-resolved bash interpreter → macOS/Linux/Windows-with-Git-Bash; the exec bit is POSIX-only belt-and-suspenders, WSL not required for the hooks — and a bare `bash` is NOT used on Windows because it can resolve to the WSL stub).
