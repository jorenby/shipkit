---
name: pr-sync
description: Reconcile an open PR's title and description with the current state of its branch, then update on confirm. Use after pushing follow-up commits to a branch whose PR body now lags behind — new commits not described, a title covering only part of the change, stale test counts / file names, "pending" items since done, or removed approaches still described. Works in any repo.
disable-model-invocation: false
argument-hint: "[optional PR number — defaults to the current branch's open PR]"
allowed-tools: Bash, Read, Grep, Glob
---

# /pr-sync — Reconcile a PR with its branch

Bring an open PR's **title + description** back in line with what the branch actually contains. Read-only until a single confirm-gated `gh pr edit`. This closes the common drift where follow-up commits land but the PR prose doesn't move.

## What this is (and isn't)

The value is **judgment**, not automation: spot where the body's claims diverge from the commits/diff, and redraft *minimally* — preserving accurate prose, fixing only what drifted. It is not a body generator; never rewrite a good description from scratch, and never fabricate specifics to fill a template.

## Steps

1. **Resolve the PR.** If `$ARGUMENTS` names a PR number, use it. Otherwise the current branch's open PR:
   `gh pr view --json number,title,body,headRefName,state,url`
   If there is no open PR for the branch, say so and stop (nothing to sync).

2. **Gather ground truth** (read-only):
   - Commits on the branch and their messages: `gh pr view <n> --json commits --jq '.commits[].messageHeadline'` (and full messages if a headline is thin).
   - What actually changed: `git diff --stat $(gh pr view <n> --json baseRefName --jq .baseRefName)...HEAD` and, where a claim hinges on it, the relevant `git show <sha> -- <path>` or `git diff` hunk.
   - The repo's PR/commit conventions: skim `CLAUDE.md` (and any `.github/pull_request_template.md`) for the expected section shape (e.g. Problem / Fix / Test plan) and voice.

3. **Detect drift.** Compare what the body *claims* against what the branch *shows*:
   - Commits whose substance is absent from the body (a whole mechanism or fix not described).
   - Title that names only a subset of the change.
   - Stale specifics: test counts, file/function names, numbers, benchmarks.
   - "TODO / pending / needs X" that a later commit has since done.
   - An approach the body describes that a later commit removed or replaced.
   - A section the repo convention expects (e.g. Test plan) that's missing.

4. **If no drift:** report "PR #<n> is in sync with its branch" and **stop — no write.**

5. **If drift:** draft a corrected **title** and **body**:
   - Minimal-diff the body — keep every accurate sentence, add/fix only the drifted parts, match existing headings, tone, and backtick usage.
   - Every added claim must trace to a commit, diff hunk, or test you actually verified. If a test count is asserted, verify it cheaply (or describe the tests without a fabricated number) — do not carry forward a number you didn't check.
   - **Durable-record hygiene:** the PR body is read by people who never see the ship. No ship ticket IDs, no session shorthand ("option B"), no internal coordination notes. Reference commit SHAs, file paths, and function names — those are durable. The same discipline applies as for commit messages.

6. **Present** a short drift list + the proposed title and the body diff (or full body if a rewrite is unavoidable).

7. **Confirm before writing.** Updating a PR is outward-facing. Wait for an explicit go, then apply the one write:
   `gh pr edit <n> --title "…" --body-file <tmpfile>`
   (Write the body to a temp file to preserve markdown exactly; don't inline a large `--body`.)

8. **Report** the updated PR URL and a one-line recap of what changed.

## Guardrails

- Read-only until the confirm; the sole mutation is one `gh pr edit`. Never edit code, never push commits, never post comments or reviews.
- Don't clobber hand-tuned prose. Drift-fix, not regenerate.
- Don't invent — no claim in the body without a branch fact behind it.
- One PR at a time. If the arg is ambiguous or the branch has several PRs, ask which.
