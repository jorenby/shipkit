#!/usr/bin/env python3
"""shipkit_init.py — the deterministic, MANIFEST-DRIVEN apply step for shipkit onboarding.

This is the plumbing the `/shipkit-setup` skill calls once it has gathered answers (and the
skill carries the upgrade JUDGMENT — this script does not). It is intentionally MINIMAL: it
does only mechanical, safe, deterministic ops and SURFACES findings for the Mate/user to
judge. It never auto-resolves an idiosyncratic divergence.

What it does:
  1. Write loop.config.json from loop.config.example.json (untouched unless --force-config).
  2. Write mate.local.md from core/mate.local.example.md (untouched unless --force-prefs).
  3. Install the selected tiers' AGENT DEFS, substituting {SHIP_DIR} in each def's hook
     command paths. (Agent defs are always WRITTEN, never symlinked — a symlink wouldn't get
     the {SHIP_DIR} substitution.) Hook commands render as `<interpreter> <abs-path>` so they
     invoke under bash without depending on the exec bit or shebang resolution (NTFS has no
     exec bit). The interpreter is RESOLVED AT INSTALL TIME (resolve_hook_interpreter): POSIX
     keeps a bare `bash`; win32 resolves an absolute Git-Bash path (a bare `bash` on Windows
     can resolve to WSL's System32 stub, which can't see the Windows script path → fail open).
     The script path is forward-slashed and the whole command is a single-quoted YAML scalar.
  4. Set +x on every selected hook (POSIX belt-and-suspenders — since commands invoke via
     `bash <path>`, the exec bit is no longer load-bearing for enforcement). It ASSERTS each
     installed agent-def hook command path EXISTS, and reports any that don't (a broken hook
     path = silent zero enforcement). Then it runs a CRITICAL placeholder-verification pass:
     it greps every installed agent def for a remaining literal template token (e.g.
     {SHIP_DIR}) and FAILS LOUDLY (non-zero exit) if any survive — a leftover placeholder
     means the hook path is garbage and enforcement is SILENTLY OFF (the v1 footgun).
  5. Symlink-or-copy the selected modules' skill dirs into the skills target.
  6. Seed state/status.json (delegates to lib/status_writer.py --init).
  7. DETECT-AND-REPORT prior-install state (orphan skills, copied-vs-symlinked skills, missing
     config keys) WITHOUT resolving it — the SKILL reasons about it with the user.

Source of truth: presets.json (preset -> module-folder list) + each module folder's
module.json (the module's files + its tier + its declared lib[] deps). This script reads
those manifests; it does NOT hard-code the module map.

Stdlib only. Cross-platform (pathlib + json + shutil). On Windows the skill/agent install
defaults to COPY (os.symlink needs admin/Developer Mode there); a failed symlink falls back
to a copy.

Usage
-----
  shipkit_init.py --defaults                         # fresh-machine one-shot: core, ship-root=., platform install mode
  shipkit_init.py --preset core        --ship-root /abs/path/to/ship
  shipkit_init.py --preset autonomous  --ship-root .  --install-mode symlink
  shipkit_init.py --modules ui                       # resolves requires[] transitively
  shipkit_init.py --preset autonomous --dry-run
  shipkit_init.py --answers /tmp/answers.json
  shipkit_init.py --refresh-agents --preset core --ship-root .   # re-render existing agent defs
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

SHIPKIT_ROOT = Path(__file__).resolve().parent
PRESETS_FILE = SHIPKIT_ROOT / "presets.json"
LIB_DIR = SHIPKIT_ROOT / "lib"
DEFAULT_SKILLS_TARGET = Path.home() / ".claude" / "skills"
DEFAULT_AGENTS_TARGET = Path.home() / ".claude" / "agents"

IS_WINDOWS = os.name == "nt"
DEFAULT_INSTALL_MODE = "copy" if IS_WINDOWS else "symlink"

# A module's folder, keyed by module name. Most live under modules/<name>/; the tier-1
# anchor is core/ (at root). The tier-3 UI slot ships on the stacked UI PR.
MODULE_DIRS = {
    "core": SHIPKIT_ROOT / "core",
}


def _err(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


# ---- hook interpreter resolution (CRITICAL: cross-platform enforcement) --------------
#
# The agent-def hook commands are rendered as `<interpreter> <script-path>` so the outer
# shell (POSIX sh / Git-Bash / cmd) invokes the script UNDER bash regardless of exec bit
# or shebang resolution (NTFS has no exec bit). Picking the interpreter is load-bearing:
#
#   On Windows, a BARE `bash` resolves via PATH — and `where bash` on a dev box very often
#   returns C:\Windows\System32\bash.exe FIRST, which is the WSL stub. The harness runs the
#   hook via cmd, WSL bash launches, and the Windows-style script path (C:\...) is invisible
#   inside the WSL filesystem (it'd need /mnt/c/...). The hook errors, PreToolUse treats a
#   non-zero-that-isn't-2 / crash as non-blocking → the bright line FAILS OPEN, silently.
#
# So on win32 we resolve an ABSOLUTE Git-Bash path at install time and FAIL LOUDLY if we
# can't find one (an unenforced install must never be silent — same doctrine as the
# placeholder gate). On POSIX, plain `bash` is correct everywhere and needs no resolution.
#
# resolve_hook_interpreter is a PURE function (platform + env + which-scan results in,
# interpreter string out) so it is unit-testable on macOS with mocked Windows inputs.

class HookInterpreterError(RuntimeError):
    """No usable bash interpreter could be resolved on this (Windows) platform."""


def resolve_hook_interpreter(platform: str, env: dict, which_results) -> str:
    """Resolve the interpreter token to render into agent-def hook commands.

    platform      : sys.platform value ('win32', 'darwin', 'linux', ...).
    env           : environment mapping (os.environ) — read for %ProgramFiles% probes.
    which_results : the paths a `where bash` / `which bash` scan returned (list[str]),
                    IN ORDER. May be empty.

    POSIX -> 'bash' (correct everywhere; PATH resolution is not a footgun there).

    win32 -> an ABSOLUTE, forward-slashed, DOUBLE-quoted Git-Bash path, chosen by:
        1. %ProgramFiles%\\Git\\bin\\bash.exe
        2. %ProgramFiles(x86)%\\Git\\bin\\bash.exe
        3. the first `where bash` hit that is NOT under System32 (that's WSL's stub).
      Raises HookInterpreterError if none of those yield a real Git-Bash — NEVER falls
      back to bare `bash` (that's the silent-fail-open path we're closing).

    The returned token is spliced directly before the (forward-slashed) script path.
    On win32 it is already double-quoted so the space in 'Program Files' survives; the
    whole command is then wrapped as a single-quoted YAML scalar by the renderer (belt).
    """
    if platform != "win32":
        return "bash"

    def _norm(p: str) -> str:
        return p.replace("\\", "/")

    def _is_system32(p: str) -> bool:
        return "system32" in p.replace("\\", "/").lower()

    # 1 + 2: probe the well-known Git install locations from the environment.
    for var in ("ProgramFiles", "ProgramFiles(x86)"):
        base = env.get(var)
        if not base:
            continue
        candidate = os.path.join(base, "Git", "bin", "bash.exe")
        if os.path.isfile(candidate):
            return f'"{_norm(candidate)}"'

    # 3: scan the `where bash` results, filtering out the WSL System32 stub.
    for hit in which_results or []:
        if not hit:
            continue
        if _is_system32(hit):
            continue
        return f'"{_norm(hit)}"'

    raise HookInterpreterError(
        "No Git-Bash found on this Windows box. Probed %ProgramFiles%\\Git\\bin\\bash.exe, "
        "%ProgramFiles(x86)%\\Git\\bin\\bash.exe, and `where bash` (System32/WSL stub "
        "filtered out) — all empty. The agent-def hooks would render a bare `bash` that "
        "resolves to WSL's bash.exe, which cannot see the Windows script path → the "
        "bright-line hooks FAIL OPEN silently. Install Git for Windows (Git-Bash) and "
        "re-run the installer. An unenforced install must never be silent."
    )


def _where_bash() -> list:
    """Best-effort `where bash` scan (win32). Pure resolution lives in
    resolve_hook_interpreter; this only feeds it the raw PATH hits."""
    try:
        res = subprocess.run(["where", "bash"], capture_output=True, text=True)
    except (OSError, subprocess.SubprocessError):
        return []
    if res.returncode != 0:
        return []
    return [ln.strip() for ln in res.stdout.splitlines() if ln.strip()]


def render_hook_command(interpreter: str, script_path_abs: str) -> str:
    """Render a hook command line body: `<interpreter> <fwd-slash script path>`, emitted
    as a SINGLE-QUOTED YAML scalar. Forward slashes (Finding C: raw backslashes in a
    double-quoted YAML scalar are invalid escapes — parser leniency was load-bearing) plus
    the single-quote wrapper make the frontmatter valid under a strict YAML parse."""
    fwd = script_path_abs.replace("\\", "/")
    inner = f"{interpreter} {fwd}"
    # Single-quoted YAML scalar: the only escape is '' for a literal single quote.
    return "'" + inner.replace("'", "''") + "'"


def _load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        _err(f"manifest missing: {path}")
    except json.JSONDecodeError as e:
        _err(f"{path} is not valid JSON: {e}")


def module_dir(name: str) -> Path:
    return MODULE_DIRS.get(name, SHIPKIT_ROOT / "modules" / name)


def load_module(name: str) -> dict:
    d = module_dir(name)
    manifest = d / "module.json"
    if not manifest.is_file():
        _err(f"module {name!r}: no module.json at {manifest}")
    meta = _load_json(manifest)
    meta["_dir"] = d
    return meta


def load_presets() -> dict:
    return _load_json(PRESETS_FILE).get("presets", {})


def resolve_modules(preset, modules):
    presets = load_presets()
    if modules:
        seeds = list(modules)
    elif preset:
        if preset not in presets:
            _err(f"unknown preset {preset!r}. Known: {', '.join(presets)}.")
        seeds = list(presets[preset])
    else:
        _err("provide --preset or --modules (or an --answers file with one).")

    # Resolve requires[] transitively; deps install first (stable order).
    ordered = []
    seen = set()

    def visit(name):
        if name in seen:
            return
        seen.add(name)
        meta = load_module(name)
        for req in meta.get("requires", []):
            visit(req)
        ordered.append(name)

    for m in seeds:
        visit(m)
    return ordered


# ---- jq preflight (CRITICAL: the enforcement hooks parse stdin with jq) --------------
#
# Every validate-*-bash.sh hook parses its PreToolUse stdin with jq. The hooks now FAIL
# CLOSED at runtime when jq is absent (they exit 2, bricking Bash for the hooked session)
# — the correct loud failure vs the old silent zero-enforcement. This preflight means a
# correctly-installed ship never hits that: if the selected module set installs ANY hook,
# assert jq is on PATH and hard-FAIL loudly BEFORE writing anything (same doctrine as the
# interpreter + placeholder gates — an unenforced OR bricked install must never be silent).

def hooks_in_module_set(module_list) -> list:
    """The hook labels ('<module>/<rel>') the selected module set would install."""
    hooks = []
    for name in module_list:
        for rel in load_module(name).get("hooks", []):
            hooks.append(f"{name}/{rel}")
    return hooks


def assert_jq_present(module_list) -> None:
    """Fail (before any write) if this module set installs hooks but jq is not on PATH."""
    hooks = hooks_in_module_set(module_list)
    if not hooks:
        return
    if shutil.which("jq"):
        return
    _err(
        "jq is REQUIRED but not found on PATH.\n"
        f"  The selected modules install enforcement hooks ({', '.join(hooks)}) that parse\n"
        "  their PreToolUse stdin with jq. Without jq every hook fails CLOSED (exit 2 — it\n"
        "  bricks Bash for the hooked agent session). Install jq and re-run:\n"
        "    macOS:              brew install jq\n"
        "    Debian/Ubuntu:      apt-get install jq\n"
        "    Windows (Git-Bash): winget install jqlang.jq   (or: pacman -S mingw-w64-x86_64-jq)"
    )


# ---- config + prefs (machine config vs taste) ---------------------------------------

def build_config(answers: dict) -> dict:
    example_path = SHIPKIT_ROOT / "loop.config.example.json"
    example = _load_json(example_path)
    cfg = {k: v for k, v in example.items() if not k.startswith("_")}
    cfg["_comment"] = ("Generated by shipkit_init.py from loop.config.example.json. "
                       "Safe to hand-edit; re-running only rewrites it with --force-config. "
                       "See loop.config.example.json for field docs.")
    for key in ("ship_root", "repos", "max_concurrent_crew", "github_org",
                "chat_surface", "validator_cmd", "headroom_signal_path", "hosts_ports"):
        if key in answers:
            cfg[key] = answers[key]
    cfg.setdefault("ship_root", ".")
    return cfg


def write_config(cfg, dry_run, force_config):
    target = SHIPKIT_ROOT / "loop.config.json"
    if target.exists() and not force_config:
        return ["loop.config.json exists — left untouched (pass --force-config to regenerate)"]
    serialized = json.dumps(cfg, indent=2, ensure_ascii=False) + "\n"
    if dry_run:
        return [f"would write loop.config.json (ship_root={cfg['ship_root']!r})"]
    tmp = target.with_suffix(".json.tmp")
    tmp.write_text(serialized, encoding="utf-8")
    os.replace(tmp, target)
    return [f"wrote loop.config.json (ship_root={cfg['ship_root']!r})"]


PREF_KEYS = {
    "max_concurrent_crew", "model_default", "model_escalate", "model_lookout", "model_speed",
    "review_policy", "review_model", "review_standards", "report_format", "chat_surface",
    "search_tool", "pr_review_cmd", "github_org", "pr_template",
}


def build_prefs(answers: dict) -> dict:
    raw = answers.get("prefs") or {}
    if not isinstance(raw, dict):
        _err("answers 'prefs' must be a JSON object of key -> value.")
    prefs = {}
    for key in PREF_KEYS:
        val = raw.get(key)
        if val is None and key == "max_concurrent_crew":
            val = answers.get("max_concurrent_crew")
        if val is None:
            continue
        prefs[key] = str(val)
    return prefs


def _substitute_pref_line(line: str, value: str) -> str:
    head, sep, comment = line.partition("#")
    colon = head.index(":")
    key_part = head[:colon + 1]
    pad_old = head[colon + 1:]
    lead_ws = pad_old[:len(pad_old) - len(pad_old.lstrip())]
    if sep:
        return f"{key_part}{lead_ws}{value}   {sep}{comment}".rstrip("\n") + "\n"
    return f"{key_part}{lead_ws}{value}".rstrip() + "\n"


def render_prefs(prefs, house_notes, example_path):
    try:
        text = example_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        _err(f"prefs template missing: {example_path}")
    out_lines = []
    in_fence = False
    for line in text.splitlines(keepends=True):
        if line.strip().startswith("```"):
            in_fence = not in_fence
            out_lines.append(line)
            continue
        if in_fence:
            body = line.lstrip()
            matched = False
            for key in prefs:
                if body.startswith(f"{key}:"):
                    out_lines.append(_substitute_pref_line(line, prefs[key]))
                    matched = True
                    break
            if matched:
                continue
        out_lines.append(line)
    text = "".join(out_lines)
    text = text.replace("# Mate — Local Preferences (template)\n",
                        "# Mate — Local Preferences\n", 1)
    text = text.replace(
        "Copy this file to **`mate.local.md`** and fill in your values. The Mate reads",
        "Generated by `/shipkit-setup` (shipkit_init.py) from "
        "`core/mate.local.example.md`.\nHand-edit anytime. The Mate reads", 1)
    if house_notes:
        note_block = "\n".join(f"- {n}" for n in house_notes) + "\n"
        marker = "- (example) Restart service X"
        idx = text.find(marker)
        text = (text[:idx] + note_block) if idx != -1 else text.rstrip("\n") + "\n\n" + note_block
    return text


def write_prefs(answers, dry_run, force_prefs):
    target = SHIPKIT_ROOT / "mate.local.md"
    example_path = SHIPKIT_ROOT / "core" / "mate.local.example.md"
    prefs = build_prefs(answers)
    house_notes = answers.get("house_notes")
    if house_notes is not None and not isinstance(house_notes, list):
        _err("answers 'house_notes' must be a JSON list of strings.")
    supplied = ", ".join(sorted(prefs)) if prefs else "(none — all defaults)"
    if target.exists() and not force_prefs:
        return [f"mate.local.md exists — left untouched (pass --force-prefs). "
                f"Prefs that WOULD apply: {supplied}"]
    text = render_prefs(prefs, house_notes, example_path)
    if dry_run:
        return [f"would write mate.local.md ({len(prefs)} pref(s): {supplied})"]
    tmp = target.with_suffix(".md.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, target)
    return [f"wrote mate.local.md ({len(prefs)} pref(s) applied: {supplied})"]


# ---- agents, hooks, lib, skills (manifest-driven) -----------------------------------

# A hook command line in a source agent def looks like (double-quoted, bare `bash`):
#     command: "bash {SHIP_DIR}/core/hooks/validate-crew-bash.sh"
# After {SHIP_DIR} substitution the body is `bash <abs-path>/...validate-*.sh`. We rewrite
# that whole line: resolve the interpreter (Finding A), forward-slash the path + single-quote
# the scalar (Finding C). Only lines whose script path contains `validate-` are rewritten —
# those are the enforcement hooks; nothing else in the def is touched.
_COMMAND_LINE = re.compile(r'^(?P<indent>\s*)command:\s*"(?P<body>.*)"\s*$')


def _rewrite_hook_command_lines(content: str, interpreter: str) -> str:
    """Rewrite every `command: "<bash|sh> <path>/validate-*.sh"` line to
    `command: '<interpreter> <fwd-slash path>'` (single-quoted YAML scalar)."""
    out = []
    for line in content.splitlines(keepends=True):
        eol = "\n" if line.endswith("\n") else ""
        m = _COMMAND_LINE.match(line.rstrip("\n"))
        if not m:
            out.append(line)
            continue
        body = m.group("body")
        # Recover the script path: strip a leading bash/sh interpreter token if present.
        script = body
        for prefix in ("bash ", "sh "):
            if script.startswith(prefix):
                script = script[len(prefix):]
                break
        script = script.strip()
        if "validate-" not in script:
            out.append(line)
            continue
        rendered = render_hook_command(interpreter, script)
        out.append(f"{m.group('indent')}command: {rendered}{eol}")
    return "".join(out)


def install_agents(module_list, agents_target, ship_root_abs, dry_run, interpreter="bash",
                   refresh=False):
    """Write each selected module's agent defs into agents_target, substituting {SHIP_DIR}
    in the hook command paths and rendering the hook interpreter resolved at install time
    (Finding A). Always WRITTEN (never symlinked) so the substitution lands.

    refresh=False (default): an existing def is left untouched — upgrades are the SKILL's
    judgment. refresh=True (--refresh-agents): existing defs are RE-RENDERED from the
    current manifests — the sanctioned recovery when installed defs carry a broken hook
    path (e.g. a first run with the wrong --ship-root)."""
    lines = []
    if not dry_run:
        agents_target.mkdir(parents=True, exist_ok=True)
    for name in module_list:
        meta = load_module(name)
        for rel in meta.get("agents", []):
            src = meta["_dir"] / rel
            if not src.is_file():
                lines.append(f"{rel}: source missing at {src} — skipped")
                continue
            dst = agents_target / Path(rel).name
            content = src.read_text(encoding="utf-8").replace("{SHIP_DIR}", ship_root_abs)
            content = _rewrite_hook_command_lines(content, interpreter)
            existed = dst.exists()
            if existed and not refresh:
                lines.append(f"{dst.name}: exists — left untouched (pass --refresh-agents to re-render; the SKILL judges upgrades)")
                continue
            verb = "refresh (re-render)" if existed else "install"
            if dry_run:
                lines.append(f"{dst.name}: would {verb} ({{SHIP_DIR}} -> {ship_root_abs}, interp={interpreter})")
                continue
            dst.write_text(content, encoding="utf-8")
            done = "refreshed (re-rendered from current manifests" if existed else "installed ({SHIP_DIR} substituted"
            lines.append(f"{dst.name}: {done}; hook interp={interpreter})")
    return lines


def chmod_hooks(module_list, dry_run):
    """Set +x on every selected module's hooks. A non-exec hook fails OPEN."""
    lines = []
    for name in module_list:
        meta = load_module(name)
        for rel in meta.get("hooks", []):
            f = meta["_dir"] / rel
            if not f.is_file():
                lines.append(f"{name}/{rel}: MISSING at {f}")
                continue
            if os.access(f, os.X_OK):
                lines.append(f"{name}/{rel}: already +x")
                continue
            if dry_run:
                lines.append(f"{name}/{rel}: would chmod +x (currently non-exec — fails OPEN!)")
                continue
            mode = f.stat().st_mode
            f.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            lines.append(f"{name}/{rel}: chmod +x (was non-exec — fixed)")
    return lines


