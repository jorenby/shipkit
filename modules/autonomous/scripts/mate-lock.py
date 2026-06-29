#!/usr/bin/env python3
"""mate-lock.py — Mate session lock: acquire / heartbeat / release / status.

The stdlib-only, cross-platform twin of mate-lock.rb (identical contract + lock-file
format, so the two are interchangeable — use whichever runtime your box has). Prevents
two Mate sessions writing queue.md at once. A stale lock (heartbeat older than
STALE_MINUTES) is auto-taken-over on acquire, which is the common case when an
event-driven Mate's prior session didn't beat the heartbeat before rotating.

Lock file: state/mate-lock.json  {session_id, acquired_at, heartbeat_at}
Atomic writes: tmp file + os.replace (atomic on the same filesystem).

Subcommands:
  acquire   SESSION_ID            take the lock; fails if held fresh by another.
                                  Succeeds with TAKEOVER if the held lock is stale.
  heartbeat SESSION_ID            stamp heartbeat_at; fails unless SESSION_ID holds it.
  release   SESSION_ID [--force]  release; --force releases unconditionally (warns).
  status    [--json]              print state; exit 0 (free/stale) / 1 (held-fresh).

Env overrides (for testing):
  LOCK_FILE=/tmp/test-lock.json   STALE_MINUTES=1
"""
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LOCK_FILE = Path(os.environ.get("LOCK_FILE", ROOT / "state" / "mate-lock.json"))
STALE_MINUTES = int(os.environ.get("STALE_MINUTES", "45"))


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse(ts):
    # Accept the trailing-Z form this script writes plus ISO offsets.
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def read_lock():
    try:
        return json.loads(LOCK_FILE.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def write_lock(data):
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = LOCK_FILE.with_suffix(f".json.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data), encoding="utf-8")
    os.replace(tmp, LOCK_FILE)


def delete_lock():
    try:
        LOCK_FILE.unlink()
    except FileNotFoundError:
        pass


def _age_minutes(ts):
    try:
        return (datetime.now(timezone.utc) - _parse(ts)).total_seconds() / 60.0
    except (ValueError, TypeError):
        return None


def is_stale(lock):
    if lock is None:
        return True
    hb = lock.get("heartbeat_at") or lock.get("acquired_at")
    age = _age_minutes(hb)
    return True if age is None else age > STALE_MINUTES


def age_string(ts):
    age = _age_minutes(ts)
    if age is None:
        return "unknown"
    return f"{round(age)}m" if age < 60 else f"{round(age / 60.0, 1)}h"


def cmd_acquire(session_id):
    if not session_id:
        sys.stderr.write("ERROR: acquire requires a session_id argument\n")
        return 2
    lock = read_lock()

    if lock is None:
        write_lock({"session_id": session_id, "acquired_at": now_iso(), "heartbeat_at": now_iso()})
        print(f"ACQUIRED {session_id}")
        return 0

    if lock.get("session_id") == session_id:
        lock["heartbeat_at"] = now_iso()
        write_lock(lock)
        print(f"ACQUIRED (re-entrant) {session_id}")
        return 0

    if is_stale(lock):
        old_id = lock.get("session_id")
        hb = lock.get("heartbeat_at") or lock.get("acquired_at")
        write_lock({"session_id": session_id, "acquired_at": now_iso(), "heartbeat_at": now_iso()})
        print(f"TAKEOVER — prior session {old_id} last heartbeat {age_string(hb)} ago (>{STALE_MINUTES}m stale)")
        print(f"ACQUIRED {session_id}")
        return 0

    hb = lock.get("heartbeat_at") or lock.get("acquired_at")
    sys.stderr.write(f"LOCK HELD by session {lock.get('session_id')} (heartbeat {age_string(hb)} ago — fresh)\n")
    sys.stderr.write(f"Cannot acquire. If the prior session is truly dead, wait {STALE_MINUTES}m for stale-takeover.\n")
    return 1


def cmd_heartbeat(session_id):
    if not session_id:
        sys.stderr.write("ERROR: heartbeat requires a session_id argument\n")
        return 2
    lock = read_lock()
    if lock is None:
        sys.stderr.write(f"ERROR: no lock held — cannot heartbeat session {session_id}\n")
        return 1
    if lock.get("session_id") != session_id:
        sys.stderr.write(f"ERROR: lock held by {lock.get('session_id')}, not {session_id} — cannot heartbeat\n")
        return 1
    lock["heartbeat_at"] = now_iso()
    write_lock(lock)
    print(f"HEARTBEAT {session_id} at {lock['heartbeat_at']}")
    return 0


def cmd_release(session_id, force):
    if not session_id:
        sys.stderr.write("ERROR: release requires a session_id argument\n")
        return 2
    lock = read_lock()
    if lock is None:
        print("RELEASED (was already free)")
        return 0
    if lock.get("session_id") == session_id:
        delete_lock()
        print(f"RELEASED {session_id}")
        return 0
    if force:
        sys.stderr.write(f"WARNING: --force releasing lock held by {lock.get('session_id')} (you are {session_id})\n")
        delete_lock()
        print(f"RELEASED (forced) by {session_id}")
        return 0
    sys.stderr.write(f"ERROR: lock held by {lock.get('session_id')}, not {session_id}\n")
    sys.stderr.write("Use --force to override (prints a warning).\n")
    return 1


def cmd_status(json_output):
    lock = read_lock()
    if lock is None:
        if json_output:
            print(json.dumps({"state": "free", "holder": None, "age": None, "fresh": False}))
        else:
            print("STATE: free")
            print("No lock held.")
        return 0

    hb = lock.get("heartbeat_at") or lock.get("acquired_at")
    fresh = not is_stale(lock)
    if json_output:
        print(json.dumps({
            "state": "held", "holder": lock.get("session_id"),
            "acquired_at": lock.get("acquired_at"), "heartbeat_at": lock.get("heartbeat_at"),
            "age": age_string(hb), "fresh": fresh, "stale_minutes": STALE_MINUTES,
        }))
    else:
        print("STATE: held")
        print(f"Holder:       {lock.get('session_id')}")
        print(f"Acquired:     {lock.get('acquired_at')}")
        print(f"Last beat:    {lock.get('heartbeat_at')} ({age_string(hb)} ago)")
        print(f"Freshness:    {'FRESH (<' + str(STALE_MINUTES) + 'm)' if fresh else 'STALE (>' + str(STALE_MINUTES) + 'm)'}")
    # Exit 1 if held-fresh (caller can't infer "mine"); 0 if free or stale (takeover ok).
    return 1 if fresh else 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("Usage: mate-lock.py <acquire|heartbeat|release|status> [session_id] [--force] [--json]\n")
        return 2
    subcmd = argv[1]
    arg1 = argv[2] if len(argv) > 2 else None
    flags = argv[3:]
    force = "--force" in flags
    json_flag = (arg1 == "--json") or ("--json" in flags)

    if subcmd == "acquire":
        return cmd_acquire(arg1)
    if subcmd == "heartbeat":
        return cmd_heartbeat(arg1)
    if subcmd == "release":
        return cmd_release(arg1, force)
    if subcmd == "status":
        return cmd_status(json_flag)
    sys.stderr.write("Usage: mate-lock.py <acquire|heartbeat|release|status> [session_id] [--force] [--json]\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
