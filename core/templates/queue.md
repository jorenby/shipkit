# Watch Bill

> **Owned by First Mate.** Crew: read only.

<!-- ENTRY RETENTION RULE — the ticket is the durable record; this queue is the index.
  Per line, keep WHETHER/WHEN to act (gate, blocker, trigger, fork-point, date);
  cut HOW (impl recipe, paths, commands) — that lives in the ticket.
  - Ready/Active/Blocked: gate / blocker / waiting-on / fork-point + date.
  - Backlog: tag + one-line + resurrect-trigger + date. Spike findings → ticket.
  - Done: last ~10 as `id + outcome + date`; drop older (ticket + git log hold it).
  SAFETY GATE: thinning is a move, not a delete — open the ticket and confirm it
  holds the prose before you cut. If the ticket's fresher, resync the line.
  EDIT-TIME: write lines thin from the start; cap Done in the same edit that adds to it. -->

## Ready
<!-- Tickets ready for dispatch, in priority order. Mate pops from top. -->
<!-- Format: 1. [ticket-id](path) - summary | last: YYYY-MM-DD -->

<!-- empty -->

## Active
<!-- Currently being worked. One crew per ticket. -->
<!-- Format: 1. [ticket-id](path) - summary | last: YYYY-MM-DD-HHMM -->

<!-- empty -->

## In Review
<!-- Has PR(s) waiting on CI, review, or merge -->
<!-- Format: 1. [ticket-id](path) - PR link + status | last: YYYY-MM-DD -->

<!-- empty -->

## Backlog
<!-- Not actively being worked. Tags: [impl-ready] [needs-captain] [someday] -->
<!-- Format: 1. [ticket-id](path) [tag] - summary | last: YYYY-MM-DD -->

<!-- empty -->

## Done (recent)
<!-- Recently completed. CAP ~10: when you add an entry, delete the oldest past the cap
     in the same edit (see ENTRY RETENTION RULE up top). -->

<!-- empty -->
