#!/bin/bash
# Notification hook (macOS): chime plus a banner titled with this session's ship role. Optional $1 = fallback message.
input=$(cat)
FALLBACK="${1:-needs your input}"

{ IFS= read -r MSG; IFS= read -r CWD; IFS= read -r SID; } < <(printf '%s' "$input" | /usr/bin/python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
for key, fallback in (("message", sys.argv[1]), ("cwd", ""), ("session_id", "")):
    print((d.get(key) or fallback).replace("\n", " "))' "$FALLBACK")
MSG="${MSG:-$FALLBACK}"
PROJ=$(basename "$CWD" 2>/dev/null)

SID=${SID//[^A-Za-z0-9-]/}
ROLE=$(cat "$HOME/.claude/ship-roles/$SID" 2>/dev/null || echo "Claude Code")

# Hooks run with a minimal PATH that may not include Homebrew.
NOTIFIER=$(command -v terminal-notifier)
for p in /opt/homebrew/bin/terminal-notifier /usr/local/bin/terminal-notifier; do
  [ -z "$NOTIFIER" ] && [ -x "$p" ] && NOTIFIER="$p"
done

afplay /System/Library/Sounds/Glass.aiff &
[ -n "$NOTIFIER" ] && "$NOTIFIER" -title "$ROLE" -subtitle "$PROJ" -message "$MSG" >/dev/null 2>&1
exit 0
