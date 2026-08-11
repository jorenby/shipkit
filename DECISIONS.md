# Decisions & Scars (framework)

Shipkit's design decisions and the failures that produced them. The operating docs state
each rule once, cleanly, in the file that owns it; this log carries the *why*, so
doctrine doesn't have to. It is a **framework** doc — impersonal, synced from upstream
like `README.md`. It changes when shipkit's design changes.

**Your ship's own history does NOT go here.** Dated incidents on your ship, Captain
rulings, house post-mortems, and locally-learned rules go in **`DECISIONS.local.md`**
(seed it from `DECISIONS.local.example.md`) — gitignored by default, `pull-upstream`
never touches it, and trackable under the same convention as `mate.local.md` when your
ship directory is your durable record. Rule of thumb: if the lesson would hold on a
stranger's ship, it may belong here (upstream it); if it names your repos, your dates,
or your Captain's calls, it's local.

---

## Enforcement must fail closed

**Failure:** v1 installs could write agent defs with a literal `{SHIP_DIR}` left in the
hook command. The hook path was garbage, so PreToolUse enforcement was **silently OFF**
while everything else looked healthy.

**Rule:** the installer asserts every installed hook command path resolves and runs a
placeholder-verification pass; **any FAIL exits non-zero**. An unenforced install must
never be silent or exit green.
**Lives in:** `shipkit_init.py` (assert + placeholder pass), `/shipkit-setup` verify screen.

## The Bosun return-channel rule

**Failure:** the first Bosun deployment ran its sweeps faithfully but never routed
findings anywhere the Mate would see — it read as "idle" for a full day while doing real
work. Lost work that looks like silence.

**Rule:** heartbeat every tick, always; every wake-class finding becomes a drop via
`bosun_emit.py`. A sweep that finds something and doesn't drop it is a bug, not a quiet tick.
**Lives in:** `modules/autonomous/bosun.md` (the return-channel rule).

## The Mate schedules nothing

**Finding (loop-mode v2 design):** any Mate-side timer — even a "long fallback floor"
`ScheduleWakeup` — self-perpetuates into a Mate-owned loop, recreating the model the
two-agent split exists to kill (periodic sweeps starving on the reactive hot path, pacing
coupled to context headroom). Real events already re-invoke the session: the wake-monitor
on drops/inbox edits, `<task-notification>` on crew completion.

**Rule:** the Mate is purely event-driven; anything periodic is the Bosun's.
**Lives in:** `modules/autonomous/mate-event-driven.md`.

## `/loop`, not `/goal`, keeps the Bosun alive

**Finding:** layering `/goal` over `/loop` breaks the heartbeat two ways: (1) setting a
goal starts a turn immediately — a wind-down-shaped goal condition makes the agent wind
down *now*; (2) the goal evaluator fires after every turn and, if unmet, starts another
turn instead of returning control — vetoing the loop's scheduled sleeps and turning the
paced heartbeat into a hot loop.

**Rule:** `/loop` and `/goal` are *alternative* session-keepers, never layered.
**Lives in:** `modules/autonomous/bosun-loop.md`.

## The `--ensure` staleness threshold must outlast the Bosun's slowest pace

**Failure:** a live ship's Bosun self-paced to an hourly cadence while
`launch-bosun.sh --ensure` kept a tighter (~45m) staleness threshold. Every morning Mate
rotation read the healthy-but-slow heartbeat as "dead Bosun" and launched a duplicate —
**two heartbeat owners**, each clobbering the other's sweep cursor, duplicate drops,
and a corrected cursor overwritten by the stale twin.

**Rule:** the staleness threshold must comfortably exceed the Bosun's slowest self-pace
(the heartbeat is only touched at tick time, so its age legitimately approaches the full
scheduled delay). The Bosun **declares** its pace — bosun-tick writes `pace_secs` into
the cursor JSON — and `--ensure`/`--check` widen the threshold to
`max(BOSUN_STALE_SECS, 2 × pace_secs)`. A fixed threshold alone silently breaks the
moment the Bosun paces slower than whoever chose the constant assumed.
**Lives in:** `modules/autonomous/scripts/launch-bosun.sh` (threshold),
`modules/autonomous/skills/bosun-tick/SKILL.md` step 6 (the declaration).

