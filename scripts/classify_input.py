#!/usr/bin/env python3
# classify_input.py <inputfile> -> prints "wake", "batch", or "silent"
#
# The Loop Mode INPUT-MODEL seam. Classify an incoming item (an inbox edit, a
# drop file from an external process, a queued signal) into one of three
# wake-classes:
#
#   WAKE   = a directive someone is waiting on -> interrupt the loop NOW.
#   BATCH  = bookkeeping / sensor-noise -> the live ticket frontmatter already
#            serves the Captain's views, so it is reconciled in ONE pass at the
#            next tick (the ship-tick "Check inbox / batch-reconcile" step).
#   SILENT = pure noise -> don't wake AND don't surface. Recorded in the seen-set
#            (so it doesn't re-fire) and logged, but never lands on a wake OR a
#            batch surface. For sources that are genuinely log-only.
#
# CONSUMER SEMANTICS (the contract the wake-monitor + tick honor):
#   - The wake-monitor wakes the Mate ONLY on "wake".
#   - "batch" items are recorded in the seen-set (so they don't re-fire) but do
#     NOT wake -- they drain at the next tick's reconcile pass.
#   - "silent" items are recorded in the seen-set too, but are suppressed from
#     BOTH the wake path AND the batch-reconcile surface (log-only).
#
# =========================================================================
# THE INPUT ENVELOPE (v1) -- declared inputs
# =========================================================================
# Producers should DECLARE their intent rather than leave the classifier to
# guess. Every input may carry a small standard metadata header -- YAML
# frontmatter for file-drops, the JSON-field equivalent for signal/thread
# events:
#
#   ---
#   shipkit_input: v1          # marks a declared input (the envelope marker)
#   source: status-surface     # producer id (free string)
#   kind: steer                # semantic type (steer|comment|status-request
#                              #   |notification|sensor-redrop|...)
#   wake_class: wake           # AUTHORITATIVE wake-class: wake | batch | silent
#   ---
#
# JSON equivalent (thread/signal events):
#   {"shipkit_input":"v1","source":"...","kind":"...","wake_class":"wake", ...}
#
# Only `wake_class` is authoritative; the others are descriptive (so undeclared
# legacy inputs still classify). A producer that declares `wake_class` controls
# its own fate; one that declares only `kind` gets the documented default; one
# that declares neither falls to the heuristic AND triggers a stderr warning so
# it gets noticed and migrated.
#
# THE 3-STEP CLASSIFIER LADDER:
#   1. `wake_class` declared  -> use it verbatim (authoritative; no guessing).
#   2. else `kind` declared   -> documented kind->class default table (below).
#   3. else                   -> content heuristic, AND warn on stderr
#                               ("undeclared input <path> -- heuristically
#                               classified <class>"). The warning is the point:
#                               the heuristic is a safety net, not the primary
#                               path, and undeclared sources get fixed over time.
#
# kind -> class default table (step 2):
#   steer | comment | status-request | ask  -> wake
#   notification                             -> batch
#   sensor-redrop                            -> batch
#   (any other / unrecognized kind)          -> wake  (directive-leaning floor)
#
# -------------------------------------------------------------------------
# DEPLOYMENT OVERRIDE -- edit the mapping blocks below for your sensors.
# -------------------------------------------------------------------------
# A fresh Ship has DIFFERENT sensors (no CI bot, a different chat surface) but
# the SAME classes. Map your own signal sources here; the shape is fixed, the
# signal list is configuration. These apply to the heuristic (step 3) path and
# the always-on self-author guard.
#
# BATCH_FILENAME_GLOBS : basename globs that are pure sensor-noise -> batch.
#     Empty by default (no sensors assumed); add your own bot/CI prefixes,
#     e.g. ['pr-buddy-*', '*ci-failure*'].
# BATCH_TYPES          : frontmatter `type:` values that are bookkeeping -> batch.
# WAKE_TYPES           : frontmatter `type:` values that are directives -> wake.
# SELF_AUTHOR_TAGS     : `source:` values that mean "the loop wrote this" -> batch,
#     so the loop never wakes itself on its own surfaces.
#
# PRINCIPLE: default to WAKE when ambiguous -- a missed steer costs more than an
# extra tick (this is the floor; never silently swallow something that might be
# a directive). `silent` is only ever reached via an explicit declaration.
# -------------------------------------------------------------------------

import fnmatch
import os
import re
import sys

# --- mapping blocks (override per deployment) ---------------------------
BATCH_FILENAME_GLOBS = [
    # 'pr-buddy-*',     # example: a CI bot that re-drops unchanged PR state
    # '*ci-failure*',   # example: CI failure re-drops (poll live state at tick time)
]
BATCH_TYPES = ["status-applied", "close-applied"]
WAKE_TYPES = ["steer", "comment", "status-request", "ask"]
SELF_AUTHOR_TAGS = ["mate"]  # values of `source:` that mean "the loop wrote this"
# ------------------------------------------------------------------------


