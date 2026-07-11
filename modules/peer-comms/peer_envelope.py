#!/usr/bin/env python3
"""peer_envelope.py — the peer-comms envelope (v1): compose, parse, validate.

The envelope is the structural half of the peer-comms doctrine (the doctrinal
half — a peer message is INPUT, not AUTHORITY — lives in peer-comms.md). Every
peer message is a markdown file with YAML frontmatter:

    ---
    shipkit_input: v1
    source: ship-beta-mate          # sender ship identity — MUST match the
                                    #   allowlist ^ship-<name>-mate$ (see SOURCE_RE)
    kind: peer-migration            # semantic type; MUST carry a peer prefix
    wake_class: wake                # wake | batch | silent (authoritative for
                                    #   classify_input.py — the receiver's ladder step 1)
    msg_id: peer-ship-beta-2026-07-02-1215-migration-report   # == file basename
    in_reply_to: <peer msg_id>      # optional threading
    thread: [migration-2026-07-02]  # optional multi-message thread token
    authenticity: tailnet-ssh-key   # transport-trust CLAIM (not proof — see doc)
    sent: 2026-07-02 12:15 -0500    # computed, not typed (field-proven rule)
    ---
    # [migration-2026-07-02] Title

    Self-contained body ...

ANTI-MASQUERADE (the load-bearing validation): a peer message must be
STRUCTURALLY UNABLE to pose as local authority. `validate()` therefore rejects,
on compose AND on receive:
  - DUPLICATE frontmatter keys, outright. Different consumers disagree on
    duplicate keys (this parser is first-wins; a last-wins parser or a
    careless human reader could be shown a different value for the same key)
    — that parser differential is a masquerade vector, so a security
    validator rejects the ambiguity itself rather than picking a winner.
  - `kind` in the Captain-directive kinds (steer|comment|status-request|ask)
  - `kind` without a recognized peer prefix (peer-*, xship-*)
  - `source` not matching the peer naming convention ^ship-<name>-mate$
    (ALLOWLIST — the live convention: ship-windows-mate, ship-mac-mate).
    Reserved local-authority identities (captain, captain-ui, mate, bosun,
    ship.html — the live Captain-UI surface) are additionally rejected by
    name with a pointed captain-masquerade error (belt and suspenders).
  - a legacy `type:` field carrying a Captain-directive value
So a peer envelope can at worst classify as a generic wake — never as a
Captain steer, and never lands on the Captain thread. (Receive-side
enforcement is wired through lib/classify_input.py, which quarantines
peer-marked drops that fail this validation — see peer-comms.md.)

msg_id == basename (sans .md) is enforced for inbox drops; files named
`*.reply.md` (the acks/ return-channel convention: `<orig-msg-id>.reply.md`)
skip the basename check since they're keyed by the message they answer.

Stdlib-only, cross-platform (Windows/Git-Bash included). Extracted from the
live lane proven 2026-07-02 (the shipkit-v2 cross-ship migration).

CLI:  peer_envelope.py validate <file>     exit 0 valid / 1 problems (listed)
"""

import re
import sys
from datetime import datetime

ENVELOPE_VERSION = "v1"

REQUIRED_FIELDS = ("source", "kind", "wake_class", "msg_id", "authenticity", "sent")
WAKE_CLASSES = ("wake", "batch", "silent")

# Peer kinds must be namespaced so they can never collide with local kinds.
# ("xship-" is the field-proven 2026-07-02 spelling; "peer-" is the generic one.)
ALLOWED_KIND_PREFIXES = ("peer-", "xship-")

# Peer sources are ALLOWLISTED by shape, not blocklisted by name: `source`
# must match the live naming convention ship-<name>-mate (field-proven:
# ship-windows-mate, ship-mac-mate). A blocklist can never enumerate every
# local-authority surface (the live Captain-UI writes `source: ship.html`,
# which no reserved-name list anticipated) — the allowlist rejects everything
# that isn't structurally a peer Mate.
SOURCE_RE = re.compile(r"^ship-[a-z0-9][a-z0-9-]*-mate$")

