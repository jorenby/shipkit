#!/usr/bin/env python3
"""Tests for modules/autonomous/scripts/bosun_emit.py — the path-locked Bosun write helper.

Runs bosun_emit.py as a subprocess with SHIP_ROOT pointed at a temp dir, and confirms the
three writes land at the hard-coded paths and that a drop is a wake-class declared input.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "scripts" / "bosun_emit.py"
CLASSIFY = HERE.parents[2] / "lib" / "classify_input.py"


def run(script, args, ship_root):
    env = dict(os.environ, SHIP_ROOT=str(ship_root))
    return subprocess.run([sys.executable, str(script), *args],
                          capture_output=True, text=True, env=env)


class TestBosunEmit(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_heartbeat_appends_line(self):
        run(SCRIPT, ["heartbeat", "alive"], self.root)
        run(SCRIPT, ["heartbeat", "still alive"], self.root)
        hb = (self.root / "state" / "bosun-heartbeat.log").read_text()
        self.assertEqual(len([l for l in hb.splitlines() if l.strip()]), 2)
        self.assertIn("alive", hb)

    def test_cursor_overwrites_with_stamp(self):
        run(SCRIPT, ["cursor", '{"prs":[1,2]}'], self.root)
        cur = json.loads((self.root / "state" / "bosun-last-sweep.json").read_text())
        self.assertEqual(cur["prs"], [1, 2])
        self.assertIn("_updated", cur)

    def test_cursor_rejects_bad_json(self):
        r = run(SCRIPT, ["cursor", "not json"], self.root)
        self.assertEqual(r.returncode, 2)

    def test_drop_is_wake_class(self):
        run(SCRIPT, ["drop", "CI red", "PR #5 CI failed", "fix it"], self.root)
        drops = list((self.root / "inbox" / "drops").glob("bosun-*.md"))
        self.assertEqual(len(drops), 1)
        body = drops[0].read_text()
        self.assertIn("wake_class: wake", body)
        self.assertIn("CI red", body)
        # And it classifies as wake through the canonical classifier.
        r = subprocess.run([sys.executable, str(CLASSIFY), str(drops[0])],
                           capture_output=True, text=True)
        self.assertEqual(r.stdout.strip(), "wake")

    def test_unknown_subcommand_errors(self):
        r = run(SCRIPT, ["nope"], self.root)
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