## Wake-monitor pitfalls (production failures)

**Failures:** four, all from a production loop: a zsh `nomatch` glob abort that silently
broke drops-detection while the rest of the loop looked healthy; a count-delta monitor
that self-woke on the Mate's own `mv`-to-processed; wake storms from unclassified
bookkeeping drops; self-wakes on the Mate clearing its own inbox lines.

**Rules:** enumerate-don't-glob, dedup by net-new filename, classify-before-wake,
clear-safe content keys. `wake_monitor.py` solves all four by construction.
**Lives in:** `modules/wake-monitor/wake-monitor.md` § Pitfalls.

## mate-lock `status` exits 1 when held (by design)

**Finding:** `status` is an "is the lock free?" predicate, so a healthy `STATE: held`
report exits 1. Chained unguarded under `&&` / `set -e`, a *successful* boot reads as a
failure.

**Rule:** guard it (`… status || [ $? -eq 1 ]`, as `ship-up.sh` does).
**Lives in:** `mate-lock.py` usage text, `ship-watch-start` step 3.

## Windows/Git-Bash is a supported substrate — with two traps

**Failures (first Windows bring-up):**

1. **A bare `bash` on Windows can resolve to WSL's `System32\bash.exe` stub**, which can't
   see the Windows script path — the hook command errors and enforcement **fails open,
   silently**. **Rule:** the hook interpreter is resolved at install time; POSIX keeps a
   bare `bash`, Windows requires an absolute Git-Bash path and the install fails without
   one. Hook commands render as `<interpreter> <abs-path>` so enforcement never depends on
   the exec bit or shebang resolution. **Lives in:** `shipkit_init.py`,
   `loop.config.example.json` (`_hooks`).
2. **Git-Bash has no `pkill`.** Process sweeps (the wake-monitor kill-sweep) need a
   PowerShell fallback. **Lives in:** `ship-watch-start` step 4, `ship-up.sh --rotate-mate`.

## Loop-mode v2: the two-agent split (2026-07)

**Decision:** replace the single "Mate runs `/loop`" model with a two-agent split — a
**read-only Bosun** owns the heartbeat (sole write path `bosun_emit.py`), the **Mate is
event-driven** and owns all authority. Bookkeeping stops starving on the Mate's reactive
hot path; pacing decouples from context headroom (the Bosun paces by *heat*); a read-only
librarian can't corrupt the store. Upgrades from the pre-v2 shape carry known footguns
(copied boot skills that keep launching the dead loop, lingering flat hooks that still
resolve) — the judgment for those lives in `.claude/skills/shipkit-setup/upgrade.md` and
`UPGRADING.md`, which deliberately keep their history inline.

## The enforcement envelope, made exact (2026-07)

**Finding (external review):** crew agents carry Write/Edit tools, but the only
PreToolUse hook matched Bash — so a *direct* Write/Edit call to `queue.md`,
`captain.md`, or `inbox/` never passed through any guard, while the docs said "writes
blocked by hook." Prose claimed more than the mechanism delivered.

**Decisions:** (1) a Write/Edit path guard (`core/hooks/validate-crew-write.sh`) now
blocks the indisputable shared-state boundaries for crew/pilot; ticket single-ticket
scope stays prompt-governed. (2) The docs describe the command hooks as what they are —
**fail-loud guardrails against accidental violations, not a sandbox** (an allowed
interpreter or build script can do anything the process can); the security boundary for
unattended writable agents is the sandbox + filesystem/credential scoping.
**Lives in:** `core/hooks/validate-crew-write.sh` (+ tests), `subagent-roster.md`
§ Security model.

