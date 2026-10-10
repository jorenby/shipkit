#!/usr/bin/env python3
# Tests for validate-memory-index.py, run as a subprocess against a fake HOME so no real memory file is touched.

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHECKER = HERE.parent / "hooks" / "validate-memory-index.py"
WRAPPER = HERE.parent / "hooks" / "validate-memory-index.sh"

LINE200 = "x" * 200
LINE201 = "x" * 201
LINE300 = "- [some-memory](some.md) — " + "y" * 300
BIG = "\n".join(f"line {i:03d}: " + "z" * 90 for i in range(1, 301))


class MemoryIndexGuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.index = self.home / ".claude" / "projects" / "testshard" / "memory" / "MEMORY.md"
        self.index.parent.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def decide(self, payload, raw=None):
        env = dict(os.environ, HOME=str(self.home))
        stdin = raw if raw is not None else json.dumps(payload)
        out = subprocess.run([sys.executable, str(CHECKER)], input=stdin, capture_output=True, text=True, env=env)
        self.assertEqual(out.returncode, 0, out.stderr)
        if not out.stdout.strip():
            return "ABSTAIN", ""
        doc = json.loads(out.stdout)["hookSpecificOutput"]
        return doc["permissionDecision"], doc["permissionDecisionReason"]

    def write(self, path, content):
        return {"tool_name": "Write", "tool_input": {"file_path": str(path), "content": content}}

    def edit(self, path, old, new, replace_all=False):
        return {"tool_name": "Edit", "tool_input": {"file_path": str(path), "old_string": old, "new_string": new, "replace_all": replace_all}}

    def multi(self, path, old, new):
        return {"tool_name": "MultiEdit", "tool_input": {"file_path": str(path), "edits": [{"old_string": old, "new_string": new}]}}

    def seed(self, text):
        self.index.write_text(text, encoding="utf-8")

    def test_known_positive_long_line_denies_with_actionable_reason(self):
        decision, reason = self.decide(self.edit(self.index, "", LINE300))
        self.assertEqual(decision, "deny")
        self.assertIn("200", reason)

    def test_line_budget_boundaries(self):
        self.assertEqual(self.decide(self.edit(self.index, "", LINE201))[0], "deny")
        self.assertEqual(self.decide(self.edit(self.index, "", LINE200))[0], "ABSTAIN")

    def test_write_tool(self):
        self.assertEqual(self.decide(self.write(self.index, LINE300))[0], "deny")
        self.assertEqual(self.decide(self.write(self.index, "- [a](a.md) — short hook"))[0], "ABSTAIN")

    def test_replace_all_edit_with_long_line_denies(self):
        self.seed("old\n")
        self.assertEqual(self.decide(self.edit(self.index, "old", LINE300, True))[0], "deny")

    def test_file_budget_on_new_file(self):
        decision, reason = self.decide(self.write(self.index, BIG))
        self.assertEqual(decision, "deny")
        self.assertIn("drain", reason)

    def test_out_of_scope_paths_abstain(self):
        notes = self.index.parent / "NOTES.md"
        nested = self.home / "code" / "clone" / ".claude" / "projects" / "x" / "memory" / "MEMORY.md"
        self.assertEqual(self.decide(self.write(notes, LINE300))[0], "ABSTAIN")
        self.assertEqual(self.decide(self.write(self.home / "queue.md", LINE300))[0], "ABSTAIN")
        self.assertEqual(self.decide(self.write(nested, LINE300))[0], "ABSTAIN")
        self.assertEqual(self.decide({"tool_name": "Read", "tool_input": {"file_path": str(self.index)}})[0], "ABSTAIN")

    def test_multiedit_is_covered(self):
        self.assertEqual(self.decide(self.multi(self.index, "", LINE300))[0], "deny")
        self.seed("- [a](a.md) — old\n")
        self.assertEqual(self.decide(self.multi(self.index, "- [a](a.md) — old", "- [a](a.md) — new"))[0], "ABSTAIN")

    def test_existing_long_line_is_grandfathered(self):
        existing_long = "- [existing-long](x.md) — " + "e" * 250
        self.seed(f"# Memory Index\n{existing_long}\n- [a](a.md) — short existing\n")
        appended = existing_long + "\n- [zz](zz.md) — short new entry"
        self.assertEqual(self.decide(self.edit(self.index, existing_long, appended))[0], "ABSTAIN")
        self.assertEqual(self.decide(self.edit(self.index, "- [a](a.md) — short existing", LINE300))[0], "deny")

    def test_lengthening_or_tail_extending_an_entry_denies(self):
        self.seed("# Memory Index\n- [a](a.md) — short existing\n")
        longer = "- [a](a.md) — " + "z" * 220
        self.assertEqual(self.decide(self.edit(self.index, "- [a](a.md) — short existing", longer))[0], "deny")
        fragment = "short existing " + "k" * 180
        self.assertEqual(self.decide(self.edit(self.index, "short existing", fragment))[0], "deny")

    def test_shrinking_an_over_budget_file_passes_and_growing_denies(self):
        big = "\n".join(f"line {i:03d}: " + "z" * 90 for i in range(1, 261)) + "\n"
        self.seed(big)
        shrunk = "\n".join(big.split("\n")[:200])
        self.assertEqual(self.decide(self.write(self.index, shrunk))[0], "ABSTAIN")
        grown = big + "- [extra](e.md) — one more short line\n"
        self.assertEqual(self.decide(self.write(self.index, grown))[0], "deny")

    def test_malformed_input_fails_open(self):
        self.assertEqual(self.decide(None, raw="this is not json")[0], "ABSTAIN")

    def test_wrapper_without_sibling_checker_fails_open(self):
        with tempfile.TemporaryDirectory() as d:
            lone = Path(d) / "validate-memory-index.sh"
            lone.write_text(WRAPPER.read_text(encoding="utf-8"), encoding="utf-8")
            out = subprocess.run(["bash", str(lone)], input=json.dumps(self.edit(self.index, "", LINE300)),
                                 capture_output=True, text=True, env=dict(os.environ, HOME=str(self.home)))
        self.assertEqual(out.returncode, 0)
        self.assertEqual(out.stdout, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
