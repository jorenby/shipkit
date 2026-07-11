#!/usr/bin/env python3
"""wake_monitor_native.py — OPTIONAL native filesystem-watch fast path for the
Loop-Mode wake-monitor. A LOCAL OPT-IN, NOT the shipped default.

shipkit ships `modules/wake-monitor/wake_monitor.py` — a zero-dependency, cross-platform,
stdlib-only POLL loop (default 8s) — as THE wake-monitor. It matches the
toolkit's "stdlib only, cross-platform" posture and is the version
`ship-watch-start` arms. This file is a separate EXPERIMENT for operators who
find the ~8s poll latency on steers annoying on a local box and are willing to
take a third-party dependency for lower latency.

It is identical in BEHAVIOR to the poll version — same surfaces, same dedup,
same classify-before-wake, same silent baseline, same persisted seen-set, same
"WAKE <reason>" stdout contract — it just *triggers* a re-check on a real
filesystem event (via `watchdog`) instead of on a fixed timer. It still runs a
slow safety poll underneath so a missed/coalesced event can't strand a steer.

DEPENDENCY (the whole reason this is opt-in):
    pip install watchdog
If `watchdog` is not importable, this script prints a clear note and exits
non-zero WITHOUT falling back silently — so you never *think* you have the fast
path when you're actually running nothing. Use the shipped poll version
(`modules/wake-monitor/wake_monitor.py`) if you don't want the dependency.

This module reuses `wake_monitor.poll()` / `_load_state()` / etc. verbatim —
there is no second, drifting copy of the wake/batch/silent ladder or the
seen-set logic. It only swaps the *scheduling* of poll passes.

Env (shared with wake_monitor.py):
    SHIP_ROOT            ship root (default: modules/wake-monitor/ -> up 2)
    WAKE_POLL_SECS       safety-poll interval seconds (default: 30 here — the
                         event watch handles latency; the poll is just a net)
    WAKE_DEBOUNCE_SECS   coalesce a burst of fs events into one poll (default 0.4)
"""

import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

# Reuse the canonical poll/state logic — one source of truth, no drift.
import wake_monitor as wm  # noqa: E402


def _require_watchdog():
    try:
        from watchdog.observers import Observer  # noqa: F401
        from watchdog.events import FileSystemEventHandler  # noqa: F401
        return True
    except Exception:
        sys.stderr.write(
            "wake_monitor_native: `watchdog` is not installed. This is the "
            "OPTIONAL native fast path; install it with `pip install watchdog`, "
            "or use the shipped zero-dep poll version: modules/wake-monitor/wake_monitor.py\n"
        )
        return False


def main() -> int:
    if not _require_watchdog():
        return 1

    from watchdog.observers import Observer
    from watchdog.events import FileSystemEventHandler

    debounce = float(os.environ.get("WAKE_DEBOUNCE_SECS", "0.4"))
    # The event watch carries latency; the poll underneath is just a safety net,
    # so default it slower than the pure-poll monitor's 8s.
    safety_poll = float(os.environ.get("WAKE_POLL_SECS", "30"))

    # Same silent-baseline + persisted-seen-set bootstrap as the poll monitor.
    seen_drops, seen_lines = wm._load_state()
    if seen_drops is None:
        seen_drops = set(wm._enumerate_drops().keys())
        seen_lines = set()
        if wm.CAPTAIN_INBOX.is_file():
            seen_lines = wm._content_line_hashes(
                wm.CAPTAIN_INBOX.read_text(encoding="utf-8", errors="replace")
            )
        wm._save_state(seen_drops, seen_lines)

    # A tiny dirty-flag the fs-event handler sets and the main loop drains.
    state = {"dirty": False, "last_event": 0.0}

    class _Bump(FileSystemEventHandler):
        def on_any_event(self, event):
            state["dirty"] = True
            state["last_event"] = time.monotonic()

    # Watch the two directive surfaces' parent dirs (recursive=False is enough;
    # both live directly under inbox/). Create them if absent so the observer
    # has something to schedule — the poll handles anything we still miss.
    inbox = wm.SHIP_ROOT / "inbox"
    drops = wm.DROPS_DIR
    inbox.mkdir(parents=True, exist_ok=True)
    drops.mkdir(parents=True, exist_ok=True)

    observer = Observer()
    handler = _Bump()
    observer.schedule(handler, str(inbox), recursive=False)
    observer.schedule(handler, str(drops), recursive=False)
    observer.start()

    last_poll = 0.0
    try:
        while True:
            now = time.monotonic()
            fire = False
            # Debounced fs event: poll once the burst has settled.
            if state["dirty"] and (now - state["last_event"]) >= debounce:
                state["dirty"] = False
                fire = True
            # Safety net: poll on the slow timer regardless.
            if (now - last_poll) >= safety_poll:
                fire = True
            if fire:
                last_poll = now
                seen_drops, seen_lines, woke = wm.poll(seen_drops, seen_lines)
                wm._save_state(seen_drops, seen_lines)
            time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    finally:
        observer.stop()
        observer.join()
    return 0


if __name__ == "__main__":
    sys.exit(main())
