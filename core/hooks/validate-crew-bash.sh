#!/bin/bash
# Ship crew allow-list bash hook
# Only allows commands matching known-safe patterns.
# Used as a PreToolUse hook for ship-crew subagent with dontAsk permissions.
#
# Design: deny-list runs first (clear error messages for common mistakes),
# then allow-list catches everything else. Default is DENY.
#
# PATTERN ANCHORING (SHIP-HOOK-PATTERN-ANCHORING): the command is split into
# segments QUOTE-AWARELY (a `|` inside "(a|b)" no longer fragments the command),
# and deny patterns are anchored to the segment's INVOKED command when that
# command is a known data-arg binary (echo/grep/git/…) — so `grep "git push" docs/`
# or `echo "rm -rf is scary"` no longer false-block. Segments invoking wrappers/
# interpreters (sh, xargs, env-prefixes, $(…)/backticks, unknowns) keep the
# ORIGINAL raw substring deny scan. The allow-list itself is unchanged and still
# default-DENY, so this relaxes only deny-list FALSE positives, never the gate.
#
# W2 (max-scrutiny review fixes): backslash-newline continuations are collapsed
# BEFORE scanning (B2); a bare-interpreter segment (`… | sh`) triggers a raw
# deny scan of the WHOLE command — the piped payload rides as data in the other
# segments (B1); $'…' quoting forces the raw scan (N2); zero segments fail
# CLOSED (N3).

# jq DEPENDENCY GUARD (fail CLOSED): every gate below parses the PreToolUse stdin
# with jq. Without jq the parse yields empty, the agent-type/command checks no-op,
# and the hook exits 0 — SILENT ZERO ENFORCEMENT. Refuse to run instead: exit 2
# (fail CLOSED) with a loud message. shipkit_init.py's preflight asserts jq is on
# PATH at install, so a correctly-installed ship never reaches this.
if ! command -v jq >/dev/null 2>&1; then
  echo "Blocked: ${0##*/} requires jq, which is not on PATH. Install jq (brew install jq / apt-get install jq / winget install jqlang.jq) — failing CLOSED to avoid silent zero enforcement of the Ship hooks." >&2
  exit 2
fi

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# ============================================================ SHIP-MATCH-LIB v2
# Shared segment-matching helpers. DUPLICATED into every validate-*-bash.sh hook —
# hooks must stay SELF-CONTAINED single files (installs invoke them in-place as
# `bash <abs-path>`; a missing sourced sibling would error the hook, and a non-2
# hook error FAILS OPEN). If you change this block, change it in ALL hooks
# (grep for SHIP-MATCH-LIB). bash-3.2 + POSIX-awk compatible (macOS + Git-Bash).

# Collapse backslash-newline line continuations BEFORE any scanning (W2 fix B2):
# the shell rejoins `git push origin \`⏎`main` into ONE command, so the scanner
# must too — a plain newline split let the halves dodge every pattern. REMOVAL
# (not a space) mirrors shell semantics, so mid-word smuggles (`git pu\`⏎`sh`)
# rejoin as well. Only an ODD run of backslashes continues a line; an escaped
# backslash before a newline stays a real boundary. Quote-blind on purpose:
# inside single quotes this only MERGES data into one segment (never splits),
# which can only ADD matches on the deny side — fail-closed direction.
ship_collapse_continuations() {
  printf '%s\n' "$1" | perl -0777 -pe 's/(?<!\\)((?:\\\\)*)\\\n/$1/g'
}

# Quote-aware split: one segment per line, splitting on UNQUOTED && || | ; and
# newlines. Exit 3 when quotes are unbalanced — caller MUST fall back to
# ship_naive_split (more fragments → over-block → fail-closed).
ship_split_segments() {
  printf '%s\n' "$1" | awk -v sq="'" '
    BEGIN { q = "" }
    {
      line = $0
      if (NR > 1) printf "\n"
      i = 1; n = length(line)
      while (i <= n) {
        c = substr(line, i, 1)
        if (q != "") {
          if (q == "\"" && c == "\\") { printf "%s", substr(line, i, 2); i += 2; continue }
          if (c == q) q = ""
          printf "%s", c; i++; continue
        }
        if (c == sq || c == "\"") { q = c; printf "%s", c; i++; continue }
        if (c == "\\") { printf "%s", substr(line, i, 2); i += 2; continue }
        if (substr(line, i, 2) == "&&" || substr(line, i, 2) == "||") { printf "\n"; i += 2; continue }
        if (c == "|" || c == ";") { printf "\n"; i++; continue }
        printf "%s", c; i++
      }
    }
    END { printf "\n"; if (q != "") exit 3 }
  '
}

