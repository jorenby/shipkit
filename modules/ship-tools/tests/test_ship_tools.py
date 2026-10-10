#!/usr/bin/env python3
# Tests for initiative-index.py and seed-conformance-check.py, run as subprocesses against a temporary ship tree.

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
INDEX = SCRIPTS / "initiative-index.py"
SEED = SCRIPTS / "seed-conformance-check.py"

TICKET_TEMPLATE = "# {id}: {title}\n\n**Status:** ready\n**Goal:** {goal}\n\n## Acceptance\n- [ ] x\n\n## Current state\nNot started.\n\n## Blocked on\nN/A\n"


class ShipTreeCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def ticket(self, project, name, body):
        path = self.root / "projects" / project / "tickets" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
        return path

    def run_script(self, script, *args):
        env = dict(os.environ, SHIP_ROOT=str(self.root))
        return subprocess.run([sys.executable, str(script), *args], capture_output=True, text=True, env=env)


class InitiativeIndexTest(ShipTreeCase):
    def test_groups_by_epic_and_reports_progress_blockers_and_next(self):
        self.ticket("api", "001-a.md", "**Status:** Done\n**Epic:** Billing\n")
        self.ticket("api", "002-b.md", "**Status:** Active\n**Epic:** Billing\n\n## Blocked on\nwaiting on vendor key\n")
        self.ticket("web", "003-c.md", "**Status:** Ready\n**Epic:** Billing\n\n## Blocked on\nN/A\n")
        self.ticket("web", "004-d.md", "**Status:** Ready\n")
        out = self.run_script(INDEX, str(self.root / "projects"))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("Billing (1/3 done)", out.stdout)
        self.assertIn("blocking: [API] 002-b - waiting on vendor key", out.stdout)
        self.assertIn("next unblocked: [WEB] 003-c", out.stdout)
        self.assertIn("(unassigned): 1 ticket(s)", out.stdout)

    def test_tag_override_and_absent_initiative(self):
        self.ticket("api-service", "001-a.md", "**Status:** Ready\n**Epic:** Search\n")
        out = self.run_script(INDEX, str(self.root / "projects"), "--tag", "api-service=API", "--initiative", "Search")
        self.assertIn("next unblocked: [API] 001-a", out.stdout)
        out = self.run_script(INDEX, str(self.root / "projects"), "--initiative", "Nope")
        self.assertIn("Nope (0/0 done) - no matching tickets found", out.stdout)

    def test_missing_root_is_an_error(self):
        out = self.run_script(INDEX, str(self.root / "nowhere"))
        self.assertEqual(out.returncode, 1)


class SeedConformanceTest(ShipTreeCase):
    def setUp(self):
        super().setUp()
        templates = self.root / "core" / "templates"
        templates.mkdir(parents=True)
        (templates / "captain.md").write_text("# Captain\n\n## Situation\n\n## Priorities\n", encoding="utf-8")
        (templates / "queue.md").write_text("# Queue\n\n## Ready\n\n## Backlog\n", encoding="utf-8")
        (templates / "ticket.md").write_text(TICKET_TEMPLATE, encoding="utf-8")
        self.drops = self.root / "inbox" / "drops"

    def write_live(self, captain, queue):
        (self.root / "captain.md").write_text(captain, encoding="utf-8")
        (self.root / "queue.md").write_text(queue, encoding="utf-8")

    def test_conformant_tree_writes_no_drop(self):
        self.write_live("# Captain\n\n## Situation\nx\n\n## Priorities\ny\n", "# Queue\n\n## Ready\n\n## Backlog\n")
        self.ticket("api", "001-a.md", TICKET_TEMPLATE)
        out = self.run_script(SEED)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("fully conformant", out.stdout)
        self.assertFalse(self.drops.exists() and any(self.drops.iterdir()))

    def test_divergence_writes_one_batch_drop_and_does_not_repeat(self):
        self.write_live("# Captain\n\n## Situation\n\n## Extra\n", "# Queue\n\n## Ready\n\n## Backlog\n")
        self.ticket("api", "001-a.md", "# 1: a\n\n**Status:** ready\n")
        out = self.run_script(SEED)
        self.assertEqual(out.returncode, 0, out.stderr)
        drops = list(self.drops.glob("*-seed-conformance-report.md"))
        self.assertEqual(len(drops), 1)
        body = drops[0].read_text(encoding="utf-8")
        self.assertIn("wake_class: batch", body)
        self.assertIn("`## Extra`", body)
        self.assertIn("`## Priorities`", body)
        self.assertIn("1 divergent", body)
        again = self.run_script(SEED)
        self.assertIn("already pending", again.stdout)
        self.assertEqual(len(list(self.drops.glob("*-seed-conformance-report.md"))), 1)

    def test_missing_live_file_is_unparsed_never_conformant(self):
        (self.root / "queue.md").write_text("# Queue\n\n## Ready\n\n## Backlog\n", encoding="utf-8")
        out = self.run_script(SEED)
        self.assertIn("UNPARSED — could not read the live file", out.stdout)
        self.assertEqual(len(list(self.drops.glob("*-seed-conformance-report.md"))), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
