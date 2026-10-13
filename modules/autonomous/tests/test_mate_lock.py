#!/usr/bin/env python3
"""Tests for modules/autonomous/scripts/mate-lock.py — acquire / heartbeat / release / status + takeover.

Runs mate-lock.py as a subprocess against a temp LOCK_FILE so it exercises the real CLI.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "scripts" / "mate-lock.py"


def run(args, lock_file, stale_minutes=None):
    env = dict(os.environ, LOCK_FILE=str(lock_file))
    if stale_minutes is not None:
        env["STALE_MINUTES"] = str(stale_minutes)
    return subprocess.run([sys.executable, str(SCRIPT), *args],
                          capture_output=True, text=True, env=env)


class TestMateLock(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.lock = Path(self.tmp.name) / "mate-lock.json"

    def tearDown(self):
        self.tmp.cleanup()

    def test_status_free_when_no_lock(self):
        r = run(["status"], self.lock)
        self.assertEqual(r.returncode, 0)
        self.assertIn("free", r.stdout)

    def test_acquire_fresh(self):
        r = run(["acquire", "sess-1"], self.lock)
        self.assertEqual(r.returncode, 0)
        self.assertIn("ACQUIRED sess-1", r.stdout)
        self.assertTrue(self.lock.exists())

    def test_reentrant_acquire(self):
        run(["acquire", "sess-1"], self.lock)
        r = run(["acquire", "sess-1"], self.lock)
        self.assertEqual(r.returncode, 0)
        self.assertIn("re-entrant", r.stdout)

    def test_other_fresh_holder_blocks(self):
        run(["acquire", "sess-1"], self.lock)
        r = run(["acquire", "sess-2"], self.lock)
        self.assertEqual(r.returncode, 1)
        self.assertIn("LOCK HELD", r.stderr)

    def test_stale_takeover(self):
        run(["acquire", "sess-1"], self.lock)
        r = run(["acquire", "sess-2"], self.lock, stale_minutes=0)
        self.assertEqual(r.returncode, 0)
        self.assertIn("TAKEOVER", r.stdout)
        self.assertIn("ACQUIRED sess-2", r.stdout)

    def test_heartbeat_requires_holder(self):
        run(["acquire", "sess-1"], self.lock)
        ok = run(["heartbeat", "sess-1"], self.lock)
        self.assertEqual(ok.returncode, 0)
        bad = run(["heartbeat", "sess-2"], self.lock)
        self.assertEqual(bad.returncode, 1)

    def test_release_by_holder_and_force(self):
        run(["acquire", "sess-1"], self.lock)
        wrong = run(["release", "sess-2"], self.lock)
        self.assertEqual(wrong.returncode, 1)
        forced = run(["release", "sess-2", "--force"], self.lock)
        self.assertEqual(forced.returncode, 0)
        self.assertFalse(self.lock.exists())

    def test_status_json_held_fresh_exit1(self):
        run(["acquire", "sess-1"], self.lock)
        r = run(["status", "--json"], self.lock)
        self.assertEqual(r.returncode, 1)  # held-fresh, no id given => exit 1
        data = json.loads(r.stdout)
        self.assertEqual(data["state"], "held")
        self.assertEqual(data["holder"], "sess-1")
        self.assertTrue(data["fresh"])
        self.assertFalse(data["mine"])

    def test_status_held_fresh_by_me_exit0(self):
        # The lock is held-fresh by MY session — status reports success (0),
        # not the "blocked" signal.
        run(["acquire", "sess-1"], self.lock)
        r = run(["status", "sess-1"], self.lock)
        self.assertEqual(r.returncode, 0)
        self.assertIn("STATE: held", r.stdout)
        self.assertIn("yours", r.stdout)

    def test_status_held_fresh_by_other_exit1(self):
        # Held-fresh by a DIFFERENT session => blocked => exit 1, mine=false.
        run(["acquire", "sess-1"], self.lock)
        r = run(["status", "sess-2", "--json"], self.lock)
        self.assertEqual(r.returncode, 1)
        data = json.loads(r.stdout)
        self.assertFalse(data["mine"])

    def test_status_held_fresh_by_me_json_mine_true(self):
        run(["acquire", "sess-1"], self.lock)
        r = run(["status", "sess-1", "--json"], self.lock)
        self.assertEqual(r.returncode, 0)
        data = json.loads(r.stdout)
        self.assertTrue(data["mine"])
        self.assertTrue(data["fresh"])

    def test_status_held_stale_exit0(self):
        # Stale lock (takeover available) => acquirable => exit 0, even with no id.
        run(["acquire", "sess-1"], self.lock)
        r = run(["status"], self.lock, stale_minutes=0)
        self.assertEqual(r.returncode, 0)
        data = json.loads(run(["status", "--json"], self.lock, stale_minutes=0).stdout)
        self.assertFalse(data["fresh"])


class TestMateLockRace(unittest.TestCase):
    """Concurrent-acquire races (reported from a v2 fork, 2026-08).

    cmd_acquire used to be read_lock() -> if None -> write_lock(), i.e. check-then-act:
    N sessions could all read "free" and all report ACQUIRED. Live rotation never hit it
    only because it is sequential (a new bg-Mate takes over a STALE lock rather than
    racing a live one) — that is luck about usage, not a property of the code.
    """

    RACERS = 16

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.lock = Path(self.tmp.name) / "mate-lock.json"

    def tearDown(self):
        self.tmp.cleanup()

    def _race(self, ids, stale_minutes=None):
        """Launch every acquire at once (all spawned before any is waited on)."""
        env = dict(os.environ, LOCK_FILE=str(self.lock))
        if stale_minutes is not None:
            env["STALE_MINUTES"] = str(stale_minutes)
        procs = [subprocess.Popen([sys.executable, str(SCRIPT), "acquire", i],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, env=env) for i in ids]
        out = []
        for sid, p in zip(ids, procs):
            stdout, stderr = p.communicate()
            out.append((sid, p.returncode, stdout, stderr))
        return out

    def test_concurrent_acquire_of_free_lock_has_exactly_one_winner(self):
        # Repeated: the pre-fix code only lost the race in ~40% of rounds (measured),
        # so a single round would be a weak detector. The fixed code is deterministic.
        for round_n in range(5):
            self.lock.unlink(missing_ok=True)
            ids = [f"r{round_n}-sess-{n}" for n in range(self.RACERS)]
            results = self._race(ids)
            winners = [sid for sid, rc, so, _ in results if rc == 0]
            self.assertEqual(len(winners), 1,
                             f"round {round_n}: expected exactly 1 winner, got {winners}")
            for sid, rc, _, _ in results:
                self.assertIn(rc, (0, 1), f"{sid} exited {rc}")
            holder = json.loads(self.lock.read_text(encoding="utf-8"))["session_id"]
            self.assertEqual(holder, winners[0])

    def test_concurrent_takeover_holder_matches_a_winner(self):
        # Seed a lock, then race everyone at it with STALE_MINUTES=0. Takeover has no
        # atomic compare-and-swap available, so this asserts the invariant the
        # re-read-confirm DOES buy: nobody reports success while the file names
        # someone else, and the file's holder is one of the reported winners.
        run(["acquire", "seed"], self.lock)
        ids = [f"sess-{n}" for n in range(self.RACERS)]
        results = self._race(ids, stale_minutes=0)
        winners = [sid for sid, rc, so, _ in results if rc == 0]
        self.assertGreaterEqual(len(winners), 1)
        holder = json.loads(self.lock.read_text(encoding="utf-8"))["session_id"]
        self.assertIn(holder, winners)
        for sid, rc, _, stderr in results:
            if rc == 1:
                self.assertIn("LOST TAKEOVER RACE", stderr)

    def test_exclusive_create_reports_loss_when_file_appears_first(self):
        # Direct unit check of the primitive: a second exclusive create must fail
        # rather than clobber.
        mod = _load_mate_lock(self.lock)
        self.assertTrue(mod.create_lock_exclusive({"session_id": "a"}))
        self.assertFalse(mod.create_lock_exclusive({"session_id": "b"}))
        self.assertEqual(json.loads(self.lock.read_text(encoding="utf-8"))["session_id"], "a")

    def test_stale_takeover_loser_backs_off(self):
        # Deterministic exercise of the re-read-confirm branch: a competitor writes
        # the lock in the window between our takeover write and our confirm read.
        mod = _load_mate_lock(self.lock, stale_minutes=0)
        self.lock.write_text(json.dumps({
            "session_id": "old", "acquired_at": "2000-01-01T00:00:00Z",
            "heartbeat_at": "2000-01-01T00:00:00Z"}), encoding="utf-8")
        real_write = mod.write_lock

        def write_then_get_beaten(data):
            real_write(data)
            real_write({"session_id": "competitor", "acquired_at": mod.now_iso(),
                        "heartbeat_at": mod.now_iso()})

        mod.write_lock = write_then_get_beaten
        self.assertEqual(mod.cmd_acquire("me"), 1)
        mod.write_lock = real_write
        self.assertEqual(json.loads(self.lock.read_text(encoding="utf-8"))["session_id"],
                         "competitor")

    def test_corrupt_lock_file_is_still_reclaimed(self):
        # Pre-change behavior: read_lock() returns None for unparseable JSON and the
        # lock is reclaimed. The exclusive create must not turn that into a deadlock.
        self.lock.write_text("{not json", encoding="utf-8")
        r = run(["acquire", "sess-1"], self.lock)
        self.assertEqual(r.returncode, 0)
        self.assertIn("ACQUIRED sess-1", r.stdout)
        self.assertEqual(json.loads(self.lock.read_text(encoding="utf-8"))["session_id"],
                         "sess-1")


def _load_mate_lock(lock_file, stale_minutes=None):
    """Import mate-lock.py as a module (hyphenated filename => load by path) bound to
    a temp LOCK_FILE, so tests can monkeypatch internals the CLI can't expose."""
    import importlib.util
    saved = {k: os.environ.get(k) for k in ("LOCK_FILE", "STALE_MINUTES")}
    os.environ["LOCK_FILE"] = str(lock_file)
    if stale_minutes is not None:
        os.environ["STALE_MINUTES"] = str(stale_minutes)
    try:
        spec = importlib.util.spec_from_file_location("mate_lock_under_test", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)  # module reads env at import time
    finally:
        # Don't leak the test env into the subprocess-based cases (run() inherits it).
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    return mod


if __name__ == "__main__":
    unittest.main(verbosity=2)
