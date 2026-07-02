# Mate — Local Preferences (template)

Copy this file to **`mate.local.md`** and fill in your values. The Mate reads `mate.md`
(the general-core doctrine), **then this file**, at watch start; the values here override
and extend the "your configured X" seams in core. `/shipkit-init` can populate this for
you conversationally — each entry maps to one interview question and one core seam.

**This file is yours.** `pull-upstream` updates core `mate.md` freely and **never touches
`mate.local.md`** (add it to `.gitignore` if you don't want it tracked). The core doc
stays generic so updates don't collide.

**Two overlays, two concerns.** *Behavioral* preferences (taste — model roster, report
format, house notes) live **here**. *Machine* config (paths, ports, hosts, watched repos,
agent/launcher/hook paths) lives in **`loop.config.json`** — see `loop.config.example.json`.

---

## Thresholds & pacing

```
max_concurrent_crew:    4         # flat crew cap. The dispatch-bands module varies this by rate.
```

Note: the **Mate is event-driven** — it does NOT self-pace on a context gauge (no `/loop`
to gate). Heartbeat pacing is the **Bosun's** concern (by heat, not headroom — see
`bosun.md`). There is no `wind_down_threshold` / `pacing_fallback` for the Mate; an idle
Mate is cheap and waits for events.

## Dispatch bands (if you run the dispatch-bands module)

Rate/cost-aware modulation of crew cap + dispatch appetite. See
[modules/dispatch-bands/dispatch-bands.md](modules/dispatch-bands/dispatch-bands.md). Example roster:

```
band_gauge_path:        state/context-gauge.json   # the capacity gauge the bands read
band_abundant:  rate < 50% OR reset < 20m   → crew cap 6, fill slots freely, speculative OK
band_normal:    50–80% AND reset > 20m      → crew cap 4, queued work only
band_tight:     ≥ 80% AND reset > 20m       → crew cap 2, hold autonomous dispatch
band_hysteresis: cross threshold ~5m before switching (don't flap)
# FIXED guardrails: Captain-directed work always dispatches, any band; authority tiers /
# bright lines NEVER vary with rate; stale/missing gauge → assume NORMAL.
```

## Model roster

```
model_default:    opus      # default crew + pilot model. Code-writing crews default here.
model_escalate:   <name>    # per-dispatch escalation for design-heavy / ambiguous watches
model_lookout:    haiku     # read-only lookouts + PR-review first pass
model_speed:      sonnet    # speed premium (many parallel lightweight watches)
# Corollary: if a faster model IS the implementer, pair it with a stronger-model reviewer gate.
```

## Review policy (if you run the review-cycle module)

```
review_policy:    significant-only           # off | significant-only | all-crew-code-every-time | rate-gated
review_model:     opus                        # the non-maker ship-reviewer model
review_standards: docs/knowledge/crew-code-standards.md   # the standards doc the reviewer checks
```

## Compound / learning loop (if you run the compound module)

```
compound_policy:  candidates-only             # off | candidates-only | full-every-winddown
knowledge_dir:    docs/knowledge              # where durable learnings live (flat dir)
compound_model:   opus                        # dedup/judgment on the consolidate pass wants a strong model
refresh_owner:    bosun                       # who runs the stale-learning sweep: mate | bosun | off
```

## Reporting & surfaces

```
report_format:    plain-bullets   # standup format. plain bullets | a tool-specific format
chat_surface:     inbox file      # where the Captain reads. Surface substantive work HERE.
                                  #   Multiple targeted replies > one mega-summary.
```

## Tools

```
search_tool:      <cmd>           # your semantic-search-across-the-vault command (if any)
pr_review_cmd:    <cmd>           # your PR-review entry point (if any) — the start-of-watch PR pass
```

(There is no `loop_skill` here — the Mate doesn't run a loop. The Bosun owns the heartbeat;
the Mate enters autonomous mode via the `ship-watch-start` skill.)

## Repos & org

```
github_org:       YourOrg         # for PR links: https://github.com/YourOrg/{repo}/pull/{number}
pr_template:      TL;DR / Background / Modification / Result / How to verify / Checklist
```

---

## House notes (free-form)

Anything else the operator wants the Mate to carry every watch — environment quirks,
standing exceptions, named teammates, escalation contacts, recurring gotchas.

- (example) Restart service X by killing its PID; the supervisor auto-restarts it.
- (example) Default infra asks go to the Platform team, not a named person.
- (example) Personal/throwaway projects skip the PR draft ceremony — merge straight to main.
