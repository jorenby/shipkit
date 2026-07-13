# Modules

Each module is a **self-contained folder** with a `module.json` (its files + tier + script
deps) and a doc. They layer on top of the general core (`core/mate.md` + `core/crew.md`).
Core stays readable on its own; each module is referenced by one line from core. A preset
(`presets.json`) selects a set of module folders — turn on what you want via `/shipkit-setup`
and ignore the rest. A core-only (tier-1) operator needs none of the tier-2 modules.

**The autonomous shape is the `autonomous/` module** (tier 2) — a **two-agent split**: the
Bosun owns the heartbeat, the Mate is event-driven. That doctrine lives in the autonomous
module's two paired docs — [autonomous/bosun-loop.md](autonomous/bosun-loop.md) (the
heartbeat half) and [autonomous/mate-event-driven.md](autonomous/mate-event-driven.md) (the
idle/wake half), alongside `autonomous/bosun.md`. They replace the older single "Mate runs
the loop" doctrine. The skills (`ship-watch-start`, `bosun-tick`, both under
`autonomous/skills/`) are the operative procedure. The `wake-monitor/` module is the one
optional capability *inside* the autonomous tier (event-driven works on the fallback timer
without it).

The remaining modules are *depth docs* pared out of a core section that stays functional
inline (session-ceremony, subagent-roster, pull-requests, review-cycle — tier 1) or
*capabilities* for the autonomous tier (dispatch-bands, sensors — tier 2). All are referenced from core as a
**plain (non-`@`) pointer** (read-on-demand).

| Module | Tier | For | What it adds |
|---|---|---|---|
| [autonomous/bosun-loop.md](autonomous/bosun-loop.md) | 2 | The Bosun (heartbeat) | The **complete** heartbeat doctrine: the bosun-tick loop, self-pacing **by heat** (not headroom), `/loop`-not-`/goal` keep-alive (the exit-guard, folded in), restart/post-compaction continuation. |
| [autonomous/mate-event-driven.md](autonomous/mate-event-driven.md) | 2 | The Mate (idle/wake) | The **complete** event-driven-Mate doctrine: the core inversion (no `/loop`, no timer, headroom-not-a-blocker), wake sources, the per-wake handler, single-instance + lock, post-compaction continuation, structural bright lines. |
| [wake-monitor/wake-monitor.md](wake-monitor/wake-monitor.md) | 2 | Event-driven Mate | The watcher that wakes the idle Mate on directives (incl. Bosun drops). Contract + the pitfalls (enumerate-don't-glob, dedup-by-filename, classify-before-wake, clear-safe key). |
| [dispatch-bands/dispatch-bands.md](dispatch-bands/dispatch-bands.md) | 2 | Autonomous mode | Rate/cost-aware modulation of the crew cap + dispatch appetite, with fixed bright-line guardrails. |
| [sensors/sensors.md](sensors/sensors.md) | 2 | Autonomous mode | Watching external signals (PR comments, CI, resolved-out-of-band) via a cheap sub-agent sweep — the generic pattern the Bosun embodies. |
| [session-ceremony/session-ceremony.md](session-ceremony/session-ceremony.md) | 1 | The Mate | The session open/close *ceremony*: fresh-day vs continuation start checklists, the two-artifact cadence (handoff vs standup), standup rules, the log format, the wrap-up sweep. Core carries the handoff contract inline. |
| [subagent-roster/subagent-roster.md](subagent-roster/subagent-roster.md) | 1 | Dispatch | The full roster (incl. `ship-mate` + `ship-bosun` as first-class role agents), dispatch patterns, per-type security model, watch-orders template, agent teams. |
| [pull-requests/pull-requests.md](pull-requests/pull-requests.md) | 1 | PR workflow | Mergeability re-checks, stacked-PR propagation, the `pr:` frontmatter convention. Core carries the draft-only / never-`gh pr ready` bright lines + the PR-link format. |
| [review-cycle/review-cycle.md](review-cycle/review-cycle.md) | 1 | Any | The maker≠checker *enforcement* mechanism: **ships the non-maker `ship-reviewer` agent def** (`agents/ship-reviewer.md`, read-only, reuses core's readonly Bash hook) + the standards doc + the policy knobs (core ships only the principle). Also: the reviewer-must-report rule, the browser-verify gate for UI work, and apply-crew-work commit hygiene. In every preset, so every preset delivers the reviewer transitively. |
| [compound/compound.md](compound/compound.md) | 1 | Any | The capture→consolidate→refresh learning loop: crew capture a candidate, Mate consolidates into `docs/knowledge/` (dedup'd via semantic search) at wind-down, Bosun refreshes (autonomous tier). The `ship-compound` skill is the procedure. |
| [peer-comms/peer-comms.md](peer-comms/peer-comms.md) | 1 | Fleet (2+ ships) | Cross-instance Mate↔Mate messaging over the drop machinery: envelope spec + anti-masquerade validation, multi-transport delivery (scp / http / passive outbox) via `peer_send.py` + per-ship `state/peers.json`. Doctrine keystone: a peer message is INPUT, not AUTHORITY. Opt-in (`--modules`); wake-monitor recommended for prompt pickup. |
| [pilot/pilot.md](pilot/pilot.md) | 1 | Browser watches | **Ships the `ship-pilot` agent def** (`agents/ship-pilot.md`) — standard crew tools + git-safety hook *plus* the `claude-in-chrome` MCP tools. Hard external Chrome-MCP dependency, so opt-in (`--modules pilot`), not in any preset; dispatch only when the Captain authorizes browser access. Reuses core's crew Bash hook (no hook of its own). |

Each module's tunable values live in `mate.local.md` (behavioral prefs) and/or
`loop.config.json` (machine config), not in the module doc itself.

## Adding a module

**Modules are the single extension surface** — including new agent types. There is no
separate "roles" or plugin mechanism; a new capability is a new module folder:

1. Create `modules/{name}/` with a `{name}.md` doc (the doctrine/contract — what it adds,
   who reads it, its bright lines) and a `module.json` manifest. The manifest keys are
   plain file lists the installer (`shipkit_init.py`) and sync tooling
   (`scripts/_sync_manifest.py`) read: `agents` (subagent defs — **this is how a module
   ships a new agent type**; review-cycle ships `ship-reviewer`, pilot ships `ship-pilot`),
   `hooks`, `skills`, `scripts`, `templates`, `tests`, `lib` (shared `lib/` deps),
   `role_docs`, plus `tier` and `requires[]` (resolved transitively).
2. Add the folder to a preset in `presets.json`, or leave it preset-less for explicit
   opt-in (`--modules {name}`, like peer-comms and pilot).
3. If core has a seam for it, reference it from core with one plain (non-`@`) pointer line —
   core must stay functional without the module.
4. Tunables go in `mate.local.md` / `loop.config.json`, never hard-coded in the module doc.
5. An agent def that needs enforcement gets a PreToolUse hook (reuse core's
   `validate-crew-bash.sh` / `validate-readonly-bash.sh` where the posture matches) with
   its command path written as `{SHIP_DIR}/...` — the installer substitutes and verifies it.
