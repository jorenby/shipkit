# Modules

Optional, generally-useful capabilities **and depth docs** that layer on top of the
general-core `mate.md` + `bosun.md`. Core stays readable on its own; each module is
referenced by one line from core and is self-contained here. Turn on the capability
modules you want (via `/shipkit-init` or by hand) and ignore the rest — a core-only
operator needs none of them.

**The autonomous shape is two modules, not one.** Ship's autonomous mode is a
**two-agent split**: the Bosun owns the heartbeat, the Mate is event-driven. That doctrine
lives in **two paired modules** — [bosun-loop.md](bosun-loop.md) (the heartbeat half) and
[mate-event-driven.md](mate-event-driven.md) (the idle/wake half). They replace the older
single "Mate runs the loop" doctrine. The role docs (`mate.md`, `bosun.md`) carry the
operative summary; these modules carry the depth. The skills (`ship-watch-start`,
`bosun-tick`) are the operative procedure.

Other modules add a *capability* you opt into (wake-monitor, review-cycle, dispatch-bands,
sensors) or are *depth docs* pared out of a core section that stays functional inline
(subagent-roster, pull-requests). Capability + depth modules are referenced from core as a
**plain (non-`@`) pointer** (read-on-demand); core's inline summary is always enough to
operate.

| Module | Kind | For | What it adds |
|---|---|---|---|
| [bosun-loop.md](bosun-loop.md) | autonomous layer | The Bosun (heartbeat) | The **complete** heartbeat doctrine: the bosun-tick loop, self-pacing **by heat** (not headroom), `/loop`-not-`/goal` keep-alive (the exit-guard, folded in), restart/post-compaction continuation. |
| [mate-event-driven.md](mate-event-driven.md) | autonomous layer | The Mate (idle/wake) | The **complete** event-driven-Mate doctrine: the core inversion (no `/loop`, no timer, headroom-not-a-blocker), wake sources, the per-wake handler, single-instance + lock, post-compaction continuation, structural bright lines. |
| [subagent-roster.md](subagent-roster.md) | depth | Dispatch | The full roster (incl. `ship-mate` + `ship-bosun` as first-class role agents), dispatch patterns, per-type security model, watch-orders template, agent teams. |
| [pull-requests.md](pull-requests.md) | depth | PR workflow | Mergeability re-checks, stacked-PR propagation, the `pr:` frontmatter convention. Core carries the draft-only / never-`gh pr ready` bright lines + the PR-link format. |
| [wake-monitor.md](wake-monitor.md) | capability | Event-driven Mate | The watcher that wakes the idle Mate on directives (incl. Bosun drops). Contract + the incident-scar pitfalls (enumerate-don't-glob, dedup-by-filename, classify-before-wake, clear-safe key). |
| [dispatch-bands.md](dispatch-bands.md) | capability | Any | Rate/cost-aware modulation of the crew cap + dispatch appetite, with fixed bright-line guardrails. |
| [review-cycle.md](review-cycle.md) | capability | Any | The maker≠checker *enforcement* mechanism: a non-maker `ship-reviewer` gate, the standards doc, the policy knobs (core ships only the principle). |
| [sensors.md](sensors.md) | capability | Autonomous mode | Watching external signals (PR comments, CI, resolved-out-of-band) via a cheap sub-agent sweep — the generic pattern the Bosun embodies. |

Each module's tunable values live in `mate.local.md` (behavioral prefs) and/or
`loop.config.json` (machine config), not in the module doc itself.
