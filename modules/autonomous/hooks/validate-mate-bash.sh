#!/bin/bash
# Ship MATE agent bright-line bash hook (PreToolUse, matcher "Bash").
# For the ship-mate agent — interactive (`--agent ship-mate`) or standalone `--bg`.
#
# Philosophy: the Mate does a HUGE range of legitimate work (arbitrary ship-repo
# edits, git commit + feature-branch push, scripts, ruby/python/node, crew dispatch,
# status writes). So this is a DEFAULT-ALLOW DENY-LIST — the opposite of the Bosun /
# crew allow-lists. It makes the autonomy bright lines STRUCTURAL: an autonomous Mate
# is blocked from the union of the "never" tier (merge / comment / review / approve,
# chat posts, prod writes) AND the "confirm-first" tier (deploys, tracker writes,
# mark-ready) — because a headless/bg Mate can't get confirmation in-band. It SURFACES
# those (drop / queue / Awaiting-Captain); it never executes them autonomously.
# Everything else passes.
#
# PATTERN ANCHORING (SHIP-HOOK-PATTERN-ANCHORING): deny patterns are matched
# per COMMAND SEGMENT (quote-aware split on && || | ;) and — for segments whose
# invoked command is a known data-arg binary (git, gh, echo, grep, …) — anchored to
# the COMMAND POSITION. So `git commit -m "gh pr edit …"` (prose about the rule) or
# `Main.scala` in a push-adjacent segment no longer false-block. Segments invoking
# wrappers/interpreters (sh -c, xargs, env-prefixes, $(…)/backticks, unknown
# commands) keep the ORIGINAL raw substring scan — every wrapper-smuggled true
# positive still blocks. Fail-closed: unbalanced quotes fall back to the naive
# splitter (strictly more fragments → over-block).
#
# W2 (max-scrutiny review fixes): backslash-newline continuations are collapsed
# BEFORE scanning (a split `git push origin \`⏎`main` rejoins — B2); the
# NEVER-VARY ops (gh pr merge/ready/review/approve/close, force-push /
# push-to-main, deploys, prod writes) ALSO get a raw WHOLE-COMMAND deny
# pre-pass, because the Mate is default-allow with no allow-list net under the
# segment pass (`echo 'gh pr merge 5' | bash` used to slip — B1). Accepted
# trade: prose mentioning those exact ops re-blocks on the Mate (documented in
# the W2 log; crew/readonly/bosun keep pure anchoring + their default-deny
# net). A bare-interpreter segment (`… | bash`) additionally triggers a raw
# scan of the whole command; $'…' quoting forces the raw scan (N2); zero
# segments fail CLOSED (N3); gh api guard also catches --method= and
# implicit-POST field flags (N1).
#
# CHMOD +x IS LOAD-BEARING: a non-exec hook fails OPEN (silent zero enforcement). The
# launcher (ship-up.sh) self-heals the bit; if you install hooks by hand, chmod +x them.
#
# Activation: self-scopes on the PreToolUse payload's agent_type == "ship-mate" (read
# from stdin JSON) — NOT an env var, which is what makes it fire in a --bg session (a
# bg session doesn't inherit launch env). Any other agent / plain session passes through.
#
# HONEST LIMITATION: a deny-list guards against the model's own over-eager mistakes,
# not an adversary — exotic evasions (eval / bash -c wrapping, string tricks) can slip
# direct patterns. Run the agent in a sandbox + a minimal MCP config for defense-in-depth.

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
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')
[ "$AGENT_TYPE" != "ship-mate" ] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$COMMAND" ] && exit 0

blk() { echo "Blocked (Mate bright line): $1 Surface it (drop/queue) or do it from an attached/Captain session." >&2; exit 2; }

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

