#!/usr/bin/env python3
"""Minimal reference status surface for a Loop-Mode Ship.

Zero dependencies (Python stdlib only). Serves a single self-contained page
that renders the loop's state/status.json and lets the Captain drop a steer.

  GET  /              -> index.html
  GET  /status.json   -> the loop's state/status.json (read fresh each request)
  GET  /activity.json -> recent per-tick telemetry lines from logs/mate/<day>.md
                         parsed newest-first ({time, tick, wake, did, crew})
  GET  /queue.json    -> parsed view of queue.md (Ready/Active/Waiting/Blocked/…)
  GET  /decisions.json-> the `## ⚓ Awaiting Captain` decision list from queue.md
                         ([{n, text, ticket?, urgent}], urgent-first); the "For
                         You" view. no-store, SW-excluded.
  GET  /tickets.json  -> list of projects/*/tickets/*.md (id, status, goal, path)
  GET  /ticket?id=ID  -> one ticket's parsed fields (goal/status/blocked_on/
                         open_acceptance[]) + raw markdown body
  GET  /steers.json   -> steer history: drops from inbox/drops/ (pending) and
                         inbox/drops/processed/ (handled), newest-first, each
                         matched to its Mate-written ack (or null) by basename,
                         and carrying its targeted `ticket` field (if any).
  GET  /ticket-steers?id=ID -> the same steer items, filtered to the ones that
                         target ticket ID (the per-ticket comment thread).
  POST /steer         -> writes a `type: steer` drop into inbox/drops/ so it
                         rides the classify_input -> wake path like any steer.
  POST /steer-ticket  -> like /steer but targets a specific ticket (id in body).

PWA shell (static, cacheable — served so the surface installs to a phone):
  GET  /manifest.webmanifest      -> the web app manifest (name/icons/theme)
  GET  /sw.js                     -> the service worker (caches the shell only)
  GET  /icon-192.png              -> app icon (192)
  GET  /icon-512.png              -> app icon (512)
  GET  /icon-512-maskable.png     -> maskable app icon (512)

Read endpoints are pure visibility — they never mutate ship state. Every write
goes through the declared-envelope drop path (the Mate owns queue/ticket writes).

Run:  python3 server.py        (then open http://localhost:8000)

Paths default to the shipkit checkout this file lives in (../../ from here).
Override with env vars if your state/inbox live elsewhere:
  SHIP_ROOT   ship root (default: two dirs up from this file)
  PORT        listen port (default: 8000)
"""

import json
import os
import re
import datetime
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Default ship root = the shipkit checkout (examples/status-surface/ -> ../../).
SHIP_ROOT = Path(os.environ.get("SHIP_ROOT", HERE.parent.parent)).resolve()
STATUS_PATH = SHIP_ROOT / "state" / "status.json"
QUEUE_PATH = SHIP_ROOT / "queue.md"
MATE_LOG_DIR = SHIP_ROOT / "logs" / "mate"
PROJECTS_DIR = SHIP_ROOT / "projects"
DROPS_DIR = SHIP_ROOT / "inbox" / "drops"
PROCESSED_DIR = DROPS_DIR / "processed"
ACKS_DIR = DROPS_DIR / "acks"
PORT = int(os.environ.get("PORT", "8000"))
# Bind localhost only: POST /steer is an unauthenticated write surface — a
# reference dev UI has no business listening on all interfaces. Override HOST
# deliberately if you front it with auth.
HOST = os.environ.get("HOST", "127.0.0.1")

INDEX_HTML = (HERE / "index.html").read_bytes()

# ── PWA shell ──────────────────────────────────────────────────────────────
# Theme/background match the UI palette (--bg / --accent in index.html).
THEME_COLOR = "#0e1116"
ACCENT_COLOR = "#4493f8"

# Bump this when any shell asset (html/css/icons/manifest/sw) changes so the
# service worker drops its old cache and re-fetches. The SW reads it via /sw.js
# (the value is interpolated below), so editing here is the single source.
SHELL_CACHE_VERSION = "ship-shell-v9"

# Static shell files served from disk by name -> (content-type). These are the
# ONLY paths the service worker is allowed to cache; live JSON/POST routes are
# explicitly excluded in sw.js. Generated once by _make_icons.py.
SHELL_FILES = {
    "/icon-192.png": "image/png",
    "/icon-512.png": "image/png",
    "/icon-512-maskable.png": "image/png",
}

