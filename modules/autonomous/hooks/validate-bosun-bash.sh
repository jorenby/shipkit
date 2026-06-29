#!/bin/bash
# Ship BOSUN agent allow-list bash hook (PreToolUse, matcher "Bash").
# For the ship-bosun standalone background loop.
#
# Same read-only posture as a lookout, with ONE narrow addition: the Bosun may run
# `modules/autonomous/scripts/bosun_emit.py` (its path-locked write helper, which can only touch
# state/bosun-heartbeat.log, state/bosun-last-sweep.json, inbox/drops/). Every OTHER
# write vector stays denied — including raw stdout redirects, tee, and dd, which a
# plain readonly hook leaves open. Default is DENY.
#
# CHMOD +x IS LOAD-BEARING: a non-exec hook fails OPEN (silent zero enforcement).
#
# Self-scopes on the PreToolUse payload's agent_type == "ship-bosun" (works in --bg,
# where launch env doesn't propagate). CRITICAL: a default-DENY allow-list MUST pass
# through (exit 0) for every other session, or it would block bash for the Mate + crew.

INPUT=$(cat)
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')
[ "$AGENT_TYPE" != "ship-bosun" ] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$COMMAND" ] && exit 0

# ============================================================
# DENY-LIST (explicit blocks with clear error messages)
# ============================================================

# Git write operations
if echo "$COMMAND" | grep -qiE '\bgit\s+(commit|push|add|reset|revert|merge|rebase|cherry-pick|clean|stash\s+(drop|pop|clear))\b'; then
  echo "Blocked: Bosun is read-only — no git write operations." >&2
  exit 2
fi
# Queue.md (Mate owns it)
if echo "$COMMAND" | grep -qE 'queue\.md'; then
  echo "Blocked: Bosun cannot touch queue.md — Mate owns the queue. Surface via a drop (bosun_emit.py drop)." >&2
  exit 2
fi
# rm (any form)
if echo "$COMMAND" | grep -qE '\brm\b'; then
  echo "Blocked: Bosun cannot delete files." >&2
  exit 2
fi
# gh write operations
if echo "$COMMAND" | grep -qiE '\bgh\s+(pr|issue)\s+(create|comment|approve|merge|close|review|edit|reopen)\b'; then
  echo "Blocked: Bosun cannot modify PRs or issues (bright line). Surface via a drop." >&2
  exit 2
fi
# mutating gh api — the allow-list permits `gh api` (reads), so a mutating call
# must be explicitly denied here or it slips through (else the Bosun could POST a
# comment / merge / close via the raw API and defeat the read-only bright line).
if echo "$COMMAND" | grep -qiE '\bgh\s+api\b' && echo "$COMMAND" | grep -qiE '\s(-X|--method)\s*(POST|PUT|DELETE|PATCH)\b'; then
  echo "Blocked: Bosun cannot make mutating gh api calls (bright line). Surface via a drop." >&2
  exit 2
fi
# tee / dd — raw write tools
if echo "$COMMAND" | grep -qE '(^|[[:space:]|;&])(tee|dd)([[:space:]]|$)'; then
  echo "Blocked: Bosun writes ONLY via modules/autonomous/scripts/bosun_emit.py — no tee/dd." >&2
  exit 2
fi
# Stdout file redirection — strip the harmless /dev/null + fd-merge forms, then if any
# '>' remains it's a write to a real file → block. (Bosun writes go through bosun_emit.)
SAN_REDIR=$(echo "$COMMAND" | sed -E 's#[0-9]?>>?[[:space:]]*/dev/null##g; s#[0-9]?>&[0-9]##g')
if echo "$SAN_REDIR" | grep -qE '>'; then
  echo "Blocked: Bosun cannot redirect output to files — use modules/autonomous/scripts/bosun_emit.py (heartbeat|cursor|drop)." >&2
  exit 2
fi

# ============================================================
# ALLOW-LIST
# ============================================================