# Legacy naive split (quote-blind) — the fail-closed fallback.
ship_naive_split() {
  printf '%s\n' "$1" | perl -pe 's/\s*(\&\&|\|\||\||;)\s*/\n/g'
}

# First whitespace-delimited word of a segment.
ship_first_word() {
  printf '%s\n' "$1" | awk '{print $1; exit}'
}

# Command word of a segment AFTER skipping `env`, VAR=… assignments, and leading
# flags — so `env -i bash` / `FOO=1 python3` read as bash / python3. Used by the
# bare-interpreter detector; over-detection only ADDS a raw scan (fail-closed).
ship_seg_cmd_word() {
  printf '%s\n' "$1" | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i == "env" || index($i, "=") > 0 || $i ~ /^-/) continue
      print $i; exit
    }
  }'
}

# W2 fix B1: does this segment invoke a BARE interpreter (one that executes its
# STDIN)? `bash -c cmd` carries its payload IN-segment (raw-scanned there); a
# bare `… | bash` executes whatever the OTHER segments produce — so the caller
# must ALSO raw-scan the FULL original command (the producing segments are the
# payload). `-c` must be its own word to disarm detection: missing a real -c
# only adds an over-blocky whole-command scan, never skips one (fail-closed).
ship_seg_bare_interpreter() {
  local seg="$1" w
  w=$(ship_seg_cmd_word "$seg")
  case "$w" in
    sh|bash|zsh|dash|ksh|python*|ruby|perl|node|deno|bun) ;;
    *) return 1 ;;
  esac
  case " $seg " in *" -c "*) return 1 ;; esac
  return 0
}

# Is this segment "transparent" (safe for ANCHORED deny checks)? Requires:
#   - first word in the hook's space-padded SAFE_ARGV list (data-arg binaries), and
#   - no command substitution ($( or backtick) anywhere in the segment, and
#   - no $'…' ANSI-C quoting (W2 fix N2: the quote-char stripper removes only
#     bare '/" characters, so $'main' would face an anchored check as $main and
#     dodge the boundary-anchored ref match — force the RAW scan instead).
# Everything else (wrappers, interpreters, env-prefixes, unknown commands) gets the
# RAW substring scan — i.e. the original, stricter behavior.
ship_seg_transparent() {
  local seg="$1" safe="$2" w
  case "$seg" in *'$('*|*'`'*|*\$\'*) return 1 ;; esac
  w=$(ship_first_word "$seg")
  [ -z "$w" ] && return 1
  case "$safe" in *" $w "*) return 0 ;; esac
  return 1
}

# Strip quote CHARACTERS (not content) — deny-side only. Removing quote chars can
# only ADD deny matches, never hide an invocation.
ship_strip_quote_chars() {
  printf '%s\n' "$1" | tr -d "'\""
}
# ========================================================== end SHIP-MATCH-LIB

# Rejoin backslash-newline continuations FIRST (W2 fix B2) — every check below,
# including the whole-command guards, must see the command the shell will run.
COMMAND=$(ship_collapse_continuations "$COMMAND")

# ============================================================
# WHOLE-COMMAND DENY (bright-line tokens blocked ANYWHERE, even quoted)
# ============================================================

# Queue.md (any reference — crew shouldn't even read it via bash)
if echo "$COMMAND" | grep -qE 'queue\.md'; then
  echo "Blocked: Crew cannot touch queue.md — Mate owns the queue." >&2
  exit 2
fi

# Data-arg binaries: their arguments are data, not commands — anchored deny checks
# apply. Deliberately EXCLUDES executors/wrappers on the crew allow-list (bash sh
# zsh ruby python node sed awk xargs env find tar devbox bundle npm npx yarn rake
# make …) — those stay raw-scanned so nothing smuggled through them is relaxed.
CREW_SAFE_ARGV=" ls pwd wc file which type stat du df tree realpath basename dirname cat head tail less more grep rg ag fd locate sort uniq tr cut jq yq tee column echo printf true false mkdir touch chmod cp mv ln rm cd ps printenv id whoami hostname uname date diff curl xxd hexdump od strings git gh qmd "

