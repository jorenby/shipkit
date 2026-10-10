#!/usr/bin/env python3
"""Read-only: compares live control docs against their core/templates/ seed, both directions; findings become one drop."""
import glob
import os
import pathlib
import re
import sys
from datetime import datetime, timezone

SHIP_ROOT = pathlib.Path(os.environ.get("SHIP_ROOT") or pathlib.Path(__file__).resolve().parents[3])
TEMPLATES = SHIP_ROOT / "core" / "templates"
DROPS_DIR = SHIP_ROOT / "inbox" / "drops"
DROP_SUFFIX = "-seed-conformance-report.md"

HEADING_RE = re.compile(r'^#{1,3} .+')
FIELD_RE = re.compile(r'^\*\*[A-Za-z][^*\n]{0,60}:\*\*')
DISPLAY_MAX = 100


def main():
    report, has_findings, unparsed_any = build_report()
    print(report)

    if not has_findings:
        print("\nno differences and nothing unparsed — fully conformant.")
        return 0

    DROPS_DIR.mkdir(parents=True, exist_ok=True)
    if glob.glob(str(DROPS_DIR / f"*{DROP_SUFFIX}")):
        print("\nfindings present but an unconsumed report is already pending; not writing another.")
        return 0

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    drop_path = DROPS_DIR / f"{ts}{DROP_SUFFIX}"
    body = [
        "---",
        "shipkit_input: v1",
        "source: seed-conformance-check",
        "kind: steer",
        "wake_class: batch",
        "---",
        "",
        report,
        "",
        "Read-only, structure-only diff (see disclaimer above). A section added or dropped on "
        "purpose is not necessarily wrong — this is a diff for a human to accept or reject, not "
        "an enforcement action. Nothing was written to any control document or template.",
    ]
    if unparsed_any:
        body += ["", "One or more files could not be read — listed above as unparsed, never as conformant."]
    drop_path.write_text("\n".join(body) + "\n", encoding="utf-8")
    print(f"\nreport written -> {drop_path}")
    return 0


def build_report():
    out = [
        "# Seed conformance report",
        "",
        "Compares `#`/`##`/`###` heading lines and `**Bold-Label:**` lines between each live "
        "control document and the `core/templates/` seed it started from, both directions. This "
        "checks section **structure** only, not the text inside sections — a wrong value "
        "inside a correctly-named section is invisible to this check.",
        "",
    ]
    has_findings = False
    unparsed_any = False

    for live_rel, tmpl_name in (("captain.md", "captain.md"), ("queue.md", "queue.md")):
        lines, unparsed, findings = report_single(live_rel, tmpl_name)
        out += lines + [""]
        unparsed_any = unparsed_any or unparsed
        has_findings = has_findings or unparsed or findings

    lines, unparsed, findings = report_tickets()
    out += lines
    unparsed_any = unparsed_any or unparsed
    has_findings = has_findings or unparsed or findings

    return "\n".join(out), has_findings, unparsed_any


def report_single(live_rel, tmpl_name):
    title = f"{live_rel} vs core/templates/{tmpl_name}"
    tmpl_text = read_or_none(TEMPLATES / tmpl_name)
    if tmpl_text is None:
        return [f"### {title}", f"UNPARSED — could not read core/templates/{tmpl_name}."], True, False
    result = diff_pair(SHIP_ROOT / live_rel, tmpl_text)
    return fmt_pair(title, live_rel, f"core/templates/{tmpl_name}", result)