# Local-authority values a peer envelope may NEVER carry (anti-masquerade).
# RESERVED_SOURCES is belt-and-suspenders under the allowlist above: these
# names get a pointed captain-masquerade error instead of the generic
# bad-source one. `ship.html` is the REAL live Captain-UI source.
RESERVED_KINDS = ("steer", "comment", "status-request", "ask")
RESERVED_SOURCES = ("captain", "captain-ui", "mate", "bosun", "ship.html")
RESERVED_TYPES = ("steer", "comment", "status-request", "ask")

MSG_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def slugify(text, max_len=48):
    """Filename-safe slug for topics: lowercase, [a-z0-9-], collapsed dashes."""
    slug = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    return slug[:max_len].rstrip("-") or "message"


def now_stamp():
    """Compact local timestamp for msg_ids: YYYY-MM-DD-HHMM."""
    return datetime.now().strftime("%Y-%m-%d-%H%M")


def sent_stamp():
    """Human `sent:` timestamp WITH utc offset. Always computed, never typed —
    a hand-typed sent: was a live-lane wart (drops carried '~12:15' guesses)."""
    return datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %z")


def make_msg_id(ship_name, topic, stamp=None):
    """peer-<ship>-<YYYY-MM-DD-HHMM>-<topic-slug> — the live naming convention,
    genericized (the field version used xship-<ship>-...)."""
    return "peer-{}-{}-{}".format(slugify(ship_name), stamp or now_stamp(), slugify(topic))


def compose(source, kind, wake_class, msg_id, title, body,
            authenticity, in_reply_to=None, thread=None, sent=None):
    """Build a full envelope document (frontmatter + body). Returns the text.
    Raises ValueError if the result would not validate — a sender must be
    unable to emit a masquerading or malformed message."""
    lines = ["---", "shipkit_input: {}".format(ENVELOPE_VERSION)]
    lines.append("source: {}".format(source))
    lines.append("kind: {}".format(kind))
    lines.append("wake_class: {}".format(wake_class))
    lines.append("msg_id: {}".format(msg_id))
    if in_reply_to:
        lines.append("in_reply_to: {}".format(in_reply_to))
    if thread:
        lines.append("thread: {}".format(thread))
    lines.append("authenticity: {}".format(authenticity))
    lines.append("sent: {}".format(sent or sent_stamp()))
    lines.append("---")
    lines.append("")

    title = (title or "").strip() or msg_id
    if thread and thread not in title:
        title = "{} {}".format(thread, title)
    lines.append("# {}".format(title))
    lines.append("")
    lines.append((body or "").rstrip())
    lines.append("")
    text = "\n".join(lines)

    problems = validate(text)
    if problems:
        raise ValueError("compose produced an invalid envelope: " + "; ".join(problems))
    return text


def _parse(text):
    """Split an envelope into (fields dict, body str, duplicate-keys list).

    Frontmatter is parsed as flat `key: scalar` lines only (the envelope never
    nests). FIRST-WINS on duplicate keys — matching classify_input.read_field
    and what a human reader sees first — with every duplicate recorded so
    validate() can reject the ambiguity outright (a first-wins/last-wins
    parser differential is a masquerade vector, never a tie to break).
    Returns ({}, text, []) when there is no frontmatter."""
    if not text.startswith("---"):
        return {}, text, []
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, text, []
    fields = {}
    duplicates = []
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            body = "\n".join(lines[i + 1:])
            return fields, body, duplicates
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$", line)
        if m:
            key = m.group(1)
            if key in fields:
                duplicates.append(key)  # first occurrence wins; dup recorded
            else:
                fields[key] = m.group(2).strip().strip('"').strip("'")
    return {}, text, []  # never closed -> not a frontmatter envelope


