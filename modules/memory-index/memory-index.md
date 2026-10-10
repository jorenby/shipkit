# Module: Memory-Index Guard

**Optional. For operators who rely on Claude Code's auto-memory.** A `PreToolUse` hook that
refuses a write which would push a memory index (`~/.claude/projects/<shard>/memory/MEMORY.md`)
past the budget the harness loads.

## Why

The memory index is loaded into every session up to a fixed byte ceiling (about 25,000
bytes) and is cut from the **bottom**. Two things push newer entries below the cut, where
they silently stop loading: one index line that grows into a paragraph, and an index that
grows past the ceiling. Nothing warns you when either happens.

## What it checks

Both budgets are evaluated on every `Write`, `Edit` and `MultiEdit` to a `MEMORY.md` directly
under `~/.claude/projects/<one segment>/memory/` (raw path or realpath; nested `.claude` trees
elsewhere, such as a memory backup clone, are out of scope):

1. **Line budget:** any line the write adds or changes over 200 characters. Lines already in
   the file are grandfathered. When the result can be modelled, the resulting lines are
   checked, so a short fragment that tail-extends an entry past 200 is still caught.
2. **File budget:** a resulting file over 23,500 bytes, **only when the write grows the
   file**. A shrinking write always passes, so draining an over-budget index is never blocked
   by its own guard.

Units differ on purpose: the line budget counts characters, the file budget counts UTF-8
bytes (the loader's unit).

## Design choices

- **Deny, not ask.** `ask` auto-denies in headless sessions, which would silently block an
  unattended session from recording a lesson. The deny reason says exactly how to fix the
  write, so the agent can shorten and retry in the same turn.
- **Fails open.** Missing `python3`, an unreadable file, unparseable input or an edit it can't
  model all abstain and let the write through. A tooling fault must not eat a memory. This is
  the opposite of the deploy module's prod guard, which fails closed; the two protect against
  opposite-cost mistakes.
- **Abstain is silence.** It never emits `defer`: an explicit `defer` from one hook suppresses
  a co-matched hook's `allow` in headless mode.
- **Seat coverage.** Top-level `PreToolUse` hooks don't fire inside subagents, so this covers
  the interactive, Mate and Navigator seats, not crew.

## Install

1. `python3 shipkit_init.py --modules memory-index` (or the `personal` preset).
2. Register it in `~/.claude/settings.json`, replacing `__SHIP_ROOT__`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [
          { "type": "command", "command": "__SHIP_ROOT__/modules/memory-index/hooks/validate-memory-index.sh" }
        ]
      }
    ]
  }
}
```

3. Watch it fire once: ask a session to append a 300-character line to a memory index and
   confirm the deny.

## Test

`python3 modules/memory-index/tests/test_validate_memory_index.py`. It runs the checker
against a temporary `HOME`, so no real memory file is read or written.
