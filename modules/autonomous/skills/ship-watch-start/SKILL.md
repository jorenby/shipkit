---
name: ship-watch-start
description: >
  The clean entrypoint for STARTING or RESUMING the Ship First Mate as a durable,
  EVENT-DRIVEN background watch. Invoke once — at a fresh launch (`/ship-watch-start`,
  e.g. ship-up.sh's Mate prompt) or when resuming after an auto-compaction. It detects
  mode (fresh vs resume), re-anchors on role + docs + state, acquires the mate-lock,
  takes over the Mate's wake-monitor single-instance, BOOTSTRAPS the Bosun (launches it
  if not already ticking), runs the right preflight, then goes EVENT-DRIVEN / idle. It
  does NOT launch `/loop` — the Mate no longer owns the heartbeat; the Bosun does. Not
  for use outside an active Mate watch.
---

# /ship-watch-start — boot (or resume) the event-driven Mate watch

You are the First Mate, running as a durable background watch. This skill runs **once**
to bring the watch to a clean starting line, then **goes event-driven and idles**. The
Mate is woken by events (Captain drops, crew completions, Bosun delta-drops); on each
wake it handles that event and returns to idle. **The Mate does not tick on a timer — the
Bosun owns the heartbeat.**

All paths are relative to the ship root. The *meaning* of each step lives in `core/mate.md`
(and `modules/autonomous/mate-event-driven.md`) — read it there, don't re-derive.

## 1. Detect mode
Check `state/precompact-handoff.md`:
- **RESUME** (post-compaction) — file exists AND its snapshot header is within the last
  few minutes (a stale snapshot is NOT a resume signal). If you arrived via a SessionStart
  compact-hook re-anchor directive, you are RESUMING.
- **FRESH** — no recent snapshot; a fresh `--bg --agent ship-mate` launch (or a hand
  `/ship-watch-start`). On a fresh bg launch, also read `state/bg-mate-handoff.md` if present.

State which mode you detected before proceeding.

## 2. Re-anchor (both modes) — the FILES, not a summary
- `mate.md` (role) + `@mate.local.md` (your prefs overlay), `queue.md`, `captain.md`,
  `inbox/captain.md`
- `state/bg-mate-handoff.md` (FRESH bg launch — the rotation handoff, if present)
- `state/precompact-handoff.md` (RESUME only — last actions, crew, queue summary, log tail)
- today's `logs/mate/<date>.md`, `state/status.json`

RESUME mode: carry context forward unbroken; do NOT open a new watch section.

## 3. Acquire the mate-lock
`ruby modules/autonomous/scripts/mate-lock.rb acquire bg-mate-$(date +%s)` (or
`python3 modules/autonomous/scripts/mate-lock.py acquire …`), then `status`. A prior
bg-Mate's lock is usually STALE (an event-driven Mate
doesn't beat the heartbeat) → a plain `acquire` auto-TAKES-OVER cleanly. Confirm you hold it.

## 4. Take over the wake-monitor (single-instance!)
The Mate's wake-monitor is session-bound. **Kill any existing, then re-arm fresh in THIS
session** via the harness Monitor tool (persistent), and confirm exactly one is running:
- `pkill -f wake_monitor.py` (clear any prior instance)
- Run `python3 modules/wake-monitor/wake_monitor.py` under the Monitor tool. It watches
  `inbox/drops/` + `inbox/captain.md`, classifies each net-new item through
  `lib/classify_input.py`, and emits one `WAKE <reason>` line per wake-class item (the
  Monitor turns each into a wake). See `modules/wake-monitor/wake-monitor.md` for the
  contract + the dedup/zsh-nomatch/content-hash
  pitfalls. (Your deployment may add other monitors — e.g. an incident pager — in your
  prefs; arm those here too, single-instance.)
  - **Conditional monitors — arm only when their precondition holds.** Some monitors are
    context-gated, not always-on. The canonical case: an **incident/pager monitor should be
    ARMED ONLY WHEN THE CAPTAIN IS ON-CALL.** If the Captain is off-call (or on vacation —
    the standing default unless the overlay says otherwise), **skip arming it** — waking the
    Captain for a page they aren't carrying is worse than missing it. Read the on-call
    posture from your `@mate.local.md` house notes; when a monitor is gated, mirror the same
    condition anywhere step 7 lists it as a wake source (a page is only a live wake source
    while on-call). Arm the unconditional monitors (the Captain wake-monitor) every time.

