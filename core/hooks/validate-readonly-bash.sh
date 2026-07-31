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
# BEFORE scanning (B2); a bare-interpreter segment forces a raw scan (B1); $'…'
# quoting forces the raw scan (N2); zero segments fail CLOSED (N3). (Interpreters
# are not on this allow-list either, so `… | bash` already dies on default-deny —
# the bare-interpreter whole-scan is defence-in-depth, fail-closed direction.)
#
# W3 (re-gate follow-ups): gh api segments carry the mate hook's N1 mutation deny
# (mutating -X/--method + implicit-POST field/body flags — this hook allow-lists
# gh api, so the deny must live here too). The BOUNDED reviewer test-runner
# allowance is DECLINED — read-only agents execute nothing; test verification is a
# read, and when execution is genuinely needed the guarded crew reviewer (032) is
# the path, not a lookout. Recorded in DECISIONS.md.
#
# SUBSTRATE SELF-PROTECTION (058 (B) allow-list inversion, ported from the crew
# guard): a read-only agent can still WRITE a guard via a redirect from an allowed
# reader (`cat innocuous > core/hooks/validate-readonly-bash.sh` — cat is allowed,
# `>` writes). The reader-inversion + redirect deny below close that Bash-path
# mirror of the 041 Edit-guard hole. See the SUBSTRATE block for the (B) rule.
#
# WRITE-SCOPE BOUNDARY (accepted residual, Fable 058-readonly MED-2): this hook gates
# COMMANDS (a read-only allow-list) and protects the SECURITY SUBSTRATE from writes. It
# does NOT sandbox all filesystem writes — an allow-listed reader can still redirect
# (`cat x > /tmp/out`), `curl -o`, `sort -o`, or `yq -i` to a NON-substrate path. Closing
# that generally would mean denying every reader's `> file` (breaking legitimate
# `cmd > /tmp/out`) — the writer-enumeration treadmill this project rejects
# (feedback_guard_design_allowlist_over_denylist). The airtight wall is the OS-level
# control (043/parked); the substrate is what actually must not be written, and it is.
#
# ACCEPTED RESIDUAL (Fable 058-readonly re-review MED-B): `git branch <name>` creates a LOCAL
# ref (a minor `.git/refs` write). The destructive forms (-d/-D/-m/-c/-C/-f/-u) ARE denied;
# creation-without-overwrite is left allowed rather than inverting `branch` (its many read
# flags — -a/-r/-v/--contains/--merged/--points-at/--show-current/--format — make an allow-list
# inversion false-block-prone, unlike the small `git tag` list-flag set that IS inverted).
# Bounded: local-only, no working-tree/remote change, no overwrite. OS-wall (043) is the closure.
#
# DELIBERATE-EVASION RESIDUAL (Fable 058-readonly re-review HIGH-1, deferred to 043 per the
# 041/047 doctrine + the crew slice's Nav ruling on the identical class). The deny funcs are a
# PRE-expansion text matcher; a flag PRODUCED BY SHELL EXPANSION carries no literal `-` for them
# to see — `git branch $'\x2dD'`, `fd . $'\x2dx' sh -c id`, `git branch ${x:--D}`, `git branch
# $(printf -- -D)`, or a bare `$FLAG` whose value is `-D`. Backslash/quote escapes ARE closed
# (deny-side normalization); expansion-produced flags cannot be, because seeing them requires
# EXPANDING the command (running it) — the very thing the guard exists to gate. This is the same
# layer-mismatch Nav ruled deferred for the substrate arming: bounded+monitored, NOT airtight;
# the airtight wall is the OS-level control (043/parked). No one types `$'\x2dx'` by accident —
# reaching this requires deliberate evasion, which the threat model brackets to 043.
# SEVERITY — this is NOT only a write residual: the fd/rg/ag/find exec-flags reached via
# expansion (`fd . $'\x2dx' sh -c id`, `find . $'\x2ddelete'`) give ARBITRARY CODE EXECUTION
# on a READ-ONLY agent — a strictly worse exposure than the crew slice's file-write residual.
# The realistic vector is prompt-injection through untrusted content a lookout reads, not a
# human typing the escape. This is why HIGH-1 is recorded as 043's strongest exec-class driver.

# jq DEPENDENCY GUARD (fail CLOSED): every gate below parses the PreToolUse stdin
# with jq. Without jq the parse yields empty, the agent-type/command checks no-op,
# and the hook exits 0 — SILENT ZERO ENFORCEMENT. Refuse to run instead: exit 2
# (fail CLOSED) with a loud message. shipkit_init.py's preflight asserts jq is on
# PATH at install, so a correctly-installed ship never reaches this.
if ! command -v jq >/dev/null 2>&1; then
  echo "Blocked: ${0##*/} requires jq, which is not on PATH. Install jq (brew install jq / apt-get install jq / winget install jqlang.jq) — failing CLOSED to avoid silent zero enforcement of the Ship hooks." >&2
  exit 2
fi
# perl DEPENDENCY GUARD (fail CLOSED): the SHIP-MATCH-LIB continuation-collapse,
# naive-split fallback, substitution extractor and span-deletion below are perl;
# without perl those degrade and the default-deny segmentation can fail OPEN.
if ! command -v perl >/dev/null 2>&1; then
  echo "Blocked: ${0##*/} requires perl, which is not on PATH — failing CLOSED to avoid silent zero enforcement of the Ship hooks." >&2
  exit 2
fi

INPUT=$(cat)
# EMPTY-INPUT GUARD (fail CLOSED): jq -r exits 0 on empty stdin, yielding an empty
# COMMAND that the empty-command allow below would pass — so a plumbing failure that
# delivers NO payload would silently allow the underlying tool call. A genuinely empty
# .command (present input, no command) is different and still allowed below.
if [ -z "$INPUT" ]; then
  echo "Blocked: ${0##*/} received empty hook input — failing closed." >&2
  exit 2
