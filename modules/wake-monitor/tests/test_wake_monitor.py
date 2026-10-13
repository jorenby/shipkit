#!/usr/bin/env python3
"""Test suite for wake_monitor.py -- the poll-based Loop-Mode wake-monitor.

Usage: python3 tests/test_wake_monitor.py

Cross-platform (stdlib only). Mirrors the Watch-1 smoke test's 5 behaviors plus
the silent-baseline + persisted-seen-set guarantees:

  1. wake-steer fires      — a net-new wake-class drop emits one WAKE line.
  2. batch is silent       — a net-new batch-class drop emits nothing.
  3. dedup holds           — a basename already in the seen-set never re-fires
                             (even after the loop mv's it to processed/).
  4. captain-add fires     — a new directive line in inbox/captain.md wakes.
  5. captain-clear no-wake  — REMOVING inbox lines cannot self-wake (clears only
                             shrink the content set).
  + baseline-silent        — first run absorbs pre-existing items, emits nothing.
  + state persists         — a restart resumes from the saved seen-set.

Each fixture writes into a temp SHIP_ROOT, so the real ship state is never
touched. wake_monitor is imported with SHIP_ROOT pointed at the temp dir.
"""

import importlib
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_DIR = os.path.join(HERE, "..")
sys.path.insert(0, MODULE_DIR)


WAKE_DROP = """---
shipkit_input: v1
source: status-surface
kind: steer
wake_class: wake
---
do the thing
"""

BATCH_DROP = """---
shipkit_input: v1
source: pr-buddy
kind: sensor-redrop
wake_class: batch
---
PR 6 unchanged
"""