def _hook_path_from_command(cmd: str) -> str:
    """Extract the hook SCRIPT PATH from a rendered command string. Commands render as
    `<interpreter> <script-path>` where <interpreter> is:
      - POSIX: a bare `bash` (or legacy `sh`),
      - win32: a DOUBLE-quoted absolute Git-Bash path (Finding A), e.g.
        `"C:/Program Files/Git/bin/bash.exe" C:/ship/core/hooks/validate-crew-bash.sh`.
    Strip whichever interpreter form leads, recover the script path. Tolerate the
    bare-path legacy form (no interpreter) too."""
    stripped = cmd.strip()
    # win32: a double-quoted interpreter path leads. Take everything after the closing quote.
    if stripped.startswith('"'):
        end = stripped.find('"', 1)
        if end != -1:
            return stripped[end + 1:].strip()
    for prefix in ("bash ", "sh "):
        if stripped.startswith(prefix):
            return stripped[len(prefix):].strip()
    return stripped


def _command_scalar(text):
    """Yield each rendered `command:` scalar VALUE from an agent def, YAML-unescaped.
    Handles the double-quoted (source/legacy) and single-quoted (rendered — Finding C)
    forms. Single-quoted YAML: '' -> a literal single quote."""
    token = re.compile(r"""command:\s*(?:"([^"]+)"|'((?:[^']|'')*)')""")
    for dq, sq in token.findall(text):
        if dq:
            yield dq
        else:
            yield sq.replace("''", "'")


