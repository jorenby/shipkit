---
name: git-town-stack
description: Set up and manage stacked PRs using git-town. Use when the user wants to stack branches, set parent lineage, sync with main, or propose stacked PRs.
argument-hint: [action: stack|sync|propose|status]
disable-model-invocation: false
allowed-tools: Bash, Read, Grep, Glob
---

# git-town Stacked PRs

Manage stacked branches and PRs using git-town. Action: `$ARGUMENTS`

## Quick Reference

### Set up a stack (lineage)
For each branch bottom-to-top, checkout and set its parent:
```bash
git checkout <branch>
git town set-parent <parent-branch>
```
git-town will rebase the branch onto its parent and push.

### Sync the entire stack
```bash
git town sync --stack
```

### Propose (create PRs) for the stack
```bash
git town propose --stack
```
Or for a single branch:
```bash
git town propose --title "Title" --body "Body"
```

### View lineage
```bash
git town config
```
Look for the "Branch Lineage" section.

## Conflict Resolution During Stacking

When `git town set-parent` or `git town sync` hits a rebase conflict:

1. **Already-applied commits**: If the conflict is from a commit that's already in the parent branch (common when branches shared history before stacking), use `git rebase --skip`
2. **Real conflicts**: Resolve manually, `git add` the files, then `git rebase --continue`
3. After resolving: `git town continue` to let git-town finish (it will push)

## Common Workflow: Create a New Stacked Branch

Use `git town append` (NOT `git town hack` — that always branches from main):
```bash
git checkout <parent-branch>
git town append <new-branch>
```
This creates the new branch as a child of the current branch with lineage already set.

## Common Workflow: Stack Existing Branches

When you have branches A, B, C that should stack on main:
```bash
# 1. Force-push any amended branches first to avoid divergence errors
git push --force-with-lease origin <branch>

# 2. Set up lineage bottom-to-top
git checkout A && git town set-parent main
git checkout B && git town set-parent A
git checkout C && git town set-parent B

# 3. Create PRs for the whole stack
git checkout C && git town propose --stack
```

## Common Workflow: Amend a Commit in the Stack

When you need to amend a commit that's in a parent branch:
```bash
# 1. Checkout the branch, make changes, amend
git checkout <branch>
git add <files>
git commit --amend --no-edit

# 2. Force-push the amended branch
git push --force-with-lease origin <branch>

# 3. Sync the stack to rebase children
git town sync --stack
```

## Useful Commands
- `git town config` — view full config and lineage
- `git town set-parent` — change parent of current branch (prompts if no arg)
- `git town sync --stack` — sync all branches in current stack
- `git town sync --all` — sync all local branches
- `git town propose --stack` — create PRs for entire stack
- `git town diff-parent` — show changes vs parent branch
- `git town undo` — undo the last git-town command
- `git town continue` — resume after conflict resolution
