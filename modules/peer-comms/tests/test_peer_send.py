#!/usr/bin/env python3
"""Test suite for peer_send.py — the peer-comms compose+deliver helper.

Usage: python3 modules/peer-comms/tests/test_peer_send.py

Cross-platform (stdlib only). Each fixture runs in a temp SHIP_ROOT so real
ship state is never touched; no network/ssh is exercised (the scp/http
transports are substituted in the TRANSPORTS table). Covers:

  - peers.json parsing: the shipped template is valid; missing file, bad JSON,
    missing self.name, unknown transport, half-configured scp/http all fail
    loudly with a pointed message.
  - outbox delivery: `send` writes a valid envelope into outbox/ and succeeds
    passively when outbox is the only transport.
  - fallback order: transports are tried in the peer's configured order; the
    first success stops the walk; total failure exits 1 and retains the file.
  - masquerade refusal: `send --kind steer` fails without delivering.
  - reply: writes <in_reply_to>.reply.md into our own acks/ with a valid
    envelope carrying its own fresh msg_id.
"""

import importlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_DIR = os.path.join(HERE, "..")
sys.path.insert(0, MODULE_DIR)

TEMPLATE = Path(MODULE_DIR) / "templates" / "peers.json"


def valid_registry():
    return {
        "self": {
            "name": "ship-alpha",
            "source": "ship-alpha-mate",
            "authenticity": "tailnet-ssh-key",
        },
        "peers": {
            "ship-beta": {
                "transports": ["outbox"],
            },
        },
    }


class PeerSendCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="peer-send-test.")
        self.root = Path(self._tmp.name)
        (self.root / "state").mkdir(parents=True)
        os.environ["SHIP_ROOT"] = str(self.root)
        os.environ.pop("SHIP_PEERS_PATH", None)
        if "peer_send" in sys.modules:
            self.ps = importlib.reload(sys.modules["peer_send"])
        else:
            self.ps = importlib.import_module("peer_send")

    def tearDown(self):
        os.environ.pop("SHIP_ROOT", None)
        self._tmp.cleanup()

    def write_registry(self, cfg):
        (self.root / "state" / "peers.json").write_text(
            json.dumps(cfg), encoding="utf-8")

    def run_main(self, argv):
        """Run peer_send.main capturing stdout/stderr; returns (rc, out, err).
        SystemExit (load_peers fail-loud path) is captured as rc/message."""
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            try:
                rc = self.ps.main(argv)
            except SystemExit as e:
                rc = 1 if isinstance(e.code, str) else (e.code or 0)
                if isinstance(e.code, str):
                    err.write(e.code)
        return rc, out.getvalue(), err.getvalue()


class TestPeersRegistry(PeerSendCase):
    def test_shipped_template_is_valid(self):
        cfg = json.loads(TEMPLATE.read_text(encoding="utf-8"))
        self.assertEqual(self.ps.peers_problems(cfg), [])
        # And transport order in the template is the field-proven fallback order.
        self.assertEqual(cfg["peers"]["ship-beta"]["transports"],
                         ["scp", "http", "outbox"])

    def test_missing_registry_fails_loudly(self):
        rc, _out, err = self.run_main(["peers"])
        self.assertEqual(rc, 1)
        self.assertIn("no peer registry", err)
        self.assertIn("templates/peers.json", err)

    def test_bad_json_fails_loudly(self):
        (self.root / "state" / "peers.json").write_text("{nope", encoding="utf-8")
        rc, _out, err = self.run_main(["peers"])
        self.assertEqual(rc, 1)
        self.assertIn("not valid JSON", err)

    def test_missing_self_name(self):
        cfg = valid_registry()
        del cfg["self"]["name"]
        self.assertTrue(any("self.name" in p for p in self.ps.peers_problems(cfg)))

    def test_unknown_transport(self):
        cfg = valid_registry()
        cfg["peers"]["ship-beta"]["transports"] = ["pigeon"]
        self.assertTrue(any("unknown transport" in p and "pigeon" in p
                            for p in self.ps.peers_problems(cfg)))

    def test_half_configured_scp_and_http(self):
        cfg = valid_registry()
        cfg["peers"]["ship-beta"]["transports"] = ["scp", "http"]
        cfg["peers"]["ship-beta"]["scp"] = {"user": "u"}  # host+drops_dir missing
        problems = self.ps.peers_problems(cfg)
        self.assertTrue(any("scp.host" in p for p in problems))
        self.assertTrue(any("scp.drops_dir" in p for p in problems))
        self.assertTrue(any("http.inbox_url" in p for p in problems))

    def test_empty_transports(self):
        cfg = valid_registry()
        cfg["peers"]["ship-beta"]["transports"] = []
        self.assertTrue(any("empty transports" in p for p in self.ps.peers_problems(cfg)))

    def test_peers_command_lists(self):
        self.write_registry(valid_registry())
        rc, out, _err = self.run_main(["peers"])
        self.assertEqual(rc, 0)
        self.assertIn("self: ship-alpha", out)
        self.assertIn("ship-beta", out)


