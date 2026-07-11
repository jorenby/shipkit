#!/usr/bin/env python3
"""bosun_emit.py — the ONLY sanctioned write path for the ship-bosun agent.

The Bosun runs read-only on everything (no Write/Edit tools; validate-bosun-bash.sh
blocks raw file redirects / tee / dd / cp / mv). Its three legitimate writes all go
through here, and the target paths are HARD-CODED relative to the ship root — there is
no user-supplied path, so the Bosun physically cannot write anywhere else:

  heartbeat   -> state/bosun-heartbeat.log    (append proof-of-life line)
  cursor      -> state/bosun-last-sweep.json  (overwrite delta cursor)
  drop        -> inbox/drops/bosun-<utc>.md   (write one wake-class drop for the Mate)

All timestamps are computed here (never passed in) so they can't drift. Stdlib only.

SHIP_ROOT defaults to the ship root (modules/autonomous/scripts/ -> up 3); override with SHIP_ROOT env.
"""
import os
import sys
import json
from datetime import datetime, timezone
from pathlib import Path

SHIP_ROOT = Path(os.environ.get("SHIP_ROOT", Path(__file__).resolve().parents[3])).resolve()
HEARTBEAT = SHIP_ROOT / "state" / "bosun-heartbeat.log"
CURSOR = SHIP_ROOT / "state" / "bosun-last-sweep.json"
DROPS_DIR = SHIP_ROOT / "inbox" / "drops"


def _now_iso():
    return datetime.now(timezone.utc).astimezone().isoformat()


def _now_stamp():
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def cmd_heartbeat(args):
    """Append one proof-of-life line. Usage: heartbeat "<note>" """
    note = args[0] if args else ""
    HEARTBEAT.parent.mkdir(parents=True, exist_ok=True)
    with HEARTBEAT.open("a") as f:
        f.write(f"{_now_iso()}\t{note}\n")
    print(f"heartbeat appended: {HEARTBEAT}")


def cmd_cursor(args):
    """Overwrite the delta cursor. Usage: cursor '<json string>' """
    if not args:
        print("cursor: need a JSON string argument", file=sys.stderr)
        return 2
    try:
        obj = json.loads(args[0])
    except json.JSONDecodeError as e:
        print(f"cursor: invalid JSON ({e})", file=sys.stderr)
        return 2
    CURSOR.parent.mkdir(parents=True, exist_ok=True)
    obj["_updated"] = _now_iso()
    CURSOR.write_text(json.dumps(obj, indent=2) + "\n")
    print(f"cursor written: {CURSOR}")


def cmd_drop(args):
    """Write ONE wake-class drop for the Mate.
    Usage: drop "<title>" "<findings markdown>" "<suggested mate action>"

    The drop is stamped `wake_class: wake` so the wake-monitor / classifier routes
    it to the Mate (the Bosun only writes a drop when it warrants Mate action).
    """
    if len(args) < 2:
        print('drop: need "<title>" "<findings>" ["<action>"]', file=sys.stderr)
        return 2
    title = args[0]
    findings = args[1]
    action = args[2] if len(args) > 2 else "(Bosun did not specify — Mate to assess.)"
    DROPS_DIR.mkdir(parents=True, exist_ok=True)
    stamp = _now_stamp()
    path = DROPS_DIR / f"bosun-{stamp}.md"
    path.write_text(
        f"---\n"
        f"shipkit_input: v1\n"
        f"source: bosun\n"
        f"kind: comment\n"
        f"wake_class: wake\n"
        f"---\n\n"
        f"# Bosun sweep delta\n\n"
        f"**From:** Bosun (standalone bg loop)\n"
        f"**Time:** {_now_iso()}\n"
        f"**Title:** {title}\n\n"
        f"## Findings\n\n{findings}\n\n"
        f"## Suggested Mate action\n\n{action}\n"
    )
    print(f"drop written: {path}")


COMMANDS = {"heartbeat": cmd_heartbeat, "cursor": cmd_cursor, "drop": cmd_drop}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        print(f"usage: bosun_emit.py {{{'|'.join(COMMANDS)}}} ...", file=sys.stderr)
        return 2
    return COMMANDS[argv[1]](argv[2:]) or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