def _interpreter_from_command(cmd: str):
    """Extract the interpreter portion of a rendered command (win32: a quoted absolute
    bash path). Returns the absolute path (unquoted) if the interpreter is a quoted path,
    else None (bare `bash`/`sh` — nothing to existence-check)."""
    stripped = cmd.strip()
    if stripped.startswith('"'):
        end = stripped.find('"', 1)
        if end != -1:
            return stripped[1:end]
    return None


def assert_hook_paths(agents_target):
    """Read the JUST-INSTALLED agent defs and assert each hook command path EXISTS.
    A broken hook command path = silent zero enforcement; surface it loudly (FAIL).

    Commands render as `<interpreter> <abs-path>` — on POSIX the interpreter is a bare
    `bash`; on win32 it's a resolved absolute Git-Bash path (Finding A). The outer shell
    invokes bash against the script, so the exec bit is NOT load-bearing for enforcement
    (Git-Bash / NTFS has no exec bit). We still REPORT a missing +x on POSIX as
    belt-and-suspenders (never a FAIL). On win32 we ALSO assert the resolved interpreter
    path itself exists — a bad interpreter fails open just like a bad script path.

    Returns (lines, ok). ok=False on ANY FAIL — the caller must exit non-zero (a printed
    FAIL with a green exit code is exactly the fail-open a script/skimmer would miss)."""
    lines = []
    ok = True
    for f in sorted(agents_target.glob("ship-*.md")):
        try:
            text = f.read_text(encoding="utf-8")
        except OSError:
            continue
        for cmd in _command_scalar(text):
            if "validate-" not in cmd:
                continue
            interp = _interpreter_from_command(cmd)
            if interp is not None and not Path(interp).is_file():
                ok = False
                lines.append(f"FAIL {f.name}: hook INTERPRETER NOT FOUND: {interp} "
                             f"(FAILS OPEN — resolve a real Git-Bash and re-render)")
                continue
            pth = Path(_hook_path_from_command(cmd))
            if not pth.is_file():
                ok = False
                lines.append(f"FAIL {f.name}: hook NOT FOUND: {pth} (FAILS OPEN — fix before relying on it)")
            elif not os.access(pth, os.X_OK):
                # Invoked via `bash <path>`, so this is fine on Git-Bash/NTFS. Note it on POSIX.
                lines.append(f"ok   {f.name}: {pth.name} resolves (invoked via `bash`; +x not set — fine on Git-Bash, add it on POSIX)")
            else:
                lines.append(f"ok   {f.name}: {pth.name} resolves + executable (invoked via `bash`)")
    if not lines:
        lines.append("(no installed agent-def hook command paths to assert)")
    return lines, ok


