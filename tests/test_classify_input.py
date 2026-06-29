#!/usr/bin/env python3
"""Test suite for classify_input.py -- the 3-step declared-input ladder.

Usage: python3 tests/test_classify_input.py   (or: scripts/classify_input.py --test)

Cross-platform (stdlib only). Fixtures are written to a temp dir and cleaned
up on exit. Mirrors the 24 assertions of the original bash fixture runner:
each `expect_class` and `expect_warn` is one assertion.
"""

import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(HERE, "..", "scripts")
sys.path.insert(0, SCRIPTS)

import classify_input  # noqa: E402


# (name, body, expected_class, want_warn) -- want_warn is None when the bash
# suite did not assert on the warning for that fixture.
FIXTURES = [
    # === Step 1: declared wake_class is authoritative ===
    (
        "wake.md",
        """---
shipkit_input: v1
source: status-surface
kind: steer
wake_class: wake
---
do the thing
""",
        "wake",
        False,
    ),
    (
        "batch.md",
        """---
shipkit_input: v1
source: pr-buddy
kind: sensor-redrop
wake_class: batch
---
PR 6 unchanged
""",
        "batch",
        False,
    ),
    (
        "silent.md",
        """---
shipkit_input: v1
source: noisy-sensor
kind: notification
wake_class: silent
---
heartbeat ping (pure noise)
""",
        "silent",
        False,
    ),
    (
        "override.md",
        """---
shipkit_input: v1
kind: steer
wake_class: batch
---
declared steer but author wants it batched
""",
        "batch",
        None,
    ),
    (
        "event.json",
        '{"shipkit_input":"v1","source":"thread","kind":"comment","wake_class":"wake","body":"hi"}\n',
        "wake",
        False,
    ),
    # === Step 2: kind-only (no wake_class) -> kind->class table ===
    (
        "kind-steer.md",
        """---
shipkit_input: v1
source: captain-ui
kind: steer
---
a directive
""",
        "wake",
        False,
    ),
    (
        "kind-statusreq.md",
        """---
kind: status-request
---
status please
""",
        "wake",
        None,
    ),
    (
        "kind-redrop.md",
        """---
shipkit_input: v1
source: pr-buddy
kind: sensor-redrop
---
unchanged PR state
""",
        "batch",
        False,
    ),
    (
        "kind-notif.md",
        """---
kind: notification
---
fyi
""",
        "batch",
        None,
    ),
    (
        "kind-unknown.md",
        """---
kind: some-future-kind
---
unrecognized but declared
""",
        "wake",
        None,
    ),
    # === Step 3: undeclared -> heuristic + stderr warning ===
    (
        "legacy-steer.md",
        """---
type: steer
title: "legacy steer, no envelope"
---
old-style directive
""",
        "wake",
        True,
    ),
    (
        "legacy-bookkeeping.md",
        """---
type: status-applied
---
bookkeeping
""",
        "batch",
        True,
    ),
    (
        "bare.md",
        "just a plain chat message with no frontmatter at all\n",
        "wake",
        True,
    ),
    # === Always-on guards ===
    (
        "self.md",
        """---
shipkit_input: v1
source: mate
kind: steer
wake_class: wake
---
the loop's own surface
""",
        "batch",
        None,
    ),
    (
        "badclass.md",
        """---
kind: steer
wake_class: bogus
---
mistyped wake_class
""",
        "wake",
        None,
    ),
]


class TestClassifyInput(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory(prefix="classify-test.")
        cls.tmp = cls._tmp.name
        cls.paths = {}
        for name, body, _cls, _warn in FIXTURES:
            p = os.path.join(cls.tmp, name)
            with open(p, "w", encoding="utf-8") as fh:
                fh.write(body)
            cls.paths[name] = p

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def _classify(self, path):
        """Returns (class, warned) where warned reflects the heuristic warning."""
        err = io.StringIO()
        with redirect_stderr(err):
            result = classify_input.classify(path)
        warned = "heuristically classified" in err.getvalue()
        return result, warned


def _make_class_test(name, expected):
    def test(self):
        got, _ = self._classify(self.paths[name])
        self.assertEqual(got, expected, f"class for {name}")
    return test


def _make_warn_test(name, want):
    def test(self):
        _, warned = self._classify(self.paths[name])
        self.assertEqual(warned, want, f"warn for {name}")
    return test


# Attach one test method per assertion to match the 24-fixture count.
for _name, _body, _cls, _warn in FIXTURES:
    safe = _name.replace(".", "_").replace("-", "_")
    setattr(TestClassifyInput, f"test_class_{safe}", _make_class_test(_name, _cls))
    if _warn is not None:
        setattr(TestClassifyInput, f"test_warn_{safe}", _make_warn_test(_name, _warn))


if __name__ == "__main__":
    unittest.main(verbosity=2)
