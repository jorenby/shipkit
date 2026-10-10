# Module: Session UX

**Optional. Conveniences for the human-facing seats (Captain, Mate, Navigator).** None of
these is a guard; each can fail without weakening enforcement.

| Piece | Surface | What it does |
|---|---|---|
| `scripts/ship-role.sh <Role>` | run by a seat when it takes a role | Records the role for this session (`~/.claude/ship-roles/<session-id>`) and for this cwd (`~/.claude/ship-roles/by-cwd/<hash>`). |
| `scripts/statusline.sh` | `statusLine` in `~/.claude/settings.json` | `user@host:dir (branch) │ model │ ctx NN% │ track │ ◈drops │ ROLE`. Context gauge turns yellow at 60% and red at 85%. |
| `hooks/role-restore.sh` | `SessionStart`, matcher `clear` | `/clear` starts a new session id, so the per-session role is lost. This reads the cwd-keyed record and tells the fresh session to resume its Mate or Navigator start procedure. |
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

Prerequisites: `jq` (status line, role-restore), `terminal-notifier` for banners
(`brew install terminal-notifier`).

## Notes

- Roles are strictly per session in the status line: there is no global fallback, so a
  stale file can't label a window that never took a role.
- `role-restore.sh` restores only `Mate` and `Navigator`; crew and lookouts are subagents
  and carry no status-line role.
- Top-level hooks don't fire inside subagents, so none of this reaches crew sessions.
