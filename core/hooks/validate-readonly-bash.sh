#!/bin/bash
# Ship readonly agent allow-list bash hook
# For ship-reviewer and ship-lookout subagents.
# Only allows read-only commands. Default is DENY.
#
# Design: deny-list runs first (clear error messages for common mistakes),
# then allow-list catches everything else. Default is DENY.
#
# PATTERN ANCHORING (SHIP-HOOK-PATTERN-ANCHORING): the command is split into
# segments QUOTE-AWARELY — so a reviewer's `grep -E "(activate|send_test)" f`
# is ONE grep segment, not a fragment starting at `send_test)"` that fails the
# allow-list. Deny patterns are anchored to the segment's INVOKED command when
# that command is a known data-arg binary (`grep "git push" README` passes);
# wrapper/interpreter/substitution segments keep the ORIGINAL raw substring scan.
# The allow-list is unchanged and still default-DENY.
#
# W2 (max-scrutiny review fixes): backslash-newline continuations are collapsed
# BEFORE scanning (B2); $'…' quoting forces the raw scan (N2); zero segments
# fail CLOSED (N3). No bare-interpreter whole-scan is needed here: interpreters
# are not on this allow-list, so `… | bash` already dies on default-deny
# (proven by tests).
#
# W3 (re-gate follow-ups): gh api segments now carry the mate hook's N1
# mutation deny (mutating -X/--method + implicit-POST field/body flags — this
# hook allow-lists gh api, so the deny must live here too); and a BOUNDED
# test-runner allowance (see ro_test_runner_allowed) lets reviewers execute
# repo test scripts instead of verifying by reading only.

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

# Queue.md (readonly agents shouldn't touch it)
if echo "$COMMAND" | grep -qE 'queue\.md'; then
  echo "Blocked: Readonly agents cannot touch queue.md — Mate owns the queue." >&2
  exit 2
fi

# Data-arg binaries: their arguments are data, not commands — anchored deny checks
# apply. Deliberately EXCLUDES executors/wrappers (find/xargs/tar and every
# interpreter) — those stay raw-scanned.
RO_SAFE_ARGV=" pr-buddy gh git ls pwd wc file which type stat du df tree realpath basename dirname cat head tail less more grep rg ag fd locate sort uniq tr cut jq yq column echo printf true false cd ps printenv id whoami hostname uname date diff curl xxd hexdump od strings "

# Deny checks for OPAQUE segments — the ORIGINAL substring patterns (unchanged).
ro_check_raw() {
  local seg="$1"
  if echo "$seg" | grep -qiE '\bgit\s+(commit|push|add|reset|revert|merge|rebase|cherry-pick|clean|stash\s+(drop|pop|clear))\b'; then
    echo "Blocked: Readonly agents cannot run git write operations." >&2
    exit 2
  fi
  if echo "$seg" | grep -qE '\brm\b'; then
    echo "Blocked: Readonly agents cannot delete files." >&2
    exit 2
  fi
  # find actions that delete/execute/write bypass the no-delete/no-write bright
  # line (find is allow-listed but is a wrapper): -delete removes files with no
  # `rm`; -exec/-execdir/-ok/-okdir run arbitrary commands; -fprint/-fprintf/-fls
  # write to a named file. `-exec rm` was already caught by \brm\b — -delete and
  # non-rm exec/write targets were not.
  if echo "$seg" | grep -qE '(^|[[:space:]])find\b' && echo "$seg" | grep -qE '(^|[[:space:]])-(delete|exec|execdir|ok|okdir|fprint|fprintf|fls)\b'; then
    echo "Blocked: Readonly agents cannot use find -delete/-exec/-execdir/-ok/-fprint (deletes/executes/writes files)." >&2
    exit 2
  fi
  if echo "$seg" | grep -qiE '\bgh\s+(pr|issue)\s+(create|comment|approve|merge|close|review|edit|reopen)\b'; then
    echo "Blocked: Readonly agents cannot modify PRs or issues." >&2
    exit 2
  fi
  # W3: gh api mutation deny (N1 port from the mate hook — this hook allow-lists
  # gh api, so the mutating -X/--method forms AND the implicit-POST field/body
  # flags must be denied here; reads take no fields).
  # W4: short -f/-F denied with ANY trailing char (pflag ATTACHED shorthand:
  # -ftitle=hi == -f title=hi bypassed the delimiter-requiring regex), and -i*
  # cluster prefixes (-iftitle=x, -iXPOST): -i/--include is gh api's ONLY boolean
  # shorthand; every other shorthand consumes the cluster remainder as its value.
  # Long forms keep their delimiter (pflag has no long-flag abbreviation, and
  # --fieldish-style names must not over-block).
  if echo "$seg" | grep -qiE '\bgh\s+api\b'; then
    if echo "$seg" | grep -qiE '\s(-i*X|--method)[[:space:]=]*(POST|PUT|DELETE|PATCH)\b'; then
      echo "Blocked: Readonly agents cannot make mutating gh api calls." >&2
      exit 2
    fi
    if echo "$seg" | grep -qE '(^|[[:space:]])((--field|--raw-field|--input)([[:space:]=]|$)|-i*[fF])'; then
      echo "Blocked: Readonly agents cannot pass gh api field/body flags (implicit POST — reads take no fields)." >&2
      exit 2
    fi
  fi
}

