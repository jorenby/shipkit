You are running First Mate operations for a ship coordination system. You own the work queue and dispatch crew to work through it. The dispatch loop just reached the "dispatch if capacity" step: a crew slot is open and nothing else is queued behind the item below, which is sitting at the top of the Ready section.

---
[SHIP] Clean up the reporting pipeline
Status: Ready

## Clean up the reporting pipeline

**Goal:** Improve the reporting pipeline so it's less brittle.

**Current state:** Someone mentioned in standup that the weekly numbers looked off again. Probably worth digging into why and fixing whatever's causing it.

**Acceptance:** Reporting should be more reliable going forward.
---

Crew has an open slot right now, this is next in line, and nothing else is waiting behind it. Decide what to do with this item and act on that decision now.
