#!/usr/bin/env python3
"""Unit tests for shipkit_init.py's hook-interpreter resolution + command rendering.

These cover Finding A (bare `bash` resolves to WSL's System32 stub on Windows → fail open)
and Finding C (double-quoted YAML with raw backslashes is invalid; single-quote + forward
slashes fix it). resolve_hook_interpreter is a PURE function (platform + env + which-scan in,
interpreter out) so the Windows cases are exercised on any OS with mocked inputs.

Usage: python3 core/tests/test_shipkit_init.py

Stdlib only for the resolution/render tests; the strict-YAML round-trip test uses PyYAML
and skips if it isn't importable (it IS the point of the test, so treat a skip as a gap to
fix in the environment — but never a hard failure that masks the resolution coverage)."""

import os
import re
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))  # repo root: shipkit/
sys.path.insert(0, ROOT)

import shipkit_init  # noqa: E402

try:
    import yaml  # noqa: E402
    HAVE_YAML = True
except ImportError:
    HAVE_YAML = False


class TestResolveHookInterpreter(unittest.TestCase):
    def test_posix_is_bare_bash(self):
        for plat in ("darwin", "linux", "freebsd"):
            self.assertEqual(
                shipkit_init.resolve_hook_interpreter(plat, {}, []),
                "bash",
                f"POSIX platform {plat} must keep bare bash",
            )

    def test_win32_prefers_programfiles_over_system32(self):
        """The WSL stub (System32\\bash.exe) may be first on PATH, but a real
        Git-Bash under %ProgramFiles% must WIN — resolved at install time."""
        env = {"ProgramFiles": r"C:\Program Files"}
        which = [r"C:\Windows\System32\bash.exe", r"C:\Program Files\Git\bin\bash.exe"]
        real = r"C:\Program Files\Git\bin\bash.exe"

        def fake_isfile(p):
            return p == os.path.join(r"C:\Program Files", "Git", "bin", "bash.exe")

        orig = shipkit_init.os.path.isfile
        shipkit_init.os.path.isfile = fake_isfile
        try:
            got = shipkit_init.resolve_hook_interpreter("win32", env, which)
        finally:
            shipkit_init.os.path.isfile = orig
        # Absolute, forward-slashed, double-quoted.
        self.assertEqual(got, '"C:/Program Files/Git/bin/bash.exe"')
        self.assertIn("System32", "".join(which))  # sanity: the stub was present…
        self.assertNotIn("System32", got)          # …and did NOT win.

    def test_win32_where_scan_filters_system32(self):
        """No %ProgramFiles% Git, but `where bash` returns the System32 WSL stub FIRST
        then a real Git-Bash — the System32 hit must be filtered, the real one chosen."""
        env = {}  # no ProgramFiles probes succeed
        which = [
            r"C:\Windows\System32\bash.exe",         # WSL stub — must be skipped
            r"C:\tools\Git\bin\bash.exe",            # real Git-Bash — must win
        ]
        orig = shipkit_init.os.path.isfile
        shipkit_init.os.path.isfile = lambda p: False  # no ProgramFiles candidate exists
        try:
            got = shipkit_init.resolve_hook_interpreter("win32", env, which)
        finally:
            shipkit_init.os.path.isfile = orig
        self.assertEqual(got, '"C:/tools/Git/bin/bash.exe"')

    def test_win32_system32_only_raises(self):
        """If the ONLY bash on the box is the System32/WSL stub, we must NOT fall back to
        it (that's the silent fail-open). Raise loudly."""
        env = {}
        which = [r"C:\Windows\System32\bash.exe"]
        orig = shipkit_init.os.path.isfile
        shipkit_init.os.path.isfile = lambda p: False
        try:
            with self.assertRaises(shipkit_init.HookInterpreterError):
                shipkit_init.resolve_hook_interpreter("win32", env, which)
        finally:
            shipkit_init.os.path.isfile = orig

    def test_win32_nothing_found_raises(self):
        """No ProgramFiles Git, empty `where bash` → must raise (never silent)."""
        orig = shipkit_init.os.path.isfile
        shipkit_init.os.path.isfile = lambda p: False
        try:
            with self.assertRaises(shipkit_init.HookInterpreterError):
                shipkit_init.resolve_hook_interpreter("win32", {}, [])
        finally:
            shipkit_init.os.path.isfile = orig

    def test_win32_programfiles_x86_fallback(self):
        env = {"ProgramFiles(x86)": r"C:\Program Files (x86)"}
        target = os.path.join(r"C:\Program Files (x86)", "Git", "bin", "bash.exe")
        orig = shipkit_init.os.path.isfile
        shipkit_init.os.path.isfile = lambda p: p == target
        try:
            got = shipkit_init.resolve_hook_interpreter("win32", env, [])
        finally:
            shipkit_init.os.path.isfile = orig
        self.assertEqual(got, '"C:/Program Files (x86)/Git/bin/bash.exe"')


