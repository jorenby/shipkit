#!/bin/bash
# Ship crew git safety hook
# Blocks destructive git operations while allowing safe read/navigation commands.
# Used as a PreToolUse hook for ship-crew subagent.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Block destructive git operations
if echo "$COMMAND" | grep -iE '\bgit\s+(commit|push|add|reset\s+--hard|revert|merge|rebase|cherry-pick|clean)\b' > /dev/null; then
  echo "Blocked: Crew cannot run destructive git operations. Mate/Captain handles commits and pushes." >&2
  exit 2
fi

# Block writes to queue.md
if echo "$COMMAND" | grep -E 'queue\.md' > /dev/null; then
  echo "Blocked: Crew cannot modify queue.md. Only Mate owns the queue." >&2
  exit 2
fi

# Block rm -rf
if echo "$COMMAND" | grep -E '\brm\s+(-rf|-fr)\b' > /dev/null; then
  echo "Blocked: Crew cannot run rm -rf." >&2
  exit 2
fi

exit 0
