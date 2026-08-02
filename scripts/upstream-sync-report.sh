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

# Metric 2: outstanding contribute-back candidates — unchecked "- [ ]" lines in the candidates file.
if [ -f "$CANDIDATES_FILE" ]; then
  CANDIDATES=$(grep -c '^- \[ \]' "$CANDIDATES_FILE" || true)
else
  CANDIDATES=0
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
echo "  contribute-back candidates outstanding: $CANDIDATES"
echo "  overlay-% of tree:                    $CHANGED_FILES/$TOTAL_FILES files differ ($OVERLAY_PCT%)"
echo ""
if [ "$BEHIND" -eq 0 ] && [ "$CANDIDATES" -eq 0 ]; then
  echo "Nothing to do this week."
else
  echo "Review: pull small clean upstream changes in an isolated worktree; bundle candidates into a PR when the list is worth sending."
fi
