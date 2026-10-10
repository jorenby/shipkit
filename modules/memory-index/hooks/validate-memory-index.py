#!/usr/bin/env python3
"""PreToolUse check: deny a write that pushes a memory index past its load budget; abstain on any error (see ../memory-index.md)."""

import json
import os
import re
import sys

LINE_MAX = 200
FILE_SOFT_MAX = 23500


def main():
    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        abstain()
    if not isinstance(data, dict):
        abstain()
    tool = data.get("tool_name", "")
    ti = data.get("tool_input")
    if not isinstance(ti, dict):
        abstain()
    fp = ti.get("file_path")
    if not isinstance(fp, str) or not fp:
        abstain()

    target = resolve_index_path(fp)
    old = read_existing(target)
    old_line_set = set(old.split("\n"))
    old_size = len(old.encode("utf-8"))

    result, added = model_write(tool, ti, old, old_line_set)
    check_line_budget(result, added, old_line_set)
    check_file_budget(result, old_size)
    abstain()


def resolve_index_path(fp):
    home = os.path.expanduser("~")
    scope_re = re.compile(r"^" + re.escape(home) + r"/\.claude/projects/[^/]+/memory/MEMORY\.md\Z")
    try:
        norm = os.path.realpath(fp)
    except Exception:
        norm = fp
    if not (scope_re.match(norm) or scope_re.match(fp)):
        abstain()
    return norm if os.path.exists(norm) else fp


def read_existing(target):
    if not os.path.exists(target):
        return ""
    try:
        with open(target, "r", encoding="utf-8") as fh:
            return fh.read()
    except Exception:
        abstain()


def model_write(tool, ti, old, old_line_set):
    """Return (result, added): the resulting file content (None if the edit can't be modelled) and the new lines."""
    if tool == "Write":
        content = ti.get("content")
        if not isinstance(content, str):
            abstain()
        return content, new_lines(content, old_line_set)
    if tool == "Edit":
        new_string = ti.get("new_string")
        if not isinstance(new_string, str):
            abstain()
        old_string = ti.get("old_string", "")
        if not isinstance(old_string, str):
            old_string = ""
        replace_all = bool(ti.get("replace_all", False))
        return apply_edit(old, old_string, new_string, replace_all), new_lines(new_string, old_line_set)
    if tool == "MultiEdit":
        return model_multi_edit(ti.get("edits"), old, old_line_set)
    abstain()


def new_lines(text, old_line_set):
    return [ln for ln in text.split("\n") if ln not in old_line_set]


def apply_edit(content, old_string, new_string, replace_all):
    if old_string and old_string in content:
        return content.replace(old_string, new_string, -1 if replace_all else 1)
    if old_string == "" and content == "":
        return new_string
    return None


def model_multi_edit(edits, old, old_line_set):
    if not isinstance(edits, list) or not edits:
        abstain()
    content = old
    added = []
    for e in edits:
        if not isinstance(e, dict):
            abstain()
        ns = e.get("new_string")
        if not isinstance(ns, str):
            abstain()
        os_ = e.get("old_string", "")
        if not isinstance(os_, str):
            os_ = ""
        added.extend(new_lines(ns, old_line_set))
        if content is not None:
            content = apply_edit(content, os_, ns, bool(e.get("replace_all", False)))
    return content, added


def check_line_budget(result, added, old_line_set):
    # Check the resulting lines when modelled: a short fragment can still tail-extend an entry past the limit.
    lines = new_lines(result, old_line_set) if result is not None else added
    for ln in lines:
        if len(ln) > LINE_MAX:
            deny(
                f"memory-index guard: an index line this write adds/modifies is {len(ln)} chars "
                f"(limit {LINE_MAX}). MEMORY.md is a one-line-per-entry index with a hard load "
                "ceiling, cut from the BOTTOM — so an over-long line pushes older entries below "
                f"the cut where they load dark. Shorten this line to <={LINE_MAX} chars: keep the "
                "title + the one-line failure-mode hook here, move detail into the topic file. "
                f"Offending line begins: {ln[:80]!r}"
            )


def check_file_budget(result, old_size):
    # A shrinking write always passes, so draining an over-budget index is never blocked.
    if result is None:
        return
    size = len(result.encode("utf-8"))
    if size > FILE_SOFT_MAX and size > old_size:
        deny(
            f"memory-index guard: this write grows MEMORY.md to {size} bytes, over the "
            f"~{FILE_SOFT_MAX}-byte soft ceiling (the loader cuts from the BOTTOM, so the NEWEST "
            "entries go dark first). Do NOT trim in haste: drain the index first — move entries "
            "into their topic files or merge them under a hub line — then retry. A write that "
            "SHRINKS the file is allowed even while over budget."
        )


def deny(reason):
    sys.stdout.write(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        )
        + "\n"
    )
    sys.exit(0)


def abstain():
    sys.exit(0)


if __name__ == "__main__":
    main()