class TestRenderHookCommand(unittest.TestCase):
    def test_posix_render(self):
        cmd = shipkit_init.render_hook_command("bash", "/abs/ship/core/hooks/validate-crew-bash.sh")
        self.assertEqual(cmd, "'bash /abs/ship/core/hooks/validate-crew-bash.sh'")

    def test_win32_render_forward_slashes_single_quoted(self):
        interp = '"C:/Program Files/Git/bin/bash.exe"'
        script = r"C:\ship\core\hooks\validate-crew-bash.sh"
        cmd = shipkit_init.render_hook_command(interp, script)
        # No raw backslashes survive (Finding C): they'd be invalid escapes in DQ YAML.
        self.assertNotIn("\\", cmd)
        # Whole scalar is single-quoted.
        self.assertTrue(cmd.startswith("'") and cmd.endswith("'"))
        self.assertIn("C:/ship/core/hooks/validate-crew-bash.sh", cmd)
        self.assertIn('"C:/Program Files/Git/bin/bash.exe"', cmd)


class TestCommandLineRewrite(unittest.TestCase):
    SRC = (
        "---\n"
        "name: ship-crew\n"
        "hooks:\n"
        "  PreToolUse:\n"
        "    - matcher: \"Bash\"\n"
        "      hooks:\n"
        "        - type: command\n"
        "          command: \"bash /abs/ship/core/hooks/validate-crew-bash.sh\"\n"
        "---\n"
        "# body {project} {ticket-id} survives verbatim\n"
    )

    def test_posix_rewrite(self):
        out = shipkit_init._rewrite_hook_command_lines(self.SRC, "bash")
        self.assertIn("command: 'bash /abs/ship/core/hooks/validate-crew-bash.sh'", out)
        # Prose braces untouched.
        self.assertIn("{project} {ticket-id} survives verbatim", out)

    def test_win32_rewrite_forward_slash(self):
        # Simulate a Windows-substituted path with backslashes coming in.
        src = self.SRC.replace(
            "/abs/ship/core/hooks/validate-crew-bash.sh",
            r"C:\ship\core\hooks\validate-crew-bash.sh",
        )
        interp = '"C:/Program Files/Git/bin/bash.exe"'
        out = shipkit_init._rewrite_hook_command_lines(src, interp)
        self.assertIn(
            "command: '\"C:/Program Files/Git/bin/bash.exe\" "
            "C:/ship/core/hooks/validate-crew-bash.sh'",
            out,
        )
        # No backslashes in the rewritten command line.
        cmd_line = [ln for ln in out.splitlines() if "command:" in ln][0]
        self.assertNotIn("\\", cmd_line)

    def test_non_validate_command_untouched(self):
        src = self.SRC.replace("validate-crew-bash.sh", "some-other-thing.sh")
        out = shipkit_init._rewrite_hook_command_lines(src, "bash")
        # Not a validate- hook → left exactly as-is (still double-quoted).
        self.assertIn('command: "bash /abs/ship/core/hooks/some-other-thing.sh"', out)


