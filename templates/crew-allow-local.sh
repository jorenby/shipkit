#!/bin/bash
# Local crew allow-list extensions.
# This file is sourced by validate-crew-bash.sh and is NOT synced from upstream.
# Copy to scripts/crew-allow-local.sh in your ship directory and customize.
#
# Define check_allowed_local() to add project-specific allowed commands.
# Return 0 to allow, return 1 to fall through to the default deny.

check_allowed_local() {
  local cmd="$1"

  # Example: readonly AWS CLI commands
  # echo "$cmd" | grep -qE '^\s*aws\s' && return 0

  return 1
}
