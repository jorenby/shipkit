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
        self.assertEqual(r.returncode, 1)  # held-fresh => exit 1
        data = json.loads(r.stdout)
        self.assertEqual(data["state"], "held")
        self.assertEqual(data["holder"], "sess-1")
        self.assertTrue(data["fresh"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
