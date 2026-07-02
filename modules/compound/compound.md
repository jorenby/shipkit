# Module: Compound (turn finished work into durable, reusable knowledge)

**Optional capability module.** Core `mate.md` ships the *principle* in one paragraph
(housekeeping → "consolidate knowledge from recent learnings"). This module is the
*mechanism* — the gate, the doc format, the dedup procedure, and the seams it
rides — for operators who want the learning loop to close **every watch, by default**
instead of whenever someone remembers. The operative procedure lives in the
`ship-compound` skill; this doc is the meaning behind it.

Adapted from Every's [compound-engineering](https://github.com/EveryInc/compound-engineering-plugin)
`/ce-compound` (MIT). We keep its three good ideas — capture while context is fresh,
dedup before you write, refresh what goes stale — and drop its rigid
`docs/solutions/<category>/` tree, because Ship pairs well with a **semantic-search index**
over the vault (e.g. qmd). Flat `docs/knowledge/` + light tags + semantic retrieval beats a
category forest you have to keep filed.

## Why it's a module, not pure core

The compounding bet is the same one Ship already makes: each unit of work should make the
next one cheaper. The antibody it adds is against **re-derivation debt** — the next watch
(or a fresh session, or a teammate without your context) solving a problem you already
solved because the lesson never left your head or your `/compact`'d transcript.

But *capturing* has a real cost: not every watch produces a durable lesson, and a
knowledge store that captures everything is noise that no one trusts. So core states
the principle; you pick the **capture policy** here, and the **gate** below keeps the
store honest.

## The shape: capture → consolidate → refresh

Ship already separates *who writes when* (crew write, Mate commits, Bosun sweeps).
Compound rides that grain instead of fighting it — three phases on three existing
seams, not one monolithic command:

