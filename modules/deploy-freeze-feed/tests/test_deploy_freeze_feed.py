#!/usr/bin/env python3
# Tests for deploy_freeze_feed.py: replayed alert snapshots in, bounded classified candidate drops out.

import importlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

FIXTURE_FREEZE = {
    "critical_unattended": True,
    "incident_id": "deploy-freeze-1",
    "channel": "#deploy-alerts",
    "condition": "deploy pipeline freeze -- main not deploying, backlog building",
    "fired_at": "2026-06-28T14:00:00Z",
    "link": "https://chat.example.com/deploy-alerts/p1",
}
FIXTURE_QUIET = {"critical_unattended": False}

ENV_KEYS = ("SHIP_ROOT", "SENSOR_DROPS_DIR", "DEPLOY_FREEZE_SIGNAL_PATH", "DEPLOY_FREEZE_STATE_PATH")


class TestDeployFreezeFeed(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="deploy-freeze-test.")
        self.root = Path(self._tmp.name)
        (self.root / "inbox" / "drops").mkdir(parents=True)
        (self.root / "state").mkdir(parents=True)
        self.signal_path = self.root / "state" / "signal.json"
        self.state_path = self.root / "state" / "feed_state.json"
        os.environ["SHIP_ROOT"] = str(self.root)
        os.environ["SENSOR_DROPS_DIR"] = str(self.root / "inbox" / "drops")
        os.environ["DEPLOY_FREEZE_SIGNAL_PATH"] = str(self.signal_path)
        os.environ["DEPLOY_FREEZE_STATE_PATH"] = str(self.state_path)
        if "deploy_freeze_feed" in sys.modules:
            self.feed = importlib.reload(sys.modules["deploy_freeze_feed"])
        else:
            self.feed = importlib.import_module("deploy_freeze_feed")

    def tearDown(self):
        for k in ENV_KEYS:
            os.environ.pop(k, None)
        self._tmp.cleanup()

    def _write_signal(self, data):
        self.signal_path.write_text(json.dumps(data), encoding="utf-8")

    def _drops(self):
        return sorted((self.root / "inbox" / "drops").glob("*.md"))

    def test_quiet_signal_emits_nothing(self):
        self._write_signal(FIXTURE_QUIET)
        _seen, result = self.feed.poll({})
        self.assertIsNone(result)
        self.assertEqual(self._drops(), [])

    def test_missing_signal_emits_nothing(self):
        _seen, result = self.feed.poll({})
        self.assertIsNone(result)

    def test_unattended_freeze_produces_wake_candidate(self):
        self._write_signal(FIXTURE_FREEZE)
        _seen, result = self.feed.poll({})
        self.assertTrue(result["first_seen"])
        self.assertEqual(result["classification"], "wake")
        drops = self._drops()
        self.assertEqual(len(drops), 1, drops)
        body = drops[0].read_text(encoding="utf-8")
        self.assertIn("wake_class: wake", body)
        self.assertIn("source: deploy-freeze-watch", body)
        self.assertTrue(result["path"].startswith(str(self.root / "inbox" / "drops")))

    def test_reobservation_while_unconsumed_emits_nothing(self):
        self._write_signal(FIXTURE_FREEZE)
        seen, _first = self.feed.poll({})
        seen, second = self.feed.poll(seen)
        self.assertIsNone(second)
        self.assertEqual(len(self._drops()), 1, self._drops())

    def test_reobservation_after_consume_downgrades_to_batch(self):
        self._write_signal(FIXTURE_FREEZE)
        seen, first = self.feed.poll({})
        Path(first["path"]).unlink()
        _seen, second = self.feed.poll(seen)
        self.assertFalse(second["first_seen"])
        self.assertEqual(second["classification"], "batch")
        body = Path(second["path"]).read_text(encoding="utf-8")
        self.assertIn("kind: sensor-redrop", body)
        self.assertIn("wake_class: batch", body)

    def test_state_persists_across_reload(self):
        self._write_signal(FIXTURE_FREEZE)
        seen, first = self.feed.poll({})
        self.feed.save_state(seen)
        reloaded = self.feed.load_state()
        self.assertEqual(reloaded, seen)
        _seen, second = self.feed.poll(reloaded)
        self.assertIsNone(second)
        Path(first["path"]).unlink()
        _seen, third = self.feed.poll(reloaded)
        self.assertEqual(third["classification"], "batch")

    def test_distinct_incident_re_escalates(self):
        self._write_signal(FIXTURE_FREEZE)
        seen, _first = self.feed.poll({})
        other = dict(FIXTURE_FREEZE, incident_id="deploy-freeze-2")
        self._write_signal(other)
        _seen, result = self.feed.poll(seen)
        self.assertTrue(result["first_seen"])
        self.assertEqual(result["classification"], "wake")

    def test_persistent_condition_bounds_file_count(self):
        self._write_signal(FIXTURE_FREEZE)
        seen = {}
        for _ in range(50):
            seen, _result = self.feed.poll(seen)
        self.assertEqual(len(self._drops()), 1, self._drops())

    def test_cleared_then_refired_incident_rewakes(self):
        self._write_signal(FIXTURE_FREEZE)
        seen, _first = self.feed.poll({})
        self._write_signal(FIXTURE_QUIET)
        seen, cleared = self.feed.poll(seen)
        self.assertIsNone(cleared)
        self._write_signal(FIXTURE_FREEZE)
        _seen, refire = self.feed.poll(seen)
        self.assertTrue(refire["first_seen"])
        self.assertEqual(refire["classification"], "wake")

    def test_missing_channel_renders_unspecified(self):
        self._write_signal({"critical_unattended": True, "condition": "stuck deploy"})
        _seen, result = self.feed.poll({})
        self.assertIn("**Channel:** (unspecified)", Path(result["path"]).read_text(encoding="utf-8"))

    def test_atomic_state_write_leaves_no_tmp(self):
        self._write_signal(FIXTURE_FREEZE)
        seen, _first = self.feed.poll({})
        self.feed.save_state(seen)
        self.assertEqual(list((self.root / "state").glob("*.tmp")), [])
        self.assertTrue(self.state_path.is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
