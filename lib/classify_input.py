#!/usr/bin/env python3
# classify_input.py <inputfile> -> prints "wake", "batch", "silent", or "quarantine"
#
# The Loop Mode INPUT-MODEL seam. Classify an incoming item (an inbox edit, a
# drop file from an external process, a queued signal) into a wake-class:
#
#   WAKE   = a directive someone is waiting on -> interrupt the loop NOW.
#   BATCH  = bookkeeping / sensor-noise -> the live ticket frontmatter already
#            serves the Captain's views, so it is reconciled in ONE pass at the
#            next tick (the ship-tick "Check inbox / batch-reconcile" step).
#   SILENT = pure noise -> don't wake AND don't surface. Recorded in the seen-set
#            (so it doesn't re-fire) and logged, but never lands on a wake OR a
#            batch surface. For sources that are genuinely log-only.
#   QUARANTINE = a PEER-MARKED drop that FAILED peer-envelope validation ->
#            never wake, never batch-as-normal. Distinct so the Mate can
#            inspect it deliberately instead of processing it as routine
#            input. Only ever emitted when the peer-comms module is installed
#            (see PEER PRE-FILTER below); reached before the 3-step ladder.
#
# CONSUMER SEMANTICS (the contract the wake-monitor + tick honor):
#   - The wake-monitor wakes the Mate ONLY on "wake".
#   - "batch" items are recorded in the seen-set (so they don't re-fire) but do
#     NOT wake -- they drain at the next tick's reconcile pass.
#   - "silent" items are recorded in the seen-set too, but are suppressed from
#     BOTH the wake path AND the batch-reconcile surface (log-only).
#   - "quarantine" items are recorded in the seen-set and NEVER wake; they are
#     surfaced at the next tick as suspect (validation problems on stderr at
#     classify time), for the Mate to inspect -- not to act on as input.
#
# =========================================================================
# PEER PRE-FILTER (runs before the ladder; peer-comms module integration)
# =========================================================================
# When a drop LOOKS peer-originated -- any frontmatter line declares a
# peer-namespaced kind (peer-*/xship-*) or a peer-shaped source (ship-...)
# -- it must pass modules/peer-comms/peer_envelope.py validate() BEFORE the
# ladder runs. Validation failure -> "quarantine" (with the problems printed
# to stderr). The detection scans EVERY frontmatter occurrence, not just the
# first, so a duplicate-key drop (`kind: steer` + `kind: peer-note`) cannot
# dodge the filter by ordering its lines.
#
# ENABLEMENT: whether peer-comms is "installed" is read from the semantic
# install record, state/install.json (written by shipkit_init.py) — file
# presence in the clone is NOT enablement (a full shipkit checkout carries
# every module's source whether or not the operator selected it). When the
# record exists, it is authoritative: peer-comms enabled iff "peer-comms" is
# in its modules list. When it's absent (a pre-record install), fall back to
# the legacy file-existence check so old ships keep working. Either way the
# import is guarded: any failure means "not installed", the pre-filter is a
# no-op, and classification behaves exactly as it did before the module
# existed. Non-peer-looking drops never touch this path at all.
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
import json
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


# --- peer pre-filter (import-guarded peer-comms integration) --------------
# A line that declares a peer-namespaced kind (peer-*/xship-*) or a
# peer-shaped source (ship-<...>; note `ship.html` does NOT match -- no dash).
# Applied per-line across the whole text so duplicate-key drops can't hide a
# peer marker behind a first-wins read.
_PEER_HINT_RE = re.compile(
    r'(?:^|[\s,{])"?(?:kind"?[ \t]*:[ \t]*"?(?:peer-|xship-)'
    r'|source"?[ \t]*:[ \t]*"?ship-)')

# Cache for the guarded import: "unset" -> not tried yet; None -> unavailable
# (module not installed / import failed); otherwise the loaded module. Tests
# reset element 0 to "unset" after changing SHIPKIT_PEER_ENVELOPE.
_PEER_ENVELOPE = ["unset"]


def _peer_comms_enabled():
    """Is peer-comms ENABLED (not merely present in the clone)?

    Authoritative source: the semantic install record, state/install.json
    (relative to this file: lib/ -> ship root -> state/; override with the
    SHIPKIT_INSTALL_MANIFEST env var for tests). Record present and readable
    -> enabled iff "peer-comms" is in its modules list. Record absent or
    unreadable (a pre-record install) -> None, meaning "unknown — fall back
    to the legacy file-existence check". NEVER raises."""
    try:
        path = os.environ.get("SHIPKIT_INSTALL_MANIFEST") or os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "..", "state", "install.json")
        if not os.path.isfile(path):
            return None
        import json
        with open(path, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        modules = doc.get("modules")
        if not isinstance(modules, list):
            return None
        return "peer-comms" in modules
    except Exception:
        return None


def _peer_envelope():
    """Load modules/peer-comms/peer_envelope.py if the module is ENABLED.

    Returns the module or None. NEVER raises: any failure (module disabled,
    absent, import error) means "peer-comms not installed" and the classifier
    behaves exactly as it did before peer-comms existed. Enablement comes from
    state/install.json when present (see _peer_comms_enabled); a pre-record
    install falls back to file existence. Path is resolved relative to this
    file (lib/ -> ship root -> modules/peer-comms/); the SHIPKIT_PEER_ENVELOPE
    env var overrides it (used by tests to simulate an absent module)."""
    if _PEER_ENVELOPE[0] != "unset":
        return _PEER_ENVELOPE[0]
    mod = None
    try:
        if _peer_comms_enabled() is False:
            _PEER_ENVELOPE[0] = None
            return None
        path = os.environ.get("SHIPKIT_PEER_ENVELOPE") or os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            "..", "modules", "peer-comms", "peer_envelope.py")
        if os.path.isfile(path):
            import importlib.util
            spec = importlib.util.spec_from_file_location("peer_envelope", path)
            if spec and spec.loader:
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
    except Exception:  # any import trouble == module unavailable, never fatal
        mod = None
    _PEER_ENVELOPE[0] = mod
    return mod


