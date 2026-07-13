# Lesson 2 — Dispatching crew

*One cycle of the dispatch loop: a real small task becomes a ticket, watch orders, a
background crew agent, and a log you can judge.*

**The idea to land.** Crew are **bounded, disposable sessions** — fresh agents that get
watch orders, do one scoped piece of work, write a log, and terminate. They are not the
Mate switching hats: they run in the background with their own context while the Mate
stays present for steering. The contract that makes this safe to scale is the **log**: a
crew session's only lasting output is written state, and the standard for that log is
brutal and simple — *a completely fresh session must be able to continue from it alone.*
Get that, and you can run five crew in parallel without losing the plot.

**Walk it:**

1. **Pick one real, small, bounded task.** From the operator's actual work — a question
   to research, a survey of a repo, a small fix. Genuinely small: the point is to feel
   the loop, not to ship a feature. (No candidates? "Survey the test layout of <a repo
   they care about> and report" is a perfect first dispatch.)
2. **Watch the Mate make it dispatchable.** Ticket under `projects/{area}/tickets/`
   (from `core/templates/ticket.md`), queued in `queue.md` — which the Mate owns
   exclusively; crew can't write it, a hook enforces that. Then the watch orders: ticket
   path, branch, goal, scope, constraints. Orders are the crew's *entire* briefing —
   whatever isn't written down, the crew doesn't know.
3. **Dispatch, in the background.** The Mate launches a `ship-crew` agent (or
   `ship-lookout` for a read-only check — the cheapest, safest first dispatch). Notice
   the operator is *not waiting*: the Mate stays responsive, and this is where parallel
   crew come from later.
4. **Read the log together.** When the watch ends, open the log in
   `logs/{project}/{ticket}/` — Did / Left off / Next steps / Handoff confidence. Apply
   the standard: could a fresh session continue from this alone? Then watch the Mate do
   its half: verify the load-bearing claims, update the ticket's Current State and Watch
   History, reconcile the queue (`core/mate.md` → "Reviewing Completed Watches").
5. **One thing to notice for next time:** the crew wrote files but committed nothing —
   it *can't*, a hook blocks it. That's not a limitation, it's a design decision, and
   it's the whole subject of lesson 3.

**Point at:** `core/crew.md` (the crew contract — scope discipline, checkpointing, the
log format), `modules/subagent-roster/subagent-roster.md` (the full roster + dispatch
patterns), `core/mate.md` → "Dispatch Details".

**Next:** Lesson 3 — the review gate: why crew can't commit, and who checks the maker's
work.