# Deny checks for TRANSPARENT segments — op anchored to the invoked command.
# $1 = segment with quote CHARS stripped.
ro_check_anchored() {
  local nq="$1"
  if echo "$nq" | grep -qiE '^[[:space:]]*git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+(commit|push|add|reset|revert|merge|rebase|cherry-pick|clean|stash[[:space:]]+(drop|pop|clear))\b'; then
    echo "Blocked: Readonly agents cannot run git write operations." >&2
    exit 2
  fi
  if echo "$nq" | grep -qiE '^[[:space:]]*rm\b'; then
    echo "Blocked: Readonly agents cannot delete files." >&2
    exit 2
  fi
  # find delete/exec/write actions — see ro_check_raw. (find is not transparent
  # today so it lands in the raw path; this keeps raw/anchored symmetric and
  # fail-closed if find is ever added to RO_SAFE_ARGV.)
  if echo "$nq" | grep -qE '(^|[[:space:]])find\b' && echo "$nq" | grep -qE '(^|[[:space:]])-(delete|exec|execdir|ok|okdir|fprint|fprintf|fls)\b'; then
    echo "Blocked: Readonly agents cannot use find -delete/-exec/-execdir/-ok/-fprint (deletes/executes/writes files)." >&2
    exit 2
  fi
  if echo "$nq" | grep -qiE '^[[:space:]]*gh[[:space:]]+(pr|issue)[[:space:]]+(create|comment|approve|merge|close|review|edit|reopen)\b'; then
    echo "Blocked: Readonly agents cannot modify PRs or issues." >&2
    exit 2
  fi
  # W3: gh api mutation deny (N1 port); W4: attached/clustered shorthands — see ro_check_raw.
  if echo "$nq" | grep -qiE '^[[:space:]]*gh[[:space:]]+api\b'; then
    if echo "$nq" | grep -qiE '\s(-i*X|--method)[[:space:]=]*(POST|PUT|DELETE|PATCH)\b'; then
      echo "Blocked: Readonly agents cannot make mutating gh api calls." >&2
      exit 2
    fi
    if echo "$nq" | grep -qE '(^|[[:space:]])((--field|--raw-field|--input)([[:space:]=]|$)|-i*[fF])'; then
      echo "Blocked: Readonly agents cannot pass gh api field/body flags (implicit POST — reads take no fields)." >&2
      exit 2
    fi
  fi
}

# ============================================================
# ALLOW-LIST
# ============================================================
# Every segment must match at least one allowed pattern.

