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
import json
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
            + glob.glob(os.path.join(ROOT, "modules", "*", "agents", "ship-*.md"))
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


class TestFreshCopyInstallNoStaleWarning(unittest.TestCase):
    """Finding 2: a FRESH copy-install must NOT flag the skill it just wrote as a stale
    'silently keeps launching /loop' copy. A copy byte-identical to the repo's current
    skill is neutral ('current, frozen'); only a DIFFERING copy earns the scary flag."""

    def _copy_skill(self, dest_parent, name):
        import shutil
        src = None
        for rel in shipkit_init.load_module("autonomous").get("skills", []):
            if os.path.basename(rel) == name:
                src = shipkit_init.load_module("autonomous")["_dir"] / rel
        self.assertIsNotNone(src, f"no source skill {name} in autonomous module")
        dst = dest_parent / name
        shutil.copytree(src, dst)
        return dst

    def test_fresh_identical_copy_is_current_not_stale(self):
        with tempfile.TemporaryDirectory() as td:
            skills_target = shipkit_init.Path(td)
            self._copy_skill(skills_target, "ship-watch-start")
            findings = shipkit_init.detect_prior_state(["autonomous"], skills_target)
            joined = "\n".join(findings)
            self.assertIn("ship-watch-start", joined)
            self.assertNotIn("silently keep launching /loop", joined)
            self.assertIn("COPY (current, frozen", joined)

    def test_differing_copy_is_flagged_stale(self):
        with tempfile.TemporaryDirectory() as td:
            skills_target = shipkit_init.Path(td)
            dst = self._copy_skill(skills_target, "ship-watch-start")
            skill_md = dst / "SKILL.md"
            skill_md.write_text(
                skill_md.read_text(encoding="utf-8") + "\nstale drift\n", encoding="utf-8"
            )
            findings = shipkit_init.detect_prior_state(["autonomous"], skills_target)
            joined = "\n".join(findings)
            self.assertIn("silently keep launching /loop", joined)
            self.assertNotIn("COPY (current, frozen", joined)


class TestJqPreflight(unittest.TestCase):
    """Finding 1(b): the installer hard-fails (before writing) when the selected module set
    installs hooks but jq is not on PATH; passes cleanly when jq is present."""

    def test_hooks_in_module_set_detects_hooks(self):
        # autonomous installs mate/bosun hooks; a doc-only set (compound) installs none.
        self.assertTrue(shipkit_init.hooks_in_module_set(["autonomous"]))
        self.assertEqual(shipkit_init.hooks_in_module_set(["compound"]), [])

    def test_assert_jq_present_no_hooks_is_noop(self):
        orig = shipkit_init.shutil.which
        shipkit_init.shutil.which = lambda _n: None  # jq "absent"
        try:
            shipkit_init.assert_jq_present(["compound"])  # no hooks → must not raise/exit
        finally:
            shipkit_init.shutil.which = orig

    def test_assert_jq_present_fails_without_jq_when_hooks(self):
        orig = shipkit_init.shutil.which
        shipkit_init.shutil.which = lambda _n: None
        try:
            with self.assertRaises(SystemExit):
                shipkit_init.assert_jq_present(["autonomous"])
        finally:
            shipkit_init.shutil.which = orig

    def test_assert_jq_present_passes_with_jq(self):
        orig = shipkit_init.shutil.which
        shipkit_init.shutil.which = lambda _n: "/usr/bin/jq"
        try:
            shipkit_init.assert_jq_present(["autonomous"])  # jq present → clean
        finally:
            shipkit_init.shutil.which = orig


class TestOrphanWhitelist(unittest.TestCase):
    """The setup skill itself must never be flagged ORPHAN (the stale 'shipkit-init'
    whitelist name had detect_prior_state telling an obedient agent to delete its own
    installer)."""

    def test_shipkit_setup_not_orphan_even_outside_module_set(self):
        with tempfile.TemporaryDirectory() as td:
            target = shipkit_init.Path(td)
            os.symlink(os.path.join(ROOT, ".claude", "skills", "shipkit-setup"),
                       target / "shipkit-setup", target_is_directory=True)
            # "compound" does NOT carry the setup skill — only the always-expected
            # whitelist can save it here (a hand-placed legacy copy in ~/.claude).
            findings = shipkit_init.detect_prior_state(["compound"], target)
            setup_lines = [ln for ln in findings if "shipkit-setup" in ln]
            self.assertTrue(setup_lines, "shipkit-setup symlink not scanned at all")
            for ln in setup_lines:
                self.assertNotIn("ORPHAN", ln)

    def test_setup_skill_is_project_level_not_manifest_installed(self):
        # The skill's canonical home is the repo's own .claude/skills/ (resolves as
        # /shipkit-setup in a fresh clone with zero install); a ~/.claude copy would
        # be a staleness surface, so no module may install it.
        self.assertTrue(
            os.path.isfile(os.path.join(ROOT, ".claude", "skills", "shipkit-setup", "SKILL.md")))
        with open(os.path.join(ROOT, "presets.json")) as f:
            all_modules = {m for mods in json.load(f)["presets"].values() for m in mods}
        for mod in sorted(all_modules):
            skills = shipkit_init.load_module(mod).get("skills", [])
            self.assertFalse(
                any(os.path.basename(s) == "shipkit-setup" for s in skills),
                f"module {mod} must not install the project-level setup skill")