# Strip quote CHARACTERS and BACKSLASHES (not content) — deny-side only. Removing
# either can only ADD deny matches, never hide an invocation — with ONE exception:
# a NEGATED condition inverts that. validate-mate-bash.sh's `gh pr create` gate
# requires --draft to be PRESENT, so `gh pr create --title x \--draft` now matches
# (correctly — bash runs it as --draft) where it previously did not, turning a block
# into an allow. Semantically right, but the invariant above is not absolute.
# BACKSLASHES ARE LOAD-BEARING HERE (reported from a v2 fork, 2026-08): bash collapses
# `\m` to `m` at exec time, so `gh pr \merge` RUNS as `gh pr merge` while an anchored
# scan of the literal text matches nothing. The scan must see what bash will execute.
# On this hook that was a REAL BYPASS, not a message nit: the Mate is default-ALLOW
# with no allow-list underneath, so an unmatched deny pattern means the op executes.
ship_strip_quote_chars() {
  printf '%s\n' "$1" | tr -d "'\"" | tr -d '\\'
}
# ========================================================== end SHIP-MATCH-LIB

# Data-arg binaries: their arguments are data, not commands, so quoted trigger
# tokens in their args are prose/paths — anchored checks apply. Deliberately
# EXCLUDES every interpreter/wrapper (sh bash env xargs eval find sed awk
# python ruby node perl …) — those stay raw-scanned.
MATE_SAFE_ARGV=" git gh echo printf cat ls grep rg head tail wc jq sort uniq cut tr diff qmd pr-buddy true false which type stat file basename dirname realpath "

# Matches when the segment's INVOKED command is `git … push` (skipping git options
# like -C <path> / -c k=v / --git-dir=…). Used on the quote-char-stripped segment.
GIT_PUSH_INVOKED='^[[:space:]]*git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+push\b'

# ============================================================
# PUSH-TO-MAIN CARVE-OUT SEAM (per-deployment; default = NO carve-out).
# ============================================================
# Some ships have exactly one repo where an autonomous push to main is legitimate
# (e.g. a Mate-published docs/artifacts repo with no PR flow). The safe shape for
# that exception — proven on a live ship — is an EXPLICIT-URL form: the push is
# allowed ONLY when the remote is spelled out as the full URL of that one repo,
# directly after `push`. No remote-NAME form (`origin` means different repos in
# different cwds), no cwd inference — the command itself must name the repo, so
# the allowed surface is exactly one string shape.
#
# Rules the seam preserves (do not weaken when populating):
#   - FORCE-PUSH stays blocked UNCONDITIONALLY — the force checks run before the
#     ref checks at every deny site, and this helper is only consulted for the
#     push-to-main/master denies.
#   - Set the regex to match `push <explicit-URL-of-YOUR-repo>` ONLY. Escape dots;
#     anchor the tail (`(\.git)?([[:space:]]|$)`) so `your-repo-evil` can't ride.
#   - The never-vary pre-pass consults the carve-out on WHOLE-command text, which
#     is over-permissive across segments by construction. Safety comes from TWO
#     properties together: (1) the anchored per-SEGMENT checks block a non-carve-out
#     push in any directly-invoked sibling segment, and (2) the RAW scans
#     (interpreter-sink whole-commands + opaque segments) never consult the
#     carve-out at all — so a push smuggled as data into an interpreter is blocked
#     even when a carved URL appears elsewhere in the command. Both are covered by
#     the test suite (sibling-segment smuggle + interpreter-sink smuggle).
#   - Add live-fire tests when you populate this (see test-mate-bash.sh, the
#     carve-out section): the allowed exact form, the evil-suffix repo, the
#     force-push forms, and the sibling-segment smuggle must all keep their verdicts.
#
# Example (commented — adapt org/repo):
#   MATE_PUSH_MAIN_CARVEOUT='\bpush[[:space:]]+(git@github\.com:|https://github\.com/)YourOrg/your-publish-repo(\.git)?([[:space:]]|$)'
MATE_PUSH_MAIN_CARVEOUT=''
mate_push_main_carveout() {
  [ -n "$MATE_PUSH_MAIN_CARVEOUT" ] || return 1
  echo "$1" | grep -qE "$MATE_PUSH_MAIN_CARVEOUT"
}