# Injected template tokens follow an UPPER_SNAKE_CASE convention ({SHIP_DIR} is the only one
# the installer substitutes today; the pattern catches any future sibling). It deliberately
# does NOT match the agent defs' legitimate prose placeholders — {project}, {ticket-id},
# {branch-name}, free-text-in-braces — which are lowercase / hyphenated / spaced and are
# SUPPOSED to survive verbatim in the installed def. Matching those would false-positive the
# gate on every good install. A leftover UPPER_SNAKE token = the render didn't land.
_TEMPLATE_TOKEN = re.compile(r"\{[A-Z][A-Z0-9_]*\}")


def verify_no_unexpanded_placeholders(agents_target, module_list):
    """CRITICAL post-install gate (v1 footgun: `{SHIP_DIR}` shipped LITERAL in installed
    agent hook commands → every hook path was garbage → enforcement was SILENTLY OFF and
    nothing surfaced it). Grep EVERY installed artifact for a remaining literal template
    token. FAILS LOUDLY (returns ok=False) — never a soft warning: a leftover `{SHIP_DIR}`
    means the bright lines are disarmed.

    Scope: the files this installer template-substitutes are the agent defs written into
    agents_target. We scan the ones this run's module set installs (by basename)."""
    lines = []
    ok = True
    # Basenames of agent defs this module set installs — the artifacts that carry {SHIP_DIR}.
    installed_names = set()
    for name in module_list:
        for rel in load_module(name).get("agents", []):
            installed_names.add(Path(rel).name)

    scanned = 0
    for f in sorted(agents_target.glob("*.md")):
        if f.name not in installed_names:
            continue
        try:
            text = f.read_text(encoding="utf-8")
        except OSError as e:
            lines.append(f"FAIL {f.name}: unreadable ({e}) — cannot verify placeholders")
            ok = False
            continue
        scanned += 1
        found = sorted(set(_TEMPLATE_TOKEN.findall(text)))
        if found:
            ok = False
            lines.append(f"FAIL {f.name}: UNEXPANDED TEMPLATE TOKEN(S) {', '.join(found)} "
                         f"still present in installed artifact")
            continue
        # On win32 the hook command carries a RESOLVED absolute interpreter path (Finding A).
        # A rendered interpreter that doesn't exist fails open exactly like a garbage script
        # path — so it's part of THIS critical gate, not just the (non-fatal) hook-path report.
        bad_interp = False
        for cmd in _command_scalar(text):
            if "validate-" not in cmd:
                continue
            interp = _interpreter_from_command(cmd)
            if interp is not None and not Path(interp).is_file():
                ok = False
                bad_interp = True
                lines.append(f"FAIL {f.name}: rendered hook INTERPRETER path does not exist: "
                             f"{interp} (enforcement would FAIL OPEN)")
        if not bad_interp:
            lines.append(f"ok   {f.name}: no template tokens remain (render landed)")

    if scanned == 0:
        # Nothing to verify is itself suspect if the module set declared agents.
        if installed_names:
            lines.append(f"WARN: expected to verify {sorted(installed_names)} but none were "
                         f"found in {agents_target} — were they installed?")
        else:
            lines.append("(no template-bearing artifacts for the selected modules)")

    if not ok:
        lines.append("")
        lines.append("!!! ENFORCEMENT WOULD BE SILENTLY OFF — a rendered agent def carries either a")
        lines.append("!!! literal template token (e.g. {SHIP_DIR}) OR a hook interpreter path that")
        lines.append("!!! does not exist. Its PreToolUse hook command is GARBAGE, so the bright-line")
        lines.append("!!! hook FAILS OPEN with zero enforcement and nothing else surfaces it. Fix the")
        lines.append("!!! affected agent def(s) (remove + re-run so the substitution/resolution lands;")
        lines.append("!!! on Windows, install Git-Bash). DO NOT run crew until this is clean.")
    return lines, ok


