---
name: checkpoint
description: Save anything worth preserving from this session before context is cleared — memories, plans, ship-role artifacts (tickets/queue/watch logs), and open loose ends. Use right before /clear or at the end of a long session.
disable-model-invocation: true
argument-hint: [optional focus note]
---

# Checkpoint — Save Before Clear

> **Action vs. file — know the difference.**
> The `/checkpoint` *action* is the point: find durable homes for everything worth keeping — memory, plans, ship artifacts. That's steps 1–3 below, and that's where value lives.
> The leftover `checkpoint-*.md` *file* is step 4: a thin, disposable ferry for residual loose ends — pointers and a backstop only. It is never durable history and must never be the sole record of any state. See "Hard invariant" under Loose ends.

The Captain is about to `/clear` (or otherwise discard this session's context). Survey the conversation, decide what's worth keeping, and write it to durable storage. Make judgment calls — don't make the Captain enumerate everything.

**Run this as a VERIFY pass, not a save pass — and default to omit.** If durable writes happened at event-time during the session (as the role docs mandate), most items are *already* in a durable home; your job is to confirm that and save only the residue. A heavy checkpoint is a symptom that writes were deferred, not a sign of thoroughness. Beware the **commission bias**: the skill is running, so *writing feels like doing the job* — but every unnecessary save is a permanent tax on every future checkpoint (one more thing to scan and dedup against) and on every session load. When unsure, **skip**.

`$ARGUMENTS` (optional): a focus note. If set, prioritize that area but still scan the rest.

## What to consider

Walk these categories. Save what applies, skip what doesn't, report both.

### Memory (default — applies to every session)

If your harness keeps a per-project memory store, use the conventions already in your system prompt:

- **User** — newly-learned facts about role, expertise, working style
- **Feedback** — corrections *or* validated approaches; include **Why** and **How to apply**
- **Project** — initiatives, deadlines, who-decided-what (convert relative dates to absolute)
- **Reference** — pointers to external systems, key files, dashboards

Bar (default = skip): a save must **name the specific future decision it improves** — "a future Claude would make a worse call on X without this." If you can't name that decision, don't write it. Skip anything derivable from code, git, or `CLAUDE.md`. Update existing memory files instead of creating duplicates (a near-duplicate is a marginal save wearing a disguise). Update the memory index for any new files.

**Event-driven demotion for `project_*` memories:** `project_*` files track in-flight initiatives and are perishable — they are stale the moment the initiative closes. When an initiative or project concludes in this session (ships, is cancelled, or reaches a stable steady state), the closing session must prune or demote its `project_*` memory: delete it if it has no lasting lesson, or boil it down to a one-line `reference_*` entry capturing only the durable takeaway. This is the retirement counterpart to event-driven durable *writes* — the same discipline applies to retiring a memory when its triggering event ends. `reference_*`, `feedback_*`, and `user` memories are durable and are NOT targets for demotion.

### Plans

If there's a plan in flight (in conversation or on disk), make sure the on-disk version reflects current decisions. A stale plan that contradicts what was just discussed is worse than no plan.

### Ship-role artifacts (role-dependent)

**Navigator** (if the `navigator` module is installed):
- Tickets drafted in conversation but not on disk → write them to `projects/<project>/tickets/<id>.md` using `core/templates/ticket.md`
- Queue strategy changes discussed → route as a drop in `inbox/drops/`; Mate is the sole writer of `queue.md`
- Open Captain-decisions surfaced this session → drop a note in `inbox/`

**Mate:**
- Active watches without a log entry → write the watch log under `logs/`
- Queue tactical state moves (Backlog→Ready, Ready→Active, →Done, →Blocked) → make sure `queue.md` reflects the live state

**Crew or normal session that did bounded work:**
- Write a watch log under `logs/` if there isn't one already

### Loose ends

If the session has open questions, half-finished decisions, or context that wouldn't make sense to a fresh assistant, write a short note to:

```
inbox/checkpoint-$(date +%Y-%m-%d-%H%M).md
```

Keep it under 30 lines. Start the file with this line so its status is unambiguous:

```
> Transient handoff — absorb durable bits into tickets/memory, then delete this file. Not durable history — never rely on it.
```

Then cover:
- What was being worked on (one sentence)
- What's resolved vs still open
- Where to pick up (pointers only — `see ticket NNN Current-state`, `see queue.md Done`, etc.)

**Hard invariant:** if a checkpoint contains a fact not already in a durable home (ticket, `queue.md`, memory, `captain.md`), that is the bug — fix the durable home, not the checkpoint. A checkpoint must never be the sole record of any state. The "Where to pick up" section must contain only pointers to durable homes, never the only copy of open work.

This file ferries only the *residual* loose ends across the boundary — the durable content (decisions, findings, who-decided-what) should already be in memory/tickets/plans per the categories above. **The Mate absorbs checkpoint files** — this one included — in its CHECK INBOX step: it verifies each still-open item's durable home and then **deletes this file** (`rm`). No other seat should janitor checkpoints. (This is about `checkpoint-*.md` only; it is *not* a claim on `inbox/drops/`. A drop named for a seat other than the Mate belongs to that seat, which clears it once actioned — see `core/mate.md` § Processing Inbox → Drops.) Checkpoints are not saved or archived: the hard invariant above guarantees the file is never the sole record of anything, so once its loose ends are confirmed in durable homes it has no further use. Don't let checkpoints accumulate in `inbox/`.

Skip this entirely if the session was clean (everything decided/landed/saved elsewhere).

## Procedure

1. **Survey & verify** — scan recent turns for items in each category, and for each check whether it's *already* in a durable home — **confirm each by reading the durable home from disk, not from session memory; a write you only remember making is unverified.** "Check whether it's already saved" can otherwise be satisfied by "I'm pretty sure I wrote that," which shares a failure mode with the very write this pass exists to insure — reading the file back is independent of that belief. Most should be. Don't over-collect; the bar is "future-Claude decision quality," default skip.
2. **Write only the residue** — write the few items that aren't already durable: memory files + index, plans, ship artifacts, loose-end notes. If everything's already durable, write nothing and say so.
3. **Report** — finish with a punch list:
   ```
   Saved:
   - <file>: <one-line reason>
   - ...
   Skipped:
   - <category>: <why>
   ```
4. **Append one ledger line** to `logs/checkpoint-ledger.md` — **always, even for a no-op checkpoint** (an empty result is data: `saved 0` proves discipline held; don't silently skip it). One line, greppable, one bracket per save, no nesting:
   ```
   - YYYY-MM-DD · <role> · saved N / skipped M · [<severity>:<class>] [<severity>:<class>] …
   ```
   - `<role>` — Navigator / Mate / Crew / plain-session.
   - One `[<severity>:<class>]` bracket **per saved item** (none on a `saved 0` line): `<severity>` ∈ `would-mis-decide` | `would-redo-work` | `cosmetic` — what would have gone wrong had the item been lost. `<class>` = one hyphenated word naming the item type (`stale-project-memory`, `unsaved-ticket`, `unlogged-watch`, `stale-plan`, …); extend the vocabulary freely — the class distribution is the point.
   - **Heavy-checkpoint diagnostic (K = 2):** if the pass saved **≥ 2 genuinely-new** durable items, suffix the same line with ` · ⚠ heavy — <one clause: why did the event-time write defer?>`. No separate artifact — the whole feature stays this one report tail. Under event-driven writes a checkpoint should be a near-no-op, so two genuinely-new items already signal deferral; K = 2 is deliberately low to fire the diagnostic early while calibrating, and if it fires constantly *that is itself the finding*. Not load-bearing — cheap to retune upward once there's data.

   Example:
   ```
   - 2026-08-05 · Navigator · saved 2 / skipped 9 · [would-mis-decide:stale-project-memory] [cosmetic:unsaved-ticket] · ⚠ heavy — two ticket decisions were written at close-out instead of when decided
   ```

   **Read-out (after ~15–20 entries):** compute the catch-rate (saves per checkpoint) and the severity/class distribution. ~0 catches and mostly `cosmetic` ⇒ checkpointing is ceremony — lighten or drop it. Low catch-rate but high severity ⇒ genuine insurance — keep it. High catch-rate ⇒ event-time writes are leaking — fix the upstream discipline, don't checkpoint harder.

## Permission posture

- **Don't ask** for low-risk writes: memory files, ship logs, drafts in `inbox/`, plan updates.
- **Do confirm** before: structural `queue.md` reorders (Captain-only call), creating new tickets if the scope is unclear, deleting or rewriting existing memory files.

## When NOT to checkpoint

- Session was purely exploratory and nothing was decided → reply "nothing worth saving" and stop.
- Captain explicitly said "no memory" or "don't save this" earlier → respect it.
- Already mid-checkpoint from a prior `/checkpoint` invocation → don't re-do it; report the prior save.
