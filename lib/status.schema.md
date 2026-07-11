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

### Retention: cap + archive any UNBOUNDED array you add (earned in production)

`status.json` is read constantly and fully rewritten on every write. Any append-only array a
module adds (`ticks[]`, `steer_feedback[]`) accretes forever if left uncapped. In production a
`ticks[]` array grew to 919 entries / 317KB before anyone noticed — and NO consumer read deep
history (the UI client capped itself to the last ~75 ticks; the cadence graph to 40; every
validator/policy reader used only the newest tick). The whole file was being re-serialized on
every write to carry ballast nobody read.

**The rule for a schema-extending module:** cap each unbounded array to a tail that comfortably
exceeds every reader, and APPEND the overflow to an append-only `state/*-archive.jsonl` (one
record per line) so history is preserved, not deleted. Do the cap on EVERY write (so the
first write over a bloated legacy file is itself the one-time migration — no separate migration
script). Make the archive append best-effort: an archive failure must WARN, never block the
status write (telemetry history is nice-to-have; the live `status.json` is not). Do NOT cap
semantically-bounded arrays that are managed by wholesale replacement or explicit removal
(`ready_for_you`, `crew`, `last_actions`) — trimming those would silently drop live items.
(Reference sizing from the live ship: `ticks`→100, `steer_feedback`→30.)

### Side effects must be env-guardable (earned in production)

If a module's writer gains a SIDE EFFECT beyond the disk write — e.g. auto-POSTing a tick
summary to a live thread/chat endpoint — it MUST be suppressible by an environment variable
(the live writer used `STATUS_WRITE_NO_THREAD=1`). Reason: the test suite sandboxes the *disk*
write to a temp file, but a network side effect ignores the temp path and hits the LIVE
surface on every test run. The live status writer quietly posted ~20 junk entries to the real
thread across two weeks of test runs before a browser-verify pass caught it. The core writer
here is deliberately side-effect-free (disk only); keep it that way, and if you wrap it with a
notifier, gate the notifier on an env var and set that var in your test harness.

## Coupling

The UI's coupling is to **this contract + the `inbox/drops/` steer path**, NOT to the writer
Python. The UI reads `state/status.json` directly and writes steer drops that
`lib/classify_input.py` later routes to `wake`. So tier-3 (ui) depends on tier-2 (autonomous)
having produced a `status.json` at runtime — a runtime ordering, not a code import.
