#!/usr/bin/env python3
"""Tests for modules/autonomous/scripts/rotation_prep.py.

Runs rotation_prep.py as a subprocess against a scratch ship root, so it exercises the
real CLI and never touches the live ship.

Run: python3 modules/autonomous/tests/test_rotation_prep.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = str(HERE.parent / "scripts" / "rotation_prep.py")


def make_scratch_ship(root: Path, pct_used=20, gauge_age_min=5, crew_shape="schema"):
    (root / "state").mkdir(parents=True)
    (root / "logs" / "mate").mkdir(parents=True)

    ts = (datetime.now(timezone.utc) - timedelta(minutes=gauge_age_min)).strftime(
        "%Y-%m-%dT%H:%M:%SZ")
    (root / "state" / "context-gauge.json").write_text(json.dumps({
        "session_id": "test-session", "pct_used": pct_used, "tokens_used": 1,
        "context_window": 100, "ts": ts, "rate_pct": 33, "rate_reset_mins": 60}))

    (root / "state" / "mate-lock.json").write_text(json.dumps({
        "session_id": "bg-mate-TEST123", "acquired_at": "2026-07-02T17:58:18Z",
        "heartbeat_at": "2026-07-02T17:58:18Z"}))

    if crew_shape == "schema":
        # lib/status.schema.md shape: {id,label,ticket,since,model}
        crew = [{"id": "a1b2c3", "label": "Build the flux capacitor",
                 "ticket": "SHIP-FLUX", "since": "2026-07-02T15:00:00-05:00",
                 "model": "opus"}]
    else:
        # legacy/wrapped shape: {name,task,ticket,dispatched,note}
        crew = [{"name": "ship-crew", "task": "Build the flux capacitor",
                 "ticket": "SHIP-FLUX", "dispatched": "2026-07-02T15:00:00-05:00"}]
    (root / "state" / "status.json").write_text(json.dumps({"crew": crew}))

    (root / "queue.md").write_text(
        "# Watch Bill\n\n"
        "## Active\n"
        "<!-- comment line -->\n"
        "0. [SHIP-FLUX](projects/ship/tickets/SHIP-FLUX.md) - flux work | last: 2026-07-02\n"
        "\n"
        "## Ready\n"
        "1. [SHIP-AAA](p) - first ready\n"
        "2. [SHIP-BBB](p) - second ready\n"
        "3. [SHIP-CCC](p) - third ready\n"
        "4. [SHIP-DDD](p) - fourth ready (should be cut)\n"
        "\n"
        "## Awaiting Captain\n"
        "1. [SHIP-PR](p) - review the draft PR\n"
        "\n"
        "## Backlog\n"
        "1. [OTHER](p) - not gathered\n")

    (root / "mate.local.md").write_text(
        "# overlay\n\n"
        "## Thresholds & pacing\n\nstuff\n\n"
        "## House notes (free-form)\n\n"
        "- **Off-call posture (standing flag).** Body text.\n"
        "  continuation line\n"
        "- **Mate-lock takeover at rotation is EXPECTED, not a surprise.** Body.\n")

    today = datetime.now().strftime("%Y-%m-%d")
    (root / "logs" / "mate" / f"{today}.md").write_text(
        "\n".join(f"log line {i}" for i in range(1, 41)) + "\n")


def run(args, env_extra=None):
    env = dict(os.environ)
    for k in ("SHIP_ROOT", "SHIP_ROTATE_THRESHOLD", "SHIP_GAUGE_PATH"):
        env.pop(k, None)
    if env_extra:
        env.update(env_extra)
    return subprocess.run([sys.executable, SCRIPT] + args,
                          capture_output=True, text=True, env=env)


class RotationPrepTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "scratch-ship"
        make_scratch_ship(self.root)

    def tearDown(self):
        self.tmp.cleanup()

    # --- skeleton -----------------------------------------------------------

    def test_skeleton_stdout_contains_gathered_state(self):
        r = run(["--ship-root", str(self.root)])
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout
        self.assertIn("bg-mate-TEST123", out)                        # lock id
        self.assertIn("SHIP_OUTGOING_LOCK_ID=bg-mate-TEST123", out)  # ready-made cmd
        self.assertIn("Build the flux capacitor", out)               # crew
        self.assertIn("SHIP-FLUX", out)                              # queue Active
        self.assertIn("first ready", out)                            # queue Ready
        self.assertNotIn("fourth ready", out)                        # top-3 cut
        self.assertIn("review the draft PR", out)                    # Awaiting Captain
        self.assertNotIn("not gathered", out)                        # Backlog excluded
        self.assertIn("Off-call posture", out)                       # posture flag
        self.assertIn("Mate-lock takeover at rotation", out)
        self.assertIn("log line 40", out)                            # log tail (last line)
        self.assertNotIn("log line 15", out)                         # tail=20 → 21..40 only
        self.assertIn("20% used", out)                               # gauge snapshot
        self.assertIn("FILL", out)                                   # judgment markers
        self.assertIn("ship-watch-rotate", out)                      # points at the skill

    def test_skeleton_uses_kit_relative_script_paths(self):
        """No flat scripts/ paths and no absolute ship path may leak into the handoff."""
        out = run(["--ship-root", str(self.root)]).stdout
        self.assertIn("modules/autonomous/scripts/ship-up.sh --rotate-mate", out)
        self.assertNotIn("scripts/ship-up.sh --rotate-mate\n", out.replace(
            "modules/autonomous/scripts/ship-up.sh --rotate-mate\n", ""))
        self.assertNotIn("/Users/", out)

    def test_skeleton_stdout_does_not_write_files(self):
        run(["--ship-root", str(self.root)])
        self.assertFalse((self.root / "state" / "bg-mate-handoff.md").exists())

    def test_write_creates_handoff_and_backs_up_previous(self):
        target = self.root / "state" / "bg-mate-handoff.md"
        target.write_text("OLD HANDOFF v5\n")
        r = run(["--ship-root", str(self.root), "--write"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("bg-mate-TEST123", target.read_text())
        backup = self.root / "state" / "bg-mate-handoff.prev.md"
        self.assertEqual(backup.read_text(), "OLD HANDOFF v5\n")
        self.assertIn("NOW: fill the FILL sections", r.stdout)

    def test_legacy_crew_shape_still_renders(self):
        legacy = Path(self.tmp.name) / "legacy-ship"
        make_scratch_ship(legacy, crew_shape="legacy")
        out = run(["--ship-root", str(legacy)]).stdout
        self.assertIn("Build the flux capacitor", out)
        self.assertIn("ticket SHIP-FLUX", out)

    def test_house_notes_without_bold_leads_still_yields_flags(self):
        plain = Path(self.tmp.name) / "plain-ship"
        make_scratch_ship(plain)
        (plain / "mate.local.md").write_text(
            "# overlay\n\n## House notes (free-form)\n\n"
            "- Restart service X by killing its PID.\n"
            "- Infra asks go to the Platform team.\n")
        out = run(["--ship-root", str(plain)]).stdout
        self.assertIn("Restart service X", out)
        self.assertNotIn("no House notes bullets found", out)

    def test_missing_pieces_degrade_gracefully(self):
        bare = Path(self.tmp.name) / "bare-ship"
        (bare / "state").mkdir(parents=True)
        r = run(["--ship-root", str(bare)])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("lock file missing/unreadable", r.stdout)
        self.assertIn("no gauge available", r.stdout)
        self.assertIn("status.json unreadable", r.stdout)
        self.assertIn("queue.md unreadable", r.stdout)

    def test_missing_root_fatal(self):
        r = run(["--ship-root", str(Path(self.tmp.name) / "nope")])
        self.assertEqual(r.returncode, 2)

    # --- --check-context ------------------------------------------------------

    def test_check_context_ok_below_threshold(self):
        r = run(["--ship-root", str(self.root), "--check-context"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("OK: context 20% used < 70%", r.stdout)

    def test_check_context_rotate_recommended(self):
        make_scratch_ship(Path(self.tmp.name) / "hot-ship", pct_used=82)
        r = run(["--ship-root", str(Path(self.tmp.name) / "hot-ship"), "--check-context"])
        self.assertEqual(r.returncode, 3)
        self.assertIn("ROTATE-RECOMMENDED: context 82% used >= 70%", r.stdout)
        self.assertIn("--rotate-mate", r.stdout)

    def test_check_context_threshold_flag(self):
        r = run(["--ship-root", str(self.root), "--check-context", "--threshold", "15"])
        self.assertEqual(r.returncode, 3)
        self.assertIn(">= 15%", r.stdout)

    def test_check_context_threshold_env(self):
        r = run(["--ship-root", str(self.root), "--check-context"],
                env_extra={"SHIP_ROTATE_THRESHOLD": "10"})
        self.assertEqual(r.returncode, 3)
        self.assertIn(">= 10%", r.stdout)

    def test_check_context_no_gauge(self):
        (self.root / "state" / "context-gauge.json").unlink()
        r = run(["--ship-root", str(self.root), "--check-context"])
        self.assertEqual(r.returncode, 4)
        self.assertIn("NO-GAUGE", r.stdout)

    def test_check_context_stale_gauge_flagged(self):
        make_scratch_ship(Path(self.tmp.name) / "stale-ship", pct_used=30,
                          gauge_age_min=60 * 12)
        r = run(["--ship-root", str(Path(self.tmp.name) / "stale-ship"), "--check-context"])
        self.assertEqual(r.returncode, 0)
        self.assertIn("STALE", r.stdout)

    # --- --gauge (the band_gauge_path seam) ------------------------------------

    def test_gauge_flag_relative_path(self):
        (self.root / "state" / "context-gauge.json").rename(
            self.root / "state" / "elsewhere.json")
        r = run(["--ship-root", str(self.root), "--check-context",
                 "--gauge", "state/elsewhere.json"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("20% used", r.stdout)

    def test_gauge_flag_absolute_path(self):
        moved = Path(self.tmp.name) / "abs-gauge.json"
        moved.write_text((self.root / "state" / "context-gauge.json").read_text())
        (self.root / "state" / "context-gauge.json").unlink()
        r = run(["--ship-root", str(self.root), "--check-context", "--gauge", str(moved)])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("20% used", r.stdout)

    def test_gauge_env_override(self):
        (self.root / "state" / "context-gauge.json").rename(
            self.root / "state" / "elsewhere.json")
        r = run(["--ship-root", str(self.root), "--check-context"],
                env_extra={"SHIP_GAUGE_PATH": "state/elsewhere.json"})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("20% used", r.stdout)

    # --- default ship root ------------------------------------------------------

    def test_default_ship_root_is_the_kit_root_not_a_hardcoded_path(self):
        """Derived from the script location (parents[3]), like mate-lock.py."""
        kit_root = Path(SCRIPT).resolve().parents[3]
        r = run(["--check-context"])
        self.assertIn(r.returncode, (0, 3, 4), r.stdout + r.stderr)
        self.assertTrue((kit_root / "modules" / "autonomous").is_dir())


if __name__ == "__main__":
    unittest.main(verbosity=2)
