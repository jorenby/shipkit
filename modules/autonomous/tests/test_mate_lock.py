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
from concurrent.futures import ThreadPoolExecutor
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

    def test_concurrent_acquire_free_single_winner(self):
        # Regression for the acquire-time race: read-then-write acquire lets many
        # racers all "win" a free lock. With O_EXCL, exactly one wins per round and
        # every loser exits 1 (never a false ACQUIRED).
        n = 32
        rounds = 40

        def acquire(sid):
            return sid, run(["acquire", sid], self.lock)

        for r in range(rounds):
            if self.lock.exists():
                self.lock.unlink()
            sessions = [f"cccc{r:04d}-0000-0000-0000-{i:012d}" for i in range(n)]
            with ThreadPoolExecutor(max_workers=n) as ex:
                results = list(ex.map(acquire, sessions))

            fresh_wins = [
                sid for sid, res in results
                if res.returncode == 0 and "ACQUIRED" in res.stdout
                and "re-entrant" not in res.stdout and "TAKEOVER" not in res.stdout
            ]
            holder = json.loads(self.lock.read_text(encoding="utf-8"))["session_id"]
            self.assertEqual(len(fresh_wins), 1,
                             f"round {r}: expected exactly one fresh winner, got {len(fresh_wins)}: {fresh_wins}")
            self.assertEqual(fresh_wins[0], holder,
                             f"round {r}: the sole fresh winner must be the recorded holder")
            for sid, res in results:
                if sid in fresh_wins:
                    continue
                self.assertEqual(res.returncode, 1,
                                 f"round {r}: loser should exit 1, got {res.returncode}: {res.stdout}{res.stderr}")
                self.assertNotIn("ACQUIRED", res.stdout.upper(),
                                 f"round {r}: loser must not report ACQUIRED: {res.stdout}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
