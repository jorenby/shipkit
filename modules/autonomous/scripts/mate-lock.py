#!/usr/bin/env python3
"""mate-lock.py — Mate session lock: acquire / heartbeat / release / status.

Stdlib-only and cross-platform. Prevents two Mate sessions writing queue.md at
once. A stale lock (heartbeat older than
STALE_MINUTES) is auto-taken-over on acquire, which is the common case when an
event-driven Mate's prior session didn't beat the heartbeat before rotating.

Lock file: state/mate-lock.json  {session_id, acquired_at, heartbeat_at}
Atomic writes: tmp file + os.replace (atomic on the same filesystem).
Atomic ACQUIRE of a free lock: O_CREAT|O_EXCL (the kernel picks the winner).

Subcommands:
  acquire   SESSION_ID            take the lock; fails if held fresh by another.
                                  Succeeds with TAKEOVER if the held lock is stale.
  heartbeat SESSION_ID            stamp heartbeat_at; fails unless SESSION_ID holds it.
  release   SESSION_ID [--force]  release; --force releases unconditionally (warns).
  status    [SESSION_ID] [--json] print state. Exit code is an "is the lock
                                  acquirable by SESSION_ID?" predicate, NOT a
                                  command-success flag:
                                    0  free / stale / held-fresh by SESSION_ID (yours)
                                    1  held-fresh by a DIFFERENT session (blocked)
                                  No SESSION_ID => any held-fresh lock exits 1. A
                                  nonzero exit with a healthy "STATE: held" report
                                  is a signal, not a failure — guard it:
                                  `status "$id" || [ $? -eq 1 ]`. --json adds "mine".

Env overrides (for testing):
  LOCK_FILE=/tmp/test-lock.json   STALE_MINUTES=1
"""
import json
import os
import sys
import time
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


def create_lock_exclusive(data):
    """Create the lock file ONLY if it does not already exist. True = we created it.

    O_CREAT|O_EXCL is the load-bearing part: `read_lock() is None` followed by
    `write_lock()` is check-then-act, so two sessions can both read "free" and both
    write, and the second silently steals the first's lock. Only an exclusive create
    lets the kernel pick a single winner.
    (TOCTOU reported from a shipkit v2 fork, 2026-08.)
    """
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(LOCK_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
    except FileExistsError:
        return False
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(data))
    except Exception:
        delete_lock()  # never leave a zero-byte file that no reader can parse
        raise
    return True


def read_lock_settled(attempts=3, delay=0.05):
    """read_lock() with a short retry. A lock file that exists but won't parse is far
    more often a torn read of a lock being created RIGHT NOW than a corrupt one, so
    retry before concluding it is garbage and reclaiming it."""
    for i in range(attempts):
        lock = read_lock()
        if lock is not None:
            return lock
        if i + 1 < attempts:
            time.sleep(delay)
    return None


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
        entry = {"session_id": session_id, "acquired_at": now_iso(), "heartbeat_at": now_iso()}
        if create_lock_exclusive(entry):
            print(f"ACQUIRED {session_id}")
            return 0
        # The exclusive create lost: either a competitor won the same free-lock
        # window, or a stale/half-written file is sitting there. Re-read and fall
        # through to the re-entrant / stale / held-fresh paths with real state.
        lock = read_lock_settled()
        if lock is None:
            # Still unparseable after retries => genuinely corrupt. Reclaim it,
            # which is what read_lock()-returns-None did before this change.
            write_lock(entry)
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
        # Re-read-confirm. NARROWS this race; does NOT close it. Takeover is
        # unavoidably read-decide-write (there is no atomic compare-and-swap on a
        # filename), so two sessions can call the same lock stale in the same
        # instant; os.replace makes the LAST writer the real holder.
        #
        # The confirm only fires when a competitor's write lands INSIDE our
        # write->read window. Surviving interleaving: A writes, A confirms A, A
        # returns 0 and starts working; THEN B writes, B confirms B, B returns 0.
        # Two winners; the file names B; A is a ghost holder. A self-detects on its
        # next heartbeat (exit 1) and cannot clobber B on release — but it may have
        # acted in between. Closing this properly needs a mutex held across the whole
        # read-decide-write (e.g. an os.mkdir sidecar, atomic on every platform).
        confirmed = read_lock()
        if confirmed is None or confirmed.get("session_id") != session_id:
            winner = confirmed.get("session_id") if confirmed else "another session"
            sys.stderr.write(f"LOST TAKEOVER RACE — {winner} claimed the stale lock first\n")
            sys.stderr.write(f"Cannot acquire as {session_id}.\n")
            return 1
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


def cmd_status(json_output, session_id=None):
    lock = read_lock()
    if lock is None:
        if json_output:
            print(json.dumps({"state": "free", "holder": None, "age": None, "fresh": False, "mine": False}))
        else:
            print("STATE: free")
            print("No lock held.")
        return 0

    hb = lock.get("heartbeat_at") or lock.get("acquired_at")
    fresh = not is_stale(lock)
    mine = fresh and session_id is not None and lock.get("session_id") == session_id
    if json_output:
        print(json.dumps({
            "state": "held", "holder": lock.get("session_id"),
            "acquired_at": lock.get("acquired_at"), "heartbeat_at": lock.get("heartbeat_at"),
            "age": age_string(hb), "fresh": fresh, "mine": mine, "stale_minutes": STALE_MINUTES,
        }))
    else:
        print("STATE: held")
        print(f"Holder:       {lock.get('session_id')}")
        print(f"Acquired:     {lock.get('acquired_at')}")
        print(f"Last beat:    {lock.get('heartbeat_at')} ({age_string(hb)} ago)")
        print(f"Freshness:    {'FRESH (<' + str(STALE_MINUTES) + 'm)' if fresh else 'STALE (>' + str(STALE_MINUTES) + 'm)'}")
        if mine:
            print("Ownership:    yours (session matches)")
    # Exit code = "is this lock acquirable by session_id?"
    #   held-fresh by ANOTHER (or no id given) => 1 (blocked); else 0.
    return 1 if (fresh and not mine) else 0


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
        status_session = arg1 if (arg1 and not arg1.startswith("--")) else None
        return cmd_status(json_flag, status_session)
    sys.stderr.write("Usage: mate-lock.py <acquire|heartbeat|release|status> [session_id] [--force] [--json]\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