# W3: bounded reviewer test-runner allowance. Test files are repo content a
# reviewer already trusts-to-read; this trades a BOUNDED execution surface for
# review quality (reviewers previously verified by reading only). Bounds, all
# fail-closed:
#   - no quotes/expansions/redirections/globs/escapes anywhere in the segment
#     (separators are already handled by segmentation; redirects are NOT — so
#     they're rejected here);
#   - the word after the interpreter must be a LITERAL relative script path
#     (never a flag → -c / -m / bare-stdin forms can't qualify; an interpreter
#     given a script arg does not execute its stdin, so pipes into these stay
#     inert);
#   - no `..` components, no absolute/home paths;
#   - python3 only for *.py under a tests/ directory; bash only for scripts
#     whose basename matches test-*.sh.
ro_test_runner_allowed() {
  local seg="$1" w script path base
  case "$seg" in
    *'$'*|*'`'*|*'>'*|*'<'*|*'&'*|*'\'*|*"'"*|*'"'*|*'('*|*')'*|*'{'*|*'}'*|*'~'*|*'*'*|*'?'*|*'['*) return 1 ;;
  esac
  w=$(printf '%s\n' "$seg" | awk '{print $1; exit}')
  script=$(printf '%s\n' "$seg" | awk '{print $2; exit}')
  [ -z "$script" ] && return 1
  case "$script" in -*|/*) return 1 ;; esac
  # Normalize: strip leading ./ repeats, then reject any .. component.
  path="$script"
  while [ "${path#./}" != "$path" ]; do path="${path#./}"; done
  case "/$path/" in */../*) return 1 ;; esac
  case "$w" in
    python3)
      case "$path" in tests/*.py|*/tests/*.py) return 0 ;; esac
      ;;
    bash)
      # No directory constraint in this lane (deliberate: basename-only per spec;
      # script content is trusted-repo class either way).
      base="${path##*/}"
      case "$base" in test-*.sh) return 0 ;; esac
      ;;
  esac
  return 1
}

check_allowed() {
  local cmd="$1"
  # Trim leading/trailing whitespace
  cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$cmd" ] && return 0

  # --- PR triage tools ---
  echo "$cmd" | grep -qE '^\s*pr-buddy\b' && return 0
  echo "$cmd" | grep -qiE '^\s*gh\s+pr\s+(view|diff|checks|list|status)\b' && return 0
  echo "$cmd" | grep -qiE '^\s*gh\s+api\b' && return 0

  # --- Git read operations (allow an optional `-C <path>` for multi-repo ships; the
  #     read-op list is UNCHANGED — writes behind -C still hit default-deny) ---
  echo "$cmd" | grep -qE '^\s*git\s+(-C\s+[^ ;|&]+\s+)?(status|diff|log|branch|show|fetch|checkout|switch|rev-parse|remote|ls-files|blame|shortlog|describe|stash\s+list|tag(\s+-l)?)\b' && return 0

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
      echo "Blocked: Readonly agents cannot make mutating HTTP requests." >&2
      return 1
    fi
    return 0
  fi

  # --- Hex/binary inspection ---
  echo "$cmd" | grep -qE '^\s*(xxd|hexdump|od|strings)\b' && return 0

  # --- Archive inspection (read-only) ---
  echo "$cmd" | grep -qE '^\s*(tar\s+(-t|--list)|unzip\s+-l|zipinfo)\b' && return 0

  # --- Reviewer test runners (W3, bounded — see ro_test_runner_allowed) ---
  ro_test_runner_allowed "$cmd" && return 0

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
  if ship_seg_transparent "$segment" "$RO_SAFE_ARGV"; then
    ro_check_anchored "$(ship_strip_quote_chars "$segment")"
  else
    ro_check_raw "$segment"
  fi
  if ! check_allowed "$segment"; then
    echo "Blocked: Command not on readonly allow-list: $(echo "$segment" | head -c 120)" >&2
    echo "Allowed: pr-buddy, gh pr view/diff/checks, git read ops, file inspection, searching, text processing" >&2
    exit 2
  fi
done <<EOF_SEGMENTS
$SEGMENTS
EOF_SEGMENTS

exit 0
