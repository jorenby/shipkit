# Module: Night Economy (watch cadence + overnight posture)

**Tier 2 (autonomous).** How an autonomous ship spends its nights and opens its days:
a **fresh rotation every day**, an **economy-model Mate overnight**, and a low-intensity
**night-watch posture** with a standing self-escalation license. Pairs with the two-agent
split ([mate-event-driven.md](../autonomous/mate-event-driven.md) +
[bosun-loop.md](../autonomous/bosun-loop.md)) — the Bosun's heartbeat is what makes a
cheap, quiet night Mate viable at all.

Codified from live-ship experience: the keep-one-marathon-session-alive-across-nights
posture was tried and **retired** — token-cache juggling doesn't merit the continuity
cost. The rhythm below is what replaced it.

Model names and the license's exact terms are **values** — they live in your
`mate.local.md` (see the seams at the end), not here.

**Optional doctrine.** This module is inert unless you actually run a day/night rotation:
nothing activates until you set the night-economy values (e.g. `model_night`) in
`mate.local.md`. If you run one continuous Mate, omit it from `--modules` — or simply
ignore it; installed-but-unconfigured has no effect.

---

## The cadence

- **Each day opens on a FRESH rotation** — a new bg-Mate, fresh context, your configured
  day model. Procedure: the `ship-watch-rotate` skill; mechanics underneath it:
  `modules/autonomous/scripts/ship-up.sh --rotate-mate` (set `SHIP_MATE_MODEL` to pick the
  model). The morning boot writes the day's standup.
- **Overnight / operator-away: rotate DOWN to an economy Mate** — a cheaper model running
  the night posture below. Economy at night holds **even during a capacity-abundance
  window**: quiet coverage doesn't need the big model, and the spend is better banked
  for the day.
- **A date change is not a watch boundary.** The night watch is ONE continuous watch
  across midnight — no fresh-day ceremony mid-watch; the standup regenerates at the
  morning's fresh boot, not at 00:00 (see the session-ceremony module's two-artifact
  cadence if installed).

## Self-escalation license (explicit, standing)

The night Mate MAY rotate itself to a bigger-model watch WITHOUT waiting for an operator
steer when circumstances merit — a real incident, the Captain arriving with substantive
work, a complex time-sensitive thread it judges beyond its tier.

- **Mechanics = a normal rotation** (`ship-up.sh --rotate-mate` with a bigger
  `SHIP_MATE_MODEL`), never an in-place switch. Note the reason in the handoff.
- **Escalation is the night Mate's judgment call; DE-escalation is not.** Dropping back
  to economy waits for the day boot — don't flap.
- **Bright lines / authority tiers NEVER vary with the model tier, in either direction**
  (same fixed-guardrail rule as the dispatch-bands module). A bigger model doesn't earn
  more autonomy; a smaller one doesn't excuse less discipline.

## The night posture

What the economy Mate actually runs overnight:

- **The heartbeat stays up** — the Bosun's `/loop` self-paces; no tick limit. The night
  Mate stays event-driven as ever (this module changes the model + intensity, not the
  operating model).
- **Read-only incident watch.** External surfaces (GitHub, chat, trackers, alerts) are
  watched for detection only.
- **No writes to external systems — bright line, absolute.** Zero PR comments/merges,
  chat posts, tracker writes, deploys, prod writes. A *push counts as external*: even a
  trivial CI-lint autofix waits for the day. (The enforcement hooks make most of this
  structural; the night posture treats the rest as if it were.)
- **Autonomous-tier dispatch continues as capacity allows** — Ready work still gets
  popped and dispatched (band-aware if you run dispatch-bands), but crews land work
  **locally only** (research, local code, drafts). Confirm-first / never-tier items go
  to Awaiting-Captain with the action stated.
- **Wake the operator only for the real thing** — a genuine human-declared incident or a
  page. Chronic bot noise never wakes a human: confirm it's the known noise, note it,
  move on. Keep a known-noise list in `mate.local.md` house notes; recurring
  never-followed-up alerts are not escalatable.
- **Survive compactions** — post-compaction continuation per
  [mate-event-driven.md](../autonomous/mate-event-driven.md); the night is where it
  gets exercised.
- **Checkpoint, don't churn.** Local commits only; checkpoint the overnight state every
  few hours plus at wind-down — but don't commit every no-delta sweep (regenerable =
  noise).

## Morning

The clean handoff is the **day rotation**: wind-down (handoff notes + housekeeping +
checkpoint commit), then a fresh `--rotate-mate` on the day model — which regenerates
the standup and resumes normal-intensity work. A quiet night is not a wind-down signal;
the rotation happens on the day boot, not because the night got boring.

---

## Values (mate.local.md seams)

```
model_day:        <name>    # the fresh daily-rotation Mate
model_night:      <name>    # the economy overnight Mate
model_night_min:  <name>    # optional: acceptable floor for pure-quiet coverage
# escalation license: standing (above); record any ship-specific terms here
```

Machine mechanics (`SHIP_MATE_MODEL`, launcher paths) live with
`modules/autonomous/scripts/ship-up.sh` — see `loop.config.json`'s `launch` block.