# Deny checks for OPAQUE segments — the ORIGINAL substring patterns (unchanged).
crew_check_raw() {
  local seg="$1"
  if echo "$seg" | grep -qiE '\bgit\s+(commit|push|add|reset|revert|merge|rebase|cherry-pick|clean|stash\s+(drop|pop|clear))\b'; then
    echo "Blocked: Crew cannot run git write operations. Mate/Captain handles commits." >&2
    exit 2
  fi
  if echo "$seg" | grep -qE '\brm\s+(-[a-z]*r[a-z]*|-[a-z]*f[a-z]*r[a-z]*|--recursive)\b'; then
    echo "Blocked: Crew cannot run recursive rm." >&2
    exit 2
  fi
  if echo "$seg" | grep -qiE '\bgh\s+(pr|issue)\s+(create|comment|approve|merge|close|review|edit|reopen)\b'; then
    echo "Blocked: Crew cannot modify PRs or issues. Document findings in your log." >&2
    exit 2
  fi
}

# Deny checks for TRANSPARENT segments — op anchored to the invoked command.
# $1 = segment with quote CHARS stripped.
crew_check_anchored() {
  local nq="$1"
  # git writes (skip git options like -C <path> / -c k=v so they still block)
  if echo "$nq" | grep -qiE '^[[:space:]]*git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+(commit|push|add|reset|revert|merge|rebase|cherry-pick|clean|stash[[:space:]]+(drop|pop|clear))\b'; then
    echo "Blocked: Crew cannot run git write operations. Mate/Captain handles commits." >&2
    exit 2
  fi
  # recursive rm — TIGHTENED vs the old substring: any dash-token containing r/R
  # (catches `rm -v -r x` and `rm -R x`, which the old adjacent-flag pattern missed)
  if echo "$nq" | grep -qiE '^[[:space:]]*rm\b' && echo "$nq" | grep -qE '(^|[[:space:]])(-[A-Za-z]*[rR][A-Za-z]*|--recursive)([[:space:]]|$)'; then
    echo "Blocked: Crew cannot run recursive rm." >&2
    exit 2
  fi
  if echo "$nq" | grep -qiE '^[[:space:]]*gh[[:space:]]+(pr|issue)[[:space:]]+(create|comment|approve|merge|close|review|edit|reopen)\b'; then
    echo "Blocked: Crew cannot modify PRs or issues. Document findings in your log." >&2
    exit 2
  fi
}

# ============================================================
# ALLOW-LIST
# ============================================================
# Every segment must match at least one allowed pattern.

