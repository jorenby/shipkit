# Module: Sensors / Sentry Sweeps

**Optional. For Heartbeat Mode.** A pattern for watching external signals (PR
comments, CI status on your open PRs, error-tracker alerts, resolved-out-of-band
work) without burning the Mate's own session on a cron.

## The core idea: dispatch a sub-agent, not an in-session cron

External-signal watching runs as a **cheap read-only sub-agent dispatch**, NOT an
in-session loop/cron. A cron-shaped check fires into the Mate's own (expensive,
interleaved) session; a sub-agent runs cheaply on a fast model, judges what's
actionable, and reports back. **The sub-agent's completion IS the wake** — no drop
round-trip needed.

The cadence rides the heartbeat: each tick, **if it's been longer than your sweep
interval since the last sweep and a crew slot is free, dispatch a `ship-lookout`
sweep**. It runs your sweep script over the watched signals since the last
watermark, judges actionable items, and reports. The Mate triages the report,
surfaces/queues anything real, then stamps a state file (`last_watch` + a `seen`
dedupe set) so the next sweep doesn't re-report.

## Signals worth sweeping

- **PR comments on the Captain's PRs** — not just review *state*; an inline comment
  needs a response even when the review status hasn't changed.
- **CI failures** → optionally auto-queue a fix crew when a slot's free (proactive
  CI-fixing, if the Captain authorizes it).
- **Ready-to-close tickets resolved out-of-band** — work resolved in a side channel
  should be flagged, not left sitting in Awaiting Captain unnoticed.
- **Unblocked deferred work** — deferred/blocked items whose blocker has cleared.
  Its natural trigger is **post-reap** ("what did landing this just unblock?"), not
  the clock — post-flight is the trigger, the sensor is the mechanism.

## Wiring

The watched repos/endpoints come from `loop.config.json` (`repos`, and any sensor-
specific config). The sweep script, the dedupe state file, and any per-signal logic
are deployment-specific — this module is the *pattern* (sub-agent sweep, watermark +
seen-set, triage-on-completion), not a shipped script. No sensor module ships code
in shipkit today; this names where one plugs in.
