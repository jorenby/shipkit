---
name: ship-compound
description: >
  Turn finished work into durable, reusable knowledge. Invoke `/ship-compound`
  at a Mate wind-down/retro (the default — consolidates the session's "Learning
  candidate" log blocks into committed docs/knowledge/ entries, dedup'd via your
  semantic-search tool), or `/ship-compound "<one-liner>"` to capture a single
  learning on the spot. The meaning, gate, doc format, and policy live in
  `modules/compound/compound.md`; this skill is the procedure. Skip routine watches —
  capture only what trips the gate.
---

# /ship-compound — close the learning loop

You are the First Mate (or a Captain running it by hand). This skill writes durable
learnings into `docs/knowledge/` so the next watch doesn't re-derive them. It is
**operative procedure only** — read the meaning in the module, don't re-derive it:

- **The gate, tracks, doc format, dedup table, policy knobs** — `modules/compound/compound.md`
  (backstop-read it now if you haven't this session).
- **Crew-side capture** (the `## Learning candidate` block) — `crew.md` → "Ending a Watch".

**Config seam:** read `knowledge_dir` (default `docs/knowledge`), `compound_policy`
(default `candidates-only`), and `compound_model` from `mate.local.md`; ship paths
resolve from `ship_root` in `loop.config.json`. If `compound_policy: off`, this skill
still runs when invoked by hand — the policy gates the *automatic* wind-down call, not
the manual one.

## Mode detection

- **Consolidate** (default, no argument) — you're at a wind-down/retro or running a
  housekeeping sweep. Harvest candidates from this session's logs and write the docs.
- **Capture** (`/ship-compound "<one-liner>"`, or an argument describing a lesson) —
  document one specific learning from the current context immediately.

State which mode you're in, then run it.

---

## Consolidate mode

### 1. Gather candidates
Find this session's work and its flagged lessons:

- List the logs touched this session: `logs/mate/<today>.md` plus the crew logs under
  `logs/<project>/<ticket>/` from watches reaped this session.
- In each, find `## Learning candidate` blocks (and bare "learning candidate:" notes
  under `## Notes`). Also scan the mate log for solved-then-verified work that tripped
  the gate but no crew flagged — `compound_policy: full-every-winddown` requires this
  re-read; `candidates-only` makes it optional.

If there are no candidates and nothing trips the gate: say "No learnings to compound
this session" and stop. **Not every session produces a durable lesson — that's fine.**

### 2. Gate each candidate
Drop anything that fails the gate in `modules/compound/compound.md` (routine work, pure
status, one-off facts, already-documented). Keep only: a non-trivial *verified* fix, or a
reusable insight/decision/pattern. When unsure, keep it — step 3 may merge it away.

### 3. Dedup via semantic search (per surviving candidate)
Run your semantic-search command (in `mate.local.md` — e.g. `qmd query "<candidate
one-liner + tags>" -n 5`) and apply the overlap table from the module:

- **High** → update the existing doc (fold in fresher detail, add `last_updated:`); do
  not create a duplicate.
- **Moderate** → create new, cross-link to the related doc.
- **Low / none** → create new.

### 4. Write
For each create/update, write `<knowledge_dir>/<slug>.md` with the light frontmatter
(`kind/track/tags/solved/source/status`) and the track-appropriate prose sections from
the module (bug: Problem · What didn't work · Root cause · Fix · Prevention; knowledge:
Context · Guidance · Why it matters · When it applies). Use **relative markdown links**
back to the source log and any related ticket/doc (links are load-bearing — see
`crew.md`). Keep it concise — a learning is prose, not a schema dump.

### 5. Commit + reindex
This rides the wind-down's existing commit — don't open a separate one. After files
are written, refresh the semantic-search index (your index-refresh command is in
`mate.local.md` / `CLAUDE.md`) so the next dedup query sees the new docs.

### 6. Refresh check (light)
If a new learning **contradicts or supersedes** an existing doc, mark the old one
`status: superseded` with a link forward — don't delete it. A broad stale-doc sweep is
**not** this skill's job; that's the refresh phase (`refresh_owner` — the Bosun on the
autonomous tier, else a deliberate Mate pass). Note any stale-doc suspicion for that
sweep rather than chasing it now.

### 7. Report
```
✓ Compound complete — N learnings (<c> created, <u> updated, <d> dropped at gate)
  - docs/knowledge/<slug>.md (bug, created)  ← logs/drip/<ticket>/<log>.md
  - docs/knowledge/<slug>.md (knowledge, updated — high overlap)
  Superseded: <path> → <replacement>   (omit if none)
  Reindex: (done | skipped: <why>)
```

---

## Capture mode

One learning, now, from current context (e.g. a mate-direct fix, or the Captain saw
something worth keeping). Run steps **2 → 5** on the single item: gate it, dedup via
semantic search, write/update the doc, then reindex. If invoked mid-watch by crew
context where you can't commit, write the doc and note in the log that it's
**uncommitted** so the next Mate housekeeping picks it up. End with the step-7 report
shape for the one item.

## Notes

- **Crew never commit** (`crew.md` git restrictions). In a crew context this skill only
  *drafts*; the Mate commits at housekeeping. The default path is Mate-side, where the
  commit seam already exists.
- **Don't let it balloon.** The consolidate pass is bounded by the session's logs, not
  the whole vault. Dedup is a `-n 5` search, not a full re-read of `docs/knowledge/`.
  Wind-down runs at low headroom — if context is tight, write lightweight docs (one tight
  prose pass, skip extra cross-referencing) rather than deferring capture; a thin durable
  doc beats a lost lesson.
- **One file per learning.** No scratch files, no `context-analysis.md` intermediates —
  gather in context, write the final doc(s) only.