def install_lib(module_list):
    """Union each selected module's declared lib[] deps; assert lib/ files present + report.
    lib/ files stay in place (this repo IS the install); the union is verified, not copied."""
    needed = []
    for name in module_list:
        for f in load_module(name).get("lib", []):
            if f not in needed:
                needed.append(f)
    if not needed:
        return ["(no shared lib deps for the selected modules)"]
    return [f"lib/{f}: present" if (LIB_DIR / f).exists() else f"lib/{f}: MISSING at {LIB_DIR / f}"
            for f in needed]


def _install_one(src: Path, dst: Path, mode: str, dry_run: bool) -> str:
    label = dst.name
    if dst.exists() or dst.is_symlink():
        if dst.is_symlink():
            try:
                if dst.resolve() == src.resolve():
                    return f"{label}: already linked (no-op)"
            except OSError:
                return f"{label}: existing symlink is broken — leaving it (the SKILL judges orphans)"
            return f"{label}: a symlink already exists pointing elsewhere — left untouched"
        return f"{label}: target already exists (a COPY, not a symlink) — left untouched (the SKILL judges copied-vs-linked)"
    if dry_run:
        return f"{label}: would {mode} -> {dst}"
    dst.parent.mkdir(parents=True, exist_ok=True)
    if mode == "symlink":
        try:
            os.symlink(src, dst, target_is_directory=True)
            return f"{label}: symlinked -> {dst}"
        except OSError as e:
            shutil.copytree(src, dst)
            return f"{label}: symlink failed ({e.strerror or e}); copied instead -> {dst}"
    shutil.copytree(src, dst)
    return f"{label}: copied -> {dst}"


