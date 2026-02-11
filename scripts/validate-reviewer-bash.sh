#!/bin/bash
# Ship triage reviewer safety hook
# Blocks any gh commands that modify PRs/issues (approve, comment, merge, close).
# Used as a PreToolUse hook for ship-reviewer subagent.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Block gh write operations
if echo "$COMMAND" | grep -iE '\bgh\s+(pr|issue)\s+(approve|comment|merge|close|review|edit|create)\b' > /dev/null; then
  echo "Blocked: Reviewers cannot modify PRs or issues. Return your verdict as a message." >&2
  exit 2
fi

# Block git write operations (reviewers have no reason to write)
if echo "$COMMAND" | grep -iE '\bgit\s+(commit|push|add|reset|revert|merge|rebase|checkout\s+-b)\b' > /dev/null; then
  echo "Blocked: Reviewers are read-only." >&2
  exit 2
fi

exit 0
