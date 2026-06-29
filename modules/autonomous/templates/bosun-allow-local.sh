#!/bin/bash
# Local Bosun allow-list extensions.
# This file is sourced by validate-bosun-bash.sh and is NOT synced from upstream.
# Copy to scripts/bosun-allow-local.sh in your ship directory and customize.
#
# Define check_allowed_local() to add deployment-specific READ-ONLY tools the Bosun
# may run during its sweeps (e.g. your own PR-curate script, a tracker read CLI).
# Return 0 to allow, return 1 to fall through to the default deny.
#
# Keep these strictly read-only — the Bosun's only write path is bosun_emit.py.

check_allowed_local() {
  local cmd="$1"

  # Example: a read-only PR-comment curate script.
  # echo "$cmd" | grep -qE '^\s*\S*curate_pr_comments\.sh\b' && return 0

  return 1
}
