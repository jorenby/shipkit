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

## Modules are the single extension surface (2026-07)

**Decision:** the vestigial `roles/` mechanism is removed. A new capability — including a
new agent type — is a module folder with a `module.json`; modules ship agents, skills,
hooks, and scripts (see `modules/README.md` § Adding a module). One mechanism, one
manifest, one installer path. The ruby `mate-lock.rb` parity was dropped at the same time
(python3 is already a hard prerequisite; two lock implementations was one to maintain and
one to drift).
