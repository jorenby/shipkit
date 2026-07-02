#!/usr/bin/env python3
"""peer_send.py — compose + deliver a peer-Mate message (the peer-comms helper).

The transport half of modules/peer-comms/ (doctrine + envelope spec in
peer-comms.md; envelope code in peer_envelope.py). Reads the per-ship peer
registry `state/peers.json` (template: templates/peers.json — NO hosts/users
are hardcoded here), composes a validated envelope, writes it to the local
outbox/ (durable record + passive tertiary transport), then walks the peer's
configured transports in order until one delivers:

  scp     — push the file into the peer's inbox/drops/ over ssh
            (primary in the field-proven lane), then verify-landed via a
            remote listing (two separate ssh execs, `ls` then `dir` — no shell
            operators, so POSIX sh, PowerShell 5.1, and cmd sshds all parse it).
  http    — POST {"type":"peer","from":<self>,"text":<envelope>} to the peer's
            /inbox endpoint (the redundant lane; receiver writes the drop).
  outbox  — passive: the file is already in our own inbox/drops/outbox/,
            which the peer's poller sweeps. Always succeeds if configured.

Exit 0 when a transport delivered (outbox counts, flagged as passive);
exit 1 with every failure listed otherwise. The message file stays in
outbox/ regardless — delivery is at-least-once, dedup is by msg_id.

Stdlib-only, cross-platform (Windows/Git-Bash: scp/ssh ship with Git for
Windows; no pkill, no exec bits, invoke as `python3 peer_send.py ...`).

Usage:
  peer_send.py send  --peer <name> --kind <peer-kind> --topic <slug> \
                     [--wake-class wake|batch] [--title <t>] [--thread <tok>] \
                     [--in-reply-to <msg_id>] (--body <text> | --body-file <f> | stdin)
        (--wake-class silent is also accepted, for classifier parity; it is
        self-limiting — the receiver logs the drop and never surfaces it)
  peer_send.py reply --in-reply-to <msg_id> --kind <peer-kind> \
                     [--wake-class ...] [--title ...] [--thread ...] (body as above)
        writes <msg_id>.reply.md into our own acks/ dir — the polled return
        channel (no push needed; the peer sweeps it).
  peer_send.py validate <file>       receive-side envelope check
  peer_send.py peers                 list configured peers + transports

Env:
  SHIP_ROOT        ship root (default: modules/peer-comms/ -> up 2)
  SHIP_PEERS_PATH  peers registry (default: $SHIP_ROOT/state/peers.json)
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import peer_envelope  # noqa: E402


def ship_root():
    return Path(os.environ.get("SHIP_ROOT", HERE.parents[1])).resolve()


def peers_path():
    return Path(os.environ.get("SHIP_PEERS_PATH", ship_root() / "state" / "peers.json"))


KNOWN_TRANSPORTS = ("scp", "http", "outbox")
HTTP_TEXT_CAP = 64 * 1024  # the field-proven /inbox endpoint caps text at 64KB


def peers_problems(cfg):
    """Structural validation of a peers registry. Returns a list of problems
    (empty == usable)."""
    problems = []
    if not isinstance(cfg, dict):
        return ["peers.json: top level must be an object"]
    self_cfg = cfg.get("self")
    if not isinstance(self_cfg, dict) or not self_cfg.get("name"):
        problems.append("peers.json: missing self.name (this ship's peer identity)")
    peers = cfg.get("peers")
    if not isinstance(peers, dict) or not peers:
        problems.append("peers.json: no peers configured under 'peers'")
        return problems
    for name, peer in peers.items():
        transports = peer.get("transports", [])
        if not transports:
            problems.append("peer {!r}: empty transports list".format(name))
        for t in transports:
            if t not in KNOWN_TRANSPORTS:
                problems.append("peer {!r}: unknown transport {!r} (known: {})".format(
                    name, t, "/".join(KNOWN_TRANSPORTS)))
                continue
            if t == "scp":
                scp = peer.get("scp", {})
                for key in ("user", "host", "drops_dir"):
                    if not scp.get(key):
                        problems.append("peer {!r}: scp transport missing scp.{}".format(name, key))
            if t == "http":
                if not peer.get("http", {}).get("inbox_url"):
                    problems.append("peer {!r}: http transport missing http.inbox_url".format(name))
    return problems


def load_peers():
    """Load + validate state/peers.json. Raises SystemExit with a clear message
    on any problem — a half-configured lane should fail loudly, not deliver
    into the void."""
    path = peers_path()
    if not path.is_file():
        sys.exit("peer_send: no peer registry at {} — copy "
                 "modules/peer-comms/templates/peers.json there and fill it in".format(path))
    try:
        cfg = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        sys.exit("peer_send: {} is not valid JSON: {}".format(path, e))
    problems = peers_problems(cfg)
    if problems:
        sys.exit("peer_send: bad peer registry:\n  " + "\n  ".join(problems))
    return cfg


def _rel_dir(cfg_dict, key, default):
    d = ship_root() / cfg_dict.get(key, default)
    d.mkdir(parents=True, exist_ok=True)
    return d


def outbox_dir(cfg):
    return _rel_dir(cfg.get("self", {}), "outbox_dir", "inbox/drops/outbox")


def acks_dir(cfg):
    return _rel_dir(cfg.get("self", {}), "acks_dir", "inbox/drops/acks")


# ---- transports ----------------------------------------------------------------------
# Each returns (ok: bool, detail: str). Table is module-level so tests (and a
# deployment with an exotic lane) can substitute entries.

def _run(cmd, timeout):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        class _R:  # minimal CompletedProcess stand-in
            returncode = 127
            stdout = ""
            stderr = str(e)
        return _R()


def send_scp(msg_path, text, peer, self_cfg):
    scp = peer["scp"]
    timeout = int(scp.get("connect_timeout", 8))
    target = "{}@{}".format(scp["user"], scp["host"])
    remote_dir = scp["drops_dir"].rstrip("/")
    base = ["-o", "BatchMode=yes", "-o", "ConnectTimeout={}".format(timeout)]

    r = _run(["scp"] + base + [str(msg_path), "{}:{}/".format(target, remote_dir)],
             timeout=timeout + 30)
    if r.returncode != 0:
        return False, "scp failed (rc={}): {}".format(r.returncode, (r.stderr or "").strip())

    # Verify-landed: remote listing as TWO separate ssh execs, no shell operators.
    # `ls X || dir X` is a hard PARSE error under a PowerShell 5.1 sshd DefaultShell
    # (field-verified by the Windows ship, PSVersion 5.1.26100: "The token '||' is
    # not a valid statement separator"). Plain `ls <p>` parses on POSIX sh AND
    # PowerShell (alias) ; `dir <p>` covers cmd.exe. Two execs parse clean on all three.
    remote_file = "{}/{}".format(remote_dir, msg_path.name)
    v = _run(["ssh"] + base + [target, "ls {p}".format(p=remote_file)],
             timeout=timeout + 15)
    if v.returncode != 0:
        v = _run(["ssh"] + base + [target, "dir {p}".format(p=remote_file)],
                 timeout=timeout + 15)
    if v.returncode == 0:
        return True, "scp delivered + verified landed: {}".format(remote_file)
    return True, "scp delivered (rc=0) but verify-landed listing failed — treat as unverified"


def send_http(msg_path, text, peer, self_cfg):
    url = peer["http"]["inbox_url"]
    if len(text.encode("utf-8")) > HTTP_TEXT_CAP:
        return False, "http: message exceeds the {}KB /inbox text cap".format(HTTP_TEXT_CAP // 1024)
    payload = json.dumps({
        "type": "peer",
        "from": self_cfg.get("name", "unknown-peer"),
        "text": text,
    }).encode("utf-8")
    req = urllib.request.Request(
        url, data=payload, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            if 200 <= resp.status < 300:
                return True, "http delivered: POST {} -> {}".format(url, resp.status)
            return False, "http: POST {} -> {}".format(url, resp.status)
    except (urllib.error.URLError, OSError) as e:
        return False, "http failed: {}".format(e)


def send_outbox(msg_path, text, peer, self_cfg):
    return True, "queued (passive) in outbox for the peer's poller: {}".format(msg_path)


TRANSPORTS = {"scp": send_scp, "http": send_http, "outbox": send_outbox}


# ---- commands ------------------------------------------------------------------------

def _read_body(args):
    if args.body is not None:
        return args.body
    if args.body_file:
        return Path(args.body_file).read_text(encoding="utf-8")
    if sys.stdin.isatty():
        sys.exit("peer_send: no body given (use --body, --body-file, or pipe stdin)")
    return sys.stdin.read()


def _compose(args, cfg, msg_id):
    self_cfg = cfg["self"]
    source = self_cfg.get("source") or "{}-mate".format(self_cfg["name"])
    return peer_envelope.compose(
        source=source,
        kind=args.kind,
        wake_class=args.wake_class,
        msg_id=msg_id,
        title=args.title or args.topic or msg_id,
        body=_read_body(args),
        authenticity=self_cfg.get("authenticity", "unverified"),
        in_reply_to=args.in_reply_to,
        thread=args.thread,
    )


def cmd_send(args):
    cfg = load_peers()
    peer = cfg["peers"].get(args.peer)
    if peer is None:
        sys.exit("peer_send: unknown peer {!r} (configured: {})".format(
            args.peer, ", ".join(sorted(cfg["peers"]))))

    msg_id = peer_envelope.make_msg_id(cfg["self"]["name"], args.topic)
    text = _compose(args, cfg, msg_id)

    # Durable record first (also IS the passive tertiary transport).
    msg_path = outbox_dir(cfg) / (msg_id + ".md")
    msg_path.write_text(text, encoding="utf-8")

    failures = []
    for t in peer.get("transports", []):
        ok, detail = TRANSPORTS[t](msg_path, text, peer, cfg["self"])
        if ok:
            if t == "outbox":
                # Passive queue is not delivery: the peer's poller MAY sweep it,
                # but nothing has landed. Distinct exit code so a Mate can tell
                # "landed" (0) from "hoped" (2). (Windows-ship review SHOULD-FIX-2.)
                print("QUEUED-ONLY [{}] {}: {}".format(t, msg_id, detail))
                for f in failures:
                    print("  (earlier attempt: {})".format(f))
                return 2
            print("DELIVERED [{}] {}: {}".format(t, msg_id, detail))
            for f in failures:
                print("  (earlier attempt: {})".format(f))
            return 0
        failures.append("{}: {}".format(t, detail))

    sys.stderr.write("peer_send: ALL transports failed for {} -> {}\n  {}\n".format(
        msg_id, args.peer, "\n  ".join(failures)))
    sys.stderr.write("  message retained at {} — retry or let the peer's poller sweep it\n".format(msg_path))
    return 1


def cmd_reply(args):
    cfg = load_peers()
    msg_id = peer_envelope.make_msg_id(cfg["self"]["name"], args.topic or "reply")
    text = _compose(args, cfg, msg_id)
    # Return-channel convention: <original-msg-id>.reply.md in OUR OWN acks/,
    # which the peer polls. No push needed; we never leave our own tree.
    reply_path = acks_dir(cfg) / (args.in_reply_to + ".reply.md")
    reply_path.write_text(text, encoding="utf-8")
    print("REPLY written [{}]: {} (peer's poller sweeps acks/)".format(msg_id, reply_path))
    return 0


def cmd_validate(args):
    return peer_envelope.main(["peer_envelope.py", "validate", args.file])


def cmd_peers(_args):
    cfg = load_peers()
    print("self: {}".format(cfg["self"]["name"]))
    for name, peer in sorted(cfg["peers"].items()):
        print("  {} -> transports: {}".format(name, ", ".join(peer.get("transports", []))))
    return 0


def build_parser():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    def _msg_args(sp, reply=False):
        sp.add_argument("--kind", required=True,
                        help="peer kind (must be namespaced: peer-*/xship-*)")
        sp.add_argument("--topic", default=None, help="short slug for the msg_id")
        sp.add_argument("--wake-class", default="wake", choices=["wake", "batch", "silent"],
                        help="wake|batch for peer traffic; silent is accepted "
                             "(classifier parity) but self-limiting — the "
                             "receiver logs it and never surfaces it")
        sp.add_argument("--title", default=None)
        sp.add_argument("--thread", default=None, help="thread token, e.g. [migration-2026-07-02]")
        sp.add_argument("--in-reply-to", required=reply, default=None)
        sp.add_argument("--body", default=None)
        sp.add_argument("--body-file", default=None)

    sp = sub.add_parser("send", help="compose + deliver to a configured peer")
    sp.add_argument("--peer", required=True)
    _msg_args(sp)
    sp.set_defaults(func=cmd_send)

    sp = sub.add_parser("reply", help="write <msg_id>.reply.md into our own acks/ (polled return channel)")
    _msg_args(sp, reply=True)
    sp.set_defaults(func=cmd_reply)

    sp = sub.add_parser("validate", help="receive-side envelope validation")
    sp.add_argument("file")
    sp.set_defaults(func=cmd_validate)

    sp = sub.add_parser("peers", help="list configured peers")
    sp.set_defaults(func=cmd_peers)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except ValueError as e:  # compose-side validation failure — fail loudly
        sys.stderr.write("peer_send: {}\n".format(e))
        return 1


if __name__ == "__main__":
    sys.exit(main())
