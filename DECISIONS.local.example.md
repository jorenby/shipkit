# Decisions & Scars — this ship (template)

Copy this file to **`DECISIONS.local.md`** and log your ship's own history here: dated
incidents, Captain rulings, house post-mortems, and the locally-learned rules they
produced. This is the operator twin of the framework's `DECISIONS.md` — same shape,
different scope:

- **`DECISIONS.md`** (framework, synced from upstream): decisions that hold on *any*
  ship. Don't edit it on an operating ship; if a local lesson generalizes, upstream it.
- **`DECISIONS.local.md`** (yours): anything that names your repos, your dates, your
  machines, or your Captain's calls.

Gitignored by default; `pull-upstream` never touches it. If your ship directory is your
durable, version-controlled record (especially with autonomous Mate rotations handing
off through git), track it — same convention as `mate.local.md`, and the same caveat:
ship history, not a secret store.

Newest at the bottom. Keep entries short: what happened, the rule it produced, where the
rule now lives (usually `mate.local.md` house notes, a knowledge doc, or a local hook
allow-list).

---

## YYYY-MM-DD — {one-line title}

**Incident/ruling:** {what happened, or what the Captain decided, in 2–3 sentences}

**Rule:** {the durable takeaway}
**Lives in:** {where you wrote the rule down}
