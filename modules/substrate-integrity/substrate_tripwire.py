#!/usr/bin/env python3
# substrate_tripwire.py -- out-of-session tripwire for tampering with the ship security
# substrate (the crew bash guards, the Edit-deny hook, the crew allow-list override, and the
# ship-* agent defs). DETECTION ONLY -- it blocks nothing; it SENSES a change to a watched
# file -> CANDIDATE wake drop so a human/Mate sees that a control was modified.
#
# Why it exists: validate-crew-bash.sh (Bash path) and ship-substrate-guard.sh (Edit path)
# RAISE THE BAR but do not fully close the guard-self-modification class -- an interpreter that
# writes a substrate path it does not name (`python3 evil.py`) reaches around both. This
# tripwire catches exactly that residual (ticket 041: bar-raising + detection, not OS-level
# closure). SENSE -> CANDIDATE drop; the classifier/agent loop decides what to do.
#
# Known inherent limits (this is detection-of-persistent-change, not transient-abuse detection):
#   - First run trusts current disk: a file ALREADY tampered at first baseline is adopted
#     silently. (Seeding from a known-good source would close this; not done yet.)
#   - Tamper-then-revert within one poll interval leaves no trace; two tampers between polls
#     coalesce into one drop reflecting the final state.
# The baseline itself is kept outside crew's write scope (see STATE_PATH) and a corrupt/unreadable
# baseline fires a wake rather than silently re-baselining -- so poisoning the record is not silent.

import hashlib
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
SHIP_ROOT = Path(os.environ.get("SHIP_ROOT", HERE.parents[1])).resolve()
HOME = Path(os.environ.get("HOME", str(Path.home())))
DROPS_DIR = Path(os.environ.get("SENSOR_DROPS_DIR", SHIP_ROOT / "inbox" / "drops"))
# The baseline lives OUTSIDE ~/code/** on purpose: it is the tripwire's integrity record, and
# a crew that could write it (crew's Edit/Write auto-allow ~/code/**) could poison the baseline
# to the tampered hash and silence the detector. Keeping it under ~/.claude/ puts it beyond
# crew's auto-write scope; its basename is also in the bash-guard + Edit-hook substrate sets.
STATE_PATH = Path(
    os.environ.get(
        "SUBSTRATE_TRIPWIRE_STATE_PATH",
        HOME / ".claude" / "ship" / "substrate_tripwire_state.json",
    )
)
POLL_SECS = float(os.environ.get("SUBSTRATE_TRIPWIRE_POLL_SECS", "60"))
FEED_SOURCE = "substrate-tripwire"


def watched_paths():
    # Colon-separated env override for tests; else the real substrate set.
    override = os.environ.get("SUBSTRATE_TRIPWIRE_PATHS")
    if override:
        return [Path(p) for p in override.split(":") if p]
    return [
        SHIP_ROOT / "scripts" / "validate-crew-bash.sh",
        SHIP_ROOT / "scripts" / "validate-readonly-bash.sh",
        SHIP_ROOT / "scripts" / "crew-allow-local.sh",
        SHIP_ROOT / "scripts" / "hooks" / "ship-substrate-guard.sh",
        HOME / ".claude" / "hooks" / "ship-substrate-guard.sh",
        HOME / ".claude" / "agents" / "ship-crew.md",
        HOME / ".claude" / "agents" / "ship-lookout.md",
        SHIP_ROOT / "agents" / "ship-crew.md",
        SHIP_ROOT / "agents" / "ship-lookout.md",
    ]


def file_hash(path):
    try:
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()
    except (FileNotFoundError, IsADirectoryError):
        return None  # missing/deleted -- itself a signal


def current_hashes():
    return {str(p): file_hash(p) for p in watched_paths()}


def load_baseline():
    # Returns (hashes, status). status is "missing" (legit first run -> baseline silently),
    # "corrupt" (baseline existed but is unreadable/invalid -> SUSPICIOUS, fire a wake rather
    # than silently re-trusting current disk, which would launder an in-flight tamper), or
    # "ok".
    if not STATE_PATH.exists():
        return None, "missing"
    try:
        raw = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None, "corrupt"
    hashes = raw.get("hashes")
    if not isinstance(hashes, dict):
        return None, "corrupt"
    return hashes, "ok"


def save_baseline(hashes):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps({"hashes": hashes}, sort_keys=True), encoding="utf-8")


def diff_hashes(baseline, current):
    # (path, kind, new_hash) for each watched file that changed since the baseline. The new
    # hash is folded into the identity so two distinct edits to the same file are distinct
    # incidents (distinct drop, not a same-name overwrite).
    changes = []
    for k in sorted(set(baseline) | set(current)):
        old, new = baseline.get(k), current.get(k)
        if old == new:
            continue
        kind = "appeared" if old is None else "deleted" if new is None else "modified"
        changes.append((k, kind, new))
    return changes


def build_envelope(changes):
    ident = hashlib.sha256(
        ";".join(f"{p}:{k}:{h}" for p, k, h in changes).encode()
    ).hexdigest()[:16]
    front = [
        "---",
        "shipkit_input: v1",
        f"source: {FEED_SOURCE}",
        "kind: steer",
        "wake_class: wake",
        f"incident_id: {ident}",
        "---",
    ]
    body = [
        "# Ship security-substrate file changed (tripwire)",
        "",
        "A watched control file was modified out of band. If this was an intentional "
        "Mate/Captain edit, acknowledge and re-baseline. If not, a crew or external process "
        "may have tampered with a guard -- treat as security-relevant.",
        "",
        "Changed files:",
    ]
    body += [f"- **{kind}**: `{path}`" for path, kind, _h in changes]
    return "\n".join(front + body) + "\n", ident


def drop_name(ident):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d-%H%M%S")
    return f"{ts}-{FEED_SOURCE}-{ident}.md"


def write_candidate(envelope, name):
    DROPS_DIR.mkdir(parents=True, exist_ok=True)
    path = DROPS_DIR / name
    path.write_text(envelope, encoding="utf-8")
    return path


def poll():
    # One cycle. Returns None on no-change or first-run baseline; else the drop path (str).
    current = current_hashes()
    baseline, status = load_baseline()
    if status == "missing":
        save_baseline(current)  # legit first run: establish baseline silently, no drop
        return None
    if status == "corrupt":
        # The integrity record is unreadable -- treat as suspicious, not as a fresh start,
        # so corrupting the baseline can't silently launder a tamper. Fire a wake, re-establish.
        changes = [(str(STATE_PATH), "baseline-unreadable", "")]
        envelope, ident = build_envelope(changes)
        path = write_candidate(envelope, drop_name(ident))
        save_baseline(current)
        return str(path)
    changes = diff_hashes(baseline, current)
    if not changes:
        return None
    envelope, ident = build_envelope(changes)
    path = write_candidate(envelope, drop_name(ident))
    save_baseline(current)  # fire once per change-set; re-baseline so we don't re-nag every poll
    return str(path)


def main():
    while True:
        result = poll()
        if result is not None:
            print(f"SENSOR {FEED_SOURCE} wake {result}", flush=True)
        time.sleep(POLL_SECS)


def run_once():
    result = poll()
    if result is not None:
        print(f"SENSOR {FEED_SOURCE} wake {result}", flush=True)


if __name__ == "__main__":
    if "--once" in sys.argv:
        run_once()
    else:
        main()
