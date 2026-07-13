# Lesson 5 — Staying current (three small guided moments)

*Living with upstream: pulling improvements, keeping local edits safe in the seams, and
adding modules — each its own small transition, none of them a re-setup.*

**The idea to land.** Your ship diverges from upstream shipkit **on purpose** — house
notes, taste, local allow rules, project state. The design promise is that upstream
improvements and your divergence never fight, because they live in different places:
**framework files sync; your files never do; and every local edit has a seam built for
it** that syncs can't touch. Staying current is therefore not an event to schedule
courage for — it's three small moments, each with its own entry point.

**Moment 1 — pull upstream.**

1. Your clone IS the ship, so the primary path is just `git pull` in the ship dir.
   `scripts/pull-upstream.sh` is the alternative when your ship's git history has gone
   its own way: it syncs the framework kernel file-by-file, enumerated from the module
   manifests. **Dry-run is its default** — run it bare, read the plan, then `--apply`.
   Either way, project state (`captain.md`, `queue.md`, `projects/`, `logs/`, `inbox/`,
   `state/`, `mate.local.md`, `loop.config.json`) is never synced. Yours stays yours.
2. **The one post-pull gotcha — teach it explicitly:** installed *agent defs* are
   rendered files (paths substituted at install time), so a pull that changes agent
   templates does NOT update `~/.claude/agents/` by itself. After a pull that touches
   `agents/` or hooks, re-render:
   `python3 shipkit_init.py --refresh-agents --preset <your tier> --ship-root .`
   (Skills symlink into the repo on macOS/Linux, so those track the pull automatically.)

**Moment 2 — keep your edits in the seams.** This is the habit that makes moment 1
boring, so check the operator's ship for it now:

- Taste, house notes, dated decisions → `mate.local.md` (the overlay), never edits to
  `core/mate.md`.
- Extra allowed crew commands (your stack's `cargo`, `kubectl`, ...) →
  `core/hooks/crew-allow-local.sh` (from the template in `core/templates/`), never edits
  to `validate-crew-bash.sh`.
- Your own knowledge docs (`docs/knowledge/...`) → not framework files; never synced,
  never in conflict.

An edit made directly to a synced framework file is a time bomb: the next sync silently
reverts it. If you find one on the operator's ship, re-home it into the right seam
together — that's this lesson's hands-on work.

**Moment 3 — add a module.** Same clean-delta property as the tier bump:

1. Browse `modules/README.md`; each folder's `module.json` says what it is and what it
   requires. (Example: `pilot` adds the browser-interaction crew type — it needs the
   Chrome MCP server, which is why it's opt-in.)
2. `python3 shipkit_init.py --modules <name> --ship-root . --dry-run` — prerequisites
   resolve transitively, existing files stay untouched. Read the plan, run it real,
   restart if it installed agent defs.

**The moment that is NOT small:** upgrading an old or hand-edited install (pre-v2
layouts, copied skills, stale hook paths). That's judgment work with real footguns —
send it to `/shipkit-setup`, whose `upgrade.md` carries the reasoning; `UPGRADING.md` is
the runnable runbook. Don't wing it from here.

**Point at:** `scripts/pull-upstream.sh --help`, `README.md` → "Customization" and
"Staying up to date", `.claude/skills/shipkit-setup/upgrade.md`.

**Next:** nothing — the tour ends here. The deep material is the standing orders
themselves: `core/mate.md`, `core/crew.md`, and each installed module's doc. The ship
teaches the rest by being sailed.