MANIFEST = json.dumps({
    "name": "Ship — Status",
    "short_name": "Ship",
    "description": "Loop-Mode Ship status surface — status, queue, tickets, steer.",
    "start_url": "/",
    "scope": "/",
    "display": "standalone",
    "orientation": "portrait-primary",
    "background_color": THEME_COLOR,
    "theme_color": THEME_COLOR,
    "icons": [
        {"src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any"},
        {"src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any"},
        {"src": "/icon-512-maskable.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable"},
    ],
}, indent=2)

# The service worker. App-shell cache-first for static assets; network-only
# (never cached) for live state — /status.json, /queue.json, /tickets.json,
# /ticket, and every POST. We never call respondWith() for those, so they fall
# straight through to the network on every request.
SW_JS = """\
// Ship status-surface service worker. Caches the app shell for offline-open;
// NEVER caches live state (status/activity/queue/tickets/ticket/steers) or any POST.
const CACHE = "%(version)s";
const SHELL = [
  "/",
  "/index.html",
  "/manifest.webmanifest",
  "/icon-192.png",
  "/icon-512.png",
  "/icon-512-maskable.png",
];

// Paths that are ALWAYS live — must hit the network, never served from cache.
const LIVE = ["/status.json", "/activity.json", "/queue.json", "/decisions.json", "/tickets.json", "/ticket", "/steers.json", "/ticket-steers", "/steer", "/steer-ticket"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  // Drop any cache that isn't the current version, then take control at once.
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  const url = new URL(req.url);
  // Only ever touch same-origin GETs; everything else (POST, cross-origin)
  // falls through to the network untouched.
  if (req.method !== "GET" || url.origin !== self.location.origin) return;
  // Live-state paths: never cache, never intercept — straight to the network.
  if (LIVE.some((p) => url.pathname === p || url.pathname.startsWith(p))) return;

  // App shell: cache-first, then network. On a successful network fetch of a
  // shell asset, refresh the cached copy so updates land after a reload.
  e.respondWith(
    caches.match(req).then((hit) => {
      const net = fetch(req).then((res) => {
        if (res && res.ok) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy));
        }
        return res;
      }).catch(() => hit);  // offline: fall back to whatever we cached
      return hit || net;
    })
  );
});
""" % {"version": SHELL_CACHE_VERSION}

# A conservative slug: lowercase, alnum + dashes, capped — keeps drop filenames sane.
_SLUG_RE = re.compile(r"[^a-z0-9]+")


def _slug(text, limit=40):
    s = _SLUG_RE.sub("-", text.lower()).strip("-")
    return (s[:limit].rstrip("-")) or "steer"


def write_steer(text):
    """Write a well-formed `type: steer` drop. Returns the filename written."""
    DROPS_DIR.mkdir(parents=True, exist_ok=True)
    now = datetime.datetime.now().astimezone()
    stamp = now.strftime("%Y-%m-%d-%H%M%S")
    title = text.strip().splitlines()[0][:72] if text.strip() else "steer"
    name = f"captain-ui-{stamp}-{_slug(title)}.md"
    # YAML-escape: double-quote, backslash-escape inner quotes.
    safe_title = title.replace("\\", "\\\\").replace('"', '\\"')
    # Declared input envelope (v1): the producer states its own wake intent so
    # classify_input.py reads it verbatim (step 1) instead of guessing. A steer
    # is a directive the Captain is waiting on → wake_class: wake.
    doc = (
        "---\n"
        "shipkit_input: v1\n"
        "source: status-surface\n"
        "kind: steer\n"
        "wake_class: wake\n"
        "type: steer\n"
        f'title: "{safe_title}"\n'
        f"created: {now.isoformat()}\n"
        "tags:\n"
        "  - captain-steer\n"
        "---\n\n"
        f"{text.strip()}\n"
    )
    (DROPS_DIR / name).write_text(doc, encoding="utf-8")
    return name