check_allowed() {
  local cmd="$1"
  cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$cmd" ] && return 0

  # --- Bosun's ONLY sanctioned write path (path-locked helper) ---
  echo "$cmd" | grep -qE '^\s*(python3?|/usr/bin/env\s+python3?)\s+\S*scripts/bosun_emit\.py\b' && return 0

  # --- PR triage / curate tools (read-only) ---
  echo "$cmd" | grep -qE '^\s*pr-buddy\b' && return 0
  echo "$cmd" | grep -qiE '^\s*gh\s+pr\s+(view|diff|checks|list|status)\b' && return 0
  echo "$cmd" | grep -qiE '^\s*gh\s+(api|search)\b' && return 0

  # --- Git read operations ---
  echo "$cmd" | grep -qE '^\s*git\s+(status|diff|log|branch|show|fetch|rev-parse|remote|ls-files|blame|shortlog|describe|stash\s+list|tag(\s+-l)?)\b' && return 0

  # --- File/directory inspection ---
  echo "$cmd" | grep -qE '^\s*(ls|pwd|wc|file|which|type|stat|du|df|tree|realpath|basename|dirname)\b' && return 0

  # --- File reading ---
  echo "$cmd" | grep -qE '^\s*(cat|head|tail|less|more)\b' && return 0

  # --- Searching ---
  echo "$cmd" | grep -qE '^\s*(find|grep|rg|ag|fd|locate)\b' && return 0
  echo "$cmd" | grep -qE '^\s*qmd\b' && return 0

  # --- Text processing (read-only — no sed/awk/tee which can write) ---
  echo "$cmd" | grep -qE '^\s*(sort|uniq|tr|cut|jq|yq|xargs|column)\b' && return 0

  # --- Output ---
  echo "$cmd" | grep -qE '^\s*(echo|printf|true|false)\b' && return 0

  # --- Navigation ---
  echo "$cmd" | grep -qE '^\s*cd\b' && return 0

  # --- Process/environment inspection ---
  echo "$cmd" | grep -qE '^\s*(ps|env|printenv|id|whoami|hostname|uname|date|sleep)\b' && return 0

  # --- Diff/compare ---
  echo "$cmd" | grep -qE '^\s*diff\b' && return 0

  # --- curl (GET only) ---
  if echo "$cmd" | grep -qE '^\s*curl\b'; then
    if echo "$cmd" | grep -qE '\s(-X\s*(POST|PUT|DELETE|PATCH)|--data\b|-d\s|--form\b|-F\s|--upload-file\b|-T\s)'; then
      echo "Blocked: Bosun cannot make mutating HTTP requests." >&2
      return 1
    fi
    return 0
  fi

  # --- Hex/binary inspection ---
  echo "$cmd" | grep -qE '^\s*(xxd|hexdump|od|strings)\b' && return 0

  # --- Local overrides (not synced from upstream) ---
  # Copy modules/autonomous/templates/bosun-allow-local.sh next to this hook
  # (modules/autonomous/hooks/bosun-allow-local.sh) for deployment-specific read-only tools
  # (e.g. your own PR-curate script). Define check_allowed_local() returning 0.
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$script_dir/bosun-allow-local.sh" ]; then
    source "$script_dir/bosun-allow-local.sh"
    check_allowed_local "$cmd" && return 0
  fi

  return 1
}

# Split on &&, ||, |, ; and check each segment.
SEGMENTS=$(echo "$COMMAND" | perl -pe 's/\s*(\&\&|\|\||\||;)\s*/\n/g')

while IFS= read -r segment; do
  segment=$(echo "$segment" | sed 's/^[[:space:]]*//')
  [ -z "$segment" ] && continue
  if ! check_allowed "$segment"; then
    echo "Blocked: Command not on bosun allow-list: $(echo "$segment" | head -c 120)" >&2
    echo "Allowed: bosun_emit.py (writes), pr-buddy, gh pr read/api/search, git read, file inspection, searching, qmd, text processing." >&2
    exit 2
  fi
done <<< "$SEGMENTS"

exit 0
