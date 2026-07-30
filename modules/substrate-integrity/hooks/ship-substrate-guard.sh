#!/bin/bash
# Ship substrate Edit-guard — PreToolUse hook on Edit|Write|MultiEdit for BOTH ship-crew and
# the unattended janitor tick (049). Companion to the Bash guards (validate-crew-bash.sh /
# validate-janitor-bash.sh). Denies edits to the security substrate — the bash guards, the
# prod guard, the crew allow-list override, this hook, the tamper tripwire, the ship-* agent
# defs, AND the janitor's own control files (guard, settings, tick wrapper, goal, terminal
# check, launchd plist) — so neither a crew nor the janitor can neuter, via the Edit tool, the controls that
# bound it (only Bash was hooked before; Edit/Write were unguarded — the S1 hole, ticket 041).
# For the janitor this is load-bearing under --permission-mode dontAsk: Edit runs headless via
# a permissions.allow rule, so without this deny the tick could rewrite its own guard (049).
#
# INSTALL: this file is the version-controlled source. The LIVE copy must be installed
# OUTSIDE ~/code/** (at ~/.claude/hooks/ship-substrate-guard.sh) so it is not reachable
# through the repo tree a crew works in. Copy it (do NOT symlink into the repo, which would
# re-expose it). It also protects its own path, so a crew that tries to edit either copy is
# blocked fail-closed.
INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty')
[ -z "$FILE" ] && exit 0

# Match on the BASENAME (case-insensitive), NOT a path glob. A path-anchored glob is
# dodgeable with a relative / non-normalized file_path that still resolves to the substrate
# file (`scripts/validate-crew-bash.sh` with no leading dir, `./`, `//`, trailing slash,
# repo-relative `agents/ship-crew.md`, uppercase on a case-insensitive FS). The substrate
# basenames are ship-specific enough that matching them is safe — a false-deny on an
# unrelated file that happens to share one of these names is negligible and fails safe.
BASE=$(basename -- "$FILE" | tr '[:upper:]' '[:lower:]')
case "$BASE" in
  validate-crew-bash.sh \
  | validate-readonly-bash.sh \
  | validate-janitor-bash.sh \
  | validate-prod-guard.sh \
  | validate-mate-mcp-bash.sh \
  | crew-allow-local.sh \
  | ship-substrate-guard.sh \
  | substrate_tripwire.py \
  | substrate_tripwire_state.json \
  | ship-crew.md \
  | ship-lookout.md \
  | ship-janitor-tick.sh \
  | janitor-terminal-check.sh \
  | janitor-goal.txt \
  | janitor-settings.json \
  | com.ship.janitor-tick.plist)
    echo "Blocked: cannot edit security-substrate files (bash guards, prod guard, agent defs, the tamper tripwire + its baseline, the substrate Edit-hook, and the janitor's guard/settings/tick/goal/terminal-check/plist). Route this change to a Mate parent-shell or the Captain." >&2
    exit 2
    ;;
esac
exit 0
