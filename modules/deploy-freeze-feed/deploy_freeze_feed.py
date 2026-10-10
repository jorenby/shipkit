#!/usr/bin/env python3
"""Out-of-session sensor: a critical deploy alert that fired but went unattended becomes a classified candidate drop."""

import hashlib
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
SHIP_ROOT = Path(os.environ.get("SHIP_ROOT", HERE.parents[1])).resolve()
SENSOR_HOME = Path(os.environ.get("SHIP_SENSOR_LOG_DIR", Path.home() / ".ship-sensors"))
DROPS_DIR = Path(os.environ.get("SENSOR_DROPS_DIR", SHIP_ROOT / "inbox" / "drops"))
STATE_PATH = Path(os.environ.get("DEPLOY_FREEZE_STATE_PATH", SENSOR_HOME / "deploy_freeze_feed_state.json"))
SIGNAL_PATH = Path(os.environ.get("DEPLOY_FREEZE_SIGNAL_PATH", SENSOR_HOME / "deploy_freeze_signal.json"))
POLL_SECS = float(os.environ.get("DEPLOY_FREEZE_POLL_SECS", "60"))

FEED_SOURCE = "deploy-freeze-watch"

sys.path.insert(0, str(HERE.parents[1] / "lib"))
from classify_input import classify  # noqa: E402


def main():
    seen = load_state()
    while True:
        seen, result = poll(seen)
        save_state(seen)
        if result is not None:
            print(
                f"SENSOR {FEED_SOURCE} {result['classification']} "
                f"{'new' if result['first_seen'] else 'redrop'} {result['path']}",
                flush=True,
            )
        time.sleep(POLL_SECS)


def load_state():
    try:
        raw = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    active = raw.get("active", {})
    if isinstance(active, dict):
        return {str(k): str(v) for k, v in active.items()}
    return {}


def poll(seen):
    """One sensing cycle. seen maps open-incident id -> its candidate filename; result is None when nothing was emitted."""
    signal = read_signal()
    if signal is None:
        seen.clear()
        return seen, None

    ident = signal_identity(signal)
    prior_name = seen.get(ident)
    if prior_name is not None and (DROPS_DIR / prior_name).is_file():
        return seen, None

    first_seen = ident not in seen
    name = drop_name(signal, first_seen)
    path = write_candidate(build_envelope(signal, first_seen), name)
    seen[ident] = name
    return seen, {"path": str(path), "classification": classify(str(path)), "first_seen": first_seen}


def read_signal():
    # The SENSE adapter: whatever watches your alert channel or CI writes this snapshot file.
    try:
        raw = SIGNAL_PATH.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict) or not data.get("critical_unattended"):
        return None
    return data


def signal_identity(signal):
    ident = signal.get("incident_id")
    if ident:
        return str(ident)
    basis = "|".join(str(signal.get(k, "")) for k in ("channel", "condition", "fired_at"))
    return hashlib.sha1(basis.encode("utf-8")).hexdigest()


def drop_name(signal, first_seen):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d-%H%M%S")
    suffix = "critical" if first_seen else "redrop"
    return f"{ts}-{FEED_SOURCE}-{signal_identity(signal)[:8]}-{suffix}.md"


def build_envelope(signal, first_seen):
    # First observation wakes; a re-observation of the same open condition is a batch sensor-redrop.
    if first_seen:
        kind, wake_class, headline = "steer", "wake", "Unattended critical deploy signal detected"
    else:
        kind, wake_class, headline = "sensor-redrop", "batch", "Unattended critical deploy signal STILL open (re-observed)"

    front = [
        "---",
        "shipkit_input: v1",
        f"source: {FEED_SOURCE}",
        f"kind: {kind}",
        f"wake_class: {wake_class}",
        f"incident_id: {signal_identity(signal)}",
        "---",
    ]
    body = [
        f"# {headline}",
        "",
        f"- **Condition:** {signal.get('condition', 'deploy pipeline freeze')}",
        f"- **Channel:** {signal.get('channel') or '(unspecified)'}",
        f"- **Fired at:** {signal.get('fired_at', 'unknown')}",
        "- **Status:** critical alert fired but unattended (unacknowledged in-channel)",
    ]
    if signal.get("link"):
        body.append(f"- **Link:** {signal['link']}")
    body += [
        "",
        "A critical deploy-pipeline condition fired into its alert channel and has not been "
        "acknowledged. Surfacing into the agent loop as a queue candidate; a human decides "
        "whether it is worth acting on.",
    ]
    return "\n".join(front + body) + "\n"


def write_candidate(envelope, name):
    DROPS_DIR.mkdir(parents=True, exist_ok=True)
    path = DROPS_DIR / name
    path.write_text(envelope, encoding="utf-8")
    return path


def save_state(seen):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_name(STATE_PATH.name + ".tmp")
    tmp.write_text(json.dumps({"active": dict(sorted(seen.items()))}), encoding="utf-8")
    os.replace(str(tmp), str(STATE_PATH))


if __name__ == "__main__":
    main()
