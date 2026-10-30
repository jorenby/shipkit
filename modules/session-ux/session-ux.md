# Module: Session UX

**Optional. Conveniences for the human-facing seats (Captain, Mate, Navigator).** None of
these is a guard; each can fail without weakening enforcement.

| Piece | Surface | What it does |
|---|---|---|
| `scripts/ship-role.sh <Role>` | run by a seat when it takes a role | Records the role for this session (`~/.claude/ship-roles/<session-id>`) and for this cwd (`~/.claude/ship-roles/by-cwd/<hash>`). |
| `scripts/statusline.sh` | `statusLine` in `~/.claude/settings.json` | `user@host:dir (branch) │ model │ ctx NN% │ track │ ◈drops │ ROLE`. Context gauge turns yellow at 60% and red at 85%. |
| `hooks/compact-recover.sh` | `SessionStart`, matcher `compact` | After a manual or auto compaction, tells a Mate or Navigator session to re-read its role doc in full and continue mid-task rather than run its start procedure (a compaction keeps at most the opening of an invoked skill). Adds a checkpoint catch-up, run against the full transcript, only when the ship repo has uncommitted, new or unpushed work, or an unabsorbed `inbox/checkpoint-*.md`. |
| `hooks/compact-log.sh` | `PostCompact`, matcher `manual\|auto` | Appends one line per Mate/Navigator compaction to `logs/compactions.jsonl`: trigger, time, and whether the summary kept the role and any open Captain gate. The summary text stays local in `~/.claude/ship-compactions/`. |
| `hooks/read-role.sh` | sourced by both compaction hooks | Reads the role: the session-id record first (a compaction keeps the session id), the cwd-keyed record as fallback. |
| `hooks/claude-notify.sh` | `Notification`, matcher `permission_prompt\|idle_prompt\|agent_needs_input` | macOS chime plus a `terminal-notifier` banner titled with the session's role. Setup and troubleshooting: [macos-notifications.md](macos-notifications.md). |

## Install

1. `python3 shipkit_init.py --modules session-ux` (or the `personal` preset). This makes
   the hooks executable; it does **not** register them.
2. Merge [`templates/settings-hooks.example.json`](templates/settings-hooks.example.json)
   into `~/.claude/settings.json`, replacing `__SHIP_ROOT__` with this checkout's absolute
   path. Settings edits are picked up without a restart; check with `/hooks`.
3. Have each role record itself when it starts. For the Mate, add a house note to
   `mate.local.md`: *"On taking the Mate role, run
   `modules/session-ux/scripts/ship-role.sh Mate`."* For the Navigator, run
   `ship-role.sh Navigator` at the start of the session (or add the same line to your
   copy of the navigator skill).
4. Optional track tags in the status line: set `SHIP_STATUSLINE_TRACKS` in the `env` block
   of `~/.claude/settings.json`, as `glob=TAG` pairs separated by `;`, first match wins:
   `"*api-service*=API;*ship*=ship"`.

Prerequisites: `jq` (status line, compaction hooks), `terminal-notifier` for banners
(`brew install terminal-notifier`).

Tests: `bash modules/session-ux/tests/compact-recover.test.sh` builds a throwaway repo and
role directory; it never touches your ship or your role records.

## Compact instructions

The recovery hook can only see what is on disk. Add a block like this to the ship's
`CLAUDE.md` so the compaction summary keeps what isn't:

```
# Compact instructions

When summarizing a ship session (Mate, Navigator), keep these verbatim or near-verbatim:
- The active role (Mate / Navigator).
- Every Captain go and every gate still waiting on the Captain, quoted with what it covers.
- Decisions reached in chat that are not yet written to a ticket, queue.md or memory.
- Worktree paths, branches and head SHAs in flight; unpushed commits.
- Commands handed to the Captain that the Captain has not yet confirmed running.
```

## Notes

- Roles are strictly per session in the status line: there is no global fallback, so a
  stale file can't label a window that never took a role.
- The compaction hooks act only on `Mate` and `Navigator`; crew and lookouts are subagents
  and carry no ship role.
- There is no `/clear` role restore. The cwd-keyed record is last-writer-wins across seats
  launched from the same directory, so after `/clear` it could hand a session the other
  seat's role; restate the role yourself after a clear. The record stays as the compaction
  hooks' fallback.
- Top-level hooks don't fire inside subagents, so none of this reaches crew sessions.
