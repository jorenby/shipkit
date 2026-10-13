---
name: ship-watch-rotate
description: >
  The clean entrypoint for ROTATING the Ship First Mate — closing the current watch and
  handing the deck to a fresh bg-Mate. Invoke once, from the OUTGOING Mate, when winding
  down: at a day/night model change, when context headroom is low, or when the operator
  calls a rotation. It runs the 4 phases (DETECT → PREP → ROTATE → VERIFY), wrapping
  `rotation_prep.py` + `ship-up.sh --rotate-mate` rather than re-deriving them, and it
  guards the traps that have actually bitten (silent no-op prep, prose-destroying re-write,
  stale lock id, over-counted monitors, a released lock with no successor). The successor
  boots via `ship-watch-start` — this skill hands off TO that, it does not duplicate it.
  Not for use outside an active Mate watch.
---

# /ship-watch-rotate — hand the deck to a fresh bg-Mate

You are the **OUTGOING** First Mate. This skill closes your watch and launches your successor.
Run it **once**, at wind-down. All paths are relative to the ship root.

**What this skill is NOT:** it is not the wind-down *ceremony*. The log close-out, handoff
notes, standup (if it's the day's true end), and any `/ship-compound` capture are
`core/mate.md` → "Sessions and Logs (the handoff contract)" — plus the session-ceremony
module if you run it — and they happen **before** you run this. This skill is the
**mechanical** rotation.

**The division of labor, stated once:** the scripts own the mechanics (preflight, monitor
sweep, `bgIsolation` heal, launch, lock release). **You own the judgment** — whether it's
time, which model the successor runs, and the handoff prose. Every trap below lives at that
seam.

---

## Phase 1 — DETECT (should this rotation happen?)

```bash
python3 modules/autonomous/scripts/rotation_prep.py --check-context
```
Exit codes: **0** = OK (headroom fine) · **3** = ROTATE-RECOMMENDED (≥ threshold, default
70%) · **4** = NO-GAUGE. Threshold seam: `--threshold N` or `SHIP_ROTATE_THRESHOLD`; gauge
path seam: `--gauge PATH` or `SHIP_GAUGE_PATH` (default `state/context-gauge.json`, the
`band_gauge_path` in your `mate.local.md`).

**This is an input, not an order.** Exit 3 means *start looking for a seam*, not *rotate
now* — finishing a coherent thread first is usually right. Conversely an **operator-called**
rotation or a **model change** (the day/night cadence in
`modules/night-economy/night-economy.md`, if you run it) is reason enough at exit 0.