class TestSend(PeerSendCase):
    SEND = ["send", "--peer", "ship-beta", "--kind", "peer-test",
            "--topic", "hello", "--body", "A self-contained test body."]

    def test_outbox_delivery_writes_valid_envelope(self):
        # Outbox is a passive queue, NOT delivery: exit 2 + QUEUED-ONLY so a Mate
        # can tell "landed" (0) from "hoped" (2). (Windows-ship review SHOULD-FIX-2.)
        self.write_registry(valid_registry())
        rc, out, _err = self.run_main(self.SEND)
        self.assertEqual(rc, 2)
        self.assertIn("QUEUED-ONLY [outbox]", out)
        files = list((self.root / "inbox" / "drops" / "outbox").glob("*.md"))
        self.assertEqual(len(files), 1)
        import peer_envelope
        text = files[0].read_text(encoding="utf-8")
        self.assertEqual(peer_envelope.validate(text, basename=files[0].name), [])
        fields, _ = peer_envelope.parse(text)
        self.assertEqual(fields["source"], "ship-alpha-mate")
        self.assertEqual(fields["kind"], "peer-test")
        self.assertTrue(fields["msg_id"].startswith("peer-ship-alpha-"))
        self.assertTrue(fields["msg_id"].endswith("-hello"))

    def test_fallback_order_first_success_wins(self):
        cfg = valid_registry()
        cfg["peers"]["ship-beta"]["transports"] = ["scp", "http", "outbox"]
        cfg["peers"]["ship-beta"]["scp"] = {
            "user": "u", "host": "h", "drops_dir": "/drops"}
        cfg["peers"]["ship-beta"]["http"] = {"inbox_url": "https://example/inbox"}
        self.write_registry(cfg)

        attempts = []
        orig = dict(self.ps.TRANSPORTS)

        def fake(name, ok, detail):
            def _t(msg_path, text, peer, self_cfg):
                attempts.append(name)
                return ok, detail
            return _t

        try:
            self.ps.TRANSPORTS["scp"] = fake("scp", False, "scp down")
            self.ps.TRANSPORTS["http"] = fake("http", True, "posted")
            self.ps.TRANSPORTS["outbox"] = fake("outbox", True, "queued")
            rc, out, _err = self.run_main(self.SEND)
        finally:
            self.ps.TRANSPORTS.update(orig)

        self.assertEqual(rc, 0)
        self.assertEqual(attempts, ["scp", "http"])  # order held; outbox never reached
        self.assertIn("DELIVERED [http]", out)
        self.assertIn("scp down", out)  # earlier failure surfaced, not hidden

    def test_all_transports_fail_exits_1_and_retains_file(self):
        cfg = valid_registry()
        cfg["peers"]["ship-beta"]["transports"] = ["http"]
        cfg["peers"]["ship-beta"]["http"] = {"inbox_url": "https://example/inbox"}
        self.write_registry(cfg)
        orig = dict(self.ps.TRANSPORTS)
        try:
            self.ps.TRANSPORTS["http"] = lambda *a: (False, "refused")
            rc, _out, err = self.run_main(self.SEND)
        finally:
            self.ps.TRANSPORTS.update(orig)
        self.assertEqual(rc, 1)
        self.assertIn("ALL transports failed", err)
        # Durable record retained for retry / passive sweep.
        self.assertEqual(len(list((self.root / "inbox" / "drops" / "outbox").glob("*.md"))), 1)

    def test_unknown_peer(self):
        self.write_registry(valid_registry())
        rc, _out, err = self.run_main(
            ["send", "--peer", "ship-gamma", "--kind", "peer-test", "--body", "x"])
        self.assertEqual(rc, 1)
        self.assertIn("unknown peer", err)

    def test_masquerade_kind_refused_nothing_delivered(self):
        self.write_registry(valid_registry())
        rc, _out, err = self.run_main(
            ["send", "--peer", "ship-beta", "--kind", "steer", "--body", "do it"])
        self.assertEqual(rc, 1)
        self.assertIn("captain-masquerade", err)
        outbox = self.root / "inbox" / "drops" / "outbox"
        self.assertEqual(list(outbox.glob("*.md")) if outbox.is_dir() else [], [])


class TestReply(PeerSendCase):
    def test_reply_lands_in_own_acks(self):
        self.write_registry(valid_registry())
        orig = "peer-ship-beta-2026-07-02-1215-migration-report"
        rc, out, _err = self.run_main(
            ["reply", "--in-reply-to", orig, "--kind", "peer-ack",
             "--topic", "pin-taken", "--wake-class", "batch", "--body", "Pin taken."])
        self.assertEqual(rc, 0)
        reply_path = self.root / "inbox" / "drops" / "acks" / (orig + ".reply.md")
        self.assertTrue(reply_path.is_file(), out)
        import peer_envelope
        text = reply_path.read_text(encoding="utf-8")
        self.assertEqual(peer_envelope.validate(text, basename=reply_path.name), [])
        fields, _ = peer_envelope.parse(text)
        self.assertEqual(fields["in_reply_to"], orig)
        self.assertEqual(fields["wake_class"], "batch")
        self.assertNotEqual(fields["msg_id"], orig)  # its own fresh msg_id


if __name__ == "__main__":
    unittest.main(verbosity=2)
