# Modules

Each module is a **self-contained folder** with a `module.json` (its files + tier + script
deps) and a doc. They layer on top of the general core (`core/mate.md` + `core/crew.md`).
Core stays readable on its own; each module is referenced by one line from core. A preset
(`presets.json`) selects a set of module folders — turn on what you want via `/shipkit-init`
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
inline (subagent-roster, pull-requests, review-cycle — tier 1) or *capabilities* for the
autonomous tier (dispatch-bands, sensors — tier 2). All are referenced from core as a
**plain (non-`@`) pointer** (read-on-demand).

| Module | Tier | For | What it adds |
|---|---|---|---|
| [autonomous/bosun-loop.md](autonomous/bosun-loop.md) | 2 | The Bosun (heartbeat) | The **complete** heartbeat doctrine: the bosun-tick loop, self-pacing **by heat** (not headroom), `/loop`-not-`/goal` keep-alive (the exit-guard, folded in), restart/post-compaction continuation. |
| [autonomous/mate-event-driven.md](autonomous/mate-event-driven.md) | 2 | The Mate (idle/wake) | The **complete** event-driven-Mate doctrine: the core inversion (no `/loop`, no timer, headroom-not-a-blocker), wake sources, the per-wake handler, single-instance + lock, post-compaction continuation, structural bright lines. |
| [wake-monitor/wake-monitor.md](wake-monitor/wake-monitor.md) | 2 | Event-driven Mate | The watcher that wakes the idle Mate on directives (incl. Bosun drops). Contract + the incident-scar pitfalls (enumerate-don't-glob, dedup-by-filename, classify-before-wake, clear-safe key). |
| [dispatch-bands/dispatch-bands.md](dispatch-bands/dispatch-bands.md) | 2 | Autonomous mode | Rate/cost-aware modulation of the crew cap + dispatch appetite, with fixed bright-line guardrails. |
| [sensors/sensors.md](sensors/sensors.md) | 2 | Autonomous mode | Watching external signals (PR comments, CI, resolved-out-of-band) via a cheap sub-agent sweep — the generic pattern the Bosun embodies. |
| [subagent-roster/subagent-roster.md](subagent-roster/subagent-roster.md) | 1 | Dispatch | The full roster (incl. `ship-mate` + `ship-bosun` as first-class role agents), dispatch patterns, per-type security model, watch-orders template, agent teams. |
| [pull-requests/pull-requests.md](pull-requests/pull-requests.md) | 1 | PR workflow | Mergeability re-checks, stacked-PR propagation, the `pr:` frontmatter convention. Core carries the draft-only / never-`gh pr ready` bright lines + the PR-link format. |
| [review-cycle/review-cycle.md](review-cycle/review-cycle.md) | 1 | Any | The maker≠checker *enforcement* mechanism: a non-maker `ship-reviewer` gate, the standards doc, the policy knobs (core ships only the principle). Also: the reviewer-must-report rule, the browser-verify gate for UI work, and apply-crew-work commit hygiene. |
| [compound/compound.md](compound/compound.md) | 1 | Any | The capture→consolidate→refresh learning loop: crew capture a candidate, Mate consolidates into `docs/knowledge/` (dedup'd via semantic search) at wind-down, Bosun refreshes (autonomous tier). The `ship-compound` skill is the procedure. |

Each module's tunable values live in `mate.local.md` (behavioral prefs) and/or
`loop.config.json` (machine config), not in the module doc itself.
