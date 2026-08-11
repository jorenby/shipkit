# Module: Session Ceremony (open, close, report)

**Depth doc for the Mate's session rhythm.** Core `mate.md` → "Sessions and Logs" carries
the *contract*: the session is the unit of work and handoff, the day is the unit of human
reporting, logs are the memory, and every close writes handoff notes. This module holds
the *ceremony* — the start-of-session checklists, the wrap-up sweep, the two-artifact
cadence, and the log format. The contract is enough to operate; read this when you want
the ceremony run well.

## Sessions, watches, and days

In **base (request/response) mode** a session is a single human-driven Claude Code
conversation: it opens when you start as First Mate and read in ship state, and closes
when the Captain ends it, when context gets long enough that recall degrades / a
compaction looms, or at a natural resting point. Multiple sessions can happen in one day.

In **autonomous (event-driven) mode** the unit is a **watch**: a single durable bg-Mate
run that opens at `/ship-watch-start` and survives a mid-watch compaction unbroken (you
resume into it, you don't start fresh). The day is still the unit of human reporting.
See [../autonomous/mate-event-driven.md](../autonomous/mate-event-driven.md).

**Wrap up a session** when the Captain calls it, when context is getting long, or at a
major resting point: commit anything unsaved, finish the day's log, and write handoff
notes so a fresh session continues cleanly. Finishing a single thread is a **checkpoint**
(commit, update the log/queue, reorient) — not a reason to end; keep going while the
Captain is engaged.

## Two artifacts, two cadences — keep them separate

| Artifact | Cadence | Audience | Written |
|---|---|---|---|
| **Handoff notes** ("open threads, pick these up") | **per session/watch** | the next session | every wrap-up |
| **Standup notes** ("what landed / what's next") | **per day** | the Captain's own standup | day's *true* end (revise AM) |

A mid-day wrap-up emits **handoff notes only — no standup.** Standup is a daily rollup:
finalized at the day's true end, aggregating across all of that day's sessions; revise in
the morning. "Yesterday" means the **full previous calendar day**. Emit it in your
configured standup format (`mate.local.md`).

## Start of session

First decide **which kind of session this is**, then run the matching ceremony. (For an
autonomous bg-Mate boot/resume, the ceremony is the `ship-watch-start` skill.)

**Fresh-day / first session of the day** (full ceremony):

1. **Read ship state**: queue.md, captain.md, inbox/captain.md
2. **Read the previous day's mate log(s) in full** — *all* of them. The convention is one
   file per day with multiple `# Session N` sections, but a day can have more than one
   file; read every section. The final handoff notes are the headline, but earlier sections
   carry threads the handoff compresses out. **Cross-reference further back** whenever a
   thread references prior context you can't resolve from the previous day alone.
3. **Check git status** on the ship directory and active repos — commit any uncommitted work.
4. **Check the ship's open PRs** — anything waiting on CI / review / merge?
5. **PR review pass** — if you run a PR-review flow (your entry point is in `mate.local.md`),
   run it here and report the count to the Captain.
6. **Open today's log** — a new `logs/mate/YYYY-MM-DD.md` with a `# Session 1 — opened HH:MM`
   section and a status block.
7. **Report status to the Captain** with **standup notes**, await steering.

**Continuation session (same day, mid-day pickup)** — lighter re-anchor:

1. **Re-anchor**: today's existing mate log, queue.md, captain.md, inbox/captain.md.
2. **Check deltas since last wrap-up**: PRs merged/changed, crew completed, inbox added,
   git status on the ship directory.
3. **Open a new section** in today's log: `# Session N — opened HH:MM (continuation)`.
4. **Run the PR-review pass only if** the session turns to ship/PR work.
5. **Report status to the Captain** — **no fresh standup**, await steering.

## Incremental logging

Write to `logs/mate/YYYY-MM-DD.md` **as you go**, not just at end of session. **One file
per day, multiple session sections within it** — each a `# Session N — opened HH:MM`
heading with its own status block, closed by a `## Status: done` block + handoff notes at
wrap-up. First thing each session: open or append to today's log with your initial status
block, then update it after each major action:

```
## Status: working | blocked | done

- [x] Read ship state
- [x] Dispatched crew on TICKET-ID
- [ ] Crew running...
- **Blocker:** (if any — describe what's needed)
```

## End of session (the wrap-up sweep)

**Every session wrap-up** (mid-day or end-of-day):

1. **Inbox:** move processed items from `inbox/captain.md` into your mate log (with outcome).
   Leave unprocessed items.
2. **Drops:** if you acted on a drop, move it to `inbox/drops/processed/` or delete it.
3. **Queue:** update ticket status in `queue.md` for anything completed or moved.
4. **Log:** close the session section with a `## Status: done` block **plus handoff notes** —
   the open threads the next session picks up. Logs are the handoff.
5. **Compound (if installed):** run `/ship-compound` over this session's logs before the
   commit — consolidate any crew "Learning candidate" blocks into `docs/knowledge/`. The
   gate, dedup, and policy are in [../compound/compound.md](../compound/compound.md).

**Before discarding a session's context** (`/clear`, or any hand-off that drops the window),
run the **`/checkpoint`** skill this module ships (`skills/checkpoint/`). It is a **verify**
pass, not a save pass: if the event-time durable writes the role docs mandate actually
happened, almost everything is already in a durable home and the checkpoint saves nothing.
Two properties are load-bearing and easy to lose if you reimplement it:

- It confirms each item **by reading the durable home from disk**, never from session memory —
  "I'm pretty sure I wrote that" shares a failure mode with the write it is meant to insure.
- It appends one greppable line to `logs/checkpoint-ledger.md` **even when it saves nothing**,
  because an empty result is the evidence that discipline held. After ~15–20 entries the
  catch-rate and severity mix tell you whether checkpointing is insurance or ceremony —
  a high catch-rate means event-time writes are leaking upstream, not that you should
  checkpoint harder.

**Additionally, if this is the day's last session (true end of day):**

6. **Standup:** write/finalize the daily standup rollup aggregating across all sessions.
