# Module: Wake-Monitor

**For the event-driven Mate.** Core `ship-watch-start` says only "arm the wake-monitor
(see module)." This is the module: what a wake-monitor is, the contract it must satisfy,
and the hard-won pitfalls of building one.

## What it is

An **event-driven Mate** ([mate-event-driven.md](mate-event-driven.md)) idles between
events. It wakes on three things: crew completions (harness-native), a fallback timer, and
**directives that arrive while it's idle**. A wake-monitor is the mechanism for that third
one — a lightweight background watcher on the Mate's **directive surfaces** (the Captain's
inbox file, the drops directory — which is also where the **Bosun** writes its delta-drops)
that re-invokes the Mate when a directive shows up, so a Captain steer or a Bosun finding
doesn't sit unseen until the fallback timer fires.

Without it, an idle Mate with a long fallback interval leaves directives unattended for
minutes. With it, directives wake promptly while routine bookkeeping does **not** (that
asymmetry is the whole point — the input model).

**Note the topology shift from the old model:** the monitor no longer feeds *the Mate's own
loop* — the Mate has no loop. It feeds an **idle** Mate, and the **Bosun is itself a wake
producer** (its drops are the heartbeat's channel to the Mate). The contract below is
otherwise unchanged.

## The contract

A wake-monitor must:

1. **Watch every directive surface** you accept directives on — typically `inbox/captain.md`
   and `inbox/drops/` (the latter carries both external producers and Bosun drops). A
   surface you don't watch can only be picked up on the fallback timer.
2. **Wake on `wake`-class inputs only.** Classify each net-new item (directive → wake;
   bookkeeping/self-authored/unchanged-state → batch; explicitly-declared noise → silent).
   Wake on `wake`; record `batch`/`silent` in the seen-set so they don't re-fire, and let
   the next wake's reconcile drain `batch`. **Default to wake when ambiguous** — a missed
   steer costs more than an extra wake.
3. **Stay in sync with the Mate's own writes.** The Mate edits the same surfaces it watches
   (it `mv`s a drop to processed, clears inbox lines). The monitor must not fire on the
   Mate's *own* actions.
4. **Survive rotation / compaction or be re-armed.** Background tasks may not carry across a
   compaction. The post-compaction continuation step checks the monitor survived and re-arms
   it if not.

## Pitfalls (incident scars — read these before building one)

These are real failures from a production loop. They generalize to anyone building a
file-watch wake-monitor.

### 1. Enumerate, don't glob

When detecting net-new files in a drops directory, **enumerate, don't use a bare shell
glob.** A shell glob that matches nothing is a footgun: under some shells (zsh with the
default `nomatch` behavior) a glob with no matches **aborts the command**. If the monitor
enumerates drops with `ls *.md *.json` and there happen to be no `.json` files, the whole
`ls` aborts and drops-detection silently breaks — while unrelated checks keep working, so
the loop *looks* healthy but drop cards never wake. A silent partial failure is the worst
kind. (The shipped `wake_monitor.py` sidesteps this with Python globbing, which returns
empty cleanly.) Companion footgun: a `bash -c` monitor on older bash has no associative
arrays — use sorted files / `comm` for the seen-set, not `declare -A`.

### 2. Dedup by net-new filename, not by count

Track drops by a **seen-set of basenames** and wake only on *growth* (a net-new filename),
NOT by a count-delta. A count-delta monitor breaks two ways: (a) it fires on the Mate's
**own** `mv`-to-processed (count goes 1→0, which looks like a change), producing a spurious
self-wake; and (b) it lags under rapid steers (reports 2→1 when the true count is already 0).
A filename-set keyed on growth stays in sync with the Mate's own edits.

### 3. Classify before you wake

Run each net-new drop through a classifier before deciding to wake. **Wake** on directives
(a Captain steer, a Bosun delta-drop, a substantive comment, a status-*request*). **Batch**
(record in the seen-set silently, drain at the next reconcile) on bookkeeping:
status-applied / close-applied confirmations, sensor re-drops of unchanged state, the Mate's
own self-authored cards. **Default to wake** when a drop doesn't clearly classify. Skipping
classification produces a **wake storm**: every bookkeeping drop wakes the Mate, each wake
may cascade, and a burst of routine updates turns into a flurry of no-op wakes.

### 4. A content surface needs a clear-safe key

If the inbox is a file the Mate *also clears* (by removing lines), key it by **added
content-line hashes**, not by raw line count. A clear can only *shrink* the content set, so
keying on added-line hashes makes a clear structurally unable to self-wake — no authorship
heuristic needed.

## The reference implementation (shipped)

shipkit ships a working wake-monitor: **`modules/wake-monitor/wake_monitor.py`** — the companion this
module used to describe only in the abstract. It's the version `ship-watch-start` arms on
launch (step 4).

- **Zero-dependency, cross-platform, stdlib-only POLL loop** (default 8s, `WAKE_POLL_SECS`).
- Reuses `lib/classify_input.py` so a declared `wake_class` is honored verbatim (no
  second, drifting copy of the wake/batch/silent ladder) — which is exactly how the Bosun's
  `wake_class: wake` drops route through.
- Solves the four pitfalls by construction: Python globbing (#1), seen-set of basenames
  (#2), classify-before-wake (#3), `inbox/captain.md` keyed by added content-line hashes (#4).
- Baselines silently on first run and persists its seen-set
  (`state/.wake_monitor_state.json`) so a restart / post-compaction re-arm resumes without
  re-firing.
- Run it under the harness Monitor tool: each `WAKE <reason>` stdout line is a Mate wake;
  `batch`/`silent` items are absorbed into the seen-set and drained at the next reconcile.

Tests: `modules/wake-monitor/tests/test_wake_monitor.py` covers wake-steer fires, batch silent, dedup across a
processed-move, captain-add fires, captain-clear no-self-wake, plus silent-baseline +
state-persistence.

### Optional native fast path (local opt-in — NOT the default)

If the ~8s poll latency on steers proves annoying locally, there's an **opt-in** native
filesystem-watch variant: **`modules/wake-monitor/wake_monitor_native.py`** — behaviorally identical
(it reuses `wake_monitor.poll()`), but triggers on a real fs event via the third-party
`watchdog` package, with a slow safety poll underneath. It's the **only** piece of the wake
machinery that takes a runtime dependency, which is why it's opt-in. `pip install watchdog`
to use it; without it the script prints a note and exits non-zero (never silently falls
back). Prefer the poll version unless you have a measured reason to switch.
