# Module: Mate Event-Driven Mode (the idle/wake half)

**This is the doctrine for the Mate half of Ship's autonomous shape: an event-driven Mate
that boots, idles cheaply, and acts only on wakes.** The companion half is the
heartbeat-owning Bosun ([bosun-loop.md](bosun-loop.md)). Core `mate.md` runs
**request/response** when a human drives the Mate turn by turn; this module is what's
different when the Mate runs as a durable background agent (`ship-mate`) alongside the
Bosun.

**You enter this mode through the `ship-watch-start` skill**, not by reading this doc —
the Mate boots via `/ship-watch-start`, which re-anchors → acquires the mate-lock → arms
the wake-monitor → bootstraps the Bosun → preflights → **goes idle**. This module is the
*meaning* behind those steps.

## The core inversion

In the older model the Mate ran `/loop /ship-tick` and owned the heartbeat. **It no longer
does.** The Bosun owns the heartbeat; the Mate is **event-driven**:

- It does **NOT** run `/loop`. It does **NOT** tick on a timer. It does **NOT** wind down on
  a context gauge (there's no loop to gate, so **headroom is not a launch blocker** — an
  idle Mate is cheap).
- It **boots once** (`ship-watch-start`), then **idles**. Each wake handles one event and
  returns to idle.

## Wake sources (what wakes an idle Mate)

| Source | Mechanism | Mate's response |
|---|---|---|
| Captain drop / inbox edit | wake-monitor (`wake_monitor.py` → `classify_input.py`) | Respond + act (queue, dispatch, MCP reads; external writes only on explicit authorization) |
| Bosun delta-drop | the Bosun writes a drop → wake-monitor picks it up | Act on the finding (Bosun proposes, Mate decides + acts) |
| Crew completion | harness `<task-notification>` | Reap: review the log, run the review gate, update ticket/queue, decide next |

**The Mate schedules NOTHING — no `ScheduleWakeup`, no timer.** Even a "long fallback floor"
self-perpetuates into a Mate-side loop, which this design forbids: the wake-monitor + Bosun
drops + crew `<task-notification>`s re-invoke the session on real events without any timer.
Anything periodic is the Bosun's job. Never poll for crew; a backgrounded crew re-invokes the
Mate when it finishes. (This is the canonical statement of the no-timer invariant — other
docs point here; history in `DECISIONS.md`.)

## What a wake does (the per-wake handler, not a periodic tick)

On each wake, **handle that event** and return to idle:

1. **Name the wake** — which source, what it touches.
2. **Reconcile what it touches** — not a full sweep (that's the Bosun's job); just the
   slice the event affects (the reaped ticket, the dropped finding, the steered item).
3. **Act if Autonomous-tier** — dispatch queued work if there's capacity and the work is in
   the Autonomous tier (`mate.md` → "Autonomy & Bright Lines"). Confirm-first / Never items
   → Awaiting Captain with the action stated, never acted on.
4. **Surface where the Captain reads** (your surface is in `mate.local.md`) — the
   idle-perception cost of staying silent usually outweighs the reasons to stay quiet.
5. **Return to idle** — stop and wait for the next event (no rescheduling — the Mate has no timer).

The tick *semantics* core knew (reap / reconcile / dispatch-on-capacity / curate) still
apply — but now as **what gets done on a wake**, not what runs on a timer. The periodic
sweep is the Bosun's `bosun-tick`.

## Single-instance + lock

The Mate is single-instance: `ship-watch-start` acquires the mate-lock
(`mate-lock.py`) and takes over the wake-monitor (kill any prior, re-arm exactly one
in this session). A prior bg-Mate's lock is usually STALE (an event-driven Mate doesn't beat
the heartbeat) → a plain `acquire` auto-takes-over.

Rotation (a REPLACEMENT Mate on a fresh context) is the session-lifecycle primitive:
`ship-up.sh --rotate-mate`. The **procedure** the outgoing Mate runs is the
`ship-watch-rotate` skill (detect → prep the handoff → rotate → verify the successor took
the deck) — the same core/procedure split as this doc vs `ship-watch-start`. The day/night
cadence built on it — fresh daily rotation, economy-model overnight Mate, self-escalation
license — is the [night-economy module](../night-economy/night-economy.md).

**A rotation is not complete when `--rotate-mate` returns.** It releases the outgoing lock
~8s after launching, without verifying the successor came up — so the verify phase (a FRESH
lock held by the new id, the Bosun still ticking) is part of the primitive, not optional
diligence.

## Post-compaction continuation

A long-lived bg Mate can survive an auto-compaction — it wakes into a summarized context,
not a fresh launch. Resume via `/ship-watch-start` in RESUME mode: re-anchor on the ship
FILES (not the summary), verify the wake-monitor + Bosun survived (re-arm / re-ensure if
not), do NOT open a "new watch" or re-run the full preflight. Compaction is a context event,
not a watch boundary.

## Structural bright lines

Running as `ship-mate`, the autonomy bright lines are **structural**, not just disciplined:
`validate-mate-bash.sh` hard-blocks merges / mark-ready / external posts / deploys / prod
writes / push-to-main, and `validate-mate-mcp.sh` confirm-gates MCP writes (audit-logged).
A headless Mate can't get in-band confirmation, so it **surfaces** Confirm-first/Never items
(drop / queue / Awaiting-Captain); it never executes them. The hooks are a backstop for the
Mate's own over-eagerness — the `mate.md` discipline still governs.

Per-deployment exceptions are **seams in the hook, not discipline**: the
`mate_check_deployment` override block (your surfaces) and the push-to-main carve-out
seam (`MATE_PUSH_MAIN_CARVEOUT` — an explicit-URL-only exception for at most one
publish repo, force-push never; ships empty). Populate them in the hook file itself and
extend the live-fire test suite when you do.
