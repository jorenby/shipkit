#!/usr/bin/env python3
"""Enumerate the shipkit FRAMEWORK files to sync from upstream, derived from the manifests so
the list can't go stale as the tiered layout grows. Prints one ship-root-relative path per
line for pull-upstream.sh to consume (mapfile).

Sources:
  - presets.json + every module's module.json -> each module's agents/hooks/scripts/lib/
    templates/role_docs/doc/prefs_example/tests, plus the module.json itself.
  - the installer + manifest at root (shipkit_init.py, presets.json).
  - the top-level generic docs (README.md, CLAUDE.md) + the sync tooling.

NEVER synced (project-specific / machine state): captain.md, queue.md, inbox/, logs/,
projects/, state/, loop.config.json, mate.local.md. The .example variants ARE generic and ARE
synced.

Usage: _sync_manifest.py <upstream-dir>   (defaults to this script's ship root)
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SHIP_ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else HERE.parent

ROOT_FILES = [
    "README.md", "CLAUDE.md",
    "shipkit_init.py", "presets.json",
    "loop.config.example.json", "mate.local.example.md",
    "scripts/pull-upstream.sh", "scripts/_sync_manifest.py",
]

# Per-module manifest keys whose values are folder-relative file paths to sync.
FILE_KEYS = ("agents", "hooks", "scripts", "templates", "tests", "role_docs")


def module_dirs():
    """Every module folder = core/, ui/, and each modules/<name>/ that has a module.json."""
    dirs = []
    for special in ("core", "ui"):
        d = SHIP_ROOT / special
        if (d / "module.json").is_file():
            dirs.append(d)
    modules = SHIP_ROOT / "modules"
    if modules.is_dir():
        for d in sorted(modules.iterdir()):
            if (d / "module.json").is_file():
                dirs.append(d)
    return dirs


def rel(p: Path) -> str:
    return str(p.relative_to(SHIP_ROOT))


def main():
    out = []

    def add(path: Path):
        if path.is_file():
            r = rel(path)
            if r not in out:
                out.append(r)

    for f in ROOT_FILES:
        add(SHIP_ROOT / f)

    # modules/README.md catalog (generic)
    add(SHIP_ROOT / "modules" / "README.md")

    for d in module_dirs():
        manifest = d / "module.json"
        add(manifest)
        try:
            meta = json.loads(manifest.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        for key in FILE_KEYS:
            for relpath in meta.get(key, []):
                # skill dirs are folders, not files -> expand to their files
                target = d / relpath
                if target.is_dir():
                    for child in sorted(target.rglob("*")):
                        add(child)
                else:
                    add(target)
        for single in ("doc", "prefs_example"):
            if meta.get(single):
                add(d / meta[single])
        # skill folders are listed under "skills" as dir paths
        for relpath in meta.get("skills", []):
            sk = d / relpath
            if sk.is_dir():
                for child in sorted(sk.rglob("*")):
                    add(child)
        # the declared lib[] deps live in lib/ at root
        for libfile in meta.get("lib", []):
            add(SHIP_ROOT / "lib" / libfile)

    for line in out:
        print(line)


if __name__ == "__main__":
    main()
