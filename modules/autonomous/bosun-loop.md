# Module: Bosun Loop (the autonomous heartbeat)

**This is the complete doctrine for the heartbeat half of Ship's autonomous shape — the
self-paced, continuously-running loop, owned by the BOSUN.** The companion half is the
event-driven Mate ([mate-event-driven.md](mate-event-driven.md)). Together they replace
the older single "Mate runs the loop" model: the Bosun ticks the heartbeat so the Mate
can stay quiet and event-driven.

Core `mate.md` runs **request/response** when a human drives it; `bosun.md` + this module
are what's *different* when Ship runs autonomously. **You enter the loop through the
Bosun, not by reading this doc** — the Bosun is launched as its own background `/loop`
session (`modules/autonomous/scripts/launch-bosun.sh`), and each tick is the **`bosun-tick`** skill. This
module is the *meaning* behind those steps.

**What stays the same.** The heartbeat changes nothing about the autonomy tiers, the
bright lines, dispatch, ticket/queue lifecycle, or PR handling — all of that is the Mate's
(`mate.md`), and the Bosun is **read-only**: it surfaces findings, the Mate decides + acts.
The heartbeat **widens throughput, not authority.**

---

## Who owns what (the split)

| | Bosun (this doc) | Mate ([mate-event-driven.md](mate-event-driven.md)) |
|---|---|---|
| Heartbeat | **Owns it** — runs `/loop` + `bosun-tick`, self-paces by heat | None — idles between events |
| Writes | Read-only; sole write path `bosun_emit.py` (heartbeat / cursor / drop) | Full Mate authority (queue, tickets, commits, dispatch) |
| Wakes the other | Writes a drop → wakes the Mate | n/a |
| Self-pacing driver | **Heat** (PR/CI activity), not context headroom | n/a — event-driven, no clock |

## The bosun-tick (the loop body)

Each tick (full procedure in the `bosun-tick` skill; remit in `bosun.md`):

1. **Heartbeat first, always** — proof-of-life even on a no-delta tick.
2. **Read the cursor** (`state/bosun-last-sweep.json`) so "delta" is real.
3. **Delta-aware sweep** — curate PRs (review/merge/CI/comments), ticket↔reality
   reconcile, open-questions freshness, light librarian.
4. **Classify findings → WAKE vs SILENT.** WAKE → write ONE drop (the Mate acts on it).
   SILENT → heartbeat only.
5. **Update the cursor + self-pace** the next `ScheduleWakeup` by heat.

## Self-pacing by heat (not by headroom)

A standalone read-only Bosun has no expensive context to protect, so — unlike the older
Mate-owns-the-loop model — **headroom is NOT the pacing driver. Heat is.** Hot (red CI, a
fresh maintainer comment on a tracked PR) → a short interval (e.g. 60–180s). Quiet (a calm
weekend) → a long interval (e.g. 900–1800s). A Monitor armed on PR comments is the primary
wake; ScheduleWakeup is the fallback floor. **An empty queue / "no delta" is NOT a stop
signal** — a quiet tick logs a heartbeat and reschedules.

## Keep-alive: `/loop`, not `/goal` (the exit-guard, folded in)

**Use `/loop` to keep the Bosun heartbeat alive.** `/loop` re-invokes the session on a
schedule and lets each tick decide its own next wake — exactly the shape of a self-pacing
loop. **Do NOT layer `/goal` over `/loop`:**

1. Setting a goal **starts a turn immediately** with the goal condition as the directive —
   a wind-down-shaped condition makes the agent wind down *now*, not when it's actually met.
2. The goal evaluator **fires after every turn** and, if unmet, starts another turn instead
   of returning control — which **vetoes the loop's scheduled-wakeup sleeps**, turning the
   paced heartbeat into a hot loop.

`/loop` and `/goal` are *alternative* session-keepers, not layers. (`/goal` is right for a
detached run-to-completion job where there's no sleep to fight — a different use case.)

If you run a session-scoped **Stop hook** as a backstop, make it loop-aware: **allow stop**
when a wakeup is pending (the gap between ticks) OR when a deliberate wind-down was recorded;
**block stop** otherwise (an accidental mid-loop death). The Bosun rarely winds down — it's
the long-lived heartbeat — so its keep-alive story is mostly "stay alive," not "exit cleanly."

## Restart / post-compaction continuation

The Bosun is cheap and stateless-on-disk: its memory is the cursor + the heartbeat log. A
restart (crash, rotation, or compaction) just re-enters `/loop`, reads the cursor as
baseline, and resumes — no special continuation ceremony. The Mate re-ensures it on every
`/ship-watch-start` (`launch-bosun.sh --ensure`), so a dead Bosun is brought back at the
next Mate boot. Keep the cursor written each tick so a restart's first delta is correct.

## Lifecycle companions

- **Wake-monitor** — feeds the *Mate* (not the Bosun); the Bosun is itself a wake *source*
  (its drops). The contract + pitfalls: [../wake-monitor/wake-monitor.md](../wake-monitor/wake-monitor.md).
- **Dispatch bands** — rate/cost-aware crew-cap modulation, a *Mate* concern (the Bosun
  doesn't dispatch). [../dispatch-bands/dispatch-bands.md](../dispatch-bands/dispatch-bands.md).
- **Sensors** — watching external signals via a cheap sweep is exactly what the Bosun *is*;
  [../sensors/sensors.md](../sensors/sensors.md) is the generic pattern, `bosun.md` is the concrete role.