# ------------------------------------------------------------------
# RAW checks — the ORIGINAL substring patterns, applied to one segment.
# Used for opaque segments (wrappers/interpreters/substitutions/unknowns) so no
# currently-blocked smuggle is relaxed.
# ------------------------------------------------------------------
mate_check_raw() {
  local seg="$1"
  # --- GitHub: PR mutations (Mate opens DRAFT PRs only; never merge/ready/comment/review/approve) ---
  if echo "$seg" | grep -qiE '\bgh\s+pr\s+(merge|ready|comment|review|approve|close|edit|reopen|lock|unlock|delete)\b'; then
    blk "no gh pr merge/ready/comment/review/approve/close/edit (Captain merges; mark-ready is Captain's)."
  fi
  # gh pr create is allowed ONLY with --draft.
  if echo "$seg" | grep -qiE '\bgh\s+pr\s+create\b' && ! echo "$seg" | grep -qiE '(^|\s)(--draft|-d)\b'; then
    blk "gh pr create is draft-only for the Mate — add --draft (marking ready is Captain's)."
  fi
  # --- GitHub: issue / repo / release / workflow / secret / auth / gist writes ---
  if echo "$seg" | grep -qiE '\bgh\s+issue\s+(create|comment|close|edit|reopen|lock|unlock|delete|pin|unpin|transfer)\b'; then
    blk "no gh issue writes."
  fi
  if echo "$seg" | grep -qiE '\bgh\s+repo\s+(create|delete|fork|archive|unarchive|edit|rename|sync)\b'; then
    blk "no gh repo-level writes."
  fi
  if echo "$seg" | grep -qiE '\bgh\s+(release|workflow\s+(run|enable|disable)|secret|ssh-key|gpg-key|auth\s+(login|logout|refresh|setup-git)|gist\s+(create|delete|edit))\b'; then
    blk "no gh release/workflow-run/secret/auth/gist writes."
  fi
  # --- GitHub: mutating API (W2 fix N1: also the --method= form, and the
  #     implicit-POST field/body flags — gh api with -f/--field/-F/--raw-field/
  #     --input mutates WITHOUT any -X; reads take no fields) ---
  # W4: short -f/-F denied with ANY trailing char (pflag ATTACHED shorthand:
  # -ftitle=hi == -f title=hi bypassed the delimiter-requiring regex), and -i*
  # cluster prefixes (-iftitle=x, -iXPOST): -i/--include is gh api's ONLY boolean
  # shorthand; every other shorthand consumes the cluster remainder as its value.
  # Long forms keep their delimiter (pflag has no long-flag abbreviation, and
  # --fieldish-style names must not over-block).
  if echo "$seg" | grep -qiE '\bgh\s+api\b'; then
    if echo "$seg" | grep -qiE '\s(-i*X|--method)[[:space:]=]*(POST|PUT|DELETE|PATCH)\b'; then
      blk "no mutating gh api calls."
    fi
    if echo "$seg" | grep -qE '(^|[[:space:]])((--field|--raw-field|--input)([[:space:]=]|$)|-i*[fF])'; then
      blk "no gh api field/body flags (implicit POST — reads take no fields)."
    fi
  fi
  # --- Deploys (generic infra-deploy verbs) ---
  if echo "$seg" | grep -qiE '(\bserverless\s+deploy\b|\bterraform\s+(apply|destroy)\b|\bkubectl\s+(apply|delete|edit|scale|patch|replace|rollout)\b|\bhelm\s+(install|upgrade|uninstall)\b)'; then
    blk "no deploys (deploys are Captain-authorized, never autonomous)."
  fi
  # --- Git: force-push, and push to main/master ---
  if echo "$seg" | grep -qiE '\bgit\s+push\b' && echo "$seg" | grep -qiE '(\s--force\b|\s-f\b|\s\+[A-Za-z])'; then
    blk "no force-push."
  fi
  if echo "$seg" | grep -qiE '\bgit\s+push\b' && echo "$seg" | grep -qiE '(\bmain\b|\bmaster\b|HEAD:(main|master))'; then
    # NO carve-out consult on raw scans (gate finding, 2026-07-14): raw runs on
    # interpreter-sink whole-commands and opaque segments -- a carve-out match
    # anywhere in that text would bleed permission onto DATA flowing into an
    # interpreter. Carve-out is honored ONLY on the anchored (direct-invocation)
    # path and the pre-pass; legit carve-out pushes are direct invocations.
    blk "no push to main/master (carve-out is direct-invocation only)."
  fi
  mate_check_deployment "$seg"
}