def parse(text):
    """Split an envelope into (fields dict, body str). First-wins on duplicate
    frontmatter keys; use validate() to REJECT duplicates (it always does)."""
    fields, body, _dups = _parse(text)
    return fields, body


def validate(text, basename=None):
    """Return a list of problems (empty == valid).

    `basename` (optional) is the on-disk filename; when given, msg_id must
    equal its stem — EXCEPT for `*.reply.md` files (the acks/ return channel is
    keyed by the message being answered, and carries its own fresh msg_id)."""
    fields, _body, duplicates = _parse(text)
    if not fields:
        return ["no YAML frontmatter envelope found"]

    problems = []

    # --- duplicate keys: rejected outright (parser-differential attack) -----
    # A drop carrying e.g. `kind: steer` AND `kind: peer-note` shows different
    # values to first-wins and last-wins consumers. A security validator must
    # reject the ambiguity itself, not adjudicate it.
    for key in duplicates:
        problems.append(
            "duplicate frontmatter key {!r} — duplicate keys present different "
            "values to different parsers (first-wins vs last-wins) and are "
            "rejected outright".format(key))
    for f in REQUIRED_FIELDS:
        if not fields.get(f):
            problems.append("missing required field: {}".format(f))

    wake_class = fields.get("wake_class", "")
    if wake_class and wake_class not in WAKE_CLASSES:
        problems.append("bad wake_class {!r} (must be one of {})".format(
            wake_class, "|".join(WAKE_CLASSES)))

    # --- anti-masquerade: peer traffic must be structurally non-Captain ------
    kind = fields.get("kind", "")
    if kind:
        if kind in RESERVED_KINDS:
            problems.append(
                "captain-masquerade: kind {!r} is a local-directive kind — "
                "a peer message may never carry it".format(kind))
        elif not kind.startswith(ALLOWED_KIND_PREFIXES):
            problems.append(
                "bad kind {!r}: peer kinds must be namespaced with one of {} "
                "(structural distinctness from local kinds)".format(
                    kind, "/".join(ALLOWED_KIND_PREFIXES)))

    source = fields.get("source", "")
    if source:
        if source.lower() in RESERVED_SOURCES:
            # Belt and suspenders: these are known local-authority surfaces
            # (incl. ship.html, the live Captain-UI source) — pointed error.
            problems.append(
                "captain-masquerade: source {!r} claims a local-authority identity "
                "— a peer message may never carry it".format(source))
        elif not SOURCE_RE.match(source):
            problems.append(
                "bad source {!r}: peer sources must be namespaced ship-<name>-mate "
                "(allowlist {}) — anything else is treated as a local surface, "
                "not a peer".format(source, SOURCE_RE.pattern))

    type_ = fields.get("type", "")
    if type_ and type_.lower() in RESERVED_TYPES:
        problems.append(
            "captain-masquerade: type {!r} is a local-directive type — "
            "a peer message may never carry it".format(type_))

    msg_id = fields.get("msg_id", "")
    if msg_id and not MSG_ID_RE.match(msg_id):
        problems.append("bad msg_id {!r} (allowed: [A-Za-z0-9._-])".format(msg_id))
    if msg_id and basename and not basename.endswith(".reply.md"):
        stem = re.sub(r"\.md$", "", basename)
        if stem != msg_id:
            problems.append(
                "msg_id {!r} != file basename {!r} (msg_id IS the basename "
                "for inbox drops)".format(msg_id, stem))

    return problems


def main(argv):
    if len(argv) >= 3 and argv[1] == "validate":
        import os
        path = argv[2]
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError as e:
            sys.stderr.write("peer_envelope: cannot read {}: {}\n".format(path, e))
            return 1
        problems = validate(text, basename=os.path.basename(path))
        if problems:
            for p in problems:
                sys.stderr.write("INVALID: {}\n".format(p))
            return 1
        print("valid peer envelope ({})".format(ENVELOPE_VERSION))
        return 0
    sys.stderr.write("usage: peer_envelope.py validate <file>\n")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
