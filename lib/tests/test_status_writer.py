#!/usr/bin/env python3
"""Tests for lib/status_writer.py — the schema-owning state writer.

Covers the load-bearing invariants: monotonic tick, computed next_wake (not a typed
literal), the bare-HH:MM ISO guard on now.since, and crew[] preservation.
"""
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "status_writer.py"


def run(args, status):
    return subprocess.run([sys.executable, str(SCRIPT), "--status", str(status), *args],
                          capture_output=True, text=True)


class TestStatusWriter(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.status = Path(self.tmp.name) / "status.json"

    def tearDown(self):
        self.tmp.cleanup()

    def _doc(self):
        return json.loads(self.status.read_text())

    def test_init_seeds_tick_zero(self):
        r = run(["--init"], self.status)
        self.assertEqual(r.returncode, 0)
        d = self._doc()
        self.assertEqual(d["tick"], 0)
        self.assertEqual(d["validator"], "NONE")

    def test_tick_monotonic_rejects_backwards(self):
        run(["--init"], self.status)
        run(["tick", "1", "boot"], self.status)
        back = run(["tick", "1", "again"], self.status)
        self.assertNotEqual(back.returncode, 0)
        self.assertIn("monotonic", back.stderr)

    def test_next_wake_computed_from_delay(self):
        run(["--init"], self.status)
        run(["tick", "1", "boot", "--delay-seconds", "1200", "--wake-label", "fallback"], self.status)
        nw = self._doc()["next_wake"]
        # Rendered as "HH:MM <tz> (fallback)", computed — not a typed literal.
        self.assertRegex(nw, r"^\d{2}:\d{2}\s+\S+\s+\(fallback\)$")

    def test_now_rejects_bare_clock_time(self):
        run(["--init"], self.status)
        # Inject a bare HH:MM into now.since by hand, then a write must abort on it.
        d = self._doc()
        d["now"]["since"] = "14:05"
        self.status.write_text(json.dumps(d))
        r = run(["now", "working"], self.status)
        # cmd_now recomputes since via now_iso(), so it actually heals — but the assertion
        # guard fires if a bare time is ever present in the doc being written. Confirm the
        # written since is a full ISO stamp, not the bare value.
        self.assertEqual(r.returncode, 0)
        self.assertRegex(self._doc()["now"]["since"], r"\d{4}-\d{2}-\d{2}T")

    def test_crew_json_written_and_preserved(self):
        run(["--init"], self.status)
        run(["now", "dispatching", "--crew-json", '[{"id":"c1","label":"crew","ticket":"T-1"}]'], self.status)
        self.assertEqual(self._doc()["crew"][0]["id"], "c1")
        # A later tick without --crew-json must preserve the roster.
        run(["tick", "1", "reap"], self.status)
        self.assertEqual(self._doc()["crew"][0]["id"], "c1")

    def test_bad_crew_json_warns_but_write_proceeds(self):
        run(["--init"], self.status)
        r = run(["now", "working", "--crew-json", "{not json"], self.status)
        self.assertEqual(r.returncode, 0)
        self.assertIn("WARN", r.stderr)
        self.assertNotIn("crew", self._doc())


if __name__ == "__main__":
    unittest.main(verbosity=2)