# ------------------------------------------------------------------
# ANCHORED checks — the op must be the segment's INVOKED command.
# $1 = segment with quote CHARS stripped (never hides an invocation; surfaces
# quoted refs like push origin "main").
# ------------------------------------------------------------------
mate_check_anchored() {
  local nq="$1"
  # --- GitHub: PR mutations ---
  if echo "$nq" | grep -qiE '^[[:space:]]*gh[[:space:]]+pr[[:space:]]+(merge|ready|comment|review|approve|close|edit|reopen|lock|unlock|delete)\b'; then
    blk "no gh pr merge/ready/comment/review/approve/close/edit (Captain merges; mark-ready is Captain's)."
  fi
  # gh pr create draft-only — --draft must be on the CREATE segment itself.
  if echo "$nq" | grep -qiE '^[[:space:]]*gh[[:space:]]+pr[[:space:]]+create\b' && ! echo "$nq" | grep -qiE '(^|\s)(--draft|-d)\b'; then
    blk "gh pr create is draft-only for the Mate — add --draft (marking ready is Captain's)."
  fi
  # --- GitHub: issue / repo / release / workflow / secret / auth / gist writes ---
  if echo "$nq" | grep -qiE '^[[:space:]]*gh[[:space:]]+issue[[:space:]]+(create|comment|close|edit|reopen|lock|unlock|delete|pin|unpin|transfer)\b'; then
    blk "no gh issue writes."
  fi
  if echo "$nq" | grep -qiE '^[[:space:]]*gh[[:space:]]+repo[[:space:]]+(create|delete|fork|archive|unarchive|edit|rename|sync)\b'; then
    blk "no gh repo-level writes."
  fi
  if echo "$nq" | grep -qiE '^[[:space:]]*gh[[:space:]]+(release|workflow[[:space:]]+(run|enable|disable)|secret|ssh-key|gpg-key|auth[[:space:]]+(login|logout|refresh|setup-git)|gist[[:space:]]+(create|delete|edit))\b'; then
    blk "no gh release/workflow-run/secret/auth/gist writes."
  fi
  # --- GitHub: mutating API (method/field flags must be on the gh api segment;
  #     W2 fix N1: also --method= and implicit-POST field/body flags;
  #     W4: attached/clustered shorthands — see mate_check_raw) ---
  if echo "$nq" | grep -qiE '^[[:space:]]*gh[[:space:]]+api\b'; then
    if echo "$nq" | grep -qiE '\s(-i*X|--method)[[:space:]=]*(POST|PUT|DELETE|PATCH)\b'; then
      blk "no mutating gh api calls."
    fi
    if echo "$nq" | grep -qE '(^|[[:space:]])((--field|--raw-field|--input)([[:space:]=]|$)|-i*[fF])'; then
      blk "no gh api field/body flags (implicit POST — reads take no fields)."
    fi
  fi
  # --- Deploys ---
  if echo "$nq" | grep -qiE '^[[:space:]]*(serverless[[:space:]]+deploy|terraform[[:space:]]+(apply|destroy)|kubectl[[:space:]]+(apply|delete|edit|scale|patch|replace|rollout)|helm[[:space:]]+(install|upgrade|uninstall))\b'; then
    blk "no deploys (deploys are Captain-authorized, never autonomous)."
  fi
  # --- Git push: force / main-master, checked ONLY on push-invoking segments,
  #     so `+` or `main` in a sibling commit-message segment can't false-trip.
  #     Ref match is case-SENSITIVE + boundary-anchored (Main.scala is not main). ---
  if echo "$nq" | grep -qiE "$GIT_PUSH_INVOKED"; then
    if echo "$nq" | grep -qiE '(\s--force(-with-lease)?\b|\s-f\b|\s\+[A-Za-z])'; then
      blk "no force-push."
    fi
    if echo "$nq" | grep -qE '((^|[[:space:]]|:)(main|master)([[:space:]]|$)|refs/heads/(main|master)\b)'; then
      mate_push_main_carveout "$nq" || blk "no push to main/master."
    fi
  fi
  mate_check_deployment "$nq"
}

