# Module: PR Tools

**Optional. For operators who work in product repos through PRs.** Two skills that sit
next to the `pull-requests` module's doctrine:

- **`git-town-stack`**: set up, sync and propose stacked PRs with
  [git-town](https://www.git-town.com/) (`set-parent`, `append`, `sync --stack`,
  `propose --stack`), plus the conflict-resolution moves a stack needs.
- **`pr-sync`**: reconcile an open PR's title and body with what its branch now contains,
  then apply one `gh pr edit` after an explicit go. Read-only until that confirm.

Both are Captain/Mate-seat tools. They push, edit PRs, or rebase, which the crew Bash
guard blocks, so a crew can read them but not run their write steps.

## Prerequisites

- `gh`, authenticated to the PR host.
- `git-town` for `git-town-stack` (`brew install git-town`).

## Install

Opt-in: `python3 shipkit_init.py --modules pr-tools` (or the `personal` preset). The
installer links both skill dirs into `~/.claude/skills/`.