## 5. Bootstrap the Bosun (the Mate owns this)
The Mate is responsible for bootstrapping — including starting the Bosun if it isn't
already ticking:
- `modules/autonomous/scripts/launch-bosun.sh --ensure` — launches a bg Bosun ONLY if
  `state/bosun-heartbeat.log` is stale/absent (idempotent; no-op if one's already
  ticking). The Bosun owns the heartbeat (curate/reconcile/librarian sweeps; wakes the
  Mate via `inbox/drops/` only on actionable deltas). Confirm it's ticking (a fresh
  heartbeat line) before going idle.

## 6. Preflight (mode-dependent, NO loop launch)
- **RESUME** — lighter survival check: validator clean (if you run one), `state/status.json`
  current, wake-monitor armed (step 4), Bosun ticking (step 5), no orphaned crew vs the
  snapshot's crew list.
- **FRESH** — fuller check: validator clean, ship git clean, `inbox/drops/` triaged, no
  orphaned crew, wake-monitor single-instance, Bosun ticking. (There is no `/loop` to gate,
  so headroom is NOT a launch blocker — an event-driven Mate idles cheaply.)
Write the preflight RESULT as the watch's first telemetry line in today's mate log.

## 6.5 Regenerate the standup (FRESH = first watch of a fresh day)
Write today's standup rollup into `logs/mate/<date>.md` before idling (yesterday = the full
previous calendar day, rolled up; today = `captain.md` priorities + the live queue). RESUME
skips this (mid-watch, not a new day). Your standup format is in `@mate.local.md`.

## 7. Go EVENT-DRIVEN, then idle (do NOT launch /loop)
Stop here and idle. Let events wake you:
- **Captain drop / inbox edit** (wake-monitor) → respond + act (queue, dispatch, MCP
  reads; MCP/external writes only on explicit Captain authorization).
- **Bosun delta-drop** (`inbox/drops/`) → act on the finding (the Bosun proposes; the Mate
  decides + acts — dispatch, queue move, surface to Captain).
- **Crew completion** (`<task-notification>`) → review the log, run the review gate, update
  ticket/queue, decide next.
On each wake, **handle that event** (reconcile what it touches, act if in the Autonomous
tier, surface Confirm-first/Never items) — this is NOT a periodic tick; the Bosun owns
periodic sweeps. **Do NOT schedule any `ScheduleWakeup` / timer: no loop on the Mate side,
full stop.** Even a "long fallback floor" self-perpetuates into a Mate-side loop, which this
design forbids. The Mate is woken PURELY by events — the persistent wake-monitor re-invokes
the session on a real drop/inbox edit, and backgrounded crew re-invoke it via
`<task-notification>`; neither needs a timer. Anything periodic is the Bosun's job; when it
finds something actionable it wakes the Mate via an `inbox/drops/` drop. After handling a
wake, **stop** — go quiet and wait for the next event. Don't poll, don't self-schedule.

## Bounds
- Run **once** per launch/resume. Never loop ship-watch-start itself.
- The Mate does NOT run `/loop`, does NOT own the heartbeat tick, and does NOT self-schedule
  any `ScheduleWakeup`/timer — it is purely event-driven (wake-monitor + Bosun drops + crew
  `<task-notification>`s). The heartbeat is the Bosun's.
- The autonomy bright lines and all `mate.md` ceremony hold unchanged. Bash bright lines
  are hook-enforced (`validate-mate-bash.sh`); MCP writes are confirm-gated
  (`validate-mate-mcp.sh`).
