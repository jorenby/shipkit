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

INPUT=$(cat)
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')
[ "$AGENT_TYPE" != "ship-mate" ] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$COMMAND" ] && exit 0

blk() { echo "Blocked (Mate bright line): $1 Surface it (drop/queue) or do it from an attached/Captain session." >&2; exit 2; }

# ============================================================
# GENERIC BRIGHT-LINE CORE — holds for ANY deployment.
# ============================================================

# --- GitHub: PR mutations (Mate opens DRAFT PRs only; never merge/ready/comment/review/approve) ---
if echo "$COMMAND" | grep -qiE '\bgh\s+pr\s+(merge|ready|comment|review|approve|close|edit|reopen|lock|unlock|delete)\b'; then
  blk "no gh pr merge/ready/comment/review/approve/close/edit (Captain merges; mark-ready is Captain's)."
fi
# gh pr create is allowed ONLY with --draft.
if echo "$COMMAND" | grep -qiE '\bgh\s+pr\s+create\b' && ! echo "$COMMAND" | grep -qiE '(^|\s)(--draft|-d)\b'; then
  blk "gh pr create is draft-only for the Mate — add --draft (marking ready is Captain's)."
fi
# --- GitHub: issue / repo / release / workflow / secret / auth / gist writes ---
if echo "$COMMAND" | grep -qiE '\bgh\s+issue\s+(create|comment|close|edit|reopen|lock|unlock|delete|pin|unpin|transfer)\b'; then
  blk "no gh issue writes."
fi
if echo "$COMMAND" | grep -qiE '\bgh\s+repo\s+(create|delete|fork|archive|unarchive|edit|rename|sync)\b'; then
  blk "no gh repo-level writes."
fi
if echo "$COMMAND" | grep -qiE '\bgh\s+(release|workflow\s+(run|enable|disable)|secret|ssh-key|gpg-key|auth\s+(login|logout|refresh|setup-git)|gist\s+(create|delete|edit))\b'; then
  blk "no gh release/workflow-run/secret/auth/gist writes."
fi
# --- GitHub: mutating API ---
if echo "$COMMAND" | grep -qiE '\bgh\s+api\b' && echo "$COMMAND" | grep -qiE '\s(-X|--method)\s*(POST|PUT|DELETE|PATCH)\b'; then
  blk "no mutating gh api calls."
fi

# --- Deploys (generic infra-deploy verbs) ---
if echo "$COMMAND" | grep -qiE '(\bserverless\s+deploy\b|\bterraform\s+(apply|destroy)\b|\bkubectl\s+(apply|delete|edit|scale|patch|replace|rollout)\b|\bhelm\s+(install|upgrade|uninstall)\b)'; then
  blk "no deploys (deploys are Captain-authorized, never autonomous)."
fi

# --- Git: force-push, and push to main/master (feature-branch pushes + commits are fine) ---
if echo "$COMMAND" | grep -qiE '\bgit\s+push\b' && echo "$COMMAND" | grep -qiE '(\s--force\b|\s-f\b|\s\+[A-Za-z])'; then
  blk "no force-push."
fi
if echo "$COMMAND" | grep -qiE '\bgit\s+push\b' && echo "$COMMAND" | grep -qiE '(\bmain\b|\bmaster\b|HEAD:(main|master))'; then
  blk "no push to main/master."
fi

# ============================================================
# PER-DEPLOYMENT OVERRIDE — edit/extend for YOUR external systems.
# ============================================================
# A fresh Ship has different surfaces (a different chat tool, a different tracker, a
# different deploy command, a different cloud). The bright-line PRINCIPLE is fixed
# (never autonomously merge / post externally / deploy / write prod); the SURFACES are
# configuration. Add your own deny patterns here. Examples (commented — uncomment +
# adapt the ones you run):
#
#   # Chat: block posts/webhooks on your chat tool.
#   if echo "$COMMAND" | grep -qiE 'hooks\.slack\.com|slack\.com/api/(chat\.postMessage|reactions\.add|chat\.update)'; then
#     blk "no chat posts/reactions."
#   fi
#   # Tracker: block your issue-tracker write helpers + mutating tracker API.
#   if echo "$COMMAND" | grep -qiE 'jira_(issue_manager|link_updater)\.sh\b'; then
#     blk "no tracker writes — reconcile is confirm-first; surface for the Captain."
#   fi
#   if echo "$COMMAND" | grep -qiE 'atlassian\.net' && echo "$COMMAND" | grep -qiE '\s(-X|--request)\s*(POST|PUT|DELETE|PATCH)\b'; then
#     blk "no mutating tracker API calls."
#   fi
#   # Your deploy command(s).
#   if echo "$COMMAND" | grep -qiE '(\bscript/release\b|\bbin/deploy\b|\bcap\s+\S*\s*deploy\b)'; then
#     blk "no deploys."
#   fi
#   # Cloud prod writes (run commands on hosts / mutate infra).
#   if echo "$COMMAND" | grep -qiE '\baws\s+ssm\s+send-command\b'; then
#     blk "no aws ssm send-command (runs commands on prod hosts)."
#   fi
#   if echo "$COMMAND" | grep -qiE '\baws\s+(lambda\s+(update-function|invoke)|ecs\s+update-service|rds\s+(modify|reboot|delete)|s3\s+(rb)|elasticache\s+)'; then
#     blk "no mutating cloud infra commands."
#   fi
# ------------------------------------------------------------

# Default ALLOW — the Mate's broad legitimate surface (edits, commit, feature-branch
# push, scripts, ruby/python/node, gh reads, crew dispatch, status writes).
exit 0