# ============================================================
# PER-DEPLOYMENT OVERRIDE — edit/extend for YOUR external systems.
# ============================================================
# A fresh Ship has different surfaces (a different chat tool, a different tracker, a
# different deploy command, a different cloud). The bright-line PRINCIPLE is fixed
# (never autonomously merge / post externally / deploy / write prod); the SURFACES are
# configuration. Add your own deny patterns here — $1 is ONE command segment (raw for
# opaque segments, quote-char-stripped for anchored ones), so pattern-pair checks
# (URL + mutating method) stay within a single invocation. Since W2, this is ALSO
# called once with the WHOLE quote-stripped command (never-vary pre-pass) — there a
# pattern-pair may over-match across segments, which is fail-closed and accepted for
# prod-write bright lines. Examples (commented — uncomment + adapt the ones you run):
mate_check_deployment() {
  local seg="$1"
  :
  #   # Chat: block posts/webhooks on your chat tool.
  #   if echo "$seg" | grep -qiE 'hooks\.slack\.com|slack\.com/api/(chat\.postMessage|reactions\.add|chat\.update)'; then
  #     blk "no chat posts/reactions."
  #   fi
  #   # Tracker: block your issue-tracker write helpers + mutating tracker API.
  #   if echo "$seg" | grep -qiE 'jira_(issue_manager|link_updater)\.sh\b'; then
  #     blk "no tracker writes — reconcile is confirm-first; surface for the Captain."
  #   fi
  #   if echo "$seg" | grep -qiE 'atlassian\.net' && echo "$seg" | grep -qiE '\s(-X|--request)\s*(POST|PUT|DELETE|PATCH)\b'; then
  #     blk "no mutating tracker API calls."
  #   fi
  #   # Your deploy command(s).
  #   if echo "$seg" | grep -qiE '(\bscript/release\b|\bbin/deploy\b|\bcap\s+\S*\s*deploy\b)'; then
  #     blk "no deploys."
  #   fi
  #   # Cloud prod writes (run commands on hosts / mutate infra).
  #   if echo "$seg" | grep -qiE '\baws\s+ssm\s+send-command\b'; then
  #     blk "no aws ssm send-command (runs commands on prod hosts)."
  #   fi
  #   if echo "$seg" | grep -qiE '\baws\s+(lambda\s+(update-function|invoke)|ecs\s+update-service|rds\s+(modify|reboot|delete)|s3\s+(rb)|elasticache\s+)'; then
  #     blk "no mutating cloud infra commands."
  #   fi
}
# ------------------------------------------------------------

# ============================================================
# MAIN: collapse continuations → whole-command NEVER-VARY pre-pass →
# split → per-segment deny checks (anchored for transparent
# segments, raw for everything else).
# ============================================================

# Rejoin backslash-newline continuations FIRST (W2 fix B2) — every check below
# must see the command the shell will actually run.
COMMAND=$(ship_collapse_continuations "$COMMAND")

# ---------------------------------------------------------------------------
# WHOLE-COMMAND NEVER-VARY PRE-PASS (W2, reviewer-endorsed belt-and-suspenders).
# The segment pass below is precise, but the Mate is DEFAULT-ALLOW — there is
# no allow-list net under it, so a payload smuggled as DATA into an executing
# sink (`echo 'gh pr merge 5' | bash`) used to sail through on textually-clean
# segments (B1). For the NEVER-VARY ops only, re-run the raw whole-command deny
# on the quote-char-stripped command BEFORE segmentation — in ADDITION to the
# segment pass. ACCEPTED TRADE (documented in the W2 log + tests): prose that
# merely MENTIONS these ops (a commit message containing "gh pr merge" or
# "terraform apply", a space-bounded "main" anywhere in a push-bearing command)
# re-blocks on the Mate. That costs a surfaced workaround, never a capability.
# The confirm-tier ops (gh pr comment/edit, issue writes, gh api) stay
# segment-scoped — they were the chief commit-message FP source; their
# pipe-into-interpreter vector is covered by the bare-interpreter whole-command
# raw scan in the segment loop below. Crew/readonly/bosun do NOT get a
# pre-pass: their default-DENY allow-lists already net orphan fragments
# (proven by their test suites).
# ---------------------------------------------------------------------------
PRE=$(ship_strip_quote_chars "$COMMAND")
if echo "$PRE" | grep -qiE '\bgh\s+pr\s+(merge|ready|review|approve|close)\b'; then
  blk "never-vary op anywhere in command: gh pr merge/ready/review/approve/close (Captain's)."
