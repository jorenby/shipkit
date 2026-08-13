# Captain's Orders

## Situation
Lumen Craft is a two-person team building Driftnote, a sync-first note-taking app. I split my time between the `driftnote-web` app and the `driftnote-sync` backend service. Most weeks I have 2-3 things in flight and not enough hours to do the queue bookkeeping myself — that's what the Mate is for.

## Priorities
1. Fix the webhook delivery bug in `driftnote-sync` (ticket 042) — customers are missing sync notifications, this is the most support-visible issue right now.
2. Add CSV export to `driftnote-web` (ticket 017) — requested by three separate customers this month, not urgent but keeps coming up.
3. Everything else in the backlog can wait for those two.

## Constraints
- `driftnote-sync` is Ruby/Sinatra. `driftnote-web` is a React app. Different repos, don't mix branches between them.
- No infra changes (queues, deploy config) without me explicitly signing off in conversation — that's a live call, not something to infer from a ticket.
- Keep PRs small. I review in the evenings; a PR I can read in 10 minutes gets merged same day, a huge one sits for a week.

## Standing Orders
- Always run the test suite before marking a ticket done.
- Commit frequently — if you'd be sad to lose it, commit it.
- When in doubt, checkpoint and ask me rather than guessing.