| Phase | Who | When (seam) | Writes? |
|---|---|---|---|
| **Capture** | Crew | End of a crew watch (`crew.md` → "Ending a Watch") | A *candidate* block in the watch log (crew can't commit — by invariant) |
| **Consolidate** | Mate | Wind-down retro + housekeeping (`mate.md` → "End of Session Housekeeping" / "Ship Maintenance & Housekeeping") | The durable `docs/knowledge/` doc, committed in the same sweep |
| **Refresh / detect** | Bosun | Per-tick delta sweep (autonomous tier — `modules/autonomous/bosun.md`) | Nothing — read-only; *surfaces* stale or capture-worthy items, Mate acts |

**Why this split (and not the alternatives):**

- **Capture must be crew-side** so it happens while context is fresh — the whole CE
  insight. By wind-down the crew's transcript is gone; only the log survives, so the
  fidelity (what was tried, what failed, the root cause) has to be written *at* the
  watch, not reconstructed after.
- **Consolidate must be Mate-side** because crew can't commit and don't hold the
  whole-knowledge-base view needed to dedup. The Mate already runs a reliable retro at
  wind-down that ends in a commit — fold the write there and it lands for free.
- **Refresh is Bosun's** (autonomous tier only) because it's standing maintenance (is any
  old learning now wrong?) — but the Bosun is **read-only**, so it flags and the Mate
  writes. This phase is a future enhancement; the loop is complete with capture +
  consolidate alone, and a core-only (no-Bosun) operator simply skips it.

The standalone invariant holds: a core-only operator with no Bosun still gets the full
loop by running `/ship-compound` by hand at the end of a session.

## The gate (keep the store honest)

Capture a learning **only** when one of these is true:

1. A **non-trivial problem was solved** *and verified working* — not a typo, not an
   obvious fix, not "the test was flaky and passed on rerun."
2. A **reusable insight, decision, or pattern** emerged that a future watch would
   otherwise re-derive — a gotcha, a convention, a "why we did it this way," a
   dead-end worth signposting.

**Do not capture:** routine implementation that went to plan, pure status ("shipped
X"), one-off facts that belong in the ticket, or anything already written down. When
in doubt, a *candidate* is cheap (it's one block in a log the crew is writing anyway);
the Mate is the filter that decides whether it becomes a durable doc.

`bug` vs `knowledge` track (mirrors CE, kept light):

- **bug** — something broke and was fixed. Sections: *Problem · What didn't work ·
  Root cause · Fix · Prevention*.
- **knowledge** — a pattern, convention, or decision worth keeping. Sections:
  *Context · Guidance · Why it matters · When it applies*.

## The candidate block (crew capture)

When a watch trips the gate, the crew appends this to its log — that's the whole
crew-side cost. No new file, no commit, rides the log it already writes:

```
## Learning candidate
- **track:** bug | knowledge
- **one-liner:** <the lesson in one sentence>
- **tags:** <comma-separated: modules, tech, error class>
- **what's durable:** <problem + root cause + fix, OR the pattern/decision — be
  concrete; this is the fresh-context detail the Mate can't reconstruct later>
- **prevention/when-it-applies:** <how to avoid recurrence, or when to reach for this>
```

If a watch trips the gate but the crew is out of headroom, a one-liner under the log's
`## Notes` ("learning candidate: <one-liner>") is an acceptable minimum — the Mate
expands it from the log + diff during consolidate.

## The durable doc (Mate consolidate)

Lives at `docs/knowledge/<slug>.md`. **Flat directory** — no category tree; semantic
search does retrieval. House style is light: a `# Title`, a provenance line, prose
sections. Add this minimal frontmatter so the index and any future board can filter:

```yaml
---
kind: learning              # learning | runbook | reference | decision
track: bug                  # bug | knowledge
tags: [shopify, webhooks]   # modules + tech + error class; freeform
solved: 2026-06-26          # date the lesson was earned
source: logs/drip/SHOPIFY-CART-ITEMS-TYPE/2026-06-26-1430.md   # the watch that earned it
status: active              # active | draft | superseded
---
```

Keep it light on purpose — Ship's knowledge docs are prose-led, not schema-heavy
(contrast the rich ticket-frontmatter schema, which is canonical *state*; a learning
is not state). `status: superseded` + a link to the replacement is how a learning
dies; don't delete it.

## Dedup before you write (the semantic-search step)

This is the step that keeps the store from rotting into near-duplicates. Before
writing a candidate, the Mate runs semantic search and decides (your search command is
in `mate.local.md` — e.g. `qmd query "<one-liner + tags>" -n 5`):

| Overlap | Action |
|---|---|
| **High** — an existing doc covers the same problem + root cause + fix | **Update** it. Fold in the fresher detail, add a `last_updated:` line. Don't create a second doc that immediately drifts. |
| **Moderate** — same area, different angle | **Create** new; cross-link both. |
| **Low / none** | **Create** new. |

After writing or updating, refresh the index so the next dedup query sees it (your
index-refresh command is in `mate.local.md` / `CLAUDE.md`).

## Discoverability (already mostly handled)

CE's `/ce-compound` ends by editing `CLAUDE.md`/`AGENTS.md` so agents know the store
exists. Ship is already there: `crew.md` points crew at `docs/knowledge/`, `mate.md`
lists the semantic-search tool, and root `CLAUDE.md` documents it over the vault. The
only standing expectation to keep alive: **before non-trivial work in a documented area,
search `docs/knowledge/` first.** If that line ever falls out of `crew.md` / `mate.md`,
put it back — a store no one searches doesn't compound.

## Policy knobs (`mate.local.md`)

```
compound_policy:    off | candidates-only | full-every-winddown   # default: candidates-only
knowledge_dir:      docs/knowledge                                 # where durable docs live
compound_model:     <model for the consolidate pass>               # dedup/judgment wants a strong model
refresh_owner:      mate | bosun | off                             # who runs the stale-learning sweep
```

- **`off`** — principle only, no candidate blocks, no enforced consolidate. Capture by
  hand with `/ship-compound` when you feel like it.
- **`candidates-only`** (default) — crew emit candidate blocks; the Mate consolidates
  blessed ones at wind-down. The honest middle: cheap on the hot path, durable docs
  only for things that earned it.
- **`full-every-winddown`** — every wind-down runs a full consolidate pass over the
  session's logs whether or not crew flagged candidates (the Mate re-reads for missed
  lessons). Highest assurance, highest token cost.

## Wiring (one line each into the seams)

Compound is inert until it's referenced from the seams. The three pointers:

- **`crew.md` → "Ending a Watch":** insert a capture step *before* "Say Watch complete"
  — "If this watch tripped the compound gate (`modules/compound/compound.md`), append a
  `## Learning candidate` block to your log."
- **Wind-down ceremony / retro** (`mate.md` → "End of Session Housekeeping" and the
  "consolidate knowledge from recent learnings" line under "Ship Maintenance &
  Housekeeping"): add — "run `/ship-compound` over this session's logs before the commit."
- **`modules/README.md`** table: register the module (capability / Any / "the
  capture→consolidate→refresh learning loop").

Optionally, on the autonomous tier the Bosun's per-tick reap can backstop-force this
module when a watch it's reaping reports a solved non-trivial problem with no candidate
block — a nudge, not a gate.