## Available ≠ enabled: the install record (2026-07)

**Finding (external review):** a full shipkit clone carries every module's source whether
or not the operator selected it, and the installer forgot its answer the moment it exited
— so "installed" meant three different things (present in the clone / selected /
materialized), a doc-only module's selection evaporated, and peer-comms activated by
file-existence rather than by choice.

**Decision:** the installer persists the semantic install record to `state/install.json`
(schema, preset, resolved module set, install mode, source commit) after — and only after
— the enforcement gates pass. Re-runs union additively, mirroring the installer's
file-level behavior. The record is authoritative for consumers when present:
`classify_input.py` gates the peer-comms pre-filter on it (legacy file-existence only as
the pre-record fallback), the dry-run report surfaces it, and upgrades/doctor diff against
it. Per-machine and gitignored, like `loop.config.json`.
**Lives in:** `shipkit_init.py` (`write_install_manifest`), `lib/classify_input.py`
(`_peer_comms_enabled`).

## Modules are the single extension surface (2026-07)

**Decision:** the vestigial `roles/` mechanism is removed. A new capability — including a
new agent type — is a module folder with a `module.json`; modules ship agents, skills,
hooks, and scripts (see `modules/README.md` § Adding a module). One mechanism, one
manifest, one installer path. The ruby `mate-lock.rb` parity was dropped at the same time
(python3 is already a hard prerequisite; two lock implementations was one to maintain and
one to drift).

## Read-only agents execute nothing — the reviewer test-runner is declined (2026-07)

**Decision:** the upstream v2 read-only bash guard shipped a bounded reviewer test-runner
allowance (`ro_test_runner_allowed` — let a reviewer run `python3 tests/*.py` / `bash
test-*.sh`). The ship fork **declines it**: a read-only agent (`ship-lookout` / reviewer)
executes *nothing*. Verifying a test is a read; when a review genuinely needs to *run*
code, the guarded crew reviewer (maker≠checker, tier-1) is the path — a separate agent
type with its own execution surface — not a lookout given a foothold to execute. Allowing
any interpreter-with-a-script form on the read-only guard trades the one bright line that
makes "read-only" mean read-only for a convenience the crew reviewer already covers.

**Rule:** `validate-readonly-bash.sh` has **no** interpreter/test-runner allowance;
interpreters default-deny. An upstream sync must not silently re-adopt `ro_test_runner_allowed`.
**Lives in:** `core/hooks/validate-readonly-bash.sh` (no test-runner; the allow-list ends
at archive-inspection), its test suite (interpreter forms assert BLOCK).

## Unreconciled drift is a fork's default outcome — watch it, don't heroics it

**Decision:** a re-fork of upstream shipkit stays reconciled via a light, read-only weekly
tick, not periodic heroic catch-up merges (the pattern that let an earlier fork go dead).
Three drift metrics are tracked — commits-behind-upstream, contribute-back candidates
outstanding, overlay-% of tree — and any one trending up over time is the early
"becoming a dead fork" signal.
**Rule:** the tripwire script only fetches and reports; it never merges, rebases, resets, or
pushes. Only a crew in an isolated worktree (small clean pulls) or Nav/Captain (conflicts, PR
bundles) act on what it surfaces.
**Lives in:** `scripts/upstream-sync-report.sh`, `notes/upstream-candidates.md`, `core/mate.md`
§ Upstream Sync, `core/crew.md` § Ending a Watch.

## Substrate changes are pre-flight, and the maker is never the checker (2026-08)

**Decision:** edits to the ship's own substrate — guards, hooks, role docs, skills, scheduler
units — happen in a session that is **not** carrying product work, and they are reviewed by
someone other than whoever made them.

**Why, concretely — three different latencies, and that's the whole point.** "Substrate" is
not one kind of file:

