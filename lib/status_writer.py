#!/usr/bin/env python3
"""status_writer.py — the reference writer for Loop Mode's state/status.json.

This owns the CORE status schema and is the only sanctioned way to write it.
Ad-hoc heredoc/echo writes drift field-by-field; this script computes every
timestamp itself so stamps can never be guessed or typed as literals.

CORE fields (all this writer knows about):
    tick         : int     monotonic counter, strictly increasing
    wake_reason  : string  what woke this tick (named, never assumed)
    now          : object  {doing, since (ISO), wake} — live Mate activity
    next_wake    : string  local-time clock stamp + reason, COMPUTED from now()
    last_actions : list    this tick's actions, plain sentences
    validator    : string  result of the reconcile step (or "NONE")
    generated_at : string  ISO 8601 stamp, set on every write

Modules EXTEND this schema. The status-surface UI preset adds rich fields
(hot_list, ready_for_you, crew[], steer_feedback[], ticks[] history). A headless
loop never writes them — the durable per-tick record is the mate-log telemetry
line, not a ticks[] array. A module subclasses/wraps this writer to add fields;
unknown fields already present in the file are preserved untouched on every write.

Stdlib only — no pip installs. Cross-platform (uses pathlib + datetime).

Subcommands
-----------
  --init                    Seed a fresh status.json (tick 0, empty core fields).
  now <doing> [--wake R]    Set now.doing/wake; stamps now.since via now().
  tick <n> <wake> [opts]    Advance to tick n; sync core fields. Computes
                            next_wake from --delay-seconds via now()+delta.
  --schema                  Print the field contract and exit.

next_wake is ALWAYS computed: pass --delay-seconds N and the writer renders
"HH:MM <tz> (<reason>)" from datetime.now() + N. Never type a clock literal.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SHIP_ROOT = SCRIPT_DIR.parent
DEFAULT_STATUS = SHIP_ROOT / "state" / "status.json"

SCHEMA_DOC = """\
status.json CORE field contract (Loop Mode)
============================================

tick          : int     Current tick. Strictly increasing — `tick` rejects n <= current.
wake_reason   : string   Named wake trigger for this tick.
now           : object   { doing, since, wake } — live Mate activity (see below).
next_wake     : string   Local clock stamp + reason, e.g. "14:05 CDT (fallback)".
                         COMPUTED by the writer from now()+delay; never a typed literal.
last_actions  : list     This tick's actions as plain sentences.
validator     : string   Reconcile result. Convention: starts with CLEAN / MISMATCH /
                         STALE, or "NONE" when no validator is configured.
generated_at  : string   ISO 8601 with offset. Set on every write.

now object
----------
  doing : string  Current activity (one plain sentence).
  since : string  ISO 8601 with offset. MUST be a full timestamp, not bare HH:MM
                  (renderers call new Date(iso); a bare time => Invalid Date).
  wake  : string  Wake reason for this activity.

Assertions enforced on every write
-----------------------------------
1. now.since (when present) must parse as a full ISO 8601 date+time.
2. tick n must be strictly greater than the current tick.

crew[] (module field, optionally written here)
----------------------------------------------
  Written ONLY when --crew-json is passed (to `now` or `tick`); otherwise left
  untouched. Each item: { id, label, ticket, since, model } (all strings).
  Represents the crew agents running RIGHT NOW — the status surface renders a
  live roster from it ("N crew out" / "idle"). Invalid --crew-json warns to
  stderr and is skipped (the now/tick write still proceeds).

