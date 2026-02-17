#!/bin/bash
# Ship readonly agent allow-list bash hook
# For ship-reviewer and ship-lookout subagents.
# Only allows read-only commands. Default is DENY.
#
# Design: deny-list runs first (clear error messages for common mistakes),
# then allow-list catches everything else. Default is DENY.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# ============================================================
# DENY-LIST (explicit blocks with clear error messages)
# ============================================================

# Git write operations
if echo "$COMMAND" | grep -qiE '\bgit\s+(commit|push|add|reset|revert|merge|rebase|cherry-pick|clean|stash\s+(drop|pop|clear))\b'; then
  echo "Blocked: Readonly agents cannot run git write operations." >&2
  exit 2
fi

# Queue.md (readonly agents shouldn't touch it)
if echo "$COMMAND" | grep -qE 'queue\.md'; then
  echo "Blocked: Readonly agents cannot touch queue.md — Mate owns the queue." >&2
  exit 2
fi

# rm (any form)
if echo "$COMMAND" | grep -qE '\brm\b'; then
  echo "Blocked: Readonly agents cannot delete files." >&2
  exit 2
fi

# gh write operations (PR/issue modifications)
if echo "$COMMAND" | grep -qiE '\bgh\s+(pr|issue)\s+(create|comment|approve|merge|close|review|edit|reopen)\b'; then
  echo "Blocked: Readonly agents cannot modify PRs or issues." >&2
  exit 2
fi

# ============================================================
# ALLOW-LIST
# ============================================================
# Check each command segment (split on pipes, &&, ||, ;)
# Every segment must match at least one allowed pattern.

check_allowed() {
  local cmd="$1"
  # Trim leading/trailing whitespace
  cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$cmd" ] && return 0

  # --- PR triage tools ---
  echo "$cmd" | grep -qE '^\s*pr-buddy\b' && return 0
  echo "$cmd" | grep -qiE '^\s*gh\s+pr\s+(view|diff|checks|list|status)\b' && return 0
  echo "$cmd" | grep -qiE '^\s*gh\s+api\b' && return 0

  # --- Git read operations ---
  echo "$cmd" | grep -qE '^\s*git\s+(status|diff|log|branch|show|fetch|checkout|switch|rev-parse|remote|ls-files|blame|shortlog|describe|stash\s+list|tag(\s+-l)?)\b' && return 0

  # --- File/directory inspection ---
  echo "$cmd" | grep -qE '^\s*(ls|pwd|wc|file|which|type|stat|du|df|tree|realpath|basename|dirname)\b' && return 0

  # --- File reading ---
  echo "$cmd" | grep -qE '^\s*(cat|head|tail|less|more)\b' && return 0

  # --- Searching ---
  echo "$cmd" | grep -qE '^\s*(find|grep|rg|ag|fd|locate)\b' && return 0

  # --- Text processing (read-only — no sed/awk/tee which can write) ---
  echo "$cmd" | grep -qE '^\s*(sort|uniq|tr|cut|jq|yq|xargs|column)\b' && return 0

  # --- Output ---
  echo "$cmd" | grep -qE '^\s*(echo|printf|true|false)\b' && return 0

  # --- Navigation ---
  echo "$cmd" | grep -qE '^\s*cd\b' && return 0

  # --- Process/environment inspection ---
  echo "$cmd" | grep -qE '^\s*(ps|env|printenv|id|whoami|hostname|uname|date)\b' && return 0

  # --- Diff/compare ---
  echo "$cmd" | grep -qE '^\s*diff\b' && return 0

  # --- curl (GET only — deny-list above doesn't catch this, so check here) ---
  if echo "$cmd" | grep -qE '^\s*curl\b'; then
    if echo "$cmd" | grep -qE '\s(-X\s*(POST|PUT|DELETE|PATCH)|--data\b|-d\s)'; then
      echo "Blocked: Readonly agents cannot make mutating HTTP requests." >&2
      return 1
    fi
    return 0
  fi

  # --- Hex/binary inspection ---
  echo "$cmd" | grep -qE '^\s*(xxd|hexdump|od|strings)\b' && return 0

  # --- Archive inspection (read-only) ---
  echo "$cmd" | grep -qE '^\s*(tar\s+(-t|--list)|unzip\s+-l|zipinfo)\b' && return 0

  # Not on allow-list
  return 1
}

# Split command into segments on &&, ||, ;, and | then check each
# Use perl for reliable splitting (handles quoted strings better than sed)
SEGMENTS=$(echo "$COMMAND" | perl -pe 's/\s*(\&\&|\|\||\||;)\s*/\n/g')

while IFS= read -r segment; do
  segment=$(echo "$segment" | sed 's/^[[:space:]]*//')
  [ -z "$segment" ] && continue
  if ! check_allowed "$segment"; then
    echo "Blocked: Command not on readonly allow-list: $(echo "$segment" | head -c 120)" >&2
    echo "Allowed: pr-buddy, gh pr view/diff/checks, git read ops, file inspection, searching, text processing" >&2
    exit 2
  fi
done <<< "$SEGMENTS"

exit 0
