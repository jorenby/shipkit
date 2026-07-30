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

## The two layers

**`hooks/ship-substrate-guard.sh`** — a PreToolUse `Edit|Write|MultiEdit` hook that
**denies** edits to security-substrate basenames (guards, hooks, agent defs),
matching on basename case-insensitively. This is the bar-raising half.

**`substrate_tripwire.py`** — an out-of-session tamper tripwire. It hashes the
watched substrate files and fires a wake drop when a hash changes unexpectedly.
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
