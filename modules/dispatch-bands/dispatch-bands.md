# Module: Dispatch Bands (rate/cost-aware crew cap)

**Optional. For Heartbeat Mode (or any operator who wants capacity-aware
dispatch).** Core `mate.md` ships a *flat* crew cap (`max_concurrent_crew` from
`loop.config.json`) and the throughput posture ("don't leave slots idle if you have
queued work"). This module is the *concept* of varying that cap — and your dispatch
appetite — with available rate/cost headroom, plus how to set the thresholds.

## The concept

At dispatch time, read a **capacity gauge** (a small JSON file a statusline hook
keeps current, e.g. `state/context-gauge.json` carrying `rate_pct` and
`rate_reset_mins`) and modulate two things by what band you're in:

- **Crew cap** — how many crew you'll run concurrently.
- **Dispatch appetite** — whether you fill slots freely (speculative/misc work
  welcome), restrict to queued work only, or hold autonomous dispatch entirely.

The decision variable is **"can a marginal dispatch hurt the Captain's own
capacity?"** — not the raw level alone. When reset is imminent, even a high level is
fine to spend; when reset is far off and the level is high, a marginal dispatch
competes with the Captain's own work.

## A three-band shape (tune the numbers in `mate.local.md`)

| Band | Condition (example) | Crew cap | Dispatch appetite |
|---|---|---|---|
| 🟢 ABUNDANT | rate low, **or** reset imminent (any level) | higher | fill slots freely; speculative work OK |
| 🟡 NORMAL | mid rate and reset not imminent | default | queued work only; no speculative dispatch |
| 🔴 TIGHT | high rate and reset not imminent | lower | hold autonomous dispatch; surface "holding until reset"; Mate goes light |

The concrete cutoffs (e.g. <50% / 50–80% / ≥80%, the reset-minutes line, the per-
band caps like 6/4/2) are **prefs** — set them in `mate.local.md` under "Dispatch
bands." Ship nothing in core; bands are entirely a tuning layer.

## Guardrails (these are FIXED — they do not vary with rate)

- **Captain-directed work always dispatches, in any band.** Bands govern only
  *autonomous* appetite.
- **Authority tiers and bright lines NEVER vary with rate**, in either direction.
  TIGHT doesn't relax a bright line; ABUNDANT doesn't loosen the autonomy tiers.
- **Hysteresis:** cross a threshold by a margin (e.g. ~5 minutes / a few points)
  before switching bands, so you don't flap at the boundary.
- **Stale or missing gauge → assume NORMAL.** Never assume ABUNDANT off a missing
  reading.
- **Log the band + model on every dispatch** — that telemetry is your tuning
  evidence for adjusting the cutoffs later.

## Setting the thresholds

Start conservative (a default cap, NORMAL appetite) and widen as you trust the
gauge. Watch the per-dispatch telemetry: if you spend ABUNDANT freely and the
Captain never feels rate-starved, the cutoffs are fine; if dispatches and the
Captain's own work collide, tighten the TIGHT boundary. The bands are a "solid
starting point, might adjust" knob — not a fixed law.
