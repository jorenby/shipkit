#!/usr/bin/env python3
"""rotation_prep.py — mechanical state-gathering for a bg-Mate rotation handoff.

A rotation handoff (`state/bg-mate-handoff.md`) is mostly derivable from live ship
state; only the judgment parts aren't. This gathers the mechanical parts into a fresh
skeleton in ONE command and marks the rest **FILL** — the outgoing Mate fills those.
The wind-down ceremony itself stays the Mate's (`core/mate.md` → "Sessions and Logs").

Driven by the `/ship-watch-rotate` skill; safe to run by hand.

Modes:
  rotation_prep.py                      # print the skeleton to stdout (safe default)
  rotation_prep.py --write              # write state/bg-mate-handoff.md (backs up the
                                        #   previous handoff to state/bg-mate-handoff.prev.md)
  rotation_prep.py --check-context      # read the capacity gauge; print
                                        #   ROTATE-RECOMMENDED when pct_used >= threshold
                                        #   exit: 0 OK · 3 rotate-recommended · 4 no gauge

Options / env:
  --ship-root PATH     ship checkout (default $SHIP_ROOT, else derived from this file)
  --gauge PATH         capacity gauge, ship-root-relative or absolute
                       (default $SHIP_GAUGE_PATH or state/context-gauge.json — the
                       `band_gauge_path` in mate.local.md)
  --threshold N        --check-context threshold pct (default $SHIP_ROTATE_THRESHOLD or 70)
  --tail N             lines of today's mate log to embed (default 20)

**Shipkit ships no gauge writer** — the gauge is operator-supplied (a statusline tee, a
harness hook, whatever your deployment has). On a ship without one, `--check-context`
returns 4 NO-GAUGE by design; that is "rotate on judgment", not an error.

Stdlib-only. Read-only except for the two handoff files under --write.

What it gathers:
  - mate-lock holder (the OUTGOING id → SHIP_OUTGOING_LOCK_ID for ship-up.sh --rotate-mate)
  - capacity gauge (pct_used / rate)
  - open crews (state/status.json crew[])
  - queue.md Active section, top Ready items, and Awaiting Captain
  - standing posture flags (mate.local.md → House notes bullet leads)
  - today's mate log tail
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

# This script lives at modules/autonomous/scripts/ -> ship root is 3 levels up.
DEFAULT_SHIP = Path(__file__).resolve().parents[3]
DEFAULT_GAUGE = "state/context-gauge.json"
DEFAULT_THRESHOLD = 70
GAUGE_STALE_MINUTES = 360  # gauge older than this gets a STALE warning

SHIP_UP = "modules/autonomous/scripts/ship-up.sh"
SELF = "modules/autonomous/scripts/rotation_prep.py"


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def read_text(path: Path):
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return None


def resolve_gauge(root: Path, gauge: str) -> Path:
    """A gauge path may be absolute or ship-root-relative."""
    p = Path(gauge)
    return p if p.is_absolute() else root / p


def gauge_age_minutes(ts: str):
    """Age of an ISO-8601 Z timestamp in minutes, or None if unparseable."""
    try:
        t = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None
    return (datetime.now(timezone.utc) - t).total_seconds() / 60.0


# ---------------------------------------------------------------------------
# --check-context
# ---------------------------------------------------------------------------

def check_context(root: Path, gauge: str, threshold: int) -> int:
    gauge_path = resolve_gauge(root, gauge)
    g = read_json(gauge_path)
    if not g or "pct_used" not in g:
        print(f"NO-GAUGE: {gauge_path} missing/unparseable — cannot judge context. "
              "Shipkit ships no gauge writer; rotate on judgment (compaction warnings, "
              "a model change, an operator call).")
        return 4
    pct = g.get("pct_used")
    ts = g.get("ts", "?")
    age = gauge_age_minutes(ts)
    stale = ""
    if age is not None and age > GAUGE_STALE_MINUTES:
        stale = f" ⚠ gauge STALE ({age / 60:.1f}h old — the session that wrote it may be gone)"
    extra = ""
    if "rate_pct" in g:
        extra = f", rate {g['rate_pct']}%"
    if pct >= threshold:
        print(f"ROTATE-RECOMMENDED: context {pct}% used >= {threshold}% threshold "
              f"(gauge {ts}{extra}){stale}")
        print(f"Next: {SELF} --write → fill FILL sections → "
              f"SHIP_OUTGOING_LOCK_ID=<your lock id> {SHIP_UP} --rotate-mate")
        return 3
    print(f"OK: context {pct}% used < {threshold}% threshold (gauge {ts}{extra}){stale}")
    return 0


# ---------------------------------------------------------------------------
# skeleton gathering
# ---------------------------------------------------------------------------

def gather_lock(root: Path):
    return read_json(root / "state" / "mate-lock.json")


def crew_line(c: dict) -> str:
    """One crew bullet, tolerant of both status.json crew[] shapes.

    lib/status.schema.md documents {id,label,ticket,since,model}; deployments that
    predate it (or wrap the writer) use {name,task,dispatched,note}. Accept either
    rather than silently rendering '?'.
    """
    label = c.get("label") or c.get("name") or c.get("task") or c.get("id") or "?"
    line = f"- **{label}**"
    detail = c.get("task") if c.get("label") or c.get("name") else None
    if detail and detail != label:
        line += f" — {detail}"
    if c.get("ticket"):
        line += f" (ticket {c['ticket']})"
    if c.get("id") and c.get("id") != label:
        line += f" · id {c['id']}"
    when = c.get("since") or c.get("dispatched")
    if when:
        line += f" · since {when}"
    if c.get("model"):
        line += f" · {c['model']}"
    if c.get("note"):
        line += f" · {c['note']}"
    return line


def gather_crews(root: Path):
    status = read_json(root / "state" / "status.json")
    if not status:
        return None
    return [crew_line(c) for c in status.get("crew", []) if isinstance(c, dict)]


def queue_section(text: str, name: str):
    """Return the entry lines of a `## <name>` section of queue.md."""
    m = re.search(rf"^## {re.escape(name)}\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not m:
        return []
    lines = []
    for ln in m.group(1).splitlines():
        s = ln.strip()
        if not s or s.startswith("<!--") or s.startswith(">"):
            continue
        lines.append(ln.rstrip())
    return lines


def gather_queue(root: Path):
    text = read_text(root / "queue.md")
    if text is None:
        return None, None, None
    active = queue_section(text, "Active")
    ready = queue_section(text, "Ready")[:3]
    awaiting = queue_section(text, "Awaiting Captain")
    return active, ready, awaiting


def posture_flags(text: str):
    """Lead phrases of the top-level House-notes bullets in mate.local.md.

    Prefers bold leads (`- **Lead.** body`); falls back to the plain bullet text so an
    overlay that doesn't use bold still yields something.
    """
    m = re.search(r"^## House notes.*?\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not m:
        return []
    body = m.group(1)
    flags = [f"- {mt.group(1)}" for mt in re.finditer(r"^- \*\*(.+?)\*\*", body, re.M)]
    if flags:
        return flags
    for mt in re.finditer(r"^- (.+)$", body, re.M):
        lead = mt.group(1).strip()
        flags.append(f"- {lead[:117] + '…' if len(lead) > 118 else lead}")
    return flags


def gather_posture_flags(root: Path):
    text = read_text(root / "mate.local.md")
    if text is None:
        return None
    return posture_flags(text)


def gather_log_tail(root: Path, tail_n: int):
    today = datetime.now().strftime("%Y-%m-%d")
    path = root / "logs" / "mate" / f"{today}.md"
    if not path.is_file():
        # fall back to the newest mate log (rotation just past midnight etc.)
        logs = sorted((root / "logs" / "mate").glob("2*.md"))
        if not logs:
            return None, None
        path = logs[-1]
    text = read_text(path)
    if text is None:
        return None, None
    lines = text.splitlines()
    return path.relative_to(root), lines[-tail_n:]


def build_skeleton(root: Path, gauge: str, tail_n: int) -> str:
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
    out = []
    ap = out.append

    ap(f"# bg-Mate rotation handoff — generated {stamp} by {SELF}")
    ap("")
    ap("> Mechanical sections below were auto-gathered from live state. OUTGOING MATE:")
    ap("> fill every **FILL** block (they're the judgment only you have), then delete this")
    ap("> callout. The successor treats FRESHEST STATE as superseding anything that conflicts.")
    ap("")

    # --- judgment first: it's what the successor reads first -------------------
    ap("**⚡ MODEL / POSTURE:** FILL — the model call (e.g. `SHIP_MATE_MODEL=<model>`, per")
    ap("your `mate.local.md` model roster / night-economy keys) + the current posture")
    ap("(operator on the bridge / away / night watch).")
    ap("")
    ap("**FRESHEST STATE (supersedes anything below that conflicts):** FILL — the 3-6 bullets")
    ap("only the outgoing Mate knows: what just closed, what's mid-thread, what to watch for.")
    ap("")
    ap("You are the **Ship First Mate** as a durable background agent. Re-anchor on the FILES:")
    ap("**`core/mate.md` (role) → `mate.local.md` (overlay — READ IT, all concrete values live")
    ap("there) →** `queue.md`, `captain.md`, `inbox/captain.md`, `state/status.json`,")
    ap("today's `logs/mate/`.")
    ap("")

    # --- mechanical state -------------------------------------------------------
    ap(f"## Mechanical state (auto-gathered {stamp})")
    ap("")

    lock = gather_lock(root)
    ap("### Outgoing mate-lock")
    if lock:
        ap(f"- holder: `{lock.get('session_id', '?')}` · acquired {lock.get('acquired_at', '?')}"
           f" · last beat {lock.get('heartbeat_at', '?')}")
        ap(f"- rotation: `SHIP_OUTGOING_LOCK_ID={lock.get('session_id', '?')} "
           f"{SHIP_UP} --rotate-mate`")
        ap("- ⚠ verify this id against the LIVE lock before trusting it "
           "(`mate-lock.py status --json` → `holder`); a skeleton generated earlier can carry "
           "a dead id.")
    else:
        ap(f"- lock file missing/unreadable — cold launch (`{SHIP_UP} --launch-mate`)")
    ap("")

    g = read_json(resolve_gauge(root, gauge))
    ap("### Capacity gauge (at generation time)")
    if g:
        ap(f"- {g.get('pct_used', '?')}% used · rate {g.get('rate_pct', '?')}% "
           f"(reset {g.get('rate_reset_mins', '?')}m) · gauge ts {g.get('ts', '?')}")
    else:
        ap("- no gauge available (shipkit ships no gauge writer — normal on a fresh ship)")
    ap("")

    crews = gather_crews(root)
    ap("### Open crews (state/status.json)")
    if crews:
        out.extend(crews)
    elif crews == []:
        ap("- ZERO crews in flight")
    else:
        ap("- status.json unreadable — check `claude agents` + queue Active by hand")
    ap("")

    active, ready, awaiting = gather_queue(root)
    ap("### Queue — Active")
    if active:
        out.extend(active)
    elif active == []:
        ap("- (empty)")
    else:
        ap("- queue.md unreadable")
    ap("")
    ap("### Queue — Ready (top 3)")
    if ready:
        out.extend(ready)
    elif ready == []:
        ap("- (empty)")
    else:
        ap("- queue.md unreadable")
    ap("")
    ap("### Queue — Awaiting Captain")
    if awaiting:
        out.extend(awaiting)
    elif awaiting == []:
        ap("- (empty)")
    else:
        ap("- queue.md unreadable")
    ap("")

    flags = gather_posture_flags(root)
    ap("### Standing posture flags (mate.local.md → House notes — read the full section)")
    if flags:
        out.extend(flags)
    elif flags == []:
        ap("- (no House notes bullets found — read mate.local.md directly)")
    else:
        ap("- mate.local.md unreadable")
    ap("")

    log_rel, tail = gather_log_tail(root, tail_n)
    ap("### Today's mate log tail")
    if tail:
        ap(f"From `{log_rel}` (last {len(tail)} lines):")
        ap("")
        ap("```")
        out.extend(tail)
        ap("```")
    else:
        ap("- no mate log found for today")
    ap("")

    # --- judgment sections -------------------------------------------------------
    ap("## In flight / watch-for")
    ap("FILL — threads mid-air (steers expected, reviews pending, promises made to the")
    ap('operator). Say "nothing mid-air" plainly if that\'s the truth.')
    ap("")
    ap("## Open Captain items")
    ap("FILL — each with a concrete next action. `queue.md` → Awaiting Captain (gathered")
    ap("above) is the source of truth; don't point at any other surface unless you have")
    ap("just confirmed it's fresh.")
    ap("")
    ap("## Corrections forward")
    ap("FILL — anything you learned this watch that contradicts a durable doc. A correction")
    ap("that lives only in your log gets re-learned the hard way.")
    ap("")
    ap("## Launch (mechanics)")
    ap(f"`{SHIP_UP} --rotate-mate` with `SHIP_OUTGOING_LOCK_ID` set (see Mechanical state")
    ap("above); `SHIP_MATE_MODEL=<model>` per the model call. It sweeps the outgoing")
    ap("monitors (orphan sweep), preflights `bgIsolation`, launches the successor")
    ap("stdin-piped `/ship-watch-start`, sleeps ~8s, releases the outgoing lock. The Bosun")
    ap("is INHERITED (`launch-bosun.sh --ensure` at the successor's boot is a no-op while")
    ap("its heartbeat is fresh). Procedure: the `/ship-watch-rotate` skill.")
    ap("")
    return "\n".join(out) + "\n"


def do_skeleton(root: Path, gauge: str, write: bool, tail_n: int) -> int:
    skeleton = build_skeleton(root, gauge, tail_n)
    if not write:
        sys.stdout.write(skeleton)
        return 0
    target = root / "state" / "bg-mate-handoff.md"
    backup = root / "state" / "bg-mate-handoff.prev.md"
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_file():
        backup.write_text(target.read_text(encoding="utf-8"), encoding="utf-8")
    target.write_text(skeleton, encoding="utf-8")
    print(f"wrote {target}")
    if backup.is_file():
        print(f"previous handoff preserved at {backup}")
    print("NOW: fill the FILL sections (model/posture, freshest state, in-flight) — "
          "the skeleton alone is NOT a handoff. --write REGENERATES; never run it again "
          "after filling.")
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--ship-root", default=os.environ.get("SHIP_ROOT", str(DEFAULT_SHIP)))
    p.add_argument("--gauge", default=os.environ.get("SHIP_GAUGE_PATH", DEFAULT_GAUGE),
                   help="capacity gauge path (absolute or ship-root-relative)")
    p.add_argument("--write", action="store_true",
                   help="write state/bg-mate-handoff.md (default: print to stdout)")
    p.add_argument("--check-context", action="store_true",
                   help="gauge check only: ROTATE-RECOMMENDED when pct_used >= threshold")
    p.add_argument("--threshold", type=int,
                   default=int(os.environ.get("SHIP_ROTATE_THRESHOLD", DEFAULT_THRESHOLD)))
    p.add_argument("--tail", type=int, default=20, help="mate-log tail lines to embed")
    args = p.parse_args(argv)

    root = Path(args.ship_root)
    if not root.is_dir():
        print(f"FATAL: ship root {root} not found", file=sys.stderr)
        return 2
    if args.check_context:
        return check_context(root, args.gauge, args.threshold)
    return do_skeleton(root, args.gauge, args.write, args.tail)


if __name__ == "__main__":
    sys.exit(main())