def _looks_peer(text):
    """True when ANY frontmatter-ish line declares a peer kind or source."""
    return any(_PEER_HINT_RE.search(ln) for ln in text.splitlines())
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


# The control fields the classifier trusts. Read from STRUCTURE only (a markdown
# frontmatter block or a JSON top-level key) -- never from body/message text.
CONTROL_FIELDS = ("wake_class", "kind", "type", "source")


def frontmatter(text):
    """Return the leading `---`...`---` YAML block (its inner lines), or "".

    Only the FIRST fenced block at the top of the file counts; a `---` that
    appears later in the body is not frontmatter. An unclosed opening fence
    yields "" -- a half-written header carries no trusted fields."""
    lines = text.splitlines()
    i = 0
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    if i >= len(lines) or lines[i].strip() != "---":
        return ""
    for j in range(i + 1, len(lines)):
        if lines[j].strip() == "---":
            return "\n".join(lines[i + 1:j])
    return ""


def control_fields(text):
    """Extract the control fields from STRUCTURE only (037 hardening).

    JSON input: parse and read TOP-LEVEL keys only -- a `wake_class` nested in a
    "body" string is never seen. A malformed or non-object JSON payload yields
    no trusted fields, so classification falls through to the safe (wake)
    direction rather than trusting a smuggled token.
    Markdown input: read fields only from the leading frontmatter block, never
    from body text (so a body that quotes `wake_class: silent` cannot suppress a
    real directive)."""
    if text.lstrip().startswith("{"):
        try:
            obj = json.loads(text)
        except (json.JSONDecodeError, ValueError):
            obj = None
        if not isinstance(obj, dict):
            return {name: "" for name in CONTROL_FIELDS}
        out = {}
        for name in CONTROL_FIELDS:
            val = obj.get(name, "")
            out[name] = val if isinstance(val, str) else ("" if val is None else str(val))
        return out
    front = frontmatter(text)
    return {name: read_field(front, name) for name in CONTROL_FIELDS}


CONTRACT_LINES = [
    "classify_input.py self-test (no fixture runner found):",
    "  Run against a sample file: classify_input.py <inputfile>",
    "  3-step ladder: wake_class (authoritative) -> kind table -> heuristic.",
    "  Output is one of: wake | batch | silent | quarantine",
    "  Peer pre-filter (before the ladder, when peer-comms is installed):",
    "    peer-marked drop (kind: peer-*/xship-* or source: ship-*) that fails",
    "    peer_envelope.validate() -> quarantine (never wake, never batch)",
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

    # --- PEER PRE-FILTER (before the ladder; import-guarded) --------------
    # A drop carrying any peer marker (kind: peer-*/xship-* or source: ship-*
    # on ANY line) must be a VALID peer envelope or it is quarantined --
    # never processed as normal input, never allowed to reach the ladder
    # where a smuggled directive field could classify as wake/steer-shaped.
    if text and _looks_peer(text):
        pe = _peer_envelope()
        if pe is not None:
            problems = pe.validate(text, basename=base)
            if problems:
                sys.stderr.write(
                    "classify_input: QUARANTINE {} -- peer-marked drop failed "
                    "envelope validation: {}\n".format(path, "; ".join(problems)))
                return "quarantine"

    # Structure-only extraction (037): control fields come from the frontmatter
    # block / JSON top-level keys, never from body text.
    fields = control_fields(text)
    wake_class = fields["wake_class"]
    kind = fields["kind"]
    type_ = fields["type"]
    source = fields["source"]

    self_author = source in SELF_AUTHOR_TAGS

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

    # Self-authored surfaces default to batch so the loop never wakes itself on
    # its own bookkeeping. But `source` is UNTRUSTED FOR SUPPRESSION (037): it may
    # only batch an OTHERWISE-UNDECLARED item -- it never overrides an explicit
    # wake_class or directive `kind` above. (v2 checked this BEFORE the ladder,
    # which silently batched an explicit steer; the reorder restores 037.)
    if self_author:
        return "batch"

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
    runner = os.path.join(here, "tests", "test_classify_input.py")
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