fi
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
# jq PARSE GUARD (fail CLOSED): a jq that runs but errors on malformed hook
# input yields a nonzero status with empty COMMAND — treat that as unparseable
# and refuse, rather than falling through the empty-command allow below.
if [ $? -ne 0 ]; then
  echo "Blocked: ${0##*/} could not parse hook input — failing closed." >&2
  exit 2
fi

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
        # A LONE `&` is a command separator (background operator) — everything after it is a
        # NEW command, not arguments to the first (Fable r5 HIGH-1: `cat x & rm guard` hid the
        # writer in segment 1). Do NOT split `&&` (handled above), `&>`/`&|` (redirect), or the
        # `&` of a `>&`/digit-`>&` fd-dup (prev char `>` ). Over-splitting only over-blocks.
        if (c == "&") {
          nx = substr(line, i+1, 1); pv = (i > 1) ? substr(line, i-1, 1) : ""
          if (nx == ">" || nx == "|" || pv == ">") { printf "%s", c; i++; continue }
          printf "\n"; i++; continue
        }
        printf "%s", c; i++
      }
    }
    END { printf "\n"; if (q != "") exit 3 }
  '
}

# Legacy naive split (quote-blind) — the fail-closed fallback. Splits on a lone `&` too
# (Fable r5 HIGH-1); `&&` matches first in the alternation. Over-splitting a `&>`/`>&` here
# only over-blocks, which is the fail-closed direction this fallback is for.
ship_naive_split() {
  printf '%s\n' "$1" | perl -pe 's/\s*(\&\&|\|\||\||;|\&)\s*/\n/g'
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

# Effective command word of a segment for the (B) substrate READER-check: skip a
# leading `env`, VAR=… assignments and -flags, then transparently unwrap `xargs`
# (+ its options) to the command it will actually run — so `… | xargs grep` reads
# as grep but `… | xargs rm` reads as rm. Lowercased (case-insensitive reader
# match); empty for a pure assignment / redirect-only segment. Resolving the REAL
# executed word is what makes the allow-list inversion compose with the engine.
ship_seg_reader_word() {
  printf '%s\n' "$1" | perl -ne '
    s/^\s+//;
    1 while s{^(?:env|[A-Za-z_][A-Za-z0-9_]*=\S*|-\S+)\s+}{};
    if (s/^xargs(?:\s+|$)//) {
      1 while s{^(?:-I\s*\S+|-[nPLsEd]\s*\S+|-[0rtxp]+|--[a-z-]+)\s+}{};
    }
    s/^\s+//;
    if (/^(\S+)/) { print lc($1); }
    exit;
  '
}

# Delete substitution/parameter SPANS from a string (for substrate matching only). The shell
# splices an empty/segment expansion INTO a filename (`.cla${x}ude` → `.claude`), so removing
# the span rejoins the real path — deletion mirrors the shell and only ADDS deny matches.
# Covers $(…)/backtick/=()/<()/>() (nested, to a fixpoint), ${…}, $NAME, and $1/$@/$*/$# etc.
# NOT covered (deliberate-evasion frontier, deferred to the OS-level wall 043): $'\NNN' ANSI-C
# escapes that PRODUCE a character, and a plain $VAR whose runtime value is a substrate path.
ship_delspans() {
  printf '%s\n' "$1" | perl -pe '
    s/\$\x27(?:[^\x27\\]|\\.)*\x27//g;
    1 while s/\$\((?:[^()]|\([^()]*\))*\)//g;
    1 while s/[<>=]\((?:[^()]|\([^()]*\))*\)//g;
    s/`[^`]*`//g;
    s/\$\{[^}]*\}//g;
    s/\$[A-Za-z_][A-Za-z0-9_]*//g;
    s/\$[0-9@*!#?\$-]//g;
    1 while s/\{[^{}]*\}//g;
  '
}

# Collapse redundant path syntax (`//` → `/`, `/./` → `/`) so a substrate path with extra
# slashes/dots still matches (Fable r7 HIGH-3: `core//hooks` / `core/./hooks` un-armed the tree).
# Monotonic on the deny side; a `://` in a URL becomes `:/` but URLs don't match substrate.
ship_pathnorm() {
  printf '%s\n' "$1" | perl -pe 's{//+}{/}g; 1 while s{/\./}{/}g;'
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

# SUBSTRATE SELF-PROTECTION — H6, (B) ALLOW-LIST INVERSION (Nav ruling 2026-07-30).
# Ported from the crew guard unchanged (058 readonly slice): the substrate set is
# identical, so protecting it here is the same rule. The Edit/Write substrate guard
# blocks the Edit tool from rewriting the security substrate; this closes the mirror
# BASH-path hole (041's Bash twin: a read-only agent still writes a guard via
# `cat innocuous > <guard>` — cat is allowed, the redirect writes). A whole-command
# WRITER-VERB deny-list was tried first and leaked across review rounds (the deny-list
# enumeration treadmill, per feedback_guard_design_allowlist_over_denylist). Nav ruled
# (B): INVERT to an allow-list. RULE: if a protected substrate NAME or DIR appears
# ANYWHERE in the command, then EVERY segment's effective command word must be in the
# small READER allow-set below; otherwise DENY. Enforced PER-SEGMENT in the main loop
# (over the AUGMENTED segments) so command-sub / xargs / process-sub bodies are covered.
# Case-insensitive + quote/backslash-normalized. NOT airtight: widen the reader set only
# on a demonstrated false-block; the airtight wall is the OS-level control (043/parked).
#
# SHIP-SUBSTRATE-PROTECTED: this basename set MUST stay in sync with the `case "$BASE"` list
# in modules/substrate-integrity/hooks/ship-substrate-guard.sh AND the same list in the crew
# guard. Self-contained hooks can't share a sourced list (a missing sibling fails OPEN, per
# SHIP-MATCH-LIB), so it is duplicated with this grep marker — grep SHIP-SUBSTRATE-PROTECTED
# to update ALL.
_SHIP_SUBSTRATE_BN='(validate-crew-bash\.sh|validate-readonly-bash\.sh|validate-janitor-bash\.sh|validate-prod-guard\.sh|validate-mate-mcp-bash\.sh|crew-allow-local\.sh|ship-substrate-guard\.sh|substrate_tripwire\.py|substrate_tripwire_state\.json|ship-crew\.md|ship-lookout\.md|ship-janitor-tick\.sh|janitor-terminal-check\.sh|janitor-goal\.txt|janitor-settings\.json|com\.ship\.janitor-tick\.plist)'
# Guard DIRECTORIES — the dir/glob forms a basename match alone misses (r3 MED-4:
# `rm core/hooks/*.sh`, `mv core/hooks core/hooks-old`). Includes the DEPLOYED guard
# dirs (`~/.claude/hooks`, `~/.claude/agents`) — a Fable r4 HIGH: `rm ~/.claude/hooks/*.sh`
# wiped the live guard. Readers still pass (`ls core/hooks`) — only non-readers deny.
_SHIP_SUBSTRATE_DIR='(core/hooks|core/agents|core/templates|modules/[^[:space:]/]*/hooks|modules/substrate-integrity|\.claude/hooks|\.claude/agents)'
# Guard ANCESTOR dir — only `.claude` (unambiguous: the crew's own config tree, which no
# adopter project writes to). Bare `core`/`modules` were DROPPED after Fable r5 MED-1: they
# collide with every downstream layout (Terraform `modules/`, app `core/`) and over-blocked
# to the point an operator would disable the hook.
_SHIP_SUBSTRATE_ANCESTOR='(^|[[:space:];|&<>()=,/])\.claude([/[:space:];|&<>()=,]|$)'
# Glob forms that elide the literal anchor: a glob PARENT of a hooks/agents dir (`rm */hooks/*.sh`)
# OR a glob in the segment right after the framework `core/`|`modules/` (`rm core/hoo*/*.sh`,
# `rm core/*.sh`). Narrow on purpose — a literal `core/train.py` / `modules/vpc` adopter path
# (no glob) does NOT arm, and a literal `src/hooks/*.js` app write is unarmed (only a globbed
# hooks/agents PARENT arms). Only globbed operations on the framework trees arm.
_SHIP_SUBSTRATE_GLOBDIR='([*?[][^[:space:];|&<>()=,/]*/(hooks|agents)([/[:space:];|&<>()=,]|$)|(^|[[:space:];|&<>()=,/])(core|modules)/[^[:space:];|&<>()=,/]*[*?[])'
# READER allow-set (Nav round-1 MINIMAL). No member takes an output-file arg, in-place flag,
# or command-EXEC flag that can hit a PROTECTED path. REMOVED (Fable r4/r5): xxd (`-r out`),
# less/more (`-o log`), rg/ag (`--pre`/`--pager` EXECUTE). EXCLUDED round 1 — widen ONLY on a
# demonstrated false-block: interpreters/linters, git (checkout/rm/mv <guard> mutate; git READ
# subcommands handled below), sort (-o), tee/dd/curl (-o / of=), sed/awk/cut (-i / write),
# echo/printf, date.
_SHIP_READER_SET=" cat head tail nl od hexdump strings grep egrep fgrep wc diff cmp ls stat file shasum sha256sum sha1sum md5sum cksum "

# Normalize the whole command for substrate matching: strip backslashes + quote chars,
# lowercase (basenames are already lowercase). `Validate-Readonly-Bash.SH`, `guard\.sh`,
# `>'…guard.sh'` all reduce to the canonical form — stripping only ADDS matches (fail-closed).
_SHIP_NORM_RAW=$(printf '%s\n' "$COMMAND" | tr -d '\\' | tr -d "'\"" | tr '[:upper:]' '[:lower:]')
_SHIP_NORM_COMMAND=$(ship_pathnorm "$_SHIP_NORM_RAW")
# Span-DELETED copy: remove $()/backtick/=()/<()/>() and ${…}/$NAME/$1/$@ spans entirely (Fable
# r6 HIGH-2 / r7 HIGH-2). The shell splices an empty/segment expansion INTO a filename, so a
# placeholder would MISS the rejoined basename — deletion mirrors the shell and only ADDS matches.
# Armed detection checks BOTH copies — monotonic, so testing both only ADDS arming.
_SHIP_NORM_DELSPANS=$(ship_pathnorm "$(ship_delspans "$_SHIP_NORM_RAW")")
_SHIP_ARM_INPUT=$(printf '%s\n%s\n' "$_SHIP_NORM_COMMAND" "$_SHIP_NORM_DELSPANS")
_SHIP_BOUND_L='(^|[^[:alnum:]_.-])'
_SHIP_BOUND_R='([^[:alnum:]_-]|$)'
_SHIP_PATH_PFX='([^[:space:];|&<>()=,]*/)?'
# Protected TREE — any path under these is write-protected while armed, not only the listed
# basenames (Fable r6 HIGH-3: `> ~/.claude/settings.json` truncates the hook wiring but wasn't
# a listed basename). Used by the per-segment redirect deny below.
_SHIP_SUBSTRATE_TREE='(\.claude/|core/hooks|core/agents|core/templates|modules/substrate-integrity|modules/[^[:space:];|&<>()=,/]*/hooks)'

# A5 (Nav arming-depth ruling 2026-07-30): the DIR/TREE literals above assume a `core/hooks`
# layout; an install that places the guard elsewhere (the live ship keeps it at `scripts/`) has
# its directory anchor pointing at a nonexistent dir, so `rm <real-dir>/*.sh` wouldn't arm.
# `${BASH_SOURCE[0]}`'s resolved dir IS the protected dir on ANY layout — add it as an EXTRA arm
# anchor (monotonic: only adds arming, never relaxes). Empty BASH_SOURCE → _SHIP_SELF_DIR stays
# empty → both A5 and A3 skip, literals stand (guard the assignment so `dirname ""`=`.` can't
# silently make the process cwd the protected dir).
_SHIP_SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _SHIP_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
fi
_SHIP_SELF_DIR_NORM=$(ship_pathnorm "$(printf '%s' "$_SHIP_SELF_DIR" | tr -d '\\' | tr -d "'\"" | tr '[:upper:]' '[:lower:]')")
_SHIP_SELF_DIR_RE=$(printf '%s' "$_SHIP_SELF_DIR_NORM" | perl -pe 's!([.\\^\$*+?()\[\]{}|])!\\$1!g')

# Arm the per-segment reader-only check when the command references a protected NAME,
# DIR, ANCESTOR (.claude), GLOB form, or the hook's OWN resolved dir (A5) anywhere
# (in the raw OR span-deleted copy).
if echo "$_SHIP_ARM_INPUT" | grep -qE "$_SHIP_BOUND_L$_SHIP_PATH_PFX$_SHIP_SUBSTRATE_BN$_SHIP_BOUND_R" \
   || echo "$_SHIP_ARM_INPUT" | grep -qE "$_SHIP_BOUND_L$_SHIP_PATH_PFX$_SHIP_SUBSTRATE_DIR"'([/[:space:];|&<>)]|$)' \
   || echo "$_SHIP_ARM_INPUT" | grep -qE "$_SHIP_SUBSTRATE_ANCESTOR" \
   || echo "$_SHIP_ARM_INPUT" | grep -qE "$_SHIP_SUBSTRATE_GLOBDIR" \
   || { [ -n "$_SHIP_SELF_DIR_NORM" ] && echo "$_SHIP_ARM_INPUT" | grep -qE "$_SHIP_SELF_DIR_RE"'([/[:space:];|&<>)]|$)'; }; then
  _SHIP_TOUCHES_SUBSTRATE=1
fi

# A3 (bounded, Nav ruling): if the SESSION cwd is inside the hook's own dir, a bare glob write
# (`rm *.sh` with no path text) would still wipe guards — arm on that. Session `.cwd` ONLY; an
# in-command `cd X && rm …` / `;`-re-cd is deliberately NOT chased (that's the recursive-glob
# residual — A2, bounded+monitored, closed by the OS-level wall 043).
_SHIP_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -n "$_SHIP_CWD" ] && [ -n "$_SHIP_SELF_DIR" ]; then
  case "$_SHIP_CWD/" in
    "$_SHIP_SELF_DIR"/*) _SHIP_TOUCHES_SUBSTRATE=1 ;;
  esac
fi

# Data-arg binaries: their arguments are data, not commands — anchored deny checks
# apply. Deliberately EXCLUDES executors/wrappers (find/xargs/tar and every
# interpreter) — those stay raw-scanned. Widened with the pure-reader members added
# to the substrate reader-set (nl egrep fgrep cmp shasum/…/cksum) so a read of a
# substrate file takes the anchored path, not the raw one.
RO_SAFE_ARGV=" pr-buddy gh git ls pwd wc file which type stat du df tree realpath basename dirname cat head tail nl less more grep egrep fgrep rg ag fd locate sort uniq tr cut jq yq column echo printf true false cd ps printenv id whoami hostname uname date diff cmp shasum sha256sum sha1sum md5sum cksum curl xxd hexdump od strings "

# Deny checks for OPAQUE segments — the ORIGINAL substring patterns (unchanged).
ro_check_raw() {
  local seg="$1"
  if echo "$seg" | grep -qiE '\bgit\s+(commit|push|add|reset|revert|merge|rebase|cherry-pick|clean|stash\s+(drop|pop|clear))\b'; then
    echo "Blocked: Readonly agents cannot run git write operations." >&2
    exit 2
  fi
  # --- Ship-hardened git content denies (re-applied on the port; the readonly allow-list
  #     permits branch/remote for LIST reads, so the destructive forms must be denied here —
  #     the live ship's readonly guard carries these; a read-only agent reads old versions via
  #     `git show <ref>:<path>`, never a checkout). raw form for opaque/wrapped segments. ---
  # git branch/tag destructive (delete/rename/force/copy/upstream); bare branch/tag list stays allowed
  if echo "$seg" | grep -qiE '\bgit\s+(branch|tag)\b[^|&;]*([[:space:]]-[a-zA-Z]*[dDmMfcCu]|[[:space:]]--(delete|move|force|copy|set-upstream-to|unset-upstream|edit-description))'; then
    echo "Blocked: Readonly agents cannot delete/rename/force branches or tags." >&2
    exit 2
  fi
  # git checkout/switch — reshape/discard working-tree or branch state (a WRITE)
  if echo "$seg" | grep -qiE '\bgit\s+(checkout|switch)\b'; then
    echo "Blocked: Readonly agents cannot checkout/switch (use 'git show <ref>:<path>' to read old versions)." >&2
    exit 2
  fi
  # git remote mutations; bare 'git remote' / 'git remote -v' list stays allowed
  if echo "$seg" | grep -qiE '\bgit\s+remote\s+(set-url|set-branches|set-head|add|remove|rm|rename|prune)\b'; then
    echo "Blocked: Readonly agents cannot modify git remotes." >&2
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
  # Allow-listed READERS with an arbitrary-EXEC flag reach code execution — a read-only agent
  # must not (Fable 058-readonly HIGH-3/MED-1 + re-review HIGH-B/LOW). fd -x/-X/--exec run a
  # command per result; rg/ag --pre/--pager/--hostname-bin and sort --compress-program run a
  # program. Deny the flag; the tools stay usable for plain search/listing. (`tar` is removed
  # from the allow-list entirely rather than enumerate its 6 exec flags — see check_allowed.)
  # `--pre` is delimited so it doesn't match ripgrep's real `--pretty` (re-review MED-A).
  if echo "$seg" | grep -qE '(^|[[:space:]])(fd|fdfind)\b' && echo "$seg" | grep -qE '(^|[[:space:]])(-[xX]|--exec)'; then
    echo "Blocked: Readonly agents cannot use fd -x/-X/--exec (runs a command per result)." >&2
    exit 2
  fi
  if echo "$seg" | grep -qE '(^|[[:space:]])(rg|ag)\b' && echo "$seg" | grep -qE '(^|[[:space:]])(--pre([[:space:]=]|$)|--pager|--hostname-bin)'; then
    echo "Blocked: Readonly agents cannot use rg/ag --pre/--pager/--hostname-bin (executes a program)." >&2
    exit 2
  fi
  if echo "$seg" | grep -qE '(^|[[:space:]])sort\b' && echo "$seg" | grep -qE '(^|[[:space:]])--compress-program'; then
    echo "Blocked: Readonly agents cannot use sort --compress-program (executes a program)." >&2
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
  # --- Ship-hardened git content denies, anchored to the invoked `git` (so a real
  #     `git checkout` blocks but `grep "git checkout"` does not). Same option-skip prefix
  #     as the git-write check above. See ro_check_raw for the rationale. ---
  if echo "$nq" | grep -qiE '^[[:space:]]*git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+(branch|tag)\b[^|&;]*([[:space:]]-[a-zA-Z]*[dDmMfcCu]|[[:space:]]--(delete|move|force|copy|set-upstream-to|unset-upstream|edit-description))'; then
    echo "Blocked: Readonly agents cannot delete/rename/force branches or tags." >&2
    exit 2
  fi
  if echo "$nq" | grep -qiE '^[[:space:]]*git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+(checkout|switch)\b'; then
    echo "Blocked: Readonly agents cannot checkout/switch (use 'git show <ref>:<path>' to read old versions)." >&2
    exit 2
  fi
  if echo "$nq" | grep -qiE '^[[:space:]]*git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+remote[[:space:]]+(set-url|set-branches|set-head|add|remove|rm|rename|prune)\b'; then
    echo "Blocked: Readonly agents cannot modify git remotes." >&2
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
  # Reader tools with an arbitrary-EXEC flag (fd/rg/ag) — see ro_check_raw. These ARE
  # transparent (in RO_SAFE_ARGV), so the anchored path is the live one for them. The command
  # is ANCHORED to segment start (`^…fd`) so the flag tokens as DATA (`grep 'rg --pre' notes`)
  # do NOT false-block — mirrors the git denies' command anchoring. (sort is also anchored.)
  if echo "$nq" | grep -qE '^[[:space:]]*(fd|fdfind)\b' && echo "$nq" | grep -qE '(^|[[:space:]])(-[xX]|--exec)'; then
    echo "Blocked: Readonly agents cannot use fd -x/-X/--exec (runs a command per result)." >&2
    exit 2
  fi
  if echo "$nq" | grep -qE '^[[:space:]]*(rg|ag)\b' && echo "$nq" | grep -qE '(^|[[:space:]])(--pre([[:space:]=]|$)|--pager|--hostname-bin)'; then
    echo "Blocked: Readonly agents cannot use rg/ag --pre/--pager/--hostname-bin (executes a program)." >&2
    exit 2
  fi
  if echo "$nq" | grep -qE '^[[:space:]]*sort\b' && echo "$nq" | grep -qE '(^|[[:space:]])--compress-program'; then
    echo "Blocked: Readonly agents cannot use sort --compress-program (executes a program)." >&2
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

check_allowed() {
  local cmd="$1"
  # Trim leading/trailing whitespace
  cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$cmd" ] && return 0

  # Unwrap ONLY the assignment-capture idiom VAR=$(...) so the inner read verb is
  # allow-checked (e.g. QID=$(gh pr view 5)) — capture stores the inner command's
  # OUTPUT in a variable, it does not execute that output. A BARE $(...)/`...` at
  # COMMAND position is different: bash runs the inner command's OUTPUT as the command,
  # so allow-checking the inner verb would launder arbitrary text into command position
  # (058 re-review HIGH-1 — DROP the bare $(…)/`…` unwrap). Anything with a residual
  # $(/backtick after the capture-unwrap → default-DENY.
  while :; do
    if echo "$cmd" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*=\$\(.*\)$'; then
      cmd=$(echo "$cmd" | sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=\$\((.*)\)$/\1/')
    else
      break
    fi
    cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$cmd" in *'$('*|*'`'*) return 1 ;; esac
  done

  # --- PR triage tools ---
  echo "$cmd" | grep -qE '^\s*pr-buddy\b' && return 0
  echo "$cmd" | grep -qiE '^\s*gh\s+pr\s+(view|diff|checks|list|status)\b' && return 0
  echo "$cmd" | grep -qiE '^\s*gh\s+api\b' && return 0

  # --- git tag: list/inspect allowed; ANY creation/annotation/mutation denied.
  #     Inverted allow — the allow set is EXACTLY git's list-mode-setting flags (which
  #     make git's own only_in_list reject any create flag), plus bare `git tag`. Every
  #     other first token — a positional <tagname> or any non-list flag — is denied.
  #     (destructive -d/-m/-f tag forms are already denied by ro_check_*.) ---
  if echo "$cmd" | grep -qE '^\s*git\s+(-C\s+[^ ;|&]+\s+)?tag\b'; then
    if echo "$cmd" | grep -qE '^\s*git\s+(-C\s+[^ ;|&]+\s+)?tag\s*$' \
       || echo "$cmd" | grep -qE '^\s*git\s+(-C\s+[^ ;|&]+\s+)?tag\s+(-l|--list|-n[0-9]*|--contains|--no-contains|--merged|--no-merged|--points-at)([=[:space:]]|$)'; then
      return 0
    fi
    echo "Blocked: Readonly agents cannot create/modify tags (list/inspect only)." >&2
    return 1
  fi

  # --- Git read operations (checkout/switch denied earlier by ro_check_*; remote-mutate
  #     denied earlier so bare `remote`/`remote -v` list stays; tag handled just above).
  #     Allow an optional `-C <path>` for multi-repo ships. ---
  echo "$cmd" | grep -qE '^\s*git\s+(-C\s+[^ ;|&]+\s+)?(status|diff|log|branch|show|fetch|rev-parse|remote|ls-files|blame|shortlog|describe|stash\s+list)\b' && return 0

  # --- File/directory inspection ---
  echo "$cmd" | grep -qE '^\s*(ls|pwd|wc|file|which|type|stat|du|df|tree|realpath|basename|dirname)\b' && return 0

  # --- File reading ---
  echo "$cmd" | grep -qE '^\s*(cat|head|tail|nl|less|more)\b' && return 0

  # --- Searching ---
  echo "$cmd" | grep -qE '^\s*(find|grep|egrep|fgrep|rg|ag|fd|locate)\b' && return 0

  # --- Checksums / compare (read-only integrity-verification toolkit — no write flags) ---
  echo "$cmd" | grep -qE '^\s*(cmp|shasum|sha256sum|sha1sum|md5sum|cksum)\b' && return 0

  # --- Text processing (read-only — no sed/awk/tee which can write) ---
  echo "$cmd" | grep -qE '^\s*(sort|uniq|tr|cut|jq|yq|column)\b' && return 0

  # --- xargs executes its argument as a command: strip the `xargs` prefix (+ its
  #     options) and allow-check the REAL command, so `... | xargs curl -X POST`
  #     is caught rather than passing on the `xargs` token alone. ---
  if echo "$cmd" | grep -qE '^\s*xargs\b'; then
    local _xrest
    # perl (not `sed -E ':a;…;ta'` — the label-loop form is BSD/macOS-incompatible):
    # strip `xargs` + its options.
    _xrest=$(printf '%s\n' "$cmd" | perl -pe 's/^\s*xargs\s*//; 1 while s{^(-I\s*\S+|-[nPLsEd]\s*\S+|-[0rtxp]+|--[a-z-]+)\s+}{};')
    [ -z "$_xrest" ] && return 0
    check_allowed "$_xrest" && return 0
    return 1
  fi

  # --- Output ---
  echo "$cmd" | grep -qE '^\s*(echo|printf|true|false)\b' && return 0

  # --- Navigation ---
  echo "$cmd" | grep -qE '^\s*cd\b' && return 0

  # --- Process/environment inspection ---
  # NB `env` is deliberately NOT allow-listed: `env <cmd>` is a wrapper that runs an
  # arbitrary (possibly denied) command, laundering interpreters/writers past this
  # read-only gate (Fable 058-readonly HIGH-1: `env python3 …`, `env sh -c …`). `printenv`
  # covers the read use (print the environment).
  echo "$cmd" | grep -qE '^\s*(ps|printenv|id|whoami|hostname|uname|date)\b' && return 0

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
  # [dFTK] must NOT match -f(fail)/-D(dump)/-t/-k(insecure). The method verb is
  # matched case-INSENSITIVELY (curl sends `-X post` verbatim) via char classes,
  # and a quote-stripped copy is scanned so `-X 'DELETE'` can't hide the verb.
  if echo "$cmd" | grep -qE '^\s*curl\b'; then
    local _curlnq
    # Strip backslashes too, not just quotes (Fable 058-readonly re-review HIGH-2): the curl
    # deny lives in check_allowed with its own local strip, so the main-loop deny-normalization
    # doesn't reach it — a `curl \-d`/`curl \-X POST` escaped the mutating-flag match. Monotonic.
    _curlnq=$(printf '%s\n' "$cmd" | tr -d '\\' | tr -d "'\"")
    if echo "$_curlnq" | grep -qE '(^|[[:space:]])-[a-zA-Z0-9#]*[dFTK]|(^|[[:space:]])-[a-zA-Z0-9#]*X[[:space:]=]*([Pp][Oo][Ss][Tt]|[Pp][Uu][Tt]|[Dd][Ee][Ll][Ee][Tt][Ee]|[Pp][Aa][Tt][Cc][Hh])|--data\b|--form\b|--upload-file\b|--json\b|--config\b|--request[[:space:]=]*([Pp][Oo][Ss][Tt]|[Pp][Uu][Tt]|[Dd][Ee][Ll][Ee][Tt][Ee]|[Pp][Aa][Tt][Cc][Hh])'; then
      echo "Blocked: Readonly agents cannot make mutating HTTP requests." >&2
      return 1
    fi
    return 0
  fi

  # --- Hex/binary inspection ---
  echo "$cmd" | grep -qE '^\s*(xxd|hexdump|od|strings)\b' && return 0

  # --- Archive inspection (read-only) ---
  # `tar` is deliberately NOT allow-listed: even in listing mode it exposes arbitrary command
  # execution via -I/--use-compress-program/--checkpoint-action=exec=/--to-command/--rsh-command
  # (a bounded but real exec surface, Fable re-review HIGH-B). Removing it default-denies all of
  # them at once rather than enumerating flags. `unzip -l` / `zipinfo` list archives with no exec.
  echo "$cmd" | grep -qE '^\s*(unzip\s+-l|zipinfo)\b' && return 0

  # NB the v2 reviewer test-runner (ro_test_runner_allowed) is DECLINED — read-only
  # agents execute nothing (test verification is a read; the guarded crew reviewer is
  # the path when execution is genuinely needed). Recorded in DECISIONS.md.

  # Not on allow-list
  return 1
}

# ============================================================
# MAIN: quote-aware split → per-segment deny (anchored for transparent
# segments, raw for everything else) → per-segment allow-list.
# ============================================================
# Pull embedded substitution bodies up to the top level so a default-denied inner verb
# (e.g. `echo $(gh pr merge 5)`, `cat <(rm guard)`) is scanned as its own segment instead
# of hiding behind a benign outer verb. The extractor is QUOTE-AWARE (single quotes suppress
# all substitution, so `awk '{print $(NF)}'` is not extracted) and counts paren DEPTH to find
# the matching `)`. It handles `$(...)`, backticks, `$'…'` ANSI-C literals (escape-aware skip),
# and process substitution `<(...)` / `>(...)` plus zsh `=(...)`. Arithmetic `$(( … ))` is NOT
# skipped — the shell runs $() inside it and reparses `$((cmd))` as `$( (cmd) )`, so its body is
# extracted like any $() (bare `$((expr))` thus fails closed). Bounded fixpoint iteration catches
# deeper NESTED substitution; an UNBALANCED opener → sentinel that fails the whole command CLOSED.
# Hitting the iteration ceiling with bodies still unextracted also fails CLOSED. Bodies appended
# with `;` so the quote-aware splitter re-splits them.
COMMAND_AUG="$COMMAND"
_work="$COMMAND"
_iter=0
while [ "$_iter" -lt 8 ]; do
  _iter=$((_iter + 1))
  _new=$(printf '%s' "$_work" | perl -0777 -ne '
    my $s = $_; my $len = length($s); my $i = 0; my $sq = 0; my $dq = 0;
    while ($i < $len) {
      my $c = substr($s, $i, 1);
      # Quote tracking must match bash: inside SINGLE quotes nothing expands; inside
      # DOUBLE quotes command substitution ($()/backtick) STILL runs but a `\x27` is
      # LITERAL (so `cat "\x27$(rm x)\x27"` executes the subst).
      if ($sq) { $sq = 0 if $c eq "\x27"; $i++; next; }   # in single quotes: literal until close
      if ($c eq "\x27" && !$dq) { $sq = 1; $i++; next; }  # single quote starts sq only when unquoted
      if ($c eq "\x22") { $dq = $dq ? 0 : 1; $i++; next; }# double quote toggles dq
      if ($c eq "\\") { $i += 2; next; }                  # escaped char (unquoted or in dq)
      # $\x27…\x27 ANSI-C quoting is a LITERAL (no substitution inside), but its backslash
      # escapes de-sync a naive single-quote tracker from the shell and let a trailing $() ride
      # unscanned (Fable r4 HIGH-1). Consume it escape-aware; unterminated → fail closed.
      if ($c eq "\$" && substr($s, $i + 1, 1) eq "\x27" && !$dq) {
        my $k = $i + 2;
        while ($k < $len) {
          my $d = substr($s, $k, 1);
          if ($d eq "\\") { $k += 2; next; }
          last if $d eq "\x27";
          $k++;
        }
        if ($k >= $len) { print "__SHIP_SUBST_UNBALANCED__\n"; last; }
        $i = $k + 1; next;
      }
      if ($c eq "`") {
        my $j = index($s, "`", $i + 1);
        if ($j < 0) { print "__SHIP_SUBST_UNBALANCED__\n"; last; }
        my $b = substr($s, $i + 1, $j - $i - 1); $b =~ s/[\r\n]+/ /g;
        print "$b\n" if $b =~ /\S/;
        $i = $j + 1; next;
      }
      # $(…) command substitution. Arithmetic $(( … )) is deliberately NOT skipped: the shell
      # runs $() inside arithmetic and reparses `$((cmd))` as `$( (cmd) )`, so skipping let a
      # writer through (Fable r4 HIGH-2). Extracting the `(…)` body is fail-closed.
      if ($c eq "\$" && substr($s, $i + 1, 1) eq "(") {
        my $depth = 1; my $k = $i + 2;
        while ($k < $len && $depth > 0) {
          my $d = substr($s, $k, 1);
          if ($d eq "(") { $depth++ } elsif ($d eq ")") { $depth-- }
          $k++;
        }
        if ($depth != 0) { print "__SHIP_SUBST_UNBALANCED__\n"; last; }
        my $b = substr($s, $i + 2, $k - $i - 3); $b =~ s/[\r\n]+/ /g;
        print "$b\n" if $b =~ /\S/;
        $i = $k; next;
      }
      # Process substitution: bash `<(…)`/`>(…)` plus zsh `=(…)` (Fable r4 HIGH-4 — the Bash
      # tool executes under zsh on this host). `=(` is only process-sub when the `=` is NOT part
      # of a `name=(…)` array assignment — i.e. it is preceded by a separator/start.
      my $procsub = 0;
      if (!$dq && ($c eq "<" || $c eq ">") && substr($s, $i + 1, 1) eq "(") { $procsub = 1; }
      elsif (!$dq && $c eq "=" && substr($s, $i + 1, 1) eq "(") {
        my $p = $i > 0 ? substr($s, $i - 1, 1) : " ";
        $procsub = 1 if $p =~ /[\s;|&(]/;
      }
      if ($procsub) {
        my $depth = 1; my $k = $i + 2;
        while ($k < $len && $depth > 0) {
          my $d = substr($s, $k, 1);
          if ($d eq "(") { $depth++ } elsif ($d eq ")") { $depth-- }
          $k++;
        }
        if ($depth != 0) { print "__SHIP_SUBST_UNBALANCED__\n"; last; }
        my $b = substr($s, $i + 2, $k - $i - 3); $b =~ s/[\r\n]+/ /g;
        print "$b\n" if $b =~ /\S/;
        $i = $k; next;
      }
      $i++;
    }
  ')
  [ -z "$_new" ] && break
  _work=""
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    if [ "$_line" = "__SHIP_SUBST_UNBALANCED__" ]; then
      echo "Blocked: unbalanced command substitution \$(…)/backtick — cannot extract the inner command to verify it. Failing closed." >&2
      exit 2
    fi
    COMMAND_AUG="$COMMAND_AUG ; $_line"
    _work="$_work"$'\n'"$_line"
  done <<< "$_new"
done
# MED-2 fail-closed: a normal exit breaks with `_new` empty. If the loop instead hit the
# iteration ceiling while the last batch STILL contains an unextracted substitution opener,
# the deepest inner command was never verified → DENY (was silently OPEN at depth >=9).
if [ -n "$_new" ] && printf '%s' "$_new" | grep -qE '\$\(|`|<\(|>\('; then
  echo "Blocked: command-substitution nesting too deep to verify (>8 levels) — failing closed." >&2
  exit 2
fi

if ! SEGMENTS=$(ship_split_segments "$COMMAND_AUG"); then
  SEGMENTS=$(ship_naive_split "$COMMAND_AUG")   # unbalanced quotes → fail-closed fallback
fi
# W2 fix N3: zero segments from BOTH splitters → fail CLOSED, not open.
if [ -z "$(printf '%s' "$SEGMENTS" | tr -d '[:space:]')" ]; then
  SEGMENTS=$(ship_naive_split "$COMMAND_AUG")
fi
if [ -z "$(printf '%s' "$SEGMENTS" | tr -d '[:space:]')" ]; then
  echo "Blocked: command produced no scannable segments (fail closed)." >&2
  exit 2
fi

while IFS= read -r segment; do
  segment=$(echo "$segment" | sed 's/^[[:space:]]*//')
  [ -z "$segment" ] && continue
  # DENY-SIDE NORMALIZATION (Fable re-review HIGH-A): the deny funcs match flags like
  # `[[:space:]]-D` / `-I` which a `\-D` escape or a `'-I'` quote defeats even though the shell
  # runs them as real flags — the anchored path stripped only quotes and the raw path stripped
  # nothing, so `git branch \-D`, `fd . '-x' …`, `find . \-delete` dodged every deny while the
  # allow-list still matched. Strip backslashes AND quotes for the deny-side copy (the same
  # normalization the substrate arming does), for BOTH paths + the bare-interpreter whole scan.
  # Monotonic (adds deny matches only); the ALLOW-list still sees the ORIGINAL segment.
  _seg_deny=$(printf '%s\n' "$segment" | tr -d '\\' | tr -d "'\"")
  # W2 fix B1: a bare interpreter executes whatever the OTHER segments pipe to it — raw-scan
  # the FULL command too. (Interpreters aren't on this allow-list either, so the sink segment
  # also dies on default-deny; this is fail-closed defence-in-depth.)
  if ship_seg_bare_interpreter "$segment"; then
    ro_check_raw "$(printf '%s\n' "$COMMAND" | tr -d '\\' | tr -d "'\"")"
  fi
  if ship_seg_transparent "$segment" "$RO_SAFE_ARGV"; then
    ro_check_anchored "$_seg_deny"
  else
    ro_check_raw "$_seg_deny"
  fi
  # SUBSTRATE redirect deny, PER SEGMENT. Two normalized forms of THIS segment: _seg_norm keeps
  # substitution/param spans (to SEE an obscured $/`/glob target); _seg_del DELETES them so a
  # spliced path rejoins (`core/hooks/$()guard.sh` → `core/hooks/guard.sh`, Fable r6 HIGH-1).
  _seg_base=$(printf '%s\n' "$segment" | tr -d '\\' | tr -d "'\"" | tr '[:upper:]' '[:lower:]')
  _seg_norm=$(ship_pathnorm "$_seg_base")
  _seg_del=$(ship_pathnorm "$(ship_delspans "$_seg_base")")
  # Redirect operator alternation covers bash `>` `>>` `>|` `&>` `&>>` `>&` AND zsh's clobber-
  # override twins `>!` `>>!` `&>!` (Fable r7 HIGH-4 — the Bash tool runs zsh, and `>!` writes).
  # (a) redirect onto a protected BASENAME (literal, quoted, or splice-rejoined) — always deny
  if echo "$_seg_del" | grep -qE '(>>?[!|]?|&>>?[!|]?|>&)[[:space:]]*'"$_SHIP_PATH_PFX$_SHIP_SUBSTRATE_BN"'\b'; then
    echo "Blocked: Readonly agents cannot redirect output onto a security-substrate file (guards, prod guard, agent defs, tripwire, janitor controls) — that overwrites the control that bounds you. Route to a Mate parent-shell." >&2
    exit 2
  fi
  if [ -n "${_SHIP_TOUCHES_SUBSTRATE:-}" ]; then
    # (b) redirect anywhere under a protected TREE, not just a listed basename (Fable r6 HIGH-3:
    #     `> ~/.claude/settings.json` truncates the hook wiring — reader may read, nobody writes).
    if echo "$_seg_del" | grep -qE '(>>?[!|]?|&>>?[!|]?|>&)[[:space:]]*[^[:space:];|&]*'"$_SHIP_SUBSTRATE_TREE"; then
      echo "Blocked: Readonly agents cannot redirect output into a protected substrate tree (~/.claude, core/hooks, core/agents, core/templates, modules/*/hooks) — that can overwrite a guard or the hook wiring. Route to a Mate parent-shell." >&2
      exit 2
    fi
    # (c) redirect onto an obscured target ($/backtick/glob) while armed — a splice/glob could
    #     expand onto a guard (checked pre-deletion so the obscuring char is still visible).
    if echo "$_seg_norm" | grep -qE '(>>?[!|]?|&>>?[!|]?|>&)[[:space:]]*[^[:space:];|&]*([*?[$]|`)'; then
      echo "Blocked: Readonly agents cannot redirect onto a glob/variable/substitution target while a substrate path is referenced — it could expand onto a guard. Name a concrete non-substrate path, or route to a Mate parent-shell." >&2
      exit 2
    fi
  fi
  # SUBSTRATE (B) reader-only enforcement: when the command references a protected
  # substrate name/dir, EVERY segment's effective command word must be a reader.
  # Runs per-segment over the AUGMENTED segments, so a substitution/xargs/process-sub
  # body that resolves to a writer (`echo $(rm guard)`, `x|xargs rm`, `cat <(rm guard)`)
  # is denied here even though the outer verb looked benign.
  if [ -n "${_SHIP_TOUCHES_SUBSTRATE:-}" ]; then
    _rw=$(ship_seg_reader_word "$segment")
    case " $_SHIP_READER_SET " in
      *" $_rw "*) : ;;
      *)
        # git READ subcommands can't write and are the hook's OWN recommended way to read old
        # guard versions (`git show <ref>:<path>`) — treat as reader-equivalent (mutating git
        # forms were already denied above). BUT `git diff|show|log --output=<file>` WRITES
        # (truncates to 0 bytes even with no diff) — exclude any `-o`/`--output` token.
        if [ "$_rw" = git ] \
           && echo "$segment" | grep -qiE '^[[:space:]]*git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+(show|diff|log|blame|ls-files|cat-file|rev-parse|describe|shortlog|status)\b' \
           && ! echo "$segment" | grep -qiE '(^|[[:space:]])--output([[:space:]=]|$)'; then
          : ;
        elif [ -n "$_rw" ]; then
          echo "Blocked: security-substrate files (bash guards, prod guard, agent defs, tripwire, janitor controls) are READ-ONLY for readonly agents — '$_rw' is not a permitted reader. Route writes to a Mate parent-shell." >&2
          exit 2
        fi
        ;;
    esac
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
