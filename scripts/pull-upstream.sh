#!/bin/bash
# Sync generic shipkit process files from upstream repo to local ship/ directory.
# Project-specific files (captain.md, queue.md, inbox/, logs/, projects/) are never touched.
#
# Usage:
#   ./pull-upstream.sh [--apply] [--new-only] [upstream-path-or-url]
#
# Modes:
#   (default)    Dry run — show what would change
#   --apply      Copy all syncable files (new + changed)
#   --new-only   Only copy files that don't exist locally (safe, no overwrites)
#
# If no upstream path is given, clones from GitHub to a temp directory.

set -euo pipefail

UPSTREAM_REPO="https://github.com/wstrinz/shipkit.git"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APPLY=false
NEW_ONLY=false
UPSTREAM_DIR=""
CLONED_TMP=""

cleanup() {
  if [ -n "$CLONED_TMP" ] && [ -d "$CLONED_TMP" ]; then
    rm -rf "$CLONED_TMP"
  fi
}
trap cleanup EXIT

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --new-only) APPLY=true; NEW_ONLY=true ;;
    --help|-h)
      echo "Usage: $0 [--apply] [--new-only] [upstream-path-or-url]"
      echo "  Default: clones $UPSTREAM_REPO"
      echo "  --apply:    copy all syncable files"
      echo "  --new-only: only copy files that don't exist locally"
      exit 0
      ;;
    -*) echo "Unknown flag: $arg"; exit 1 ;;
    *) UPSTREAM_DIR="$arg" ;;
  esac
done

if [ -z "$UPSTREAM_DIR" ]; then
  CLONED_TMP=$(mktemp -d)
  echo "Cloning $UPSTREAM_REPO ..."
  git clone --depth 1 --quiet "$UPSTREAM_REPO" "$CLONED_TMP"
  UPSTREAM_DIR="$CLONED_TMP"
  echo ""
elif [ ! -d "$UPSTREAM_DIR" ]; then
  echo "Error: Upstream not found: $UPSTREAM_DIR"
  exit 1
fi

echo "Upstream: $UPSTREAM_DIR"
echo "Local:    $LOCAL_DIR"
if $NEW_ONLY; then
  echo "Mode:     NEW ONLY (skip existing files)"
elif $APPLY; then
  echo "Mode:     APPLY (overwrite changed files)"
else
  echo "Mode:     DRY RUN"
fi
echo ""

# Generic process files to sync (relative paths).
# These are the "shipkit framework" files, not project-specific content.
SYNC_FILES=(
  # Role standing orders
  "crew.md"
  "mate.md"
  "CLAUDE.md"
  "README.md"
  # Subagent definitions
  "agents/ship-crew.md"
  "agents/ship-lookout.md"
  # Hook scripts
  "scripts/validate-crew-bash.sh"
  # Sync script (keeps itself up to date)
  "scripts/pull-upstream.sh"
  # Templates
  "templates/captain.md"
  "templates/queue.md"
  "templates/ticket.md"
)

# Files that are NEVER synced (project-specific content).
# Listed here for documentation — the script simply doesn't include them above.
# captain.md, queue.md, inbox/, logs/, projects/

NEW=0
CHANGED=0
UNCHANGED=0
APPLIED=0

for file in "${SYNC_FILES[@]}"; do
  upstream="$UPSTREAM_DIR/$file"
  target="$LOCAL_DIR/$file"

  if [ ! -f "$upstream" ]; then
    echo "  WARN: not in upstream: $file"
    continue
  fi

  if [ ! -f "$target" ]; then
    echo "  NEW:  $file"
    NEW=$((NEW + 1))
    if $APPLY; then
      mkdir -p "$(dirname "$target")"
      cp "$upstream" "$target"
      [ -x "$upstream" ] && chmod +x "$target"
      APPLIED=$((APPLIED + 1))
      echo "        -> copied"
    fi
  elif diff -q "$upstream" "$target" > /dev/null 2>&1; then
    UNCHANGED=$((UNCHANGED + 1))
  else
    echo "  DIFF: $file"
    diff_output=$(diff -u "$target" "$upstream" --label "local/$file" --label "upstream/$file" || true)
    diff_lines=$(echo "$diff_output" | wc -l)
    echo "$diff_output" | head -40
    if [ "$diff_lines" -gt 40 ]; then
      echo "        ... ($((diff_lines - 40)) more lines)"
    fi
    echo ""
    CHANGED=$((CHANGED + 1))
    if $APPLY && ! $NEW_ONLY; then
      cp "$upstream" "$target"
      [ -x "$upstream" ] && chmod +x "$target"
      APPLIED=$((APPLIED + 1))
      echo "        -> overwritten"
    elif $NEW_ONLY; then
      echo "        (skipped — file exists locally)"
    fi
  fi
done

echo "---"
echo "New: $NEW  Changed: $CHANGED  Unchanged: $UNCHANGED"
if $APPLY; then
  echo "Applied: $APPLIED"
fi
if ! $APPLY && [ $((NEW + CHANGED)) -gt 0 ]; then
  echo ""
  echo "To copy new files only:  $0 --new-only"
  echo "To copy everything:      $0 --apply"
fi