class TestAssertHookPathsExitContract(unittest.TestCase):
    """assert_hook_paths returns (lines, ok); ok=False on any FAIL — main() exits non-zero."""

    DEF_TMPL = (
        "---\nname: ship-crew\nhooks:\n  PreToolUse:\n    - matcher: \"Bash\"\n"
        "      hooks:\n        - type: command\n          command: '{cmd}'\n---\nbody\n"
    )

    def test_broken_path_fails(self):
        with tempfile.TemporaryDirectory() as td:
            agents = shipkit_init.Path(td)
            (agents / "ship-crew.md").write_text(
                self.DEF_TMPL.format(cmd="bash /nope/validate-crew-bash.sh"),
                encoding="utf-8")
            lines, ok = shipkit_init.assert_hook_paths(agents)
            self.assertFalse(ok)
            self.assertTrue(any(ln.startswith("FAIL") for ln in lines))

    def test_resolving_path_ok(self):
        real_hook = os.path.join(ROOT, "core", "hooks", "validate-crew-bash.sh")
        with tempfile.TemporaryDirectory() as td:
            agents = shipkit_init.Path(td)
            (agents / "ship-crew.md").write_text(
                self.DEF_TMPL.format(cmd=f"bash {real_hook}"), encoding="utf-8")
            lines, ok = shipkit_init.assert_hook_paths(agents)
            self.assertTrue(ok, f"expected ok, got: {lines}")



class TestEndToEndFreshInstall(unittest.TestCase):
    """Subprocess runs against a scratch COPY of the repo (simulating a fresh clone:
    no loop.config.json, no mate.local.md) with redirected agents/skills targets.
    Covers: --defaults resolution, fresh config creation from the example, the
    hook-path FAIL -> non-zero exit contract, and --refresh-agents recovery."""

    import subprocess as _sp

    def _make_kit(self, td):
        import shutil as _sh
        kit = os.path.join(td, "kit")
        _sh.copytree(ROOT, kit, ignore=_sh.ignore_patterns(
            ".git", "__pycache__", "*.pyc", "loop.config.json", "mate.local.md"))
        return kit

    def _run(self, kit, *argv):
        return self._sp.run(
            [sys.executable, os.path.join(kit, "shipkit_init.py"), *argv],
            capture_output=True, text=True, cwd=kit)

    def test_defaults_fresh_install(self):
        with tempfile.TemporaryDirectory() as td:
            kit = self._make_kit(td)
            agents = os.path.join(td, "agents")
            skills = os.path.join(td, "skills")
            res = self._run(kit, "--defaults",
                            "--agents-target", agents, "--skills-target", skills)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertIn("--defaults chose: preset=core", res.stdout)
            # Fresh clone has no config -> the run must CREATE it from the example.
            self.assertIn("wrote loop.config.json", res.stdout)
            self.assertTrue(os.path.isfile(os.path.join(kit, "loop.config.json")))
            self.assertNotIn("exists — left untouched (pass --force-config", res.stdout)
            # Core agents installed; no FAIL lines anywhere.
            self.assertTrue(os.path.isfile(os.path.join(agents, "ship-crew.md")))
            self.assertNotIn("FAIL", res.stdout)
            # The setup skill self-installs and is NOT an orphan.
            # Project-level skill: never installed to the skills target.
            self.assertFalse(os.path.exists(os.path.join(skills, "shipkit-setup")))
            self.assertTrue(os.path.isfile(
                os.path.join(kit, ".claude", "skills", "shipkit-setup", "SKILL.md")))
            for ln in res.stdout.splitlines():
                if "shipkit-setup" in ln:
                    self.assertNotIn("ORPHAN", ln)

    def test_defaults_mutually_exclusive(self):
        with tempfile.TemporaryDirectory() as td:
            kit = self._make_kit(td)
            res = self._run(kit, "--defaults", "--preset", "autonomous")
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("mutually exclusive", res.stderr)

    def test_broken_ship_root_exits_nonzero_and_refresh_recovers(self):
        with tempfile.TemporaryDirectory() as td:
            kit = self._make_kit(td)
            agents = os.path.join(td, "agents")
            skills = os.path.join(td, "skills")
            elsewhere = os.path.join(td, "not-the-ship")
            os.makedirs(elsewhere)
            common = ["--preset", "core",
                      "--agents-target", agents, "--skills-target", skills]
            # Wrong ship-root: hook paths don't resolve -> FAIL lines AND exit != 0.
            res = self._run(kit, *common, "--ship-root", elsewhere)
            self.assertNotEqual(res.returncode, 0,
                                "hook-path FAIL must not exit green:\n" + res.stdout)
            self.assertIn("FAIL", res.stdout)
            self.assertIn("hook-path assertion", res.stderr)
            # Naive re-run with the CORRECT root but no flag: defs left untouched,
            # still broken, still non-zero.
            res2 = self._run(kit, *common, "--ship-root", ".")
            self.assertNotEqual(res2.returncode, 0)
            self.assertIn("left untouched (pass --refresh-agents", res2.stdout)
            # The documented recovery: --refresh-agents re-renders -> clean, exit 0.
            res3 = self._run(kit, *common, "--ship-root", ".", "--refresh-agents")
            self.assertEqual(res3.returncode, 0, res3.stdout + res3.stderr)
            self.assertIn("refreshed (re-rendered", res3.stdout)
            self.assertNotIn("FAIL", res3.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