def install_skills(module_list, skills_target, mode, dry_run):
    lines = []
    for name in module_list:
        meta = load_module(name)
        for rel in meta.get("skills", []):
            src = meta["_dir"] / rel
            if not src.is_dir():
                lines.append(f"{Path(rel).name}: source dir missing at {src} — skipped")
                continue
            lines.append(_install_one(src, skills_target / Path(rel).name, mode, dry_run))
    if not lines:
        lines.append("(no skill dirs to install for the selected modules)")
    return lines


def _dirs_identical(a: Path, b: Path) -> bool:
    """True iff directory trees a and b hold the same set of files with byte-identical
    contents. Deep (byte) compare — NOT filecmp's default shallow stat compare, since a
    fresh copytree preserves mtimes and we need content truth, not signature truth."""
    if not a.is_dir() or not b.is_dir():
        return False
    try:
        a_files = {p.relative_to(a) for p in a.rglob("*") if p.is_file()}
        b_files = {p.relative_to(b) for p in b.rglob("*") if p.is_file()}
        if a_files != b_files:
            return False
        for rel in a_files:
            if (a / rel).read_bytes() != (b / rel).read_bytes():
                return False
    except OSError:
        return False
    return True


def detect_prior_state(module_list, skills_target):
    """SURFACE prior-install findings for the SKILL/user to JUDGE. Resolves nothing.
    - orphan skills (in the target, not in any selected module) — e.g. a stale ship-tick
    - copied-vs-symlinked installed skills (a copied old ship-watch-start silently keeps /loop)
    - missing loop.config.json schema keys (vs the example) — never auto-migrated here"""
    findings = []
    selected_skills = {"shipkit-setup"}  # the setup skill is always expected, never an orphan
    source_skill_dirs = {}  # basename -> repo source dir (to tell a stale copy from a current one)
    for name in module_list:
        for rel in load_module(name).get("skills", []):
            selected_skills.add(Path(rel).name)
            source_skill_dirs[Path(rel).name] = load_module(name)["_dir"] / rel

    if skills_target.is_dir():
        for entry in sorted(skills_target.iterdir()):
            if not (entry.name.startswith("ship") or entry.name == "bosun-tick"):
                continue
            if entry.is_symlink():
                try:
                    target = entry.resolve(strict=True)
                    kind = "symlink->repo" if str(SHIPKIT_ROOT) in str(target) else "symlink->elsewhere"
                except OSError:
                    kind = "BROKEN symlink (target gone)"
            else:
                # A COPY only warrants the scary "silently keeps launching /loop" flag when it
                # DIFFERS from this repo's current skill (a genuinely stale/frozen old copy). A
                # copy byte-identical to the repo — e.g. the one THIS fresh copy-install just
                # wrote — is current, so the message stays neutral (no false alarm for a
                # first-timer).
                src = source_skill_dirs.get(entry.name)
                if src is not None and _dirs_identical(entry, src):
                    kind = "COPY (current, frozen — re-run init after git pull to refresh)"
                else:
                    kind = "COPY (frozen — a copied old boot skill can silently keep launching /loop)"
            orphan = " ORPHAN (not in any selected module)" if entry.name not in selected_skills else ""
            findings.append(f"skill {entry.name}: {kind}{orphan}")

    cfg = SHIPKIT_ROOT / "loop.config.json"
    example = SHIPKIT_ROOT / "loop.config.example.json"
    if cfg.exists() and example.exists():
        try:
            have = set(json.loads(cfg.read_text(encoding="utf-8")))
            want = {k for k in json.loads(example.read_text(encoding="utf-8")) if not k.startswith("_")}
            missing = sorted(want - have)
            if missing:
                findings.append(f"loop.config.json MISSING keys vs example: {', '.join(missing)} "
                                f"(the SKILL merges these with the user — not auto-migrated here)")
        except (json.JSONDecodeError, OSError):
            findings.append("loop.config.json present but unreadable — the SKILL should inspect it")

    if not findings:
        findings.append("(no prior-install state detected — clean machine)")
    return findings


def seed_state(dry_run):
    status_path = SHIPKIT_ROOT / "state" / "status.json"
    writer = LIB_DIR / "status_writer.py"
    if status_path.exists():
        try:
            doc = json.loads(status_path.read_text(encoding="utf-8"))
            if doc.get("generated_at"):
                return ["state/status.json already seeded (has generated_at) — no-op"]
        except (json.JSONDecodeError, OSError):
            pass
    if dry_run:
        return ["would seed state/status.json via lib/status_writer.py --init"]
    if not writer.exists():
        _err(f"status_writer.py not found at {writer}")
    res = subprocess.run([sys.executable, str(writer), "--init", "--force"],
                         capture_output=True, text=True)
    if res.returncode != 0:
        _err(f"status_writer.py --init failed: {res.stderr.strip() or res.stdout.strip()}")
    return [f"seeded state/status.json ({res.stdout.strip()})"]