Other module extensions (NOT written here): hot_list, ready_for_you,
steer_feedback[], ticks[]. Preserved untouched if a module wrote them.
"""


def _abort(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def now_iso() -> str:
    """Current local time as ISO 8601 with UTC offset. Always computed."""
    return datetime.now(tz=timezone.utc).astimezone().isoformat()


def assert_iso_timestamp(value: str, field: str) -> None:
    """Reject bare HH:MM and anything that doesn't parse as a date+time."""
    if not value:
        _abort(f"{field} is empty — must be a full ISO 8601 timestamp")
    if re.match(r"^\d{1,2}:\d{2}", value) and len(value) < 16:
        _abort(
            f"{field}={value!r} looks like a bare clock time, not an ISO timestamp. "
            "Renderers call new Date(iso); a bare time => Invalid Date. "
            "Use ISO 8601: 2026-06-20T15:27:04-05:00"
        )
    if not re.search(r"\d{4}-\d{2}-\d{2}", value):
        _abort(f"{field}={value!r} is not an ISO 8601 timestamp (no YYYY-MM-DD).")


def assert_whole_doc(doc: dict) -> None:
    now = doc.get("now")
    if isinstance(now, dict) and now.get("since"):
        assert_iso_timestamp(now["since"], "now.since")


def parse_crew_json(raw: str) -> list | None:
    """Parse the --crew-json argument into a normalized crew[] list.

    Each item is coerced to {id, label, ticket, since, model} with string
    values (missing keys -> ""). On any parse/shape error we WARN to stderr and
    return None so the caller can skip the crew write without crashing the
    writer — a malformed roster must never block a now/tick state update.
    """
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"WARN: --crew-json is not valid JSON ({e}); skipping crew[]",
              file=sys.stderr)
        return None
    if not isinstance(data, list):
        print(f"WARN: --crew-json must be a JSON array, got {type(data).__name__}; "
              "skipping crew[]", file=sys.stderr)
        return None
    out = []
    for i, item in enumerate(data):
        if not isinstance(item, dict):
            print(f"WARN: --crew-json item {i} is not an object; skipping it",
                  file=sys.stderr)
            continue
        out.append({
            "id": str(item.get("id", "")),
            "label": str(item.get("label", "")),
            "ticket": str(item.get("ticket", "")),
            "since": str(item.get("since", "")),
            "model": str(item.get("model", "")),
        })
    return out


