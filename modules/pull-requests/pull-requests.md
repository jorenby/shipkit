# Module: Pull Requests (PR-workflow mechanics)

**Depth doc for a PR workflow.** Core `mate.md` → "Pull Requests" carries the
safety-critical bright lines every operator needs the moment they touch a PR:
**create PRs as drafts**, **never `gh pr ready` without per-PR confirmation**, match
description length to change size while keeping the template structure, and the
clickable PR-link format. That inline kernel is enough to handle PRs safely. This
module holds the *mechanics* an operator pushing to their own main never hits:
mergeability re-checks and stacked-PR propagation. It's a **plain (non-`@`)
reference** — read on demand, and the tick skills backstop-force it when reaping a
PR watch or resolving cross-branch conflicts.

## Verify mergeability after every push

**After pushing crew work to any open PR branch, confirm the PR is still mergeable
before calling the land done.** One command: `gh pr view <n> --json
mergeable,mergeStateStatus`. A push that lands clean locally can still leave the PR
`CONFLICTING` against a base that advanced — content correctness and test-green do
not imply the PR can merge. Don't trust the queue's last-known "clean"; re-check
after you touch the branch. Skipping this is how a PR sits silently un-mergeable for
days.

## Stacked PRs

When PRs are stacked (PR B based on PR A's branch, not the main branch), the base
moves out from under the feature whenever A advances — leaving B stale or
`CONFLICTING` even though nobody touched B:

- **After any change to a base PR, propagate to everything stacked on it.** Merge
  the updated base into each downstream feature branch (the "update branch"
  pattern), resolve conflicts, re-run that level's tests, and re-verify
  mergeability. Work top-down through the stack.
- **Prefer merging the base in over rebasing** for open-PR branches: it resolves
  conflicts in one pass, keeps the PR's diff clean against its base, and avoids
  force-pushing a branch others may be reviewing.
- **Merging a base in can silently drop a downstream's own additions** via three-way
  resolution (base removed X, feature left X unchanged → git removes X). If a change
  must live in a specific PR, after the merge confirm it's still present and re-add
  it as that PR's own commit if needed.
- **Resolving conflicts across parallel crew branches is the Mate's job** — crew
  can't push, so the Mate does the merge/rebase, conflict resolution, and the
  post-resolution test + mergeability re-check.

## The `pr:` frontmatter field

If you keep a `pr:` field (or equivalent) in ticket frontmatter so the Captain's
views render the live PR, keep it current — lead with the live PR, keep prior ones
after for history. A stale link makes a ticket look like it has no PR even when one
exists.