class TestWakeMonitor(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="wake-test.")
        self.root = Path(self._tmp.name)
        (self.root / "inbox" / "drops").mkdir(parents=True)
        (self.root / "state").mkdir(parents=True)
        os.environ["SHIP_ROOT"] = str(self.root)
        # Re-import so module-level SHIP_ROOT/paths bind to this temp dir.
        if "wake_monitor" in sys.modules:
            self.wm = importlib.reload(sys.modules["wake_monitor"])
        else:
            self.wm = importlib.import_module("wake_monitor")

    def tearDown(self):
        os.environ.pop("SHIP_ROOT", None)
        self._tmp.cleanup()

    # --- helpers ---------------------------------------------------------
    def _drop(self, name, body):
        (self.root / "inbox" / "drops" / name).write_text(body, encoding="utf-8")

    def _captain(self, text):
        (self.root / "inbox" / "captain.md").write_text(text, encoding="utf-8")

    def _poll(self, seen_drops, seen_lines):
        """Run one poll pass; return (seen_drops, seen_lines, emitted_lines)."""
        out = io.StringIO()
        with redirect_stdout(out):
            sd, sl, _woke = self.wm.poll(seen_drops, seen_lines)
        emitted = [ln for ln in out.getvalue().splitlines() if ln.strip()]
        return sd, sl, emitted

    # --- the five behaviors ----------------------------------------------
    def test_wake_steer_fires(self):
        self._drop("steer.md", WAKE_DROP)
        _sd, _sl, emitted = self._poll(set(), set())
        self.assertEqual(len(emitted), 1, emitted)
        self.assertTrue(emitted[0].startswith("WAKE "), emitted)

    def test_batch_is_silent(self):
        self._drop("redrop.md", BATCH_DROP)
        _sd, _sl, emitted = self._poll(set(), set())
        self.assertEqual(emitted, [], emitted)

    def test_dedup_holds_across_processed_move(self):
        self._drop("steer.md", WAKE_DROP)
        sd, sl, emitted = self._poll(set(), set())
        self.assertEqual(len(emitted), 1)
        # The loop processes the drop: move it out of drops/. A basename in the
        # seen-set must NOT re-fire, and removing the file must not re-fire.
        (self.root / "inbox" / "drops" / "steer.md").unlink()
        _sd, _sl, emitted2 = self._poll(sd, sl)
        self.assertEqual(emitted2, [], emitted2)

    def test_captain_add_fires(self):
        self._captain("# Inbox\n")
        # Baseline the heading-only inbox, then add a directive line.
        seen_lines = self.wm._content_line_hashes((self.root / "inbox" / "captain.md").read_text(encoding="utf-8"))
        self._captain("# Inbox\nplease look at the deploy\n")
        _sd, _sl, emitted = self._poll(set(), seen_lines)
        self.assertEqual(len(emitted), 1, emitted)
        self.assertIn("captain", emitted[0])

    def test_captain_clear_no_self_wake(self):
        self._captain("# Inbox\nplease look at the deploy\nand the second thing\n")
        sd, sl, emitted = self._poll(set(), set())
        self.assertEqual(len(emitted), 1, emitted)  # first pass sees the adds
        # Now the Mate CLEARS the inbox (removes the directive lines). A clear
        # only shrinks the content set, so it structurally cannot self-wake.
        self._captain("# Inbox\n")
        _sd, _sl, emitted2 = self._poll(sd, sl)
        self.assertEqual(emitted2, [], emitted2)

    # --- baseline + persistence ------------------------------------------
    def test_baseline_silent_then_persists(self):
        # Pre-existing drop + inbox content present before the monitor's first run.
        self._drop("preexisting.md", WAKE_DROP)
        self._captain("# Inbox\nan old directive already here\n")
        # _load_state returns None,None on a fresh state file -> baseline path.
        sd, sl = self.wm._load_state()
        self.assertIsNone(sd)
        sd = set(self.wm._enumerate_drops().keys())
        sl = self.wm._content_line_hashes((self.root / "inbox" / "captain.md").read_text(encoding="utf-8"))
        self.wm._save_state(sd, sl)
        # A poll right after baseline must emit nothing (everything absorbed).
        _sd, _sl, emitted = self._poll(sd, sl)
        self.assertEqual(emitted, [], emitted)
        # Reload state from disk (simulates a monitor restart) -> resumes.
        sd2, sl2 = self.wm._load_state()
        self.assertEqual(sd2, sd)
        self.assertEqual(sl2, sl)
        _sd, _sl, emitted2 = self._poll(sd2, sl2)
        self.assertEqual(emitted2, [], emitted2)

    # --- state-safety hardening ------------------------------------------
    def test_captain_identical_readd_rewakes(self):
        # Snapshot semantics: a line removed then re-added identically must
        # wake again (no grow-only accumulator suppression).
        self._captain("# Inbox\nplease look at the deploy\n")
        sd, sl, emitted = self._poll(set(), set())
        self.assertEqual(len(emitted), 1, emitted)
        self._captain("# Inbox\n")
        sd, sl, emitted2 = self._poll(sd, sl)
        self.assertEqual(emitted2, [], emitted2)
        self._captain("# Inbox\nplease look at the deploy\n")
        _sd, _sl, emitted3 = self._poll(sd, sl)
        self.assertEqual(len(emitted3), 1, emitted3)

    def test_corrupt_state_fails_loud(self):
        # A torn/corrupt state file must raise, never silently re-baseline
        # (which would swallow every pending wake).
        state_path = self.root / "state" / ".wake_monitor_state.json"
        state_path.parent.mkdir(parents=True, exist_ok=True)
        state_path.write_text("{not valid json", encoding="utf-8")
        with self.assertRaises(self.wm.CorruptState):
            self.wm._load_state()

    def test_missing_state_baselines(self):
        # A fresh (absent) state file is uninitialized -> baseline path, not corrupt.
        sd, sl = self.wm._load_state()
        self.assertIsNone(sd)
        self.assertIsNone(sl)

    def test_atomic_state_write_leaves_no_tmp(self):
        # tmp + os.replace leaves no partial .tmp behind and round-trips.
        self.wm._save_state({"a.md"}, {"deadbeef"})
        state_dir = self.root / "state"
        leftovers = list(state_dir.glob("*.tmp"))
        self.assertEqual(leftovers, [], leftovers)
        sd, sl = self.wm._load_state()
        self.assertEqual(sd, {"a.md"})
        self.assertEqual(sl, {"deadbeef"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