def write_ticket_steer(ticket_id, text):
    """Write a steer drop that targets a specific ticket. Same envelope as
    write_steer (so it rides the same classify_input -> wake path); the targeted
    ticket id is declared in the body. The Mate stays the only writer of ship
    state — this only drops a directive."""
    DROPS_DIR.mkdir(parents=True, exist_ok=True)
    now = datetime.datetime.now().astimezone()
    stamp = now.strftime("%Y-%m-%d-%H%M%S")
    tid = ticket_id.strip()
    body = text.strip()
    title = f"steer {tid}: " + (body.splitlines()[0] if body else "")
    title = title[:72]
    name = f"captain-ui-{stamp}-{_slug(title)}.md"
    safe_title = title.replace("\\", "\\\\").replace('"', '\\"')
    safe_tid = tid.replace("\\", "\\\\").replace('"', '\\"')
    doc = (
        "---\n"
        "shipkit_input: v1\n"
        "source: status-surface\n"
        "kind: steer\n"
        "wake_class: wake\n"
        "type: steer\n"
        f'title: "{safe_title}"\n'
        f'ticket: "{safe_tid}"\n'
        f"created: {now.isoformat()}\n"
        "tags:\n"
        "  - captain-steer\n"
        "  - ticket-steer\n"
        "---\n\n"
        f"Steer for ticket **{tid}**:\n\n"
        f"{body}\n"
    )
    (DROPS_DIR / name).write_text(doc, encoding="utf-8")
    return name


# ── Read-side parsing (pure visibility; never mutates ship state) ──────────────

# A per-tick telemetry line in logs/mate/<day>.md, e.g.
#   17:43 tick 11 — wake=crew-completion (UI-MOBILE-PWA) · did=reviewed+… · crew=0 · validator=NONE · gauge=stale
# Leading `HH:MM tick <n> — ` is required; the rest is `key=value` fields joined
# by ` · `. We stay tolerant: preflight lines (`HH:MM preflight — …`) and any
# line without the `tick <n> —` head are skipped. Fields beyond did/wake/crew are
# ignored. The mate log is the durable record — this is read-only (no cache write).
_TELEM_RE = re.compile(r"^(\d{1,2}:\d{2})\s+tick\s+(\d+)\s+[—–-]\s+(.*)$")


def _telem_field(body, key):
    """Pull `key=value` from a telemetry line body (value runs to the next
    ` · ` field separator or end of line). Returns None if absent."""
    m = re.search(r"(?:^|·\s*)" + re.escape(key) + r"=(.*?)(?:\s*·|$)", body)
    return m.group(1).strip() if m else None


def _parse_telemetry(md):
    """Parse a mate-log markdown body into a list of telemetry dicts, in file
    order (oldest-first). Caller reverses for newest-first."""
    out = []
    for line in md.splitlines():
        line = line.strip()
        m = _TELEM_RE.match(line)
        if not m:
            continue
        body = m.group(3)
        # `did=` runs the rest of the line up to the next field; but `did` values
        # themselves contain ` · ` separators, so grab everything from did= up to
        # the trailing ` · crew=` (or ` · validator=` / end) deliberately.
        did = None
        dm = re.search(r"did=(.*?)(?:\s*·\s*crew=|\s*·\s*validator=|$)", body)
        if dm:
            did = dm.group(1).strip()
        out.append({
            "time": m.group(1),
            "tick": int(m.group(2)),
            "wake": _telem_field(body, "wake"),
            "did": did,
            "crew": _telem_field(body, "crew"),
        })
    return out


def _read_activity(limit=50):
    """Read recent telemetry from today's mate log (rolling back to the previous
    day if today is short), newest-first, capped at `limit`. Read-only."""
    today = datetime.date.today()
    entries = []
    for back in (0, 1):
        day = today - datetime.timedelta(days=back)
        path = MATE_LOG_DIR / f"{day.isoformat()}.md"
        try:
            md = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        # Tag each with its date so multi-day feeds stay unambiguous.
        for e in _parse_telemetry(md):
            e["date"] = day.isoformat()
            entries.append(e)
        # Only reach back a day when today's file is thin.
        if back == 0 and len(entries) >= limit:
            break
    # entries are oldest-first within each file and today precedes yesterday in
    # the list; sort by (date, time) then reverse so the feed is newest-first.
    entries.sort(key=lambda e: (e.get("date", ""), e.get("time", "")))
    entries.reverse()
    return entries[:limit]


# Matches the queue.md `## Section` headers we surface, in display order.
_QUEUE_SECTIONS = ("Ready", "Active", "Waiting", "Blocked", "On Hold", "Done")
# A queue line item, e.g.  `1. [TICKET-ID](path) - summary | last: 2026-06-21`
# or a bullet `- TEXT`. We keep it forgiving: link + text are both optional.
_LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")