def report_tickets():
    out = ["### ticket files vs core/templates/ticket.md"]
    ticket_tmpl = read_or_none(TEMPLATES / "ticket.md")
    if ticket_tmpl is None:
        out.append("UNPARSED — could not read core/templates/ticket.md. No ticket comparison possible.")
        return out, True, False

    tmpl_headings = extract_headings(ticket_tmpl)
    tmpl_set = set(tmpl_headings)
    ticket_files = sorted(glob.glob(str(SHIP_ROOT / "projects" / "*" / "tickets" / "*.md")))
    conformant, divergent, unparsed_tickets = [], [], []
    added_freq, missing_freq = {}, {}
    for f in ticket_files:
        p = pathlib.Path(f)
        live_text = read_or_none(p)
        if live_text is None:
            unparsed_tickets.append(rel(p))
            continue
        live_headings = extract_headings(live_text)
        live_set = set(live_headings)
        added = list(dict.fromkeys(h for h in live_headings if h not in tmpl_set))
        missing = list(dict.fromkeys(h for h in tmpl_headings if h not in live_set))
        if not added and not missing:
            conformant.append(rel(p))
            continue
        divergent.append((rel(p), added, missing))
        for h in added:
            added_freq[h] = added_freq.get(h, 0) + 1
        for h in missing:
            missing_freq[h] = missing_freq.get(h, 0) + 1

    out.append(
        f"{len(ticket_files)} ticket files scanned: {len(conformant)} conformant, {len(divergent)} divergent, "
        f"{len(unparsed_tickets)} unparsed."
    )
    if unparsed_tickets:
        out.append(f"Unparsed (never counted conformant), up to 10 of {len(unparsed_tickets)}:")
        out += [f"- `{u}`" for u in unparsed_tickets[:10]]
    if divergent:
        out.append("Most common added headings across divergent tickets (heading: count):")
        out += [f"- `{trunc(h)}`: {c}" for h, c in sorted(added_freq.items(), key=lambda kv: -kv[1])[:10]]
        out.append("Most common dropped headings across divergent tickets (heading: count):")
        out += [f"- `{trunc(h)}`: {c}" for h, c in sorted(missing_freq.items(), key=lambda kv: -kv[1])[:10]]
        out.append(f"Sample divergent tickets, up to 15 of {len(divergent)}:")
        for relpath, added, missing in divergent[:15]:
            out.append(f"- `{relpath}`")
            if added:
                out.append(f"  - added: {summarize(added)}")
            if missing:
                out.append(f"  - dropped: {summarize(missing)}")
    return out, bool(unparsed_tickets), bool(divergent)


def diff_pair(live_path, tmpl_text):
    live_text = read_or_none(live_path)
    if live_text is None:
        return None
    live = extract_headings(live_text)
    tmpl = extract_headings(tmpl_text)
    tmpl_set, live_set = set(tmpl), set(live)
    added = list(dict.fromkeys(h for h in live if h not in tmpl_set))
    missing = list(dict.fromkeys(h for h in tmpl if h not in live_set))
    return added, missing


def fmt_pair(title, live_rel, tmpl_rel, result):
    lines = [f"### {title}", f"live: `{live_rel}`  template: `{tmpl_rel}`"]
    if result is None:
        lines.append("UNPARSED — could not read the live file. Not counted as matching.")
        return lines, True, False
    added, missing = result
    if not added and not missing:
        lines.append("No section-heading differences.")
        return lines, False, False
    if added:
        lines.append(f"Added (present live, not in template) — {len(added)}:")
        lines += [f"- `{trunc(h)}`" for h in added]
    if missing:
        lines.append(f"Dropped (present in template, not live) — {len(missing)}:")
        lines += [f"- `{trunc(h)}`" for h in missing]
    return lines, False, True


def extract_headings(text):
    return [raw.strip() for raw in text.splitlines() if HEADING_RE.match(raw) or FIELD_RE.match(raw)]


def read_or_none(path):
    try:
        return path.read_text(encoding="utf-8")
    except Exception:
        return None


def rel(p):
    return str(pathlib.Path(p).relative_to(SHIP_ROOT))


def summarize(headings):
    shown = ", ".join(f"`{trunc(h)}`" for h in headings[:8])
    extra = f" (+{len(headings) - 8} more)" if len(headings) > 8 else ""
    return shown + extra


def trunc(s):
    return s if len(s) <= DISPLAY_MAX else s[:DISPLAY_MAX - 1] + "…"


if __name__ == "__main__":
    sys.exit(main())
