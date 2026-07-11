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

1. **Boot the Mate.** Have the operator say the boot line to you: *"You're First Mate on
   this ship. Read `core/mate.md` for your standing orders."* (Autonomous tier installed?
   The boot is `/ship-watch-start` instead — but the cycle below is the same.) Then do
   what a booting Mate does, visibly: read `queue.md`, `captain.md`, `inbox/captain.md`,
   and the latest `logs/mate/` entry before saying anything substantive. That re-anchor
   opens *every* watch — the fresh session earning its context back from written state.
2. **Give the ship its standing orders.** `captain.md` is how the Captain steers durably —
   priorities and constraints every future session inherits without being told. Have the
   Mate interview the operator briefly (what are you working on, what matters most, what
   should never happen without asking) and write the answers into `captain.md`.
3. **Run one item through the inbox.** Have the operator drop one real, small thought
   into `inbox/captain.md` — a task, an idea, a nagging question. Then watch the Mate
   triage it: ticket, quick task, or discussion (`core/mate.md` → "Processing Inbox"),
   and clear the line once processed. This is the everyday rhythm: the Captain drops,
   the Mate triages, the inbox is always empty-able.
4. **Wind down.** Have the Mate close the session properly (`core/mate.md` → "End of
   Session Housekeeping"): the day's mate log in `logs/mate/` with status + handoff
   notes, queue reconciled, anything worth keeping committed. Then say the quiet part
   out loud: the next session — tomorrow, or after a crash — reads that log and
   continues as if nothing was lost. Logs are the handoff.

**Point at:** `core/mate.md` (the Mate's whole doctrine — skim the section headings
together so the operator knows what the Mate is *supposed* to do), `captain.md`,
`inbox/captain.md`.

**Next:** Lesson 2 — dispatching crew: the Mate stops doing the work itself and starts
sending bounded background agents to do it.
