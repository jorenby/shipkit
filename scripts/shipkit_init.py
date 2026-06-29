#!/usr/bin/env python3
"""shipkit_init.py — the deterministic APPLY step for shipkit onboarding (v2).

This is the plumbing the `/shipkit-init` interview skill calls once it has gathered
answers. The conversational interview is the main experience; this script is the small,
idempotent, re-runnable apply step that wires the bits. v2 installs the TWO-AGENT
autonomous kernel — it does, all safe to repeat:

  1. Write loop.config.json from loop.config.example.json, populated with answers.
  2. Write mate.local.md from mate.local.example.md, populated with taste answers.
  3. Install the custom AGENT DEFS (agents/ship-*.md) into the agents target
     (default ~/.claude/agents), substituting {SHIP_DIR} in each def's hook command
     paths with the absolute ship_root. (v2: this is the heart of "The Way" — the two
     role agents + the worker agents — not "install the loop skills into core".)
  4. Set the EXECUTE BIT on every PreToolUse hook (chmod +x). LOAD-BEARING: a non-exec
     hook fails OPEN (silent zero enforcement).
  5. Symlink-or-copy the selected skills/ dirs into the skills target.
  6. Seed state/status.json (delegates to status_writer.py --init).
  7. Print the smoke-test steps.

Two overlays, two concerns: BEHAVIORAL prefs (taste) go in mate.local.md; MACHINE config
(paths, ports, agent/launcher/hook paths, watched repos) goes in loop.config.json.

Stdlib only — no pip installs. Cross-platform (pathlib + json + shutil). On Windows the
skill/agent install defaults to COPY (os.symlink needs admin/Developer Mode there), and a
failed symlink falls back to a copy.

Usage
-----
  shipkit_init.py --preset standard --ship-root /abs/path/to/ship --install-mode symlink
  shipkit_init.py --answers /tmp/answers.json
  shipkit_init.py --preset custom --modules core status-surface
  shipkit_init.py --preset standard --dry-run
  shipkit_init.py --preset full --skills-target /tmp/sk --agents-target /tmp/ag   # testing
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SHIPKIT_ROOT = SCRIPT_DIR.parent
DEFAULT_SKILLS_TARGET = Path.home() / ".claude" / "skills"
DEFAULT_AGENTS_TARGET = Path.home() / ".claude" / "agents"

IS_WINDOWS = os.name == "nt"
DEFAULT_INSTALL_MODE = "copy" if IS_WINDOWS else "symlink"

# The custom subagent defs shipkit installs. The two role agents (ship-mate, ship-bosun)
# are the autonomous shape; the rest are dispatched workers. Each def's frontmatter hook
# commands carry a {SHIP_DIR} token that this script substitutes with the absolute ship_root.
AGENT_DEFS = ["ship-mate", "ship-bosun", "ship-crew", "ship-lookout", "ship-reviewer", "ship-pilot"]

# The PreToolUse hooks whose execute bit MUST be set (a non-exec hook fails OPEN).
HOOKS = [
    "validate-mate-bash.sh", "validate-mate-mcp.sh", "validate-bosun-bash.sh",
    "validate-crew-bash.sh", "validate-readonly-bash.sh",
]

# PRESET -> MODULE mapping. THE single source of truth (the skill documents it).
# HONESTY: only "shipped" modules exist today. "planned" entries name the framework slot
# but ship NO code yet — the apply step skips them with a clear note.
MODULES = {
    "core": {
        "status": "shipped",
        "blurb": "the two-agent kernel: event-driven Mate (ship-watch-start) + heartbeat Bosun (bosun-tick), status writer, input classifier, wake-monitor, hooks (always on)",
        "skills": ["ship-watch-start", "bosun-tick", "shipkit-init"],
        "examples": [],
        "mandatory": True,
    },
    "status-surface": {
        "status": "shipped",
        "blurb": "reference browser PWA console that renders status.json + a steer box",
        "skills": [],
        "examples": ["status-surface"],
        "mandatory": False,
    },
    "pr-buddy": {
        "status": "planned",
        "blurb": "PR sensor that re-drops PR state (NOT YET IN SHIPKIT)",
        "skills": [], "examples": [], "mandatory": False,
    },
    "sentry-sweeps": {
        "status": "planned",
        "blurb": "error-tracker sweeps as a sensor (NOT YET IN SHIPKIT)",
        "skills": [], "examples": [], "mandatory": False,
    },
}

PRESETS = {
    "minimal": ["core"],
    "standard": ["core", "status-surface"],
    "full": ["core", "status-surface"],
}

PRESET_BLURBS = {
    "minimal": "the headless two-agent kernel — no UI",
    "standard": "core + the status-surface PWA so you can watch and steer in a browser",
    "full": "everything shipkit ships today (currently == standard; grows as modules land)",
    "custom": "pick your own module set",
}

# Behavioral-pref keys -> mate.local.md. Map 1:1 to the "your configured X" seams in core.
# (v2: no `loop_skill` — the Mate doesn't run a loop; the Bosun owns the heartbeat.)
PREF_KEYS = {
    "max_concurrent_crew": {"group": "thresholds", "primary": True},
    "model_default": {"group": "model_roster", "primary": True},
    "model_escalate": {"group": "model_roster", "primary": False},
    "model_lookout": {"group": "model_roster", "primary": False},
    "model_speed": {"group": "model_roster", "primary": False},
    "review_policy": {"group": "review", "primary": True},
    "review_model": {"group": "review", "primary": False},
    "review_standards": {"group": "review", "primary": False},
    "report_format": {"group": "reporting", "primary": True},
    "chat_surface": {"group": "reporting", "primary": True},
    "search_tool": {"group": "tools", "primary": True},
    "pr_review_cmd": {"group": "tools", "primary": True},
    "github_org": {"group": "repos_org", "primary": True},
    "pr_template": {"group": "repos_org", "primary": True},
}


def _err(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def resolve_modules(preset, modules):
    if modules:
        selected = list(modules)
    elif preset and preset != "custom":
        if preset not in PRESETS:
            _err(f"unknown preset {preset!r}. Known: {', '.join(PRESETS)} (or custom).")
        selected = list(PRESETS[preset])
    elif preset == "custom":
        _err("preset=custom requires --modules (or a 'modules' list in --answers).")
    else:
        _err("provide --preset or --modules (or an --answers file with one).")
    ordered = ["core"]
    for m in selected:
        if m not in MODULES:
            _err(f"unknown module {m!r}. Known: {', '.join(MODULES)}.")
        if m not in ordered:
            ordered.append(m)
    return ordered


def load_answers(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        _err(f"answers file not found: {path}")
    except json.JSONDecodeError as e:
        _err(f"answers file is not valid JSON: {e}")
    if not isinstance(data, dict):
        _err("answers file must be a JSON object.")
    return data


def build_config(answers: dict) -> dict:
    example_path = SHIPKIT_ROOT / "loop.config.example.json"
    try:
        example = json.loads(example_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        _err(f"template missing: {example_path}")
    except json.JSONDecodeError as e:
        _err(f"loop.config.example.json is not valid JSON: {e}")
    # Strip the example's underscore doc-keys; overlay answers.
    cfg = {k: v for k, v in example.items() if not k.startswith("_")}
    cfg["_comment"] = ("Generated by scripts/shipkit_init.py from loop.config.example.json. "
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


def render_prefs(prefs, house_notes):
    example_path = SHIPKIT_ROOT / "mate.local.example.md"
    try:
        text = example_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        _err(f"template missing: {example_path}")
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
        "Generated by `/shipkit-init` (scripts/shipkit_init.py) from "
        "`mate.local.example.md`.\nHand-edit anytime. The Mate reads", 1)
    if house_notes:
        note_block = "\n".join(f"- {n}" for n in house_notes) + "\n"
        marker = "- (example) Restart service X"
        idx = text.find(marker)
        text = (text[:idx] + note_block) if idx != -1 else text.rstrip("\n") + "\n\n" + note_block
    return text


def write_prefs(answers, dry_run, force_prefs):
    target = SHIPKIT_ROOT / "mate.local.md"
    prefs = build_prefs(answers)
    house_notes = answers.get("house_notes")
    if house_notes is not None and not isinstance(house_notes, list):
        _err("answers 'house_notes' must be a JSON list of strings.")
    supplied = ", ".join(sorted(prefs)) if prefs else "(none — all defaults)"
    if target.exists() and not force_prefs:
        return [f"mate.local.md exists — left untouched (pass --force-prefs). "
                f"Prefs that WOULD apply: {supplied}"]
    text = render_prefs(prefs, house_notes)
    if dry_run:
        return [f"would write mate.local.md ({len(prefs)} pref(s): {supplied})"]
    tmp = target.with_suffix(".md.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, target)
    return [f"wrote mate.local.md ({len(prefs)} pref(s) applied: {supplied})"]


def install_agents(agents_target: Path, ship_root_abs: str, mode: str, dry_run: bool):
    """Install agents/ship-*.md into agents_target, substituting {SHIP_DIR} in each def's
    hook command paths. Agent defs are single FILES (not dirs), and the {SHIP_DIR} token
    means a symlink would NOT get the substitution — so agents are always WRITTEN (copied
    with substitution), never symlinked."""
    lines = []
    src_root = SHIPKIT_ROOT / "agents"
    agents_target.mkdir(parents=True, exist_ok=True) if not dry_run else None
    for name in AGENT_DEFS:
        src = src_root / f"{name}.md"
        if not src.is_file():
            lines.append(f"{name}: source missing at {src} — skipped")
            continue
        dst = agents_target / f"{name}.md"
        content = src.read_text(encoding="utf-8").replace("{SHIP_DIR}", ship_root_abs)
        if dst.exists():
            lines.append(f"{name}.md: exists at {dst} — left untouched (re-run with the file removed to refresh)")
            continue
        if dry_run:
            lines.append(f"{name}.md: would install -> {dst} ({{SHIP_DIR}} -> {ship_root_abs})")
            continue
        dst.write_text(content, encoding="utf-8")
        lines.append(f"{name}.md: installed -> {dst} ({{SHIP_DIR}} substituted)")
    return lines


def chmod_hooks(dry_run: bool):
    """Set the execute bit on every PreToolUse hook. A non-exec hook fails OPEN."""
    lines = []
    for h in HOOKS:
        f = SCRIPT_DIR / h
        if not f.is_file():
            lines.append(f"{h}: MISSING at {f}")
            continue
        is_exec = os.access(f, os.X_OK)
        if is_exec:
            lines.append(f"{h}: already +x")
            continue
        if dry_run:
            lines.append(f"{h}: would chmod +x (currently non-exec — fails OPEN!)")
            continue
        mode = f.stat().st_mode
        f.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        lines.append(f"{h}: chmod +x (was non-exec — fixed; a non-exec hook fails OPEN)")
    return lines


def _install_one(src: Path, dst: Path, mode: str, dry_run: bool) -> str:
    label = dst.name
    if dst.exists() or dst.is_symlink():
        if dst.is_symlink():
            try:
                if dst.resolve() == src.resolve():
                    return f"{label}: already linked (no-op)"
            except OSError:
                return f"{label}: existing symlink is broken — leaving it"
            return f"{label}: a symlink already exists pointing elsewhere — left untouched"
        return f"{label}: target already exists (not a symlink) — left untouched"
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
    src_root = SHIPKIT_ROOT / "skills"
    for m in module_list:
        meta = MODULES[m]
        if meta["status"] != "shipped":
            for s in meta["skills"]:
                lines.append(f"{m}/{s}: PLANNED module — no code ships yet, skipped")
            continue
        for skill in meta["skills"]:
            src = src_root / skill
            if not src.is_dir():
                lines.append(f"{skill}: source dir missing at {src} — skipped")
                continue
            lines.append(_install_one(src, skills_target / skill, mode, dry_run))
    if not lines:
        lines.append("(no skill dirs to install for the selected modules)")
    return lines


def report_examples(module_list, dry_run):
    lines = []
    for m in module_list:
        meta = MODULES[m]
        if meta["status"] != "shipped":
            continue
        for ex in meta["examples"]:
            ex_dir = SHIPKIT_ROOT / "examples" / ex
            if ex_dir.is_dir():
                lines.append(f"{m}: reference UI at examples/{ex}/ (run per examples/{ex}/README.md)")
            else:
                lines.append(f"{m}: expected examples/{ex}/ missing — skipped")
    return lines


def seed_state(dry_run):
    status_path = SHIPKIT_ROOT / "state" / "status.json"
    writer = SCRIPT_DIR / "status_writer.py"
    if status_path.exists():
        try:
            doc = json.loads(status_path.read_text(encoding="utf-8"))
            if doc.get("generated_at"):
                return ["state/status.json already seeded (has generated_at) — no-op"]
        except (json.JSONDecodeError, OSError):
            pass
    if dry_run:
        return ["would seed state/status.json via status_writer.py --init"]
    if not writer.exists():
        _err(f"status_writer.py not found at {writer}")
    res = subprocess.run([sys.executable, str(writer), "--init", "--force"],
                         capture_output=True, text=True)
    if res.returncode != 0:
        _err(f"status_writer.py --init failed: {res.stderr.strip() or res.stdout.strip()}")
    return [f"seeded state/status.json ({res.stdout.strip()})"]


def smoke_test_lines(module_list, skills_target, agents_target):
    has_surface = "status-surface" in module_list
    lines = [
        "",
        "Smoke test (the acceptance):",
        "  1. Open Claude Code in the shipkit dir; say \"you're First Mate\".",
        "  2. Run /ship-watch-start — it boots event-driven: re-anchors, acquires the",
        "     mate-lock, arms the wake-monitor, BOOTSTRAPS THE BOSUN (launch-bosun.sh",
        "     --ensure), preflights, then IDLES. (It does NOT launch /loop.)",
        "  3. Confirm the Bosun is ticking: tail state/bosun-heartbeat.log (fresh line).",
        "  4. Drop a directive (inbox/captain.md edit or inbox/drops/) -> the Mate WAKES.",
        "  5. Flip a bookkeeping item -> NO wake; it reconciles at the next wake.",
    ]
    if has_surface:
        lines += [
            "  6. (status-surface) cd examples/status-surface && start its server,",
            "     open it in a browser, confirm it renders state/status.json.",
        ]
    lines += [
        "",
        f"Agent defs installed under: {agents_target}  (the two role agents +",
        "  the worker agents; {SHIP_DIR} substituted to your absolute ship_root).",
        f"Skills installed under:     {skills_target}",
        "Running the agent in a SANDBOX is recommended (defense-in-depth on top of the",
        "  bright-line hooks). On macOS, agent-safehouse.dev is a good option; point",
        "  SHIP_SANDBOX_RUN at its wrapper. Bare 'claude' is the no-sandbox fallback.",
        "Launch the bg Mate with: scripts/ship-up.sh --check  (then --launch-mate).",
        "Re-run shipkit_init.py any time — idempotent; --force-prefs / --force-config to refresh.",
    ]
    return lines


def main():
    p = argparse.ArgumentParser(prog="shipkit_init.py",
                                description="Deterministic apply step for shipkit onboarding (v2 two-agent kernel).")
    p.add_argument("--answers", metavar="PATH")
    p.add_argument("--preset", choices=["minimal", "standard", "full", "custom"])
    p.add_argument("--modules", nargs="*")
    p.add_argument("--ship-root", help="ship_root for loop.config.json + {SHIP_DIR} substitution (default '.')")
    p.add_argument("--max-concurrent-crew", type=int, dest="max_crew")
    p.add_argument("--install-mode", choices=["symlink", "copy"], default=None)
    p.add_argument("--skills-target", metavar="DIR")
    p.add_argument("--agents-target", metavar="DIR")
    p.add_argument("--force-config", action="store_true")
    p.add_argument("--pref", action="append", metavar="KEY=VALUE", default=[])
    p.add_argument("--house-note", action="append", metavar="TEXT", default=[])
    p.add_argument("--force-prefs", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    answers = load_answers(Path(args.answers)) if args.answers else {}
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
                _err(f"unknown pref key {k!r}. Known: {', '.join(PREF_KEYS)}.")
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
    # {SHIP_DIR} substitution uses the ABSOLUTE ship_root (hook paths must be absolute).
    ship_root_raw = answers.get("ship_root", ".")
    ship_root_abs = str(Path(ship_root_raw).expanduser().resolve()) if ship_root_raw == "." \
        else str(Path(ship_root_raw).expanduser())
    if ship_root_raw == ".":
        ship_root_abs = str(SHIPKIT_ROOT)

    prefix = "[dry-run] " if args.dry_run else ""
    print(f"{prefix}shipkit init (v2) — preset={preset or 'custom'} modules={module_list} mode={install_mode}")
    print(f"{prefix}agents target: {agents_target}   skills target: {skills_target}")
    print(f"{prefix}ship_root (for {{SHIP_DIR}}): {ship_root_abs}")
    print()

    planned = [m for m in module_list if MODULES[m]["status"] != "shipped"]
    if planned:
        print(f"NOTE: PLANNED modules (no code yet), will be skipped: {', '.join(planned)}\n")

    cfg = build_config(answers)
    plan = []
    plan.append("== loop.config.json (machine config) ==")
    plan += [f"  {ln}" for ln in write_config(cfg, args.dry_run, args.force_config)]
    plan.append("== mate.local.md (behavioral prefs / taste) ==")
    plan += [f"  {ln}" for ln in write_prefs(answers, args.dry_run, args.force_prefs)]
    plan.append("== agents (the two-agent kernel + workers; {SHIP_DIR} substituted) ==")
    plan += [f"  {ln}" for ln in install_agents(agents_target, ship_root_abs, install_mode, args.dry_run)]
    plan.append("== hooks (+x — a non-exec hook fails OPEN) ==")
    plan += [f"  {ln}" for ln in chmod_hooks(args.dry_run)]
    plan.append("== skills ==")
    plan += [f"  {ln}" for ln in install_skills(module_list, skills_target, install_mode, args.dry_run)]
    ex_lines = report_examples(module_list, args.dry_run)
    if ex_lines:
        plan.append("== examples (reference UIs, run in-place) ==")
        plan += [f"  {ln}" for ln in ex_lines]
    plan.append("== state/status.json ==")
    plan += [f"  {ln}" for ln in seed_state(args.dry_run)]

    for line in plan:
        print(f"{prefix}{line}")
    for line in smoke_test_lines(module_list, skills_target, agents_target):
        print(f"{prefix}{line}" if line else "")


if __name__ == "__main__":
    main()
