#!/usr/bin/env python3
# Test suite for substrate_tripwire.py -- the security-substrate tamper tripwire (ticket 041, opt-3).

import importlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_DIR = os.path.join(HERE, "..")
sys.path.insert(0, MODULE_DIR)


class SubstrateTripwireTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        # Two fake watched files + the drops/state dirs, all under the tmp root.
        self.guard = root / "guard.sh"
        self.agentdef = root / "agent.md"
        self.guard.write_text("original guard\n", encoding="utf-8")
        self.agentdef.write_text("original agent\n", encoding="utf-8")
        self.drops = root / "drops"
        self.state = root / "state" / "tripwire.json"

        os.environ["SUBSTRATE_TRIPWIRE_PATHS"] = f"{self.guard}:{self.agentdef}"
        os.environ["SENSOR_DROPS_DIR"] = str(self.drops)
        os.environ["SUBSTRATE_TRIPWIRE_STATE_PATH"] = str(self.state)

        # Re-import fresh so module-level constants pick up the env.
        import substrate_tripwire
        importlib.reload(substrate_tripwire)
        self.mod = substrate_tripwire

    def tearDown(self):
        for k in ("SUBSTRATE_TRIPWIRE_PATHS", "SENSOR_DROPS_DIR", "SUBSTRATE_TRIPWIRE_STATE_PATH"):
            os.environ.pop(k, None)
        self.tmp.cleanup()

    def _drop_files(self):
        return sorted(self.drops.glob("*.md")) if self.drops.exists() else []

    def test_first_run_establishes_baseline_no_drop(self):
        self.assertIsNone(self.mod.poll())
        self.assertTrue(self.state.exists(), "baseline should be written on first run")
        self.assertEqual(self._drop_files(), [], "first run must not emit a drop")

    def test_no_change_no_drop(self):
        self.mod.poll()  # baseline
        self.assertIsNone(self.mod.poll())
        self.assertEqual(self._drop_files(), [])

    def test_modification_fires_one_wake_drop(self):
        self.mod.poll()  # baseline
        self.guard.write_text("TAMPERED\n", encoding="utf-8")
        result = self.mod.poll()
        self.assertIsNotNone(result, "a modification must emit a candidate drop")
        drops = self._drop_files()
        self.assertEqual(len(drops), 1)
        body = drops[0].read_text(encoding="utf-8")
        self.assertIn("wake_class: wake", body)
        self.assertIn("source: substrate-tripwire", body)
        self.assertIn("modified", body)
        self.assertIn(str(self.guard), body)

    def test_deletion_is_detected(self):
        self.mod.poll()  # baseline
        self.agentdef.unlink()
        self.assertIsNotNone(self.mod.poll())
        self.assertIn("deleted", self._drop_files()[0].read_text(encoding="utf-8"))

    def test_rebaseline_after_fire_no_renag(self):
        self.mod.poll()  # baseline
        self.guard.write_text("TAMPERED\n", encoding="utf-8")
        self.mod.poll()  # fires once, re-baselines
        self.assertIsNone(self.mod.poll(), "must not re-nag the same still-changed state")
        self.assertEqual(len(self._drop_files()), 1)

    def test_distinct_change_fires_again(self):
        self.mod.poll()  # baseline
        self.guard.write_text("TAMPER 1\n", encoding="utf-8")
        self.mod.poll()  # fire 1
        self.guard.write_text("TAMPER 2\n", encoding="utf-8")
        self.assertIsNotNone(self.mod.poll(), "a new distinct change must fire again")
        self.assertEqual(len(self._drop_files()), 2)

    def test_corrupt_state_fires_wake_not_silent_rebaseline(self):
        # A corrupt/unreadable baseline is SUSPICIOUS (a crew could corrupt it to launder a
        # tamper) -> fire a wake and re-establish, rather than silently trusting current disk.
        self.mod.poll()  # establish a valid baseline first
        self.state.write_text("{not valid json", encoding="utf-8")
        result = self.mod.poll()
        self.assertIsNotNone(result, "corrupt baseline must fire a wake, not re-baseline silently")
        body = self._drop_files()[0].read_text(encoding="utf-8")
        self.assertIn("wake_class: wake", body)
        self.assertIn("baseline-unreadable", body)
        # After firing it re-establishes, so a clean follow-up poll is quiet.
        self.assertIsNone(self.mod.poll())

    def test_missing_state_is_silent_first_run(self):
        # Distinct from corrupt: a genuinely absent baseline is a legit first run -> no wake.
        self.assertIsNone(self.mod.poll())
        self.assertEqual(self._drop_files(), [])


if __name__ == "__main__":
    unittest.main()