def module_installs_nothing(name: str) -> bool:
    """True when a module's manifest declares NO installable artifacts (agents/hooks/
    skills/scripts) — a reserved slot (e.g. ui before its files land on the UI PR)."""
    meta = load_module(name)
    return not any(meta.get(k) for k in ("agents", "hooks", "skills", "scripts"))


def smoke_test_lines(module_list, skills_target, agents_target):
    has_autonomous = "autonomous" in module_list
    lines = ["", "Smoke test (the acceptance):"]
    if not has_autonomous:
        lines += [
            "  (tier 1 — core) Open Claude Code in the shipkit dir; say \"you're First Mate\".",
            "  The Mate reads core/mate.md and runs REQUEST/RESPONSE — a human drives it turn",
            "  by turn. It dispatches worker crew (ship-crew/lookout/reviewer/pilot) with the",
            "  crew-safety hooks armed. No Bosun, no loop, no UI at this tier.",
        ]
    else:
        lines += [
            "  1. Open Claude Code in the shipkit dir; say \"you're First Mate\".",
            "  2. Run /ship-watch-start — it boots event-driven: re-anchors, acquires the",
            "     mate-lock, arms the wake-monitor, BOOTSTRAPS THE BOSUN, preflights, IDLES.",
            "  3. Confirm the Bosun is ticking: tail state/bosun-heartbeat.log (fresh line).",
            "  4. Drop a directive (inbox/captain.md edit or inbox/drops/) -> the Mate WAKES.",
            "  5. Flip a bookkeeping item -> NO wake; it reconciles at the next wake.",
        ]
    lines += [
        "",
        f"Agent defs installed under: {agents_target}  ({{SHIP_DIR}} substituted).",
        f"Skills installed under:     {skills_target}",
        "Running the agent in a SANDBOX is recommended (defense-in-depth on top of the hooks).",
    ]
    if has_autonomous:
        lines.append("Launch the bg Mate: modules/autonomous/scripts/ship-up.sh --check (then --launch-mate).")
    lines.append("Re-run shipkit_init.py any time — idempotent; the SKILL judges upgrades.")
    return lines


