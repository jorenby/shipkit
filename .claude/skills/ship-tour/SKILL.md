---
name: ship-tour
description: >
  The progressive guided tour of running a Ship — five short, self-contained lessons
  (your first watch → dispatching crew → the review gate → going autonomous → staying
  current), invocable ANYTIME, in any order, at any experience level. Invoke
  (`/ship-tour`) right after a fresh install (the setup skill's "show me the ropes"
  path hands off here), or later to pick up a single lesson — `/ship-tour 3`,
  `/ship-tour review gate`. Each lesson is hands-on: the operator DOES one real cycle
  of the thing, small, on their actual ship. The tour teaches Ship's working
  philosophy by pointing at the standing orders, never by duplicating them. Lessons 4
  and 5 double as the guided TRANSITION paths (tier bump, staying in sync, adding
  modules) — small moments with their own entry points, not a mega-interview. Not the
  setup skill: install/upgrade mechanics stay in /shipkit-setup.
---

# /ship-tour — learn the ship by sailing it

You are teaching the operator — the **Captain** — how to run their ship. Not a lecture:
each lesson is one small, real cycle done together on their actual ship, with the
philosophy landed along the way. Ship's docs are the deep material; your job is to make
the operator *feel* one loop of each mechanism and know where its standing orders live.

**The frame you're teaching, underneath every lesson:** context rot is the enemy. Agent
sessions degrade as they grow, so Ship never relies on one long-lived context — it
structures work as bounded sessions with **written handoffs** (logs, tickets, the queue),
so a completely fresh session can always pick up where the last one stopped. Everything
in the tour — watches, crew, logs, the review gate, the Bosun — is that one idea wearing
different hats.

## The lessons

| # | Lesson | One cycle of |
|---|--------|--------------|
| 1 | [Your first watch](lessons/01-first-watch.md) | steering the Mate: boot, read state, one inbox item, wind down |
| 2 | [Dispatching crew](lessons/02-dispatching-crew.md) | the dispatch loop: ticket → watch orders → background crew → log |
| 3 | [The review gate](lessons/03-review-gate.md) | maker ≠ checker: why crew can't commit, and who checks the work |
| 4 | [Going autonomous](lessons/04-going-autonomous.md) | the tier bump, guided: event-driven Mate + Bosun heartbeat |
| 5 | [Staying current](lessons/05-staying-current.md) | living with upstream: pulls, the edit-safe seams, adding modules |

Lessons are **self-contained** — any one can be taken cold — and **short**: one sitting,
one cycle, done. Each ends by naming the next, but nothing requires taking them in order
or taking them all. 1–3 assume only the core tier; 4 is the door to autonomous; 5 applies
to every tier.

## Conducting a lesson

1. **Pick the lesson.** If the operator named one (`/ship-tour 3`, "the review gate one"),
   take it. Otherwise recommend from the ship's actual state — don't quiz them:
   - `logs/mate/` empty or missing → **lesson 1** (they haven't run a watch yet).
   - Mate logs exist but no `logs/{project}/{ticket}/` crew logs → **lesson 2**.
   - Crew logs exist, review gate never mentioned in them → **lesson 3**.
   - Core tier only (`ls ~/.claude/agents/ | grep ship-mate` empty) and they're asking
     about autonomy → **lesson 4**.
   - Otherwise → **lesson 5**, or ask which itch brought them here.
2. **Read the lesson file, then teach it in conversation.** Never paste the file at the
   operator. Each lesson gives you *the idea to land* (say it in your own words, early)
   and *a cycle to walk* (do it live, on their real ship, at real scale — small).
3. **Point, don't duplicate.** When a lesson touches doctrine, name the doc and the
   section (`core/mate.md` → "Maker ≠ Checker") so the operator learns where the standing
   orders live. The tour must stay true when the doctrine evolves — the docs are the
   source of truth, the lessons are the walk-through.
4. **Close by naming the next lesson** in one line, and stop. A lesson that runs long has
   failed — cut scope, not corners.

## Bounds

- **One lesson per invocation.** The operator comes back for the next one; that's the
  design (each return visit is itself a fresh-session handoff — the thing Ship practices).
- **Not the setup skill.** Install, tier-bump apply steps, and upgrade judgment live in
  `/shipkit-setup` (+ its `upgrade.md`). Lessons 4 and 5 *walk the operator to* those
  entry points and narrate what they'll see; they never re-implement them.
- **Real ship, real state.** Lessons act on the operator's actual queue/inbox/logs, at
  toy scale. Don't fabricate demo state; find (or have the Captain supply) one genuinely
  small real thing.
- If the ship isn't set up at all (no `~/.claude/agents/ship-*`), stop and send them to
  `/shipkit-setup` first.