check_allowed() {
  local cmd="$1"
  # Trim leading/trailing whitespace
  cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$cmd" ] && return 0

  # --- Dev command wrappers ---
  echo "$cmd" | grep -qE '^\s*devbox\s+' && return 0
  echo "$cmd" | grep -qE '^\s*bundle\s+exec\b' && return 0
  echo "$cmd" | grep -qE '^\s*npm\s+(run|test|exec)\b' && return 0
  echo "$cmd" | grep -qE '^\s*npx\b' && return 0
  echo "$cmd" | grep -qE '^\s*yarn\b' && return 0
  echo "$cmd" | grep -qE '^\s*rake\b' && return 0
  echo "$cmd" | grep -qE '^\s*make\b' && return 0

  # --- Git read operations (allow an optional `-C <path>` for multi-repo ships; the
  #     read-op list is UNCHANGED — writes behind -C still hit default-deny) ---
  echo "$cmd" | grep -qE '^\s*git\s+(-C\s+[^ ;|&]+\s+)?(status|diff|log|branch|show|fetch|checkout|switch|rev-parse|remote|ls-files|blame|shortlog|describe|stash\s+list|tag(\s+-l)?)\b' && return 0

  # --- File/directory inspection ---
  echo "$cmd" | grep -qE '^\s*(ls|pwd|wc|file|which|type|stat|du|df|tree|realpath|basename|dirname)\b' && return 0

  # --- File reading ---
  echo "$cmd" | grep -qE '^\s*(cat|head|tail|less|more)\b' && return 0

  # --- Searching ---
  echo "$cmd" | grep -qE '^\s*(find|grep|rg|ag|fd|locate)\b' && return 0

  # --- Text processing ---
  echo "$cmd" | grep -qE '^\s*(sort|uniq|tr|cut|sed|awk|jq|yq|tee|xargs|column)\b' && return 0

  # --- Output ---
  echo "$cmd" | grep -qE '^\s*(echo|printf|true|false)\b' && return 0

  # --- Directory/file manipulation (non-destructive) ---
  echo "$cmd" | grep -qE '^\s*(mkdir|touch|chmod|cp|mv|ln|rm)\b' && return 0

  # --- Navigation ---
  echo "$cmd" | grep -qE '^\s*cd\b' && return 0

  # --- Process/environment inspection ---
  echo "$cmd" | grep -qE '^\s*(ps|env|printenv|id|whoami|hostname|uname|date)\b' && return 0

  # --- Diff/compare ---
  echo "$cmd" | grep -qE '^\s*diff\b' && return 0

  # --- Scripting (one-liners and script execution) ---
  echo "$cmd" | grep -qE '^\s*(ruby|python|python3|node|bash|sh|zsh)\b' && return 0

  # --- curl (deny-list above catches nothing; allow GET, block mutating) ---
  # A mutating body/form/upload can be implied WITHOUT any -X POST. Mirrors the
  # W4 gh-api pflag fix (attached/cluster shorthands): the old `-d\s|--data\b|-X`
  # regex missed the attached form (-d'x'/-dx), clustered forms (-sd x/-sdx),
  # --json, --data-binary/-raw/-urlencode (long \b already covers -data-*), and
  # -F/--form / -T/--upload-file, and -K/--config (a config file can carry
  # 'data = ...' lines -> full mutating bypass; gate finding 2026-07-11).
  # Case-SENSITIVE on the shorthands: curl short flags are case-sensitive, so
  # [dFTK] must NOT match -f(fail)/-D(dump)/-t/-k(insecure).
  #   short data/form/upload/config (attached|separate|clustered):  -[flags]*[dFTK]
  #   short/cluster method + mutating verb (attached|separate): -[flags]*X ...verb
  #   long forms: --data\b (covers --data-*), --form\b, --upload-file, --json,
  #               --request + mutating verb.
  if echo "$cmd" | grep -qE '^\s*curl\b'; then
    if echo "$cmd" | grep -qE '(^|[[:space:]])-[a-zA-Z0-9#]*[dFTK]|(^|[[:space:]])-[a-zA-Z0-9#]*X[[:space:]=]*(POST|PUT|DELETE|PATCH)|--data\b|--form\b|--upload-file\b|--json\b|--config\b|--request[[:space:]=]*(POST|PUT|DELETE|PATCH)'; then
      echo "Blocked: Crew cannot make mutating HTTP requests." >&2
      return 1
    fi
    return 0
  fi

  # --- Hex/binary inspection ---
  echo "$cmd" | grep -qE '^\s*(xxd|hexdump|od|strings)\b' && return 0

  # --- Archive inspection (read-only) ---
  echo "$cmd" | grep -qE '^\s*(tar\s+(-t|--list)|unzip\s+-l|zipinfo)\b' && return 0

  # --- Local overrides (not synced from upstream) ---
  # Copy core/templates/crew-allow-local.sh next to this hook (core/hooks/crew-allow-local.sh)
  # to add project-specific allow rules. It must define check_allowed_local() returning 0 for allowed.
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$script_dir/crew-allow-local.sh" ]; then
    source "$script_dir/crew-allow-local.sh"
    check_allowed_local "$cmd" && return 0
  fi

  # Not on allow-list
  return 1
}

# ============================================================
# MAIN: quote-aware split → per-segment deny (anchored for transparent
# segments, raw for everything else) → per-segment allow-list.
# ============================================================
if ! SEGMENTS=$(ship_split_segments "$COMMAND"); then
  SEGMENTS=$(ship_naive_split "$COMMAND")   # unbalanced quotes → fail-closed fallback
fi
# W2 fix N3: zero segments from BOTH splitters → fail CLOSED, not open.
if [ -z "$(printf '%s' "$SEGMENTS" | tr -d '[:space:]')" ]; then
  SEGMENTS=$(ship_naive_split "$COMMAND")
fi
if [ -z "$(printf '%s' "$SEGMENTS" | tr -d '[:space:]')" ]; then
  echo "Blocked: command produced no scannable segments (fail closed)." >&2
  exit 2
fi

while IFS= read -r segment; do
  segment=$(echo "$segment" | sed 's/^[[:space:]]*//')
  [ -z "$segment" ] && continue
  # W2 fix B1: a bare interpreter executes whatever the OTHER segments pipe to
  # it (`echo 'git push origin main' | sh`) — the payload rides as DATA in the
  # producing segments, so raw-scan the FULL command too.
  if ship_seg_bare_interpreter "$segment"; then
    crew_check_raw "$COMMAND"
  fi
  if ship_seg_transparent "$segment" "$CREW_SAFE_ARGV"; then
    crew_check_anchored "$(ship_strip_quote_chars "$segment")"
  else
    crew_check_raw "$segment"
  fi
  if ! check_allowed "$segment"; then
    echo "Blocked: Command not on crew allow-list: $(echo "$segment" | head -c 120)" >&2
    echo "Allowed commands: devbox run, bundle exec, git read ops, npm/npx, file inspection, mkdir, ruby/python/node" >&2
    exit 2
  fi
done <<EOF_SEGMENTS
$SEGMENTS
EOF_SEGMENTS

exit 0