def _parse_queue(md):
    """Parse queue.md into {section: [ {id, path, text} ...] }."""
    out = {s: [] for s in _QUEUE_SECTIONS}
    current = None
    in_comment = False  # track multi-line <!-- … --> blocks
    for line in md.splitlines():
        # Step over HTML comment blocks (queue.md uses multi-line hint comments).
        if in_comment:
            if "-->" in line:
                in_comment = False
            continue
        if "<!--" in line and "-->" not in line:
            in_comment = True
            continue
        h = re.match(r"^##\s+(.*?)\s*$", line)
        if h:
            name = h.group(1).strip()
            # Tolerate "Done (recent)" -> "Done".
            for s in _QUEUE_SECTIONS:
                if name.lower().startswith(s.lower()):
                    current = s
                    break
            else:
                current = None
            continue
        if current is None:
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith("<!--"):
            continue
        # Strip a leading list marker ("1." or "-").
        item = re.sub(r"^(\d+\.|-)\s*", "", stripped)
        if not item:
            continue
        m = _LINK_RE.search(item)
        out[current].append({
            "id": m.group(1) if m else None,
            "path": m.group(2) if m else None,
            "text": item,
        })
    return out


# ── Decisions ("For You") parsing ─────────────────────────────────────────────
# Canonical source: the `## ⚓ Awaiting Captain` section in queue.md — the Mate
# maintains it as the crisp, already-curated list of what's blocked on the
# Captain. We parse the numbered items under that heading (until the next `##`),
# in file order, then float 🔴-marked (urgent) items to the front. Each item's
# text IS the ask; if it carries a `[label](path)` link we surface the ticket id.
# Read-only — never mutates ship state.
def _parse_decisions(md):
    """Parse queue.md's `## ⚓ Awaiting Captain` section into a list of
    decision dicts: [{n, text, ticket?, urgent}]. `ticket` is the link label
    when a `[label](path)` link is present (matches the ticket-id convention);
    `urgent` is True when the item carries a 🔴 marker. Items are returned with
    urgent ones first, otherwise in file order. Tolerates multi-line numbered
    items (continuation lines fold into the current item) and skips HTML
    comments (the Mate annotates the section with <!-- … --> hints)."""
    # Find the Awaiting-Captain heading (match on the words, tolerant of the
    # leading ⚓ emoji and any trailing prose like "— the decision queue").
    sec = re.search(
        r"^##\s+[^\n]*Awaiting\s+Captain[^\n]*$\n(.*?)(?=^##\s|\Z)",
        md, re.M | re.S)
    if not sec:
        return []
    body = sec.group(1)
    items = []          # [{n, lines:[...], urgent}]
    in_comment = False
    for line in body.splitlines():
        # Skip single-line and multi-line HTML comment blocks.
        if in_comment:
            if "-->" in line:
                in_comment = False
            continue
        if "<!--" in line and "-->" not in line:
            in_comment = True
            continue
        stripped_full = line.strip()
        if stripped_full.startswith("<!--") and stripped_full.endswith("-->"):
            continue
        # A new numbered item starts a new decision; other non-blank lines fold
        # into the current item as continuation text.
        num = re.match(r"^\s*(\d+)\.\s+(.*)$", line)
        if num:
            items.append({"n": int(num.group(1)), "lines": [num.group(2)]})
        elif items and stripped_full:
            items[-1]["lines"].append(stripped_full)
        # blank lines / pre-item prose are ignored
    out = []
    for idx, it in enumerate(items):
        text = " ".join(ln.strip() for ln in it["lines"] if ln.strip()).strip()
        if not text:
            continue
        m = _LINK_RE.search(text)
        out.append({
            "n": it["n"],
            "text": text,
            "ticket": m.group(1) if m else None,
            "urgent": "🔴" in text,
            "_order": idx,
        })
    # Urgent (🔴) first, then file order. Stable sort preserves file order
    # within each urgency group.
    out.sort(key=lambda d: (0 if d["urgent"] else 1, d["_order"]))
    for d in out:
        d.pop("_order", None)
    return out


