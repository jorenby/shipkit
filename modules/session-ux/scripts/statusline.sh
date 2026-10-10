#!/bin/sh
# Claude Code status line: user@host:dir (branch) | model | ctx NN% | track | pending drops | ship role.

input=$(cat)

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SHIP_ROOT="${SHIP_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

tab=$(printf '\t')
IFS="$tab" read -r current_dir model ctx_pct wt_branch <<EOF
$(printf '%s' "$input" | jq -r '[
  .workspace.current_dir, .model.display_name,
  (.context_window.used_percentage // ""),
  (.worktree.branch // "")
] | @tsv')
EOF

printf "\033[36m%s@%s\033[0m:\033[34m%s\033[0m" "$(whoami)" "$(hostname -s)" "$(basename "$current_dir")"

branch="$wt_branch"
if [ -z "$branch" ] && git -C "$current_dir" rev-parse --git-dir >/dev/null 2>&1; then
  branch=$(git -C "$current_dir" --no-optional-locks branch --show-current 2>/dev/null || echo detached)
fi
[ -n "$branch" ] && printf " \033[33m(%s)\033[0m" "$branch"

printf " │ \033[90m%s\033[0m" "$model"

if [ -n "$ctx_pct" ]; then
  pct_int=$(printf '%.0f' "$ctx_pct")
  if   [ "$pct_int" -ge 85 ]; then c="\033[1;91m"
  elif [ "$pct_int" -ge 60 ]; then c="\033[33m"
  else c="\033[32m"; fi
  printf " │ ${c}ctx %s%%\033[0m" "$pct_int"
fi

# SHIP_STATUSLINE_TRACKS="glob=TAG;glob=TAG", first match wins, e.g. "*api-service*=API;*ship*=ship".
track=""
old_ifs=$IFS
IFS=';'
set -f
for pair in ${SHIP_STATUSLINE_TRACKS:-}; do
  pattern=${pair%%=*}
  tag=${pair#*=}
  [ -z "$pattern" ] && continue
  # shellcheck disable=SC2254
  case "$current_dir" in $pattern) track="$tag"; break ;; esac
done
set +f
IFS=$old_ifs
[ -n "$track" ] && printf " │ \033[90m%s\033[0m" "$track"

drops_dir="$SHIP_ROOT/inbox/drops"
if [ -d "$drops_dir" ]; then
  set -- "$drops_dir"/*.md
  [ -e "$1" ] && printf " │ \033[35m◈%s\033[0m" "$#"
fi

role=""
session_role_file="$HOME/.claude/ship-roles/$CLAUDE_CODE_SESSION_ID"
if [ -n "$CLAUDE_CODE_SESSION_ID" ] && [ -f "$session_role_file" ]; then
  role=$(tr -d '[:space:]' < "$session_role_file")
fi
if [ -n "$role" ]; then
  case "$role" in
    Navigator*) rc="\033[1;97;45m" ;;
    Mate*)      rc="\033[1;30;46m" ;;
    Crew*)      rc="\033[1;30;43m" ;;
    Captain*)   rc="\033[1;97;41m" ;;
    *)          rc="\033[1;97;45m" ;;
  esac
  printf " │ ${rc} %s \033[0m" "$role"
fi
