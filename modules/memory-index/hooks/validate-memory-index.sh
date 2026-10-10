#!/bin/bash
# PreToolUse[Write|Edit|MultiEdit] wrapper for validate-memory-index.py. Fails OPEN: missing tooling or a crash lets the write proceed.

DIR="$(cd "$(dirname "$0")" && pwd)"
PY="$DIR/validate-memory-index.py"

command -v python3 >/dev/null 2>&1 || exit 0
[ -f "$PY" ] || exit 0

python3 "$PY" || exit 0
