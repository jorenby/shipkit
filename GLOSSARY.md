# Glossary

Ship has its own vocabulary, borrowed loosely from a ship's chain of command. This page defines the terms as they're actually used across `core/mate.md`, `core/crew.md`, and `README.md`. If you're new to agent orchestration, read this once before diving into the role docs — the rest of the system assumes you already know these words.

## The three roles

**Captain** — The human. Sets priorities in `captain.md`, resolves escalations, makes external communications (PR reviews, Slack messages), and merges/pushes code. The Captain steers; they don't do the day-to-day queue bookkeeping.

**First Mate** — A Claude Code session running in the room with the Captain. Owns `queue.md`, triages the inbox, dispatches Crew, and reviews finished watches. The Mate is the only role that writes the queue. Think of the Mate as the standing coordinator — one long-lived, steerable session per work day.

**Crew** — A Claude Code subagent dispatched by the Mate to do one bounded piece of work. Crew read their watch orders, do the work, write a log, and terminate. A Crew session never persists across tasks — each watch starts from a fresh context and ends with a handoff, not a running conversation.

## Core mechanics

**Watch** — One bounded work session performed by a Crew subagent, from dispatch to log. A watch has a scope (defined by its watch orders and the ticket it's assigned), a start, and an end. "Doing a watch" means: read orders, do the work within scope, write the log, stop. Watches are deliberately short-lived — that's what keeps context from rotting.

**Watch orders** — The instructions the Mate hands a Crew subagent at dispatch time: which ticket, which branch, what "done" looks like, and any constraints specific to that watch. Watch orders are the Mate's half of the handoff *into* a watch (the log is Crew's half of the handoff *out*).

**Drop** — An item placed into the inbox by something other than a live conversation — an external process, an automation, or the Captain jotting a quick note into `inbox/captain.md` between conversations. A drop isn't a ticket yet; it's raw input waiting for the Mate to triage it into one (or into a quick task, or a question to raise with the Captain).

**Handoff** — The transfer of context between one bounded session and the next, with no shared memory in between. Ship treats handoffs as the central design problem: every artifact (log, ticket, watch orders) exists to make a handoff clean, because the *only* thing that survives between sessions is what got written down.

**Ticket** — A single unit of trackable work: a goal, acceptance criteria, current state, and a running watch history. Tickets live at `projects/{area}/tickets/{id}.md` and are the unit the queue tracks and Crew gets dispatched against. A ticket outlives any one watch — it accumulates state across however many watches it takes to finish.

**Queue** (`queue.md`) — The Mate's single source of truth for what's ready to work, what's active, what's blocked, and what's done. Organized into sections (Ready, Active, In Review, Awaiting Captain, Blocked, Backlog, Done) that tickets move through as their status changes. Only the Mate writes to it; Crew are blocked from touching it by a hook, on purpose — it keeps one role accountable for prioritization.

**Log** — The file a Crew subagent writes at the end of a watch, recording what it did, where things stand, and concrete next steps. Logs are *the* handoff mechanism in Ship — a fresh Crew session (or the Mate) should be able to read a log plus its ticket and continue with no other context. If you'd summarize a session as "what happened and what's next," that's a log.

**Bounded context** — The scope of a single watch: one ticket, one goal, a defined start and end. "Bounded" is doing real work here — it's the opposite of an open-ended, ever-growing conversation. Keeping contexts bounded is how Ship avoids context rot: instead of one session accumulating scrollback until the model loses the thread, each unit of work gets a fresh session sized to just that unit.

**Scope gate** — The discipline of staying inside a watch's assigned boundary even when it would be easy to drift outside it. If a Crew subagent notices the ticket's scope is wrong, or finds adjacent work worth doing, the scope gate says: flag it, don't do it. Scope creep inside one watch is exactly the kind of silent expansion the bounded-context model is designed to prevent — so it gets named and enforced as a rule, not left to individual judgment.

## How the terms connect

A **Captain** drops a task into the inbox (a **drop**). The **First Mate** triages it into a **ticket** and places it in the **queue**. When the Mate has dispatch capacity, it turns the ticket into **watch orders** and hands them to a **Crew** subagent, which works inside that **bounded context**, respects the **scope gate**, and ends the **watch** by writing a **log** — the **handoff** that lets the next watch (or the Mate) pick up cleanly.
