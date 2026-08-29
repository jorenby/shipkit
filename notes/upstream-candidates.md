# Upstream contribute-back candidates

Running backlog of general-purpose fixes/improvements worth sending to `wstrinz/shipkit`.

`scripts/upstream-sync-report.sh` no longer counts TODO lines here. It derives the count
from the repo — commits ahead of `upstream/main` — and subtracts any commit whose short
SHA appears in a **disposition** line below. So this file is a **disposition ledger**, not
a wishlist: a commit ahead of upstream stays in the count until you record what happened
to it. Two dispositions take a commit out of the count:

- `- [x] <one-line description> <short-sha> (PR: <link>)` — **sent** upstream.
- `- [~] <one-line description> <short-sha>` — **local-only / won't-send** (de-Drip,
  repo-identity, ship-specific config). This is what lets the count converge: intentional
  divergence is not a contribute-back candidate, so excuse it here rather than letting it
  inflate the pool forever.

The `<short-sha>` must be the ahead-commit's `git log --format=%h` short SHA — the report
matches it with word boundaries. A commit ahead of upstream with no `- [x]`/`- [~]` line
for its SHA counts as outstanding (the report prints the outstanding SHAs so you can triage
them into one disposition or the other).