| What | When your edit takes effect | Consequence of editing mid-flight |
|---|---|---|
| Hooks / guards (`core/hooks/`, a module's `hooks/`) | **Immediately**, for any agent whose definition renders that hook | You change the rules a *currently running* crew is being judged by, mid-watch |
| Skills, role docs (`core/mate.md`, a module's skill) | **Next session** — these are read at start | The edit is invisible in the session that makes it and inherited whole by the next one, so it cannot be observed or tested by its own author |
| Scheduler units (launchd/cron) | On next load, and they run **unattended** | A bad edit fails where nobody is watching |
| Tickets, `queue.md`, notes, `DECISIONS.md` | Immediately, and harmlessly | None — these are **not** substrate; apply them mid-flight freely |

"Don't change the airplane while flying." A substrate itch discovered mid-flight is a ticket
for the next pre-flight pass, not a now-edit. Recovery, if an edit bricks a running session:
revert with `git` from a plain shell or a fresh session.

Note the trap in row 2, since it is the one that bites: a role-doc or skill edit *looks*
inert — nothing changes, no error — which reads as "that went fine" when in fact nothing has
been tested at all.

**Rule:**
- **Who shapes ≠ who builds ≠ who checks.** One seat shapes the change and sets the review
  bar, another executes it in a cleared hands-on pass, and an **independent** reviewer (a
  fresh model/session that did not write it) gates it. The load-bearing safety is
  maker ≠ **checker**, and it holds regardless of which seat is the maker. See `core/mate.md`
  § Maker ≠ Checker.
- **Don't hand substrate to a crew subagent — but know that "the guard stops it" depends on
  what you installed.** Core's write guard (`core/hooks/validate-crew-write.sh`) protects
  `queue.md`, `captain.md`, and `inbox/**` — **not** the hook scripts themselves. Blocking a
  crew from editing guards is what the optional `substrate-integrity` module adds, and it is
  in no preset. So on a core-only install a crew `Edit` of `core/hooks/validate-crew-bash.sh`
  lands silently. Treat this rule as doctrine you enforce, not a mechanism you inherit.
- **Not the long-lived coordination session either** — keep the heavy build out of the one
  context that is expensive to rebuild.

**Lives in:** `core/mate.md` § Maker ≠ Checker (execution + review bar), the `navigator`
module (shaping + review ownership), `modules/substrate-integrity/` (detection — and the
enforcement that core alone does not provide).

## Drops propose; promotion to Ready is a live human act (2026-08)

**Decision:** a drop may file a ticket to Backlog, re-summarize a line, or re-order *within*
Backlog. It must **never** move a ticket into **Ready**. Entry into Ready happens on a live
human (or human-directed Navigator) pass, and on nothing else.

**Why:** Ready is the dispatch surface. On an install that dispatches from Ready — the
`autonomous` preset, or any loop that pops the top of the queue — the moment a ticket enters
Ready is the **last point a human sees the work** before an executor acts on it. So a Ready
promotion isn't a status edit, it's agenda-setting: it decides what the ship does next. That
is the one thing an automated writer must not be able to do on its own.

The gap this closes is unauthenticated authorship: a drop's `source:` field is free text that
any process can write. `source: nav` is not evidence that a human passed on the work, so a
Mate that trusts it has no gate at all — it just has a gate that is trivially spoofed by the
next sensor someone wires up.

**Rule:** a drop requesting Ready entry is a **recommendation**. Leave the ticket in Backlog,
surface it, and let a human promote it. This is a discipline gate today, not a structural one
— a typed non-Ready lane plus authenticated drop authorship would make it mechanical, and
until that exists the rule lives in the role docs.

**Corollary — the shovel-ready bar becomes a safety mechanism, not tidiness.** If Ready is
auto-dispatched, an under-specified Ready ticket is an unreviewed instruction to an executor.
Whoever promotes owns that: clear scope, explicit acceptance, and a cold-start fork-point.

**Lives in:** `core/mate.md` § Processing Inbox → Drops (the Mate is the only writer who could
apply such a drop), the `navigator` module (the seat that most often wants to).