def _field(md, label):
    """Pull a `**Label:** value` field (first match) from a ticket body."""
    m = re.search(r"^\*\*" + re.escape(label) + r":\*\*\s*(.+?)\s*$", md, re.M)
    return m.group(1).strip() if m else None


def _section(md, heading):
    """Pull the prose body of a `## Heading` section (text up to the next `##`
    header or end of file), collapsed to a single line. Used for tickets that
    write Goal/Blocked on as a section rather than an inline `**Label:**` field.
    Returns None if the section is absent or empty."""
    m = re.search(
        r"^##\s+" + re.escape(heading) + r"\s*$\n(.*?)(?=^##\s|\Z)",
        md, re.M | re.S)
    if not m:
        return None
    # Collapse the section body to a single space-joined line, dropping blanks.
    body = " ".join(ln.strip() for ln in m.group(1).splitlines() if ln.strip())
    return body or None


def _goal(md):
    """A ticket's goal, from an inline `**Goal:** …` field or a `## Goal`
    section (whichever exists). Inline field wins when both are present."""
    return _field(md, "Goal") or _section(md, "Goal")


def _blocked_on(md):
    """A ticket's blocker, from `**Blocked on:** …` / `**Blocked:** …` inline
    fields or a `## Blocked on` section. Returns None when nothing is set."""
    return (_field(md, "Blocked on") or _field(md, "Blocked")
            or _section(md, "Blocked on"))


# An acceptance checklist line: `- [ ] text` (open) or `- [x] text` (done).
_ACCEPT_RE = re.compile(r"^\s*[-*]\s+\[( |x|X)\]\s+(.*?)\s*$")


def _open_acceptance(md):
    """List the UNCHECKED `- [ ]` acceptance items (text only). We scope to the
    `## Acceptance` section when present so unrelated checklists elsewhere in a
    ticket don't leak in; if there's no such section, scan the whole body."""
    sec = re.search(r"^##\s+Acceptance\s*$\n(.*?)(?=^##\s|\Z)", md, re.M | re.S)
    scope = sec.group(1) if sec else md
    out = []
    for line in scope.splitlines():
        m = _ACCEPT_RE.match(line)
        if m and m.group(1) == " ":
            out.append(m.group(2).strip())
    return out


def _ticket_summary(path, full=False):
    """Parse one ticket file into {id, title, status, goal, blocked_on,
    open_acceptance, project, file}. With full=True the derived header fields
    (blocked_on, open_acceptance) are included; the list view omits them."""
    md = path.read_text(encoding="utf-8", errors="replace")
    # Heading: "# ID: Title" (id = token before the first colon).
    title_line = ""
    for line in md.splitlines():
        if line.startswith("# "):
            title_line = line[2:].strip()
            break
    if ":" in title_line:
        tid, _, title = title_line.partition(":")
        tid, title = tid.strip(), title.strip()
    else:
        tid, title = path.stem, title_line
    # Prefer the filename stem as the canonical id (matches queue links).
    tid = path.stem
    try:
        project = path.relative_to(PROJECTS_DIR).parts[0]
    except ValueError:
        project = ""
    data = {
        "id": tid,
        "title": title,
        "status": _field(md, "Status") or "",
        "goal": _goal(md) or "",
        "project": project,
        "file": path.name,
    }
    if full:
        data["blocked_on"] = _blocked_on(md) or ""
        data["open_acceptance"] = _open_acceptance(md)
    return data


def _list_tickets():
    if not PROJECTS_DIR.is_dir():
        return []
    items = []
    for p in sorted(PROJECTS_DIR.glob("*/tickets/*.md")):
        try:
            items.append(_ticket_summary(p))
        except OSError:
            continue
    return items


def _find_ticket(ticket_id):
    """Resolve a ticket id (filename stem, case-insensitive) to its Path,
    guarding against path traversal — only files under PROJECTS_DIR match."""
    if not ticket_id or not PROJECTS_DIR.is_dir():
        return None
    want = ticket_id.strip().lower()
    for p in PROJECTS_DIR.glob("*/tickets/*.md"):
        if p.stem.lower() == want:
            return p
    return None


# ── Steer history (read-only conversation view) ───────────────────────────────
# A steer drop is a markdown file with a YAML frontmatter block delimited by
# `---` lines. We parse only what the conversation view needs: the declared
# `kind`, the `title`/`created` fields, and the prose body beneath the front
# matter. The Mate owns acks (we never write them) — we just read them if present.
_FM_RE = re.compile(r"^---\s*$\n(.*?)^---\s*$\n?(.*)$", re.S | re.M)


