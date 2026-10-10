---
name: drops
description: Apply and delete the pending Mate-addressed drops in inbox/drops/ into queue.md and tickets, then commit the slice. Mutating, Mate-only.
disable-model-invocation: true
---

# /drops — Flush Pending Drops

## Guard

Run only as the Mate. If `~/.claude/ship-roles/$CLAUDE_CODE_SESSION_ID` exists (the session-ux module writes it) and does not contain `Mate`, refuse and stop. If it doesn't exist, proceed only if this session was told it is the First Mate. `queue.md` has a single writer; another seat running this reintroduces the two-writer race drops exist to prevent.

## Flow

1. List `inbox/drops/` in the ship root. Skip `.gitkeep`, directories, and `processed/`.
2. Skip every drop addressed to another seat: a `for-{seat}-` name prefix (optionally after a date) or a frontmatter `for:` naming a seat other than the Mate. Leave those in place; they are that seat's to clear.
3. If nothing remains, report "no pending drops" and stop.
4. For each remaining drop:
   a. Read it and apply the change to `queue.md` or the named ticket, following `core/mate.md` → "Processing Inbox" → Drops. Substitute real sequential IDs for any `NEXT` / `NEXT+1` placeholders in a proposed ticket: you are the single writer that mints numbers.
   b. **Never promote into Ready off a drop.** A drop asking for Ready is a recommendation: file or keep the ticket in Backlog and surface the ask to the Captain.
   c. Delete the drop file once applied.
5. Report what changed in `queue.md` and tickets, which drops were cleared, and which were left (and why).

## After flushing — commit the slice

Commit only the files this flush touched: `queue.md`, the tickets you edited or filed, and the deleted drop files. Nothing else that happens to be staged or dirty belongs in this commit. This is the same "commit the slice" rule as reviewing completed watches, applied here so a drop flush doesn't drift into a large uncommitted pile.