def read_field(text, name):
    """Echo the first scalar value of `name`, or "" if absent.

    Tolerant of both YAML (key: val at line start) and inline JSON
    ({"key":"val",...}) shapes. The key must be preceded by start-of-line,
    '{', ',', or whitespace so a bare `kind` never matches a substring like
    `some_kind`. Mirrors the grep|sed pipeline of the original bash port.
    """
    # Find the first line that carries the key (grep -m1 semantics).
    line_re = re.compile(r'(^|[\s,{])"?' + re.escape(name) + r'"?[ \t]*:')
    line = None
    for ln in text.splitlines():
        if line_re.search(ln):
            line = ln
            break
    if line is None:
        return ""

    # Strip up to and including the key + ':' + optional opening quote.
    # The sed used two alternatives: one anchored on a preceding non-ident
    # char, one anchored at start-of-line. fnmatch the JSON/whitespace-led
    # case first, then the line-leading case.
    m = re.search(r'[^_a-zA-Z]' + re.escape(name) + r'"?[ \t]*:[ \t]*"?', line)
    if m:
        rest = line[m.end():]
    else:
        m = re.match(r'^' + re.escape(name) + r'"?[ \t]*:[ \t]*"?', line)
        if m:
            rest = line[m.end():]
        else:
            rest = line

    # Strip from the first closing delimiter ("/space/,/}) onward.
    rest = re.split(r'["\s,}]', rest, maxsplit=1)[0]
    return rest


CONTRACT_LINES = [
    "classify_input.py self-test (no fixture runner found):",
    "  Run against a sample file: classify_input.py <inputfile>",
    "  3-step ladder: wake_class (authoritative) -> kind table -> heuristic.",
    "  Output is one of: wake | batch | silent",
    "  Declared:  wake_class: wake|batch|silent  -> used verbatim",
    "  kind only: steer|comment|status-request|ask -> wake;",
    "             notification|sensor-redrop        -> batch",
    "  Undeclared: content heuristic + a stderr warning",
]


def classify(path):
    """Classify the input file at `path`. Returns the class string and prints
    any stderr warnings as a side effect (mirroring the bash contract)."""
    base = os.path.basename(path)

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        # Missing file/fields are non-fatal (empty string), as in the bash port.
        text = ""

    wake_class = read_field(text, "wake_class")
    kind = read_field(text, "kind")
    type_ = read_field(text, "type")
    source = read_field(text, "source")

    # Self-authored surfaces must never wake the loop (always-on guard, applies
    # regardless of declaration -- the loop shouldn't wake itself even if a self-
    # authored producer mistakenly stamped wake_class: wake).
    if source in SELF_AUTHOR_TAGS:
        return "batch"

    # --- STEP 1: wake_class declared -> authoritative --------------------
    if wake_class in ("wake", "batch", "silent"):
        return wake_class
    elif wake_class != "":
        sys.stderr.write(
            f"classify_input: unknown wake_class '{wake_class}' in {path} "
            "— ignoring declaration, falling through\n"
        )

    # --- STEP 2: kind declared -> documented kind->class default table ---
    if kind:
        if kind in ("steer", "comment", "status-request", "ask"):
            return "wake"
        if kind in ("notification", "sensor-redrop"):
            return "batch"
        return "wake"  # directive-leaning floor

    # --- STEP 3: content heuristic (safety net) + WARN -------------------
    # No declaration -> fall back to the legacy heuristic and warn so the source
    # gets noticed and migrated.

    # 3a. Filename-glob sensor-noise -> batch (checked first; cheapest).
    for g in BATCH_FILENAME_GLOBS:
        if fnmatch.fnmatch(base, g):
            sys.stderr.write(
                f"classify_input: undeclared input {path} "
                "— heuristically classified batch\n"
            )
            return "batch"

    # 3b. Legacy frontmatter `type:` classification.
    heuristic = "wake"
    for t in WAKE_TYPES:
        if type_ == t:
            heuristic = "wake"
            break
    for t in BATCH_TYPES:
        if type_ == t:
            heuristic = "batch"
            break
    # (No recognized type -- e.g. a plain chat message -- stays the "wake" floor.)

    sys.stderr.write(
        f"classify_input: undeclared input {path} "
        f"— heuristically classified {heuristic}\n"
    )
    return heuristic


def run_tests():
    """Defer to the fixture runner if present; else print the contract."""
    here = os.path.dirname(os.path.abspath(__file__))
    runner = os.path.join(here, "..", "tests", "test_classify_input.py")
    if os.path.isfile(runner):
        os.execv(sys.executable, [sys.executable, runner])
    for line in CONTRACT_LINES:
        sys.stderr.write(line + "\n")
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "--test":
        return run_tests()

    if len(argv) < 2 or not argv[1]:
        sys.stderr.write(
            "usage: classify_input.py <inputfile>   "
            "(or --test for the contract)\n"
        )
        return 1

    print(classify(argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