class TestHookPathExtraction(unittest.TestCase):
    def test_bare_bash(self):
        self.assertEqual(
            shipkit_init._hook_path_from_command("bash /a/b/validate-crew-bash.sh"),
            "/a/b/validate-crew-bash.sh",
        )

    def test_quoted_interpreter(self):
        cmd = '"C:/Program Files/Git/bin/bash.exe" C:/ship/core/hooks/validate-crew-bash.sh'
        self.assertEqual(
            shipkit_init._hook_path_from_command(cmd),
            "C:/ship/core/hooks/validate-crew-bash.sh",
        )
        self.assertEqual(
            shipkit_init._interpreter_from_command(cmd),
            "C:/Program Files/Git/bin/bash.exe",
        )

    def test_bare_path_legacy(self):
        self.assertEqual(
            shipkit_init._hook_path_from_command("/a/b/validate-crew-bash.sh"),
            "/a/b/validate-crew-bash.sh",
        )


@unittest.skipUnless(HAVE_YAML, "PyYAML not importable — strict round-trip cannot run")
class TestStrictYamlRoundTrip(unittest.TestCase):
    """A rendered def's frontmatter must parse under a STRICT YAML load (Finding C:
    raw backslashes in a double-quoted scalar are invalid escapes; parser leniency was
    load-bearing). We render the win32 form (backslash-bearing input) and assert it
    round-trips to the exact intended command string."""

    def _frontmatter(self, text):
        parts = text.split("---", 2)
        self.assertGreaterEqual(len(parts), 3, "expected --- fenced frontmatter")
        return parts[1]

    def test_win32_rendered_frontmatter_parses_strictly(self):
        src = TestCommandLineRewrite.SRC.replace(
            "/abs/ship/core/hooks/validate-crew-bash.sh",
            r"C:\ship\core\hooks\validate-crew-bash.sh",
        )
        interp = '"C:/Program Files/Git/bin/bash.exe"'
        out = shipkit_init._rewrite_hook_command_lines(src, interp)
        doc = yaml.safe_load(self._frontmatter(out))  # raises on invalid escapes
        cmd = doc["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
        self.assertEqual(
            cmd,
            '"C:/Program Files/Git/bin/bash.exe" C:/ship/core/hooks/validate-crew-bash.sh',
        )

    def test_double_quoted_backslash_form_would_be_invalid(self):
        """Demonstrates WHY the fix matters: the OLD double-quoted-with-backslashes form
        is invalid YAML (\\s, \\c... are not valid escapes). This asserts the failure
        mode we moved away from — guards against a regression to double-quoting."""
        bad = 'command: "bash C:\\ship\\core\\hooks\\validate-crew-bash.sh"\n'
        with self.assertRaises(yaml.YAMLError):
            yaml.safe_load(bad)

    def test_all_installed_source_defs_render_and_parse(self):
        """Render EVERY real source agent def through the installer's substitution +
        rewrite (POSIX interpreter) and assert strict YAML parse — the acceptance."""
        import glob
        agent_defs = (
            glob.glob(os.path.join(ROOT, "core", "agents", "ship-*.md"))
            + glob.glob(os.path.join(ROOT, "modules", "autonomous", "agents", "ship-*.md"))
        )
        self.assertGreater(len(agent_defs), 0, "no source agent defs found")
        for src_path in agent_defs:
            with open(src_path, encoding="utf-8") as fh:
                raw = fh.read()
            substituted = raw.replace("{SHIP_DIR}", "/abs/ship")
            rendered = shipkit_init._rewrite_hook_command_lines(substituted, "bash")
            fm = self._frontmatter(rendered)
            doc = yaml.safe_load(fm)  # strict
            for block in doc.get("hooks", {}).get("PreToolUse", []):
                for h in block.get("hooks", []):
                    self.assertRegex(
                        h.get("command", ""),
                        r"^bash /abs/ship/.*validate-.*\.sh$",
                        f"{os.path.basename(src_path)}: command not rendered as expected",
                    )


if __name__ == "__main__":
    unittest.main(verbosity=2)
