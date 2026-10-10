#!/usr/bin/env python3
"""Derived, read-only per-initiative index: groups tickets by their **Epic:** field."""
import argparse
import glob
import os
import re
import sys

BOLD_FIELD_RE = re.compile(r"^\*\*([^*:]+):\*\*\s*(.*)$")
HEADING_RE = re.compile(r"^##\s+(.*)$")
UNBLOCKED_RE = re.compile(r"^(nothing|n/a|none)\b", re.IGNORECASE)
DONE_RE = re.compile(r"^done\b", re.IGNORECASE)
TERMINAL_KEYWORDS = ("done", "merged", "closed", "parked", "superseded", "dropped", "retired", "complete", "shipped")
TERMINAL_RE = re.compile(r"\b(?:" + "|".join(TERMINAL_KEYWORDS) + r")\b", re.IGNORECASE)
STATUS_BLOCKED_KEYWORDS = ("blocked", "waiting", "parked")
STATUS_BLOCKED_RE = re.compile(r"\b(?:" + "|".join(STATUS_BLOCKED_KEYWORDS) + r")\b", re.IGNORECASE)
TICKET_NUMBER_RE = re.compile(r"^(\d+)(?:-|\.)")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Print a derived per-initiative index from ticket Epic fields. Read-only."
    )
    parser.add_argument(
        "root",
        nargs="?",
        default="projects",
        help="Directory containing <project>/tickets/*.md (default: projects)",
    )
    parser.add_argument(
        "--initiative",
        help="Only report this initiative; if it matches zero tickets, reports absent rather than erroring.",
    )
    parser.add_argument(
        "--tag",
        action="append",
        default=[],
        metavar="DIR=TAG",
        help="Display tag for a project directory (repeatable); default is the directory name upper-cased.",
    )
    args = parser.parse_args(argv)

    tags = parse_tags(args.tag)
    if tags is None:
        print("--tag expects DIR=TAG", file=sys.stderr)
        return 2
    if not os.path.isdir(args.root):
        print("No tickets directory found at: {}".format(args.root), file=sys.stderr)
        return 1

    initiatives, unassigned, unreadable = build_index(args.root, tags)

    if args.initiative:
        if args.initiative in initiatives:
            print(summarize_initiative(args.initiative, initiatives[args.initiative]))
        else:
            print("{} (0/0 done) - no matching tickets found".format(args.initiative))
        print_unreadable(unreadable)
        return 0

    if not initiatives:
        print("No initiatives found under: {}".format(args.root))
    else:
        for name in sorted(initiatives.keys()):
            print(summarize_initiative(name, initiatives[name]))
            print()

    print("(unassigned): {} ticket(s) with no Epic field".format(len(unassigned)))
    print_unreadable(unreadable)
    return 0


def parse_tags(pairs):
    tags = {}
    for pair in pairs:
        if "=" not in pair:
            return None
        directory, tag = pair.split("=", 1)
        tags[directory.strip()] = tag.strip()
    return tags


def build_index(root, tags):
    initiatives = {}
    unassigned = []
    unreadable = []
    for path in sorted(glob.glob(os.path.join(root, "*", "tickets", "*.md"))):
        try:
            parsed = parse_ticket(path)
        except (OSError, UnicodeDecodeError) as exc:
            unreadable.append((path, str(exc)))
            continue
        parsed["ref"] = ticket_ref(path, tags)
        parsed["number"] = ticket_number(path)
        if parsed["epic"]:
            initiatives.setdefault(parsed["epic"], []).append(parsed)
        else:
            unassigned.append(parsed)
    return initiatives, unassigned, unreadable


def parse_ticket(path):
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.read().splitlines()

    fields = {}
    blocked_on_lines = []
    in_blocked_section = False
    for line in lines:
        heading_match = HEADING_RE.match(line)
        if heading_match:
            in_blocked_section = heading_match.group(1).strip().lower() == "blocked on"
            continue
        if in_blocked_section:
            blocked_on_lines.append(line)
            continue
        field_match = BOLD_FIELD_RE.match(line)
        if field_match:
            key = field_match.group(1).strip().lower()
            fields.setdefault(key, field_match.group(2).strip())

    blocked_text = "\n".join(blocked_on_lines).strip()
    status = fields.get("status", "")
    is_done = bool(DONE_RE.match(status)) or bool(TERMINAL_RE.search(status))
    is_blocked = (bool(blocked_text) and not UNBLOCKED_RE.match(blocked_text)) or bool(STATUS_BLOCKED_RE.search(status))

    blocker_summary = None
    if is_blocked:
        for raw_line in blocked_on_lines:
            stripped = raw_line.strip().lstrip("#*> ").strip()
            if stripped:
                blocker_summary = stripped
                break

    return {
        "path": path,
        "status": status,
        "is_done": is_done,
        "epic": fields.get("epic") or None,
        "is_blocked": is_blocked,
        "blocker_summary": blocker_summary,
    }


def ticket_ref(path, tags):
    project_dir = os.path.basename(os.path.dirname(os.path.dirname(path)))
    tag = tags.get(project_dir, project_dir.upper())
    return "[{}] {}".format(tag, os.path.splitext(os.path.basename(path))[0])


def ticket_number(path):
    match = TICKET_NUMBER_RE.match(os.path.basename(path))
    return int(match.group(1)) if match else float("inf")


def summarize_initiative(name, tickets):
    tickets_sorted = sorted(tickets, key=lambda t: t["number"])
    done = sum(1 for t in tickets_sorted if t["is_done"])
    blocked = [t for t in tickets_sorted if not t["is_done"] and t["is_blocked"]]
    next_unblocked = next((t for t in tickets_sorted if not t["is_done"] and not t["is_blocked"]), None)

    lines = ["{} ({}/{} done)".format(name, done, len(tickets_sorted))]
    if blocked:
        for t in blocked:
            reason = t["blocker_summary"] or "blocked, no summary line found"
            lines.append("  blocking: {} - {}".format(t["ref"], reason))
    else:
        lines.append("  blocking: none")
    lines.append("  next unblocked: {}".format(next_unblocked["ref"] if next_unblocked else "none"))
    return "\n".join(lines)


def print_unreadable(unreadable):
    if not unreadable:
        return
    print("(unreadable): {} ticket file(s) could not be read".format(len(unreadable)))
    for path, reason in unreadable:
        print("  {} - {}".format(path, reason))


if __name__ == "__main__":
    sys.exit(main())
