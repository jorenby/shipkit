#!/bin/bash
# Read-only weekly drift report against wstrinz/shipkit. Never merges/rebases/resets/pushes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$LOCAL_DIR"

REMOTE="upstream"
LOCAL_BRANCH="main"
CANDIDATES_FILE="notes/upstream-candidates.md"

if ! git remote get-url "$REMOTE" > /dev/null 2>&1; then
  echo "No '$REMOTE' remote configured. Run: git remote add $REMOTE git@github.com:wstrinz/shipkit.git" >&2
  exit 1
fi

echo "Fetching $REMOTE (read-only; no merge/rebase/push)..."
git fetch "$REMOTE" --quiet

UPSTREAM_BRANCH=""
for candidate in main master; do
  if git show-ref --verify --quiet "refs/remotes/$REMOTE/$candidate"; then
    UPSTREAM_BRANCH="$candidate"
    break
  fi
done
if [ -z "$UPSTREAM_BRANCH" ]; then
  echo "Could not find $REMOTE/main or $REMOTE/master — check upstream's default branch." >&2
  exit 1
fi

UPSTREAM_REF="$REMOTE/$UPSTREAM_BRANCH"

# Metric 1: commits-behind-upstream (upstream commits we haven't merged up).
BEHIND=$(git log --oneline "$LOCAL_BRANCH..$UPSTREAM_REF" | wc -l | tr -d ' ')

# Metric 2: ahead-of-upstream commits not yet sent, derived from the repo.
# Pool = commits ahead of upstream. A commit LEAVES the count when its short SHA is
# recorded in the ledger as either sent ("- [x]") or local-only/won't-send ("- [~]"),
# matched with word boundaries so a longer hex token cannot false-match. So the count
# is "ahead of upstream, not yet sent and not marked local-only" — a real, convergeable
# signal (intentional divergence can be excused with "- [~]"), NOT the old hollow TODO
# count that read 0 on top of real work. It is a candidate POOL, not a vetted list — the
# human curates which are worth a PR, which is why the label is not "candidates".
AHEAD_SHAS=$(git log --format='%h' "$UPSTREAM_REF..$LOCAL_BRANCH")
CANDIDATES=0
OUTSTANDING=""
if [ -n "$AHEAD_SHAS" ]; then
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    if [ -f "$CANDIDATES_FILE" ] && grep -qE "^- \[[x~]\].*\b$sha\b" "$CANDIDATES_FILE"; then
      continue  # recorded as sent (- [x]) or local-only/won't-send (- [~])
    fi
    CANDIDATES=$((CANDIDATES + 1))
    OUTSTANDING="$OUTSTANDING $sha"
  done <<< "$AHEAD_SHAS"
fi

# Metric 3: overlay-% of tree, measured as files-changed-% (simplest; not line-level diff).
TOTAL_FILES=$(git ls-files | wc -l | tr -d ' ')
CHANGED_FILES=$(git diff --name-only "$LOCAL_BRANCH" "$UPSTREAM_REF" | wc -l | tr -d ' ')
if [ "$TOTAL_FILES" -eq 0 ]; then
  OVERLAY_PCT="0.0"
else
  OVERLAY_PCT=$(awk "BEGIN { printf \"%.1f\", ($CHANGED_FILES/$TOTAL_FILES)*100 }")
fi

echo ""
echo "Upstream sync report ($UPSTREAM_REF vs local $LOCAL_BRANCH)"
echo "  commits-behind-upstream:              $BEHIND"
echo "  ahead-of-upstream, unsent (pool):     $CANDIDATES"
echo "  overlay-% of tree:                    $CHANGED_FILES/$TOTAL_FILES files differ ($OVERLAY_PCT%)"
echo ""
# Only upstream drift (behind > 0) triggers the weekly auto-drop — the tick keys on
# a leading "Review:". The contribute-back backlog is a slow-draining pool curated
# one PR at a time, so it is reported honestly every run but does not nag as a drop.
if [ "$BEHIND" -gt 0 ]; then
  echo "Review: pull small clean upstream changes in an isolated worktree."
fi
if [ "$CANDIDATES" -gt 0 ]; then
  echo "Backlog: $CANDIDATES commit(s) ahead of upstream, unsent — curate the general ones into a PR, or excuse local-only ones with a '- [~] <desc> <sha>' line in $CANDIDATES_FILE."
  echo "  outstanding:$OUTSTANDING"
fi
if [ "$BEHIND" -eq 0 ] && [ "$CANDIDATES" -eq 0 ]; then
  echo "Nothing to do this week."
fi
