# Worked Example

The rest of Ship's docs describe the *shape* of a ship directory. This directory shows a *populated instance* of that shape, so you have something concrete to imitate instead of just a template.

Everything here is synthetic. "Lumen Craft" and "Driftnote" are invented for this example — not a real company, product, or repo. If any of it looks like something real, that's coincidence.

## The scenario

Lumen Craft is a fictional two-person company building Driftnote, a sync-first note-taking app, across two repos: `driftnote-web` (the frontend) and `driftnote-sync` (the backend sync service). The Captain runs both repos through one ship directory and has a First Mate session doing the day-to-day coordination.

## What's in `ship/`

```
ship/
  captain.md                                            # the Captain's priorities
  queue.md                                               # the Mate's queue, mid-flight
  projects/driftnote-sync/tickets/
    042-retry-webhook-delivery.md                        # a ticket, in-review state
  logs/driftnote-sync/042-retry-webhook-delivery/
    2026-07-25-1430.md                                   # the one completed watch on that ticket
```

Read them in this order — it mirrors how they'd actually get created:

1. **[`captain.md`](ship/captain.md)** — The Captain has written down what matters: fix a webhook bug affecting customers (ticket 042), then add CSV export (ticket 017). Everything else is lower priority. This is the input the Mate uses to decide what to dispatch next.

2. **[`queue.md`](ship/queue.md)** — The Mate's live picture of the world, built from `captain.md` plus whatever's happened since. Ticket 017 is sitting in **Ready** because 042 was the priority and got dispatched first. Ticket 042 has since moved to **In Review** — the watch is done, a PR is open, and it's waiting on the Captain, not on more Crew work. Notice `009-dark-mode` and `029-sync-conflict-banner` sitting in **Backlog** with tags (`[someday]`, `[needs-captain]`) — not every ticket is actively being pushed forward at once.

3. **[`projects/driftnote-sync/tickets/042-retry-webhook-delivery.md`](ship/projects/driftnote-sync/tickets/042-retry-webhook-delivery.md)** — The actual unit of work. Notice the shape: a one-line goal, a checklist of acceptance criteria (most checked, one waiting on the Captain), a "Current state" paragraph that's specific enough to reorient a stranger, and a "Watch history" section linking out to the log below. This ticket has had exactly one watch so far — many tickets take more.

4. **[`logs/driftnote-sync/042-retry-webhook-delivery/2026-07-25-1430.md`](ship/logs/driftnote-sync/042-retry-webhook-delivery/2026-07-25-1430.md)** — The Crew subagent's handoff from that one watch. This is the file to study most closely: "Did" is specific (file names, what changed, what was tested), "Left off" states plainly that this is a wait-on-human handoff rather than a wait-on-Crew one, "Next steps" are concrete enough to act on without guessing, and "Handoff confidence" is a blunt self-assessment (5, because there's nothing ambiguous left). The "Notes" section flags an adjacent TODO the Crew noticed but deliberately didn't touch — that's the scope gate in action.

## How the pieces connect

This is the loop, with this example's names filled in:

**Captain sets priority** (`captain.md`: "fix the webhook bug first") **-> Mate queues it** (`queue.md`: ticket 042 moves from Ready to Active) **-> Crew runs a watch** (reads the ticket, implements the retry logic, opens a draft PR) **-> the log is the handoff** (042's watch history links to the 2026-07-25-1430 log, which says clearly that the ball is now in the Captain's court) **-> Mate updates the queue again** (042 moves to In Review) **-> the Captain reviews and merges**, closing the loop.

Nothing here depends on anyone remembering the previous conversation. A brand-new session — Mate or Crew — could read `captain.md`, `queue.md`, the ticket, and the log, and know exactly where things stand and what happens next. That's the property this whole system is built to preserve.
