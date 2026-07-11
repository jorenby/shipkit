#!/usr/bin/env python3
"""wake_monitor.py — the Loop-Mode wake-monitor (the companion to
modules/wake-monitor/wake-monitor.md).

Run it UNDER the harness Monitor tool (or any supervisor that treats each stdout
line as a wake event). It polls the Mate's directive surfaces and prints ONE
line per `wake`-class net-new item — nothing else ever goes to stdout, because
the supervisor turns every stdout line into a loop wake. Bookkeeping (`batch`)
and noise (`silent`) are recorded in the seen-set so they never re-fire, but are
NOT printed — they drain at the next tick's reconcile pass.

Surfaces watched (the directive surfaces from modules/wake-monitor/wake-monitor.md §contract):
  - inbox/drops/*.md, *.json  — external producers + the status-surface UI.
      Deduped by a seen-set of BASENAMES; wake on net-new `wake`-class only
      (classified through classify_input.py so a declared `wake_class` is honored
      verbatim). Once a basename is seen it stays seen, so the loop moving a drop
      to inbox/drops/processed/ never re-fires it (pitfall #2: dedup by name, not
      count).
  - inbox/captain.md           — the Captain's inbox.
      Keyed by content-line HASHES; wake only on ADDED content lines. The Mate
      clears the inbox by REMOVING lines, which can only shrink the content set,
      so a clear structurally cannot self-wake (pitfall #4 solved by construction,
      no authorship heuristic needed).

Startup is silent: the first run baselines whatever is already present WITHOUT
emitting, so pre-existing drops / inbox content don't fire a spurious wake. The
seen-set is persisted (state/.wake_monitor_state.json) so a monitor restart /
post-compaction re-arm resumes without re-firing.

Env:
  SHIP_ROOT       ship root (default: modules/wake-monitor/ -> up 2)
  WAKE_POLL_SECS  poll interval seconds (default: 8)
"""

import hashlib
import json
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SHIP_ROOT = Path(os.environ.get("SHIP_ROOT", HERE.parents[1])).resolve()
DROPS_DIR = SHIP_ROOT / "inbox" / "drops"
CAPTAIN_INBOX = SHIP_ROOT / "inbox" / "captain.md"
STATE_PATH = SHIP_ROOT / "state" / ".wake_monitor_state.json"
POLL_SECS = float(os.environ.get("WAKE_POLL_SECS", "8"))

# Import the canonical classifier from shared lib/ so a declared `wake_class` is honored
# verbatim (no second, drifting copy of the wake/batch/silent ladder lives here).
sys.path.insert(0, str(HERE.parents[1] / "lib"))
from classify_input import classify  # noqa: E402


def _content_line_hashes(text):
    """Hashes of the inbox's *directive* lines — blanks, headings, blockquotes,
    HTML comments and `---` rules are template scaffolding, not directives."""
    out = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ">", "<!--", "---")):
            continue
        out.add(hashlib.sha1(line.encode("utf-8")).hexdigest())
    return out


def _enumerate_drops():
    """Net-new drop files by basename. Python globbing returns empty cleanly —
    no shell-nomatch abort footgun (pitfall #1)."""
    if not DROPS_DIR.is_dir():
        return {}
    found = {}
    for pat in ("*.md", "*.json"):
        for p in DROPS_DIR.glob(pat):
            if p.is_file():
                found[p.name] = p
    return found


def _load_state():
    try:
        raw = json.loads(STATE_PATH.read_text(encoding="utf-8"))
        return set(raw.get("drops", [])), set(raw.get("captain_lines", []))
    except (FileNotFoundError, json.JSONDecodeError):
        return None, None  # None => uninitialized => baseline silently


def _save_state(seen_drops, seen_lines):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(
        json.dumps({"drops": sorted(seen_drops), "captain_lines": sorted(seen_lines)}),
        encoding="utf-8",
    )


def _emit(reason):
    # The ONLY thing that ever reaches stdout — each line is a loop wake.
    print(f"WAKE {reason}", flush=True)


def poll(seen_drops, seen_lines):
    """One poll pass. Returns (seen_drops, seen_lines, woke_bool)."""
    woke = False

    # --- drops: wake on net-new wake-class basenames ---
    current = _enumerate_drops()
    for name in sorted(current):
        if name in seen_drops:
            continue
        seen_drops.add(name)  # record regardless of class (never re-fire)
        try:
            cls = classify(str(current[name]))
        except Exception:
            cls = "wake"  # default-to-wake on a classifier error
        if cls == "wake":
            _emit(f"drop {name}")
            woke = True

    # --- captain.md: wake on ADDED directive lines only ---
    if CAPTAIN_INBOX.is_file():
        text = CAPTAIN_INBOX.read_text(encoding="utf-8", errors="replace")
        for h in _content_line_hashes(text):
            if h not in seen_lines:
                seen_lines.add(h)
                if not woke:  # one wake per pass is enough to start a tick
                    _emit("captain-inbox edited")
                woke = True

    return seen_drops, seen_lines, woke


def main():
    seen_drops, seen_lines = _load_state()
    if seen_drops is None:
        # Baseline silently: absorb everything currently present, emit nothing.
        seen_drops = set(_enumerate_drops().keys())
        seen_lines = set()
        if CAPTAIN_INBOX.is_file():
            seen_lines = _content_line_hashes(
                CAPTAIN_INBOX.read_text(encoding="utf-8", errors="replace")
            )
        _save_state(seen_drops, seen_lines)

    while True:
        seen_drops, seen_lines, woke = poll(seen_drops, seen_lines)
        if woke:
            _save_state(seen_drops, seen_lines)
        else:
            # Persist occasionally so newly-absorbed batch/silent items survive
            # a restart even on quiet passes.
            _save_state(seen_drops, seen_lines)
        time.sleep(POLL_SECS)


if __name__ == "__main__":
    main()
