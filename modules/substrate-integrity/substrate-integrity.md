# Module: Substrate Integrity

**Optional. For ships that want tamper-detection on their own security files.**
Two layers that protect the *substrate* — the guards, hooks, and agent
definitions that enforce every other safety rule — from being edited out from
under the ship.

## Why it matters

The crew-safety hooks are the ship's bright line. But a hook is just a file, and
an agent that can write files can, in principle, edit its own guard. Core's
crew-write guard denies edits to a basename set; this module adds the detection
half: notice if a substrate file changes anyway, and make it hard to change in
the first place.

## ⚠ Known gaps — read before relying on either layer

Both layers **ship** with this module; neither is **armed** by installing it, and one is
currently mis-targeted for this repo's layout. Until these are fixed, treat the module as
raising the bar, not as a control you can trust.

1. **Installing the module arms nothing.** `shipkit_init.py` makes the guard executable; it
   does not register it. No agent definition names it (crew defs render only
   `validate-crew-bash.sh` and `validate-crew-write.sh`), and the guard's own header asks for
   the live copy to sit at `~/.claude/hooks/`, which implies a user-level PreToolUse
   registration you write by hand. **Arming it is a manual step, and it is not yet
   documented.** So a green install line for this module does not mean crew are blocked.
2. **The deny list covers 6 of this repo's 14 substrate files.** Measured, not estimated —
   **denied:** `validate-crew-bash.sh`, `validate-readonly-bash.sh`, `validate-prod-guard.sh`,
   `ship-substrate-guard.sh`, `ship-crew.md`, `ship-lookout.md`. **Not denied:**
   `core/hooks/validate-crew-write.sh` (the guard protecting `queue.md`, `captain.md`,
   `inbox/**` — itself unprotected), the autonomous tier's `validate-mate-bash.sh`,
   `validate-bosun-bash.sh`, and `validate-mate-mcp.sh`, and **four of six agent defs**
   (`ship-mate.md`, `ship-bosun.md`, `ship-reviewer.md`, `ship-pilot.md`). That last set
   matters most on the `autonomous` preset, where `core/mate.md` describes the Mate's bright
   lines as structurally enforced by two of the guards in that undenied list.
   Seven further entries name files that don't exist here at all — including
   `validate-mate-mcp-bash.sh`, one character-class away from the real
   `validate-mate-mcp.sh`. That near-miss *is* the argument: hand-enumerated basename lists
   drift silently against the tree they're meant to protect, and nothing tests them against
   it. Check yours file by file; never infer coverage from "it's a guard."
3. **The tripwire's watch list targets a different layout.** `watched_paths()` looks for
   `$SHIP_ROOT/scripts/validate-*.sh`, `$SHIP_ROOT/scripts/crew-allow-local.sh`,
   `$SHIP_ROOT/scripts/hooks/ship-substrate-guard.sh`, and `$SHIP_ROOT/agents/*.md`; here
   those live at `core/hooks/`, `core/templates/`, `modules/substrate-integrity/hooks/`, and
   `core/agents/` respectively. A missing path hashes stably to `None`, so the sensor
   **runs clean and detects nothing** on six of its nine paths. It will log healthy ticks and
   populate a baseline while watching almost nothing that exists. Do not schedule it until the
   watch list is derived from the installed layout — and make an all-absent watch set a loud
   error rather than a quiet success.
4. **Baseline state is keyed per user, not per checkout** (`~/.claude/ship/…`), and written
   non-atomically. Two checkouts both running the tripwire will each see the other's paths as
   `deleted` and their own as `appeared`, firing a tamper drop every poll until real tampering
   is indistinguishable from the noise; a concurrent read can also catch a half-written file
   and raise a false `baseline-unreadable` alarm.

## The two layers

**`hooks/ship-substrate-guard.sh`** — a PreToolUse `Edit|Write|MultiEdit` hook that
**denies** edits to a **hand-enumerated subset** of security-substrate basenames,
matching on basename case-insensitively. It is not "guards, hooks and agent defs" —
read the `case` list and compare it against your own tree (**Known gaps** #2 above),
because the omissions are not obvious. This is the bar-raising half, and it is not
armed by installing the module (**Known gaps** #1).

**`substrate_tripwire.py`** — an out-of-session tamper tripwire. It hashes the
watched substrate files and fires a wake drop when a hash changes unexpectedly —
but see **Known gaps** #3: in this repo's layout most of those paths do not exist,
so it currently detects almost nothing.
This is best-effort **detection**, not prevention — it catches a change the
deny-hook didn't. Its baseline state lives **outside the ship tree** (default
`~/.claude/ship/substrate_tripwire_state.json`) by design, so an agent writing
inside the repo can't poison the baseline it's checked against.

## Threat model (read before trusting it)

This is calibrated to a **non-adversarial, human-in-the-loop crew** — it raises
the bar and detects accidents / prompt-injection drift, not a determined attacker
with shell access. "Monitored" here means best-effort detection, not tamper-proof.
An OS-level wall is a separate, deferred concern.

## Test

- `tests/test_substrate_tripwire.py` — hash/baseline/fire behavior, including the
  baseline-poisoning edge.
- `tests/substrate-guard.test.sh` — the deny decision-table across substrate and
  non-substrate basenames.
