# Lesson 1 — Your first watch

*One full cycle of steering the Mate: boot, read state, one inbox item through the loop,
wind down.*

**The idea to land.** You are the Captain. You don't operate the ship — you steer it. The
Mate reads state, triages your inbox, dispatches work, and reports; you set priorities,
make the calls, and own everything external (commits to shared repos, merges, comments).
And the ship's memory is **written state, not the session**: when this conversation ends,
everything that matters survives in `captain.md`, `queue.md`, and the logs. A session you
could lose without losing anything — that's the shape of every watch from here on.

**Walk it** (this session is already the right place — you, the tour conductor, *become*
the Mate for this cycle and run the real ceremony, narrating as you go):

1. **Boot the Mate.** Take the role yourself — announce it ("putting on the Mate's hat
   for this watch") and read `core/mate.md`; the operator doesn't need to recite
   anything. (Mention in passing that *"You're First Mate on this ship — read
   `core/mate.md`"* is the manual boot line for future sessions without the tour; on the
   autonomous tier the boot is `/ship-watch-start`.) Then do what a booting Mate does,
   visibly: read `queue.md`, `captain.md`, `inbox/captain.md`, and the latest
   `logs/mate/` entry before saying anything substantive. That re-anchor opens *every*
   watch — the fresh session earning its context back from written state.
2. **Give the ship its standing orders.** `captain.md` is how the Captain steers durably —
   priorities and constraints every future session inherits without being told. Have the
   Mate interview the operator briefly (what are you working on, what matters most, what
   should never happen without asking) and write the answers into `captain.md`.
3. **Run one item through the inbox.** Have the operator drop one real, small thought
   into `inbox/captain.md` — a task, an idea, a nagging question, ideally something they
   actually want done this week. Then triage it visibly: ticket, quick task, or
   discussion (`core/mate.md` → "Processing Inbox"), and clear the line once processed.
   If it triages to a ticket, **create it for real** (`projects/{area}/tickets/`, queued
   under Ready) — that ticket is lesson 2's dispatch, already waiting. This is the
   everyday rhythm: the Captain drops, the Mate triages, the inbox is always empty-able.
4. **Wind down.** Close the session properly (`core/mate.md` → "Sessions and Logs"; the
   full sweep is `modules/session-ceremony/session-ceremony.md` → "End of session"): the
   day's mate log in `logs/mate/` with status + handoff notes, queue reconciled, anything
   worth keeping committed. Then say the quiet part out loud: the next session —
   tomorrow, or after a crash — reads that log and continues as if nothing was lost.
   Logs are the handoff.

**Point at:** `core/mate.md` (the Mate's whole doctrine — skim the section headings
together so the operator knows what the Mate is *supposed* to do), `captain.md`,
`inbox/captain.md`.

**Next:** Lesson 2 — dispatching crew: the Mate stops doing the work itself and starts
sending bounded background agents to do it.