def main():
    p = argparse.ArgumentParser(prog="shipkit_init.py",
                                description="Manifest-driven apply step for shipkit onboarding.")
    p.add_argument("--answers", metavar="PATH")
    p.add_argument("--defaults", action="store_true",
                   help="one-shot fresh install: --preset core --ship-root . --install-mode "
                        "<platform default>. Zero further flags; mutually exclusive with the "
                        "flags it sets.")
    p.add_argument("--preset", help="a preset name from presets.json (core / autonomous / ui)")
    p.add_argument("--modules", nargs="*", help="explicit module set (requires[] resolved transitively)")
    p.add_argument("--ship-root", help="ship_root for loop.config.json + {SHIP_DIR} substitution (default '.')")
    p.add_argument("--max-concurrent-crew", type=int, dest="max_crew")
    p.add_argument("--install-mode", choices=["symlink", "copy"], default=None)
    p.add_argument("--refresh-agents", action="store_true",
                   help="re-render EXISTING agent defs from the current manifests/ship-root "
                        "(the recovery for defs installed with a broken hook path). Default "
                        "behavior leaves existing defs untouched.")
    p.add_argument("--skills-target", metavar="DIR")
    p.add_argument("--agents-target", metavar="DIR")
    p.add_argument("--force-config", action="store_true")
    p.add_argument("--pref", action="append", metavar="KEY=VALUE", default=[])
    p.add_argument("--house-note", action="append", metavar="TEXT", default=[])
    p.add_argument("--force-prefs", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    if args.defaults:
        conflicts = [flag for flag, val in (
            ("--preset", args.preset), ("--modules", args.modules),
            ("--ship-root", args.ship_root), ("--install-mode", args.install_mode),
            ("--answers", args.answers),
        ) if val is not None]
        if conflicts:
            _err(f"--defaults is one-shot and mutually exclusive with {', '.join(conflicts)}. "
                 f"Drop --defaults to choose your own values.")
        args.preset = "core"
        args.ship_root = "."
        args.install_mode = DEFAULT_INSTALL_MODE
        print(f"--defaults chose: preset=core  ship-root=. (this shipkit clone)  "
              f"install-mode={DEFAULT_INSTALL_MODE} (platform default)")

    answers = _load_json(Path(args.answers)) if args.answers else {}
    if not isinstance(answers, dict):
        _err("answers file must be a JSON object.")
    preset = args.preset or answers.get("preset")
    modules = args.modules if args.modules is not None else answers.get("modules")
    if args.ship_root is not None:
        answers["ship_root"] = args.ship_root
    if args.max_crew is not None:
        answers["max_concurrent_crew"] = args.max_crew

    if args.pref:
        merged = dict(answers.get("prefs") or {})
        for item in args.pref:
            if "=" not in item:
                _err(f"--pref expects KEY=VALUE, got {item!r}")
            k, v = item.split("=", 1)
            k = k.strip()
            if k not in PREF_KEYS:
                _err(f"unknown pref key {k!r}. Known: {', '.join(sorted(PREF_KEYS))}.")
            merged[k] = v.strip()
        answers["prefs"] = merged
    if args.house_note:
        answers["house_notes"] = list(args.house_note)

    install_mode = args.install_mode or answers.get("install_mode") or DEFAULT_INSTALL_MODE
    skills_target = Path(args.skills_target).expanduser() if args.skills_target \
        else Path(answers.get("skills_target", DEFAULT_SKILLS_TARGET)).expanduser()
    agents_target = Path(args.agents_target).expanduser() if args.agents_target \
        else Path(answers.get("agents_target", DEFAULT_AGENTS_TARGET)).expanduser()

    module_list = resolve_modules(preset, modules)
    ship_root_raw = answers.get("ship_root", ".")
    if ship_root_raw == ".":
        ship_root_abs = str(SHIPKIT_ROOT)
    else:
        ship_root_abs = str(Path(ship_root_raw).expanduser())

    prefix = "[dry-run] " if args.dry_run else ""
    print(f"{prefix}shipkit init — preset={preset or 'custom'} modules={module_list} mode={install_mode}")
    print(f"{prefix}agents target: {agents_target}   skills target: {skills_target}")
    print(f"{prefix}ship_root (for {{SHIP_DIR}}): {ship_root_abs}")

    # LOAD-BEARING invariant: the hooks live in THIS repo (core/hooks/,
    # modules/*/hooks/), and the agent defs' hook command paths are built from
    # {SHIP_DIR} == ship_root. So ship_root MUST be this shipkit dir — that's the
    # sanctioned "one ship per machine, ship-root = the shipkit dir" topology. If
    # ship_root points elsewhere, every installed agent def gets a hook path that
    # DOESN'T EXIST → the hook-path assertion FAILs → the bright lines are disarmed
    # (fail-open). Warn loudly rather than let it fail silently. (The assertion
    # below still catches it, but a foreign operator should see WHY up front.)
    try:
        same = Path(ship_root_abs).resolve() == SHIPKIT_ROOT.resolve()
    except OSError:
        same = False
    if not same:
        print(f"{prefix}WARNING: ship_root ({ship_root_abs}) is NOT this shipkit dir "
              f"({SHIPKIT_ROOT}). The hooks live HERE; the installed agent defs' hook "
              f"command paths will point at ship_root and NOT resolve → the bright-line "
              f"hooks FAIL OPEN. Sanctioned topology is ship-root = the shipkit dir "
              f"(--ship-root . ). Only diverge if you know the hooks are mirrored under "
              f"ship_root; the hook-path assertion below will confirm.")
    print()

    # Resolve the hook interpreter at install time (Finding A). POSIX -> bare `bash`.
    # win32 -> an absolute Git-Bash path (FAILS LOUDLY if none — an unenforced install must
    # never be silent). Done up front so a Windows box with no Git-Bash aborts before writing.
    try:
        which = _where_bash() if sys.platform == "win32" else []
        hook_interpreter = resolve_hook_interpreter(sys.platform, os.environ, which)
    except HookInterpreterError as e:
        _err(str(e))

    # PREFLIGHT: the enforcement hooks parse stdin with jq — assert it's on PATH before
    # writing anything (runs in --dry-run too, so a jq-less box fails loudly there as well).
    assert_jq_present(module_list)

    cfg = build_config(answers)
    plan = []
    plan.append(f"== hook interpreter (resolved at install time): {hook_interpreter} ==")
    plan.append("== loop.config.json (machine config) ==")
    plan += [f"  {ln}" for ln in write_config(cfg, args.dry_run, args.force_config)]
    plan.append("== mate.local.md (behavioral prefs / taste) ==")
    plan += [f"  {ln}" for ln in write_prefs(answers, args.dry_run, args.force_prefs)]
    plan.append("== agents ({SHIP_DIR} substituted; hook interpreter resolved) ==")
    plan += [f"  {ln}" for ln in install_agents(module_list, agents_target, ship_root_abs,
                                                args.dry_run, hook_interpreter,
                                                refresh=args.refresh_agents)]
    plan.append("== hooks (+x — POSIX belt-and-suspenders; commands invoke via `bash`) ==")
    plan += [f"  {ln}" for ln in chmod_hooks(module_list, args.dry_run)]
    placeholder_ok = True
    hook_paths_ok = True
    if not args.dry_run:
        plan.append("== hook path assertion (a broken hook path = silent zero enforcement) ==")
        hp_lines, hook_paths_ok = assert_hook_paths(agents_target)
        plan += [f"  {ln}" for ln in hp_lines]
        plan.append("== placeholder verification (a leftover {SHIP_DIR} = enforcement silently OFF) ==")
        ph_lines, placeholder_ok = verify_no_unexpanded_placeholders(agents_target, module_list)
        plan += [f"  {ln}" for ln in ph_lines]
    plan.append("== lib/ (shared infra — unioned from module lib[] deps) ==")
    plan += [f"  {ln}" for ln in install_lib(module_list)]
    plan.append("== skills ==")
    plan += [f"  {ln}" for ln in install_skills(module_list, skills_target, install_mode, args.dry_run)]
    plan.append("== state/status.json ==")
    plan += [f"  {ln}" for ln in seed_state(args.dry_run)]
    plan.append("== prior-install state (REPORTED, not resolved — the SKILL judges) ==")
    plan += [f"  {ln}" for ln in detect_prior_state(module_list, skills_target)]

    for line in plan:
        print(f"{prefix}{line}")
    for line in smoke_test_lines(module_list, skills_target, agents_target):
        print(f"{prefix}{line}" if line else "")

    # CRITICAL gates: a leftover template token OR a hook path that doesn't resolve means
    # the bright lines are silently disarmed. FAIL LOUDLY (non-zero) so the install cannot
    # be trusted as green — a printed FAIL with exit 0 is exactly what a script or a
    # skimming agent misses. (Dry-run skips these — nothing is installed to verify.)
    if not placeholder_ok or not hook_paths_ok:
        print()
        if not placeholder_ok:
            print("ERROR: install FAILED placeholder verification — ENFORCEMENT WOULD BE SILENTLY OFF. "
                  "See the '== placeholder verification ==' section above.", file=sys.stderr)
        if not hook_paths_ok:
            print("ERROR: install FAILED the hook-path assertion — one or more installed agent defs "
                  "carry a hook command path (or interpreter) that does NOT resolve, so those "
                  "bright-line hooks FAIL OPEN with zero enforcement. Most common cause: --ship-root "
                  "is not this shipkit clone (sanctioned topology: --ship-root .). Fix the cause, "
                  "then re-run with --refresh-agents to re-render the affected defs.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