def load_status(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        _abort(f"status.json not found at {path} — run `status_writer.py --init` first")
    except json.JSONDecodeError as e:
        _abort(f"status.json is not valid JSON: {e}")


def write_status(doc: dict, path: Path) -> None:
    """Assert, atomic-write (tmp + rename), read-back verify."""
    assert_whole_doc(doc)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    serialized = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
    tmp.write_text(serialized, encoding="utf-8")
    os.replace(tmp, path)  # atomic on same filesystem; overwrites on POSIX + Windows
    try:
        check = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        _abort(f"read-back failed (file written but not valid JSON): {e}")
    if check.get("tick") != doc.get("tick"):
        _abort("read-back failed: tick mismatch")


def seed_doc() -> dict:
    return {
        "tick": 0,
        "wake_reason": "init",
        "now": {"doing": "", "since": now_iso(), "wake": "init"},
        "next_wake": "",
        "last_actions": [],
        "validator": "NONE",
        "generated_at": now_iso(),
    }


def cmd_init(args: argparse.Namespace, path: Path) -> None:
    if path.exists() and not args.force:
        _abort(f"{path} already exists — pass --force to overwrite")
    write_status(seed_doc(), path)
    print(f"OK: seeded {path} at tick 0")


def apply_crew(doc: dict, args: argparse.Namespace) -> None:
    """Write doc['crew'] from --crew-json when supplied. Omitted => untouched
    (preserves an existing roster); a parse error warns + leaves it unchanged."""
    if getattr(args, "crew_json", None) is None:
        return
    crew = parse_crew_json(args.crew_json)
    if crew is None:
        return  # warned to stderr; don't break the now/tick write
    doc["crew"] = crew


def cmd_now(args: argparse.Namespace, path: Path) -> None:
    doc = load_status(path)
    if not isinstance(doc.get("now"), dict):
        doc["now"] = {}
    doc["now"]["doing"] = args.doing
    doc["now"]["since"] = now_iso()  # always computed, never typed
    if args.wake:
        doc["now"]["wake"] = args.wake
    apply_crew(doc, args)
    doc["generated_at"] = now_iso()
    write_status(doc, path)
    print(f"OK: now.doing set, since={doc['now']['since']}")


def cmd_tick(args: argparse.Namespace, path: Path) -> None:
    doc = load_status(path)
    current = doc.get("tick", 0)
    if not isinstance(current, int):
        current = 0
    if args.n <= current:
        _abort(
            f"tick n={args.n} is not greater than current tick={current}. "
            "The counter is monotonic — no skips, no reuse."
        )

    # next_wake is ALWAYS computed from now() — never a typed clock literal.
    if args.delay_seconds is not None:
        wake_dt = datetime.now() + timedelta(seconds=args.delay_seconds)
        tz_abbr = datetime.now(tz=timezone.utc).astimezone().strftime("%Z")
        reason = args.wake_label or "fallback"
        next_wake = wake_dt.strftime(f"%H:%M {tz_abbr} ({reason})")
    else:
        next_wake = doc.get("next_wake", "")

    doc["tick"] = args.n
    doc["wake_reason"] = args.wake
    doc["next_wake"] = next_wake
    doc["generated_at"] = now_iso()
    if args.validator is not None:
        doc["validator"] = args.validator
    if args.last_actions is not None:
        doc["last_actions"] = args.last_actions
    if args.clear_now:
        doc["now"] = {"doing": "", "since": now_iso(), "wake": args.wake}
    apply_crew(doc, args)
    write_status(doc, path)
    print(f"OK: tick {args.n}, next_wake={next_wake!r}")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="status_writer.py",
        description="Reference writer for Loop Mode's CORE state/status.json fields",
    )
    p.add_argument("--status", metavar="PATH", default=str(DEFAULT_STATUS),
                   help="Path to status.json (default: state/status.json next to scripts/)")
    p.add_argument("--schema", action="store_true", help="Print the field contract and exit")
    p.add_argument("--init", action="store_true", help="Seed a fresh status.json at tick 0")
    p.add_argument("--force", action="store_true", help="With --init, overwrite an existing file")

    sub = p.add_subparsers(dest="cmd")

    pn = sub.add_parser("now", help="Set now.doing/wake (stamps since via now())")
    pn.add_argument("doing", help="Current activity description")
    pn.add_argument("--wake", help="Wake reason")
    pn.add_argument("--crew-json", dest="crew_json", metavar="JSON",
                    help="JSON array of running crew: "
                         '[{id,label,ticket,since,model}] -> status.json crew[]. '
                         "Invalid JSON warns to stderr + is skipped (write proceeds).")

    pt = sub.add_parser("tick", help="Advance the tick counter and sync core fields")
    pt.add_argument("n", type=int, help="Tick number (must be > current)")
    pt.add_argument("wake", help="Wake reason string")
    pt.add_argument("--delay-seconds", dest="delay_seconds", type=int,
                    help="Compute next_wake from now()+N seconds (the only correct way)")
    pt.add_argument("--wake-label", dest="wake_label",
                    help="Reason shown in next_wake parens (default: 'fallback')")
    pt.add_argument("--validator", help="Validator result string (e.g. CLEAN / NONE)")
    pt.add_argument("--last-actions", dest="last_actions", nargs="*",
                    help="last_actions list (replaces existing)")
    pt.add_argument("--clear-now", dest="clear_now", action="store_true",
                    help="Reset now after the tick (tick = completed state)")
    pt.add_argument("--crew-json", dest="crew_json", metavar="JSON",
                    help="JSON array of running crew: "
                         '[{id,label,ticket,since,model}] -> status.json crew[]. '
                         "Invalid JSON warns to stderr + is skipped (write proceeds).")
    return p


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if args.schema:
        print(SCHEMA_DOC)
        sys.exit(0)

    path = Path(args.status)

    if args.init:
        cmd_init(args, path)
    elif args.cmd == "now":
        cmd_now(args, path)
    elif args.cmd == "tick":
        cmd_tick(args, path)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