def _parse_frontmatter(text):
    """Split a drop file into (front-matter dict, body str). Only flat
    `key: value` lines are read (enough for our fields); list/nested YAML is
    skipped gracefully. Returns ({}, text) when there's no front-matter block."""
    m = _FM_RE.match(text)
    if not m:
        return {}, text
    fm = {}
    for line in m.group(1).splitlines():
        fmatch = re.match(r"^([A-Za-z0-9_]+):\s*(.*)$", line)
        if not fmatch:
            continue  # list items / indented YAML — ignored
        key, val = fmatch.group(1), fmatch.group(2).strip()
        # Strip surrounding quotes the writer added for YAML-safety.
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        fm[key] = val
    return fm, m.group(2)


def _read_ack(basename):
    """Read the Mate-written ack for a steer, if any. The Mate owns acks; we
    only read. The acks dir may not exist — that's not an error, just "no acks
    yet". We accept both observed naming conventions: `<basename>.json` (the
    ticket-stated form) and `<basename>.md.json` (the drop's full filename +
    .json, which is what the live Mate loop actually writes). Never writes."""
    for name in (f"{basename}.json", f"{basename}.md.json"):
        path = ACKS_DIR / name
        try:
            return json.loads(path.read_text(encoding="utf-8", errors="replace"))
        except FileNotFoundError:
            continue
        except (OSError, json.JSONDecodeError):
            return None
    return None


