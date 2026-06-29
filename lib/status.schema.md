# status.json — the field contract (shared moat)

`state/status.json` is the contract between the producer (`lib/status_writer.py`, written by
the autonomous Mate/heartbeat) and every consumer (any UI — the tier-3 status-surface, or
your own render). The data contract is the moat: frozen contract, disposable render. This doc
is the authoritative field list; `status_writer.py` is the only sanctioned writer.

## CORE fields (all the writer knows about)

| Field | Type | Meaning |
|---|---|---|
| `tick` | int | monotonic counter, strictly increasing |
| `wake_reason` | string | what woke this tick (named, never assumed) |
| `now` | object | `{doing, since (ISO), wake}` — live Mate activity |
| `next_wake` | string | local-time clock stamp + reason, COMPUTED from `now()` (never a typed literal) |
| `last_actions` | list | this tick's actions, plain sentences |
| `validator` | string | result of the reconcile step (or `"NONE"`) |
| `generated_at` | string | ISO 8601 stamp, set on every write |

## Module extensions

Modules EXTEND this schema; they do not fork it. The status-surface UI adds rich fields
(`hot_list`, `ready_for_you`, `crew[]`, `steer_feedback[]`, `ticks[]` history). A headless
loop never writes them — the durable per-tick record is the mate-log telemetry line, not a
`ticks[]` array. A module subclasses/wraps the writer to add fields; **unknown fields already
present in the file are preserved untouched on every write.**

## Coupling

The UI's coupling is to **this contract + the `inbox/drops/` steer path**, NOT to the writer
Python. The UI reads `state/status.json` directly and writes steer drops that
`lib/classify_input.py` later routes to `wake`. So tier-3 (ui) depends on tier-2 (autonomous)
having produced a `status.json` at runtime — a runtime ordering, not a code import.
