# Queue

> **Owned by First Mate.** Crew: read only.

## Ready
<!-- Tickets ready for dispatch, in priority order. Mate pops from top. -->
<!-- Format: 1. [ticket-id](path) - summary | last: YYYY-MM-DD -->

## Active
<!-- Currently being worked. One crew per ticket. -->
<!-- Format: 1. [ticket-id](path) - summary | last: YYYY-MM-DD-HHMM -->

## Waiting
<!-- Waiting on CI, approval, or external action -->

## Blocked
<!-- Waiting on external input / decision needed -->
<!-- Format: 1. [ticket-id](path) - blocker summary | last: YYYY-MM-DD -->

## On Hold
<!-- Intentionally paused - not blocked, waiting for right time -->
<!-- Format: 1. [ticket-id](path) - state summary | held: YYYY-MM-DD -->

## Done (recent)
<!-- Recently completed, for reference -->