**Exit 4 is the DEFAULT on a stock ship** — shipkit ships no gauge writer, so a fresh
install has no gauge to read. That means *rotate on judgment* (compaction warnings, the
model change, the operator's call); it does not mean keep sailing blind.

State which trigger applies before continuing.

## Phase 2 — PREP (generate the skeleton, THEN fill it)

### 🔴 Order matters, and getting it backwards destroys your work

```bash
python3 modules/autonomous/scripts/rotation_prep.py --write     # ← --write FIRST. Always.
```

- **`--write` REGENERATES the handoff; it does NOT preserve prose.** Running it *after*
  you've filled the FILL sections silently replaces them with stubs. **Recovery:
  `state/bg-mate-handoff.prev.md`** holds the previous version.
- **A bare `rotation_prep.py` with NO `--write` prints to stdout and writes NOTHING.** It
  looks like success. The file stays stale, and the `SHIP_OUTGOING_LOCK_ID` baked into it
  can be two rotations dead. Confirm the file actually changed — check its
  mechanical-state timestamp.

### Then fill the FILL sections by hand — this is the part only you can do

The skeleton is a frame, not a handoff. Load-bearing sections:

| Section | What it must say |
|---|---|
| **⚡ MODEL / POSTURE** | The successor's model + why (your `mate.local.md` model roster / night-economy keys). Name the posture explicitly — "operator on the bridge", "night posture applies", "drop the night posture entirely". |
| **FRESHEST STATE** (supersedes all below) | 3–6 bullets: what just closed, what's mid-air, what to watch. **Only you know this.** |
| **In flight / watch-for** | Threads mid-air, reviews pending, promises made — or say plainly "nothing mid-air". |
| **Open Captain items** | Each with a concrete next action. `queue.md` → Awaiting Captain is the source of truth; **do not** point at any other surface unless you've just confirmed it's fresh. |
| **Corrections forward** | Anything you discovered this watch that contradicts a durable doc, stated explicitly ("PR #31 is CONFLICTING, not MERGEABLE — needs a rebase"). A correction that lives only in your log will be re-learned the hard way. |

## Phase 3 — ROTATE (launch the successor, stand down)

### Verify the lock id against the LIVE lock before trusting it

```bash
python3 modules/autonomous/scripts/mate-lock.py status     # who actually holds it, right now
export SHIP_OUTGOING_LOCK_ID=$(python3 modules/autonomous/scripts/mate-lock.py status --json \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['holder'])")
echo "$SHIP_OUTGOING_LOCK_ID"                              # must match the holder above
```
If it disagrees with the skeleton's copy, the skeleton's id is stale — use the live one.
**`status` exits 1 when the lock is held-fresh, by design** (it's an "is the lock free?"
predicate) — don't read that as a failure, and guard it under `&&` / `set -e`
(`… status || [ $? -eq 1 ]`, as `ship-up.sh` does).

Those invocations are spelled out on purpose. Don't collapse them into a
`LOCKER="python3 …"` variable and then run `$LOCKER status` — **zsh does not word-split an
unquoted variable**, so it tries to exec the whole string as a single filename and dies with
`no such file or directory`. `ship-up.sh` gets away with that idiom only because it is
`#!/bin/bash`.

### Preflight first if you're unsure. It is safe.

```bash
modules/autonomous/scripts/ship-up.sh --check    # the DEFAULT mode: preflight + report, NO launch
```
`--check` runs the whole preflight and prints the launch command **without launching or
touching the lock**. There is no `--dry-run` for `--rotate-mate` itself: **`--rotate-mate`
launches and releases for real.** Use `--check` to satisfy yourself the preflight is GO,
then rotate.

### Then rotate for real

```bash
SHIP_MATE_MODEL=<model> modules/autonomous/scripts/ship-up.sh --rotate-mate   # omit SHIP_MATE_MODEL to take the CLI default
```

What it does for you, in order — **don't do these by hand**:
1. Preflight: hooks `+x` (self-heal), MCP config, lock cycle, launcher. **Refuses to rotate
   on NO-GO.**
2. **bgIsolation self-heal:** patches `.claude/settings.json` →
   `worktree.bgIsolation:"none"` (without it a fresh bg-Mate deadlocks — the isolation
   guard even blocks the write that would disable it). Fails LOUD on corrupt JSON rather
   than clobbering. Confirm you see `worktree.bgIsolation=none` in the output.
3. **Monitor orphan sweep:** kills orphaned `wake_monitor.py` **before** launching, so it
   can't reap the successor's fresh one. (Harness `TaskStop` halts a Monitor's session
   re-invocation but does not kill the detached OS process — hence the sweep.) Git-Bash has
   no `pkill`; the script falls back to PowerShell.
4. Launches the successor stdin-piped into `/ship-watch-start`.
5. Sleeps ~8s, then releases your lock.

⚠️ **Leave no helper running whose command line names a monitor.** The sweep matches
broadly and will correctly reap a rotation-watcher loop of yours if it mentions
`wake_monitor`.

⚠️ **The sweep only knows `wake_monitor.py`.** If your deployment arms other monitors (a
pager, a custom watch — see `ship-watch-start` step 4), sweep those yourself, by name,
**before** launching.

⚠️ **The +8s release is `--force`** (it deletes the lock regardless of holder). A successor
that boots in under 8s has already acquired, and the force-release then deletes *its* live
lock — leaving a running Mate and a free lock. Phase 4 catches this; the fix is one
`acquire` (below), not a relaunch.

**The Bosun is INHERITED, not relaunched.** The successor's `launch-bosun.sh --ensure` is a
no-op while the heartbeat is fresh. Don't kill it, and don't pre-launch one.

## Phase 4 — VERIFY (did the successor actually take the deck?)

`ship-up.sh` launches, sleeps 8s, and releases the lock **without checking the successor
came up.** A silently-failed launch leaves a released lock and no Mate. **This phase is the
gap; don't skip it.**

```bash
claude agents                                                    # the successor is listed
python3 modules/autonomous/scripts/mate-lock.py status           # held by the NEW id, FRESH
bash modules/autonomous/scripts/launch-bosun.sh --check          # heartbeat FRESH (inherited)
python3 -c "import json;print(json.load(open('state/status.json'))['generated_at'])"   # advances after the successor's boot
```
🔴 **`launch-bosun.sh --check` exits 1 only when the heartbeat file is ABSENT.** A heartbeat that is
present but STALE — a Bosun that died an hour ago and left its log on disk — **exits 0**. Measured:
absent → 1 · present+stale → **0** · fresh → 0. So a Mate that trusts the exit code passes this gate on
a dead Bosun. **Read the printed verdict (`FRESH — ticking` vs `STALE/absent — NOT ticking`), never the
exit code alone.**

### 🔴 Count monitors with an ANCHORED match, never `pgrep -f` / a bare `ps | grep`

```bash
# CORRECT (POSIX) — anchored on the interpreter at argv[0]
ps -eo command= | grep -ciE "^[^ ]*python[^ ]* .*wake_monitor\.py"
```
```bash
# CORRECT (Windows / Git-Bash — no `ps -eo command=`) — same anchor, via CIM.
# \$_ is escaped so the SHELL doesn't expand it before PowerShell sees it (as ship-up.sh does).
powershell.exe -NoProfile -Command "(Get-CimInstance Win32_Process | Where-Object {\$_.CommandLine -match '^\S*python\S* .*wake_monitor\.py'} | Measure-Object).Count"
```
`pgrep -f` and a bare `ps | grep` match the **whole command line**, which includes the
shell wrapper that launched it, any helper that merely *names* it, and the grep process
itself. Measured on one healthy monitor: the naive `ps | grep -c` returned **2**, then
**3** once an unrelated helper mentioned the name — both a hair from reporting a
duplicate-monitor incident that did not exist. The anchored form returned **1** both times.

**Asymmetric on purpose: fix the COUNTING, keep the broad KILL.** A narrow `pkill` that
misses a real orphan leaves two monitors double-acking every wake, which is far worse than
sweeping a helper.

**Add a positive control before believing a zero.** Drop the script name and confirm the
instrument can see *something* first (`ps -eo command= | grep -ciE "^[^ ]*python[^ ]* "`) —
an empty result from an uncalibrated match is not evidence of absence. Interpreter names and
paths vary (`python3` · `/usr/bin/python3` · `python3.12` · a version-managed shim ·
`python.exe`), which is exactly why the anchor is `^[^ ]*python[^ ]*` and not `^python3`.
**And it MUST be case-insensitive (`-ciE`).** On stock macOS a **bare `python3`** — the very invocation
`ship-watch-start` step 4 prescribes — resolves to the Xcode CLT framework binary, which `ps` renders as
`…/MacOS/`**`P`**`ython`. Measured: with three live probes the case-sensitive form matched **1 of 3**.
A missed count reads as **0 monitors**, so the Mate arms a second one and both double-ack every wake —
the exact failure the broad-kill asymmetry exists to prevent, reached from the other side. `-i` also
makes this agree with the PowerShell form below, whose `-match` is case-insensitive by default.

### If verification fails

- **Successor up but the lock is FREE** — the +8s force-release ate its lock. Don't
  relaunch (that would give you two Mates). Have the successor re-acquire:
  `python3 modules/autonomous/scripts/mate-lock.py acquire <its-session-id>`.
- **Successor did NOT come up** — relaunch with
  `modules/autonomous/scripts/ship-up.sh --launch-mate`. There is no auto-relaunch on Mate
  crash; the Bosun can detect a stale lock and drop a wake, but it is read-only and
  hook-blocked from running `claude`, so it cannot launch a Mate.

---

## Then stop

Once the successor holds a FRESH lock and the Bosun is ticking, **your watch is over.** Do
not keep working, do not re-arm monitors, do not schedule a wakeup. Say plainly that the
deck is handed over, and stop. Two Mates believing they hold the deck is the failure this
whole mechanism exists to prevent.

## Bounds
- Run **once** per rotation. Never loop this skill.
- The wind-down ceremony (log close, handoff notes, standup, compound) happens **before** —
  not here.
- The successor's boot is `ship-watch-start`'s job. Don't duplicate its preflight.
- **A stale prior lock at the successor's boot is EXPECTED**, not an incident — an
  event-driven Mate doesn't beat the heartbeat, so a plain `acquire` takes over cleanly.
- Bright lines are unchanged and hook-enforced throughout. A rotation is internal ship
  work; it needs no operator confirmation unless they asked to be consulted on the model
  call.

## Reference
(Ship-root-relative — this file is installed outside the ship, so read them from there.)
- `modules/autonomous/mate-event-driven.md` — rotation as the session-lifecycle primitive;
  the single-instance + lock invariant
- `modules/night-economy/night-economy.md` — the day/night model cadence and
  self-escalation license, if you run it
- `core/mate.md` → "Sessions and Logs" — the wind-down ceremony that precedes this
- `DECISIONS.md` — the scars behind the traps above