fi
if echo "$PRE" | grep -qiE '\bgit\s+push\b'; then
  if echo "$PRE" | grep -qiE '(\s--force\b|\s-f\b|\s\+[A-Za-z])'; then
    blk "never-vary op anywhere in command: force-push."
  fi
  # Ref match keeps the 06-30 sharpening (case-SENSITIVE, boundary-anchored):
  # every real to-main form still matches on quote-stripped text; Main.scala /
  # feature/main-menu do not — those W1 FP fixes survive the pre-pass.
  if echo "$PRE" | grep -qE '((^|[[:space:]]|:)(main|master)([[:space:]]|$)|refs/heads/(main|master)\b)'; then
    # The carve-out at the pre-pass is over-permissive across segments by
    # construction (whole-command text); safe because the anchored per-segment
    # checks block direct sibling pushes AND the raw scans (interpreter sinks,
    # opaque segments) never consult the carve-out (see helper doc).
    mate_push_main_carveout "$PRE" || blk "never-vary op anywhere in command: push touching main/master."
  fi
fi
if echo "$PRE" | grep -qiE '(\bserverless\s+deploy\b|\bterraform\s+(apply|destroy)\b|\bkubectl\s+(apply|delete|edit|scale|patch|replace|rollout)\b|\bhelm\s+(install|upgrade|uninstall)\b)'; then
  blk "never-vary op anywhere in command: deploy/infra-mutate."
fi
# Prod-write patterns from the per-deployment override are never-vary too.
mate_check_deployment "$PRE"
# ------------------------------------------------------------- end pre-pass

if ! SEGMENTS=$(ship_split_segments "$COMMAND"); then
  SEGMENTS=$(ship_naive_split "$COMMAND")   # unbalanced quotes → fail-closed fallback
fi
# W2 fix N3: zero segments from BOTH splitters → fail CLOSED, not open.
if [ -z "$(printf '%s' "$SEGMENTS" | tr -d '[:space:]')" ]; then
  SEGMENTS=$(ship_naive_split "$COMMAND")
fi
if [ -z "$(printf '%s' "$SEGMENTS" | tr -d '[:space:]')" ]; then
  blk "command produced no scannable segments (fail closed)."
fi

while IFS= read -r SEG; do
  SEG_TRIM=$(printf '%s' "$SEG" | tr -d '[:space:]')
  [ -z "$SEG_TRIM" ] && continue
  # W2 fix B1 (defense-in-depth under the pre-pass): a bare interpreter executes
  # whatever the OTHER segments pipe to it — the payload rides as DATA in the
  # producing segments, so raw-scan the FULL command with the complete deny set
  # (confirm-tier included), not just the never-vary pre-pass set.
  if ship_seg_bare_interpreter "$SEG"; then
    mate_check_raw "$COMMAND"
  fi
  if ship_seg_transparent "$SEG" "$MATE_SAFE_ARGV"; then
    mate_check_anchored "$(ship_strip_quote_chars "$SEG")"
  else
    mate_check_raw "$SEG"
  fi
done <<EOF_SEGMENTS
$SEGMENTS
EOF_SEGMENTS

# Default ALLOW — the Mate's broad legitimate surface (edits, commit, feature-branch
# push, scripts, ruby/python/node, gh reads, crew dispatch, status writes).
exit 0