def _parse_steer(path, handled):
    """Parse one steer drop into a conversation entry, or None if it isn't a
    `kind: steer` drop. `handled` flags drops already moved to processed/."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    fm, body = _parse_frontmatter(text)
    if fm.get("kind") != "steer":
        return None
    basename = path.stem
    return {
        "id": basename,
        "time": fm.get("created") or "",
        "title": fm.get("title") or (body.strip().splitlines() or [""])[0][:72],
        "text": body.strip(),
        "handled": handled,
        # The targeted ticket id, if this steer was dropped via /steer-ticket
        # (write_ticket_steer stamps `ticket: "<id>"` in the front matter).
        # Empty string for general/un-targeted steers. Lets the conversation
        # split: ticket-scoped steers thread on their ticket detail, the rest
        # stay in the Console.
        "ticket": fm.get("ticket") or "",
        "ack": _read_ack(basename),
    }


def _list_steers(limit=50, ticket=None):
    """Steer drops from inbox/drops/ (pending) + processed/ (handled), newest
    first by `created`, capped. Each carries its inline ack (null if none).

    When `ticket` is given, return ONLY steers whose front-matter `ticket:`
    field matches it (case-insensitive); otherwise return all steers."""
    want = ticket.strip().lower() if ticket else None
    out = []
    for d, handled in ((DROPS_DIR, False), (PROCESSED_DIR, True)):
        if not d.is_dir():
            continue
        for p in d.glob("*.md"):
            if not p.is_file():
                continue
            e = _parse_steer(p, handled)
            if not e:
                continue
            if want is not None and (e.get("ticket") or "").strip().lower() != want:
                continue
            out.append(e)
    # Newest-first by created timestamp; fall back to filename for ties/blanks
    # (drop names lead with the YYYY-MM-DD-HHMMSS stamp, so they sort sanely).
    out.sort(key=lambda e: (e.get("time") or "", e.get("id") or ""), reverse=True)
    return out[:limit]


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json", cache=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        # Live state (the default) must never be cached by the browser/proxy —
        # the service worker also refuses to cache it. Static shell assets pass
        # an explicit cache directive. sw.js is no-cache so updates land.
        self.send_header("Cache-Control", cache or "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path)
        route = path.path
        if route in ("/", "/index.html"):
            # Shell HTML: short cache + revalidate so the SW/app updates land.
            self._send(200, INDEX_HTML, "text/html; charset=utf-8",
                       cache="no-cache")
        elif route == "/manifest.webmanifest":
            self._send(200, MANIFEST, "application/manifest+json; charset=utf-8",
                       cache="max-age=3600")
        elif route == "/sw.js":
            # The SW itself must never be served stale, or clients get stuck on
            # an old worker. no-cache => the browser always revalidates it.
            self._send(200, SW_JS, "text/javascript; charset=utf-8",
                       cache="no-cache")
        elif route in SHELL_FILES:
            try:
                self._send(200, (HERE / route.lstrip("/")).read_bytes(),
                           SHELL_FILES[route], cache="max-age=86400")
            except FileNotFoundError:
                self._send(404, json.dumps({"error": f"missing asset {route}"}))
        elif route == "/status.json":
            try:
                self._send(200, STATUS_PATH.read_bytes())
            except FileNotFoundError:
                self._send(404, json.dumps({"error": f"no status at {STATUS_PATH}"}))
        elif route == "/activity.json":
            # Read-only view of the mate-log telemetry lines (newest-first).
            # Missing logs are not an error — just an empty feed.
            self._send(200, json.dumps({"activity": _read_activity()}))
        elif route == "/queue.json":
            try:
                md = QUEUE_PATH.read_text(encoding="utf-8", errors="replace")
                self._send(200, json.dumps({"sections": _parse_queue(md)}))
            except FileNotFoundError:
                self._send(404, json.dumps({"error": f"no queue at {QUEUE_PATH}"}))
        elif route == "/decisions.json":
            # The "For You" decision list: the `## ⚓ Awaiting Captain` section
            # of queue.md, urgent-first. Never cached (no-store, SW-excluded) —
            # it's a live view of what currently blocks the Captain.
            try:
                md = QUEUE_PATH.read_text(encoding="utf-8", errors="replace")
                self._send(200, json.dumps({"decisions": _parse_decisions(md)}))
            except FileNotFoundError:
                self._send(404, json.dumps({"error": f"no queue at {QUEUE_PATH}"}))
        elif route == "/tickets.json":
            self._send(200, json.dumps({"tickets": _list_tickets()}))
        elif route == "/ticket":
            qs = urllib.parse.parse_qs(path.query)
            tid = (qs.get("id") or [""])[0]
            p = _find_ticket(tid)
            if not p:
                self._send(404, json.dumps({"error": f"no ticket {tid!r}"}))
                return
            data = _ticket_summary(p, full=True)
            data["body"] = p.read_text(encoding="utf-8", errors="replace")
            self._send(200, json.dumps(data))
        elif route == "/steers.json":
            # Read-only steer history (pending + handled), newest-first, each
            # with its Mate-written ack inline (null if none). Missing acks dir
            # is not an error. We never write acks here. Each entry now also
            # carries its `ticket` field so the UI can split ticket-scoped
            # steers off into their ticket detail thread.
            self._send(200, json.dumps({"steers": _list_steers()}))
        elif route == "/ticket-steers":
            # Read-only: the steer conversation scoped to ONE ticket — the
            # steers dropped via /steer-ticket carrying `ticket: <id>`, plus
            # their Mate acks. Same shape as /steers.json's items. Newest-first.
            qs = urllib.parse.parse_qs(path.query)
            tid = (qs.get("id") or [""])[0]
            if not tid.strip():
                self._send(400, json.dumps({"error": "missing ticket id"}))
                return
            self._send(200, json.dumps({"steers": _list_steers(ticket=tid)}))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        route = urllib.parse.urlparse(self.path).path
        if route not in ("/steer", "/steer-ticket"):
            self._send(404, json.dumps({"error": "not found"}))
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._send(400, json.dumps({"error": "bad json"}))
            return
        text = payload.get("text", "")
        if not text.strip():
            self._send(400, json.dumps({"error": "empty steer"}))
            return
        if route == "/steer-ticket":
            tid = payload.get("ticket", "").strip()
            if not tid:
                self._send(400, json.dumps({"error": "missing ticket id"}))
                return
            if not _find_ticket(tid):
                self._send(404, json.dumps({"error": f"no ticket {tid!r}"}))
                return
            name = write_ticket_steer(tid, text)
        else:
            name = write_steer(text)
        self._send(200, json.dumps({"ok": True, "drop": name}))

    def log_message(self, *args):
        pass  # quiet by default


if __name__ == "__main__":
    print(f"status-surface: serving http://{HOST}:{PORT}")
    print(f"  status: {STATUS_PATH}")
    print(f"  queue:  {QUEUE_PATH}")
    print(f"  tickets:{PROJECTS_DIR}")
    print(f"  drops:  {DROPS_DIR}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
