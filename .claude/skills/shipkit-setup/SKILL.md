---
name: shipkit-setup
description: >
  The conversational onboarding AND upgrade interview for shipkit's tiered, manifest-driven
  install (core / autonomous / ui). Invoke (`/shipkit-setup`) when standing Ship up on a
  machine for the first time, when progressing to a higher tier, or when upgrading an older
  (incl. pre-v2 "Mate-runs-/loop") install. Fresh machines take the FAST PATH: three
  questions, two commands, one verify screen. The agent CONDUCTS the interview AND CARRIES
  THE UPGRADE JUDGMENT (see upgrade.md for diverged installs) — then calls the MINIMAL
  deterministic apply step (`shipkit_init.py`), which reads presets.json + each module.json,
  installs the selected tiers' files, substitutes {SHIP_DIR}, asserts hook paths (non-zero
  exit on any FAIL), and REPORTS prior-install state for the agent to act on. Conversational
  + judgment front; mechanical apply. Runs as needed, then yields.
---

# /shipkit-setup — onboarding + upgrade interview (tiered, manifest-driven)

You are conducting Ship bring-up or upgrade for the Captain. **You carry the judgment; the
script is mechanical.** The script (`shipkit_init.py`) only does safe deterministic ops —
install files, verify enforcement, and *report* what it finds.

## FAST PATH — fresh machine (most users; start here)

**Freshness check** (two commands):

```
ls ~/.claude/skills/ 2>/dev/null | grep -E 'ship|bosun'
ls ~/.claude/agents/ 2>/dev/null | grep ship
```

Both empty → **fresh machine, stay on this path.** Anything found → jump to
"NOT FRESH?" below.

**Three questions** (one at a time; accept the default on a shrug):

1. **Tier?** → recommend **core** first. A tier bump later is a clean, pure delta
   (re-run at the higher preset; existing files untouched — tested). Recommend
   `autonomous` up front only when the user explicitly asks for the full autonomous
   Ship (bg Mate + Bosun) from day one.
2. **Ship dir?** → **this clone IS your ship** (`--ship-root .`). The hooks live in this
   repo and the installed agent defs' hook paths point into it — any other ship-root
   breaks enforcement (the apply step will fail loudly if you try). One ship per machine.
3. **Set taste now?** → default **no**. `mate.local.md` is generated with sane defaults
   and is hand-editable anytime; the full interview below exists for people who want it.

**Apply** (dry-run, show the plan, then real):

```
python3 shipkit_init.py --defaults --dry-run
python3 shipkit_init.py --defaults
```

(`--defaults` = `--preset core --ship-root . --install-mode <platform default>`. Chose a
different tier or taste? Use the explicit flags — see "The apply step" below.)

**Verify** (one screen):

- The report's hook-path assertion + placeholder verification sections are all `ok` — no
  `FAIL` lines. (Any FAIL now exits non-zero; if it does, read its remediation, fix, re-run
  with `--refresh-agents`.)
- `grep -rl '{SHIP_DIR}' ~/.claude/agents/` prints **nothing** (adapt the path if you set a
  non-default `agents.install_target`).
- **RESTART the Claude Code session** — the agent-def registry is snapshotted at session
  start, so the session that ran the install can't see the defs it just wrote.

Done. Go run "Your first watch" below.

## Your first watch (guided)

Post-install, walk the operator through ONE cycle so the ceremony is muscle memory before they
run solo. Event-driven model — there is **no `/loop`**; a watch opens, runs long, and winds down
on low context / a resting point.

1. **Boot the Mate.** Open Claude Code in the ship dir; say "you're First Mate." At the
   **autonomous** tier, run `/ship-watch-start` — it re-anchors, acquires the mate-lock, arms the
   wake-monitor, bootstraps the Bosun, preflights, then IDLES. At **core** tier there's no
   boot skill — the Mate just reads `core/mate.md` and runs request/response.
2. **Read the state.** Have the Mate re-anchor on the ship: `queue.md` (what's Ready / Active /
   Awaiting-Captain), `captain.md` (standing priorities), the latest mate log in `logs/mate/`.
   This is the "where are we" that every watch opens with (see `core/mate.md` → the role + the
   event-driven overlay `modules/autonomous/mate-event-driven.md`).
3. **Do ONE small thing.** Either dispatch a tiny crew watch (a lookout read-only check is the
   safest first dispatch — see `core/crew.md` for the dispatch contract) OR a housekeeping action
   (reconcile a queue entry, trim a stale Done item). Keep it bounded — the point is to feel the
   dispatch → log → reconcile loop once, not to do real work.
4. **Wind down.** Walk the wind-down ceremony (`core/mate.md` → wind-down): write the mate log
   (did / left-off / next-steps), reconcile `queue.md`, checkpoint anything you'd be sad to lose.
   A watch ENDS here — it does not loop back on its own; the next wake (a directive drop, a
   Captain turn) opens the next one.

Point the operator at the doc for each step rather than re-explaining it — the goal is to teach
them where the standing orders live, not to duplicate them here.

## NOT FRESH? (tier bump / older install)

- **Tier bump** (current-generation install, user wants more): re-run the apply step at the
  higher preset — it installs the delta and leaves existing files untouched. Verified clean:
  `python3 shipkit_init.py --preset autonomous --ship-root . --dry-run`, show, then real.
  Then the one-screen verify above — and act on any prior-install findings in the dry-run's
  report (a copied boot skill or an orphan can ride along on a current-gen machine; see
  upgrade.md for what each finding means). That's it.
- **Older / pre-v2 / hand-edited install** (a `ship-tick` skill, COPY-installed skills, agent
  defs with flat `scripts/...` hook paths, a v1 config): **read
  [`upgrade.md`](upgrade.md) BEFORE applying.** It carries the upgrade judgment — topology
  classification, the copied-skill and lingering-flat-hook footguns, config migration, and
  the clean-reinstall procedure. You carry that judgment; the script stays mechanical.

## The tiers (a preset = "install these module folders")

shipkit is organized as folders, each a self-contained module with a `module.json`. A preset
selects a set of folders; tiers are **start-at OR progress-through** (re-run with a higher
preset to install the delta). `presets.json` is the source of truth; this mirrors it.

| Tier | Preset | What it installs |
|---|---|---|
| **1 — core** | `core` | plain **request/response** Mate (`core/mate.md`) + the worker agents (ship-crew/lookout; ship-reviewer via the review-cycle depth module) + crew-safety hooks + this setup skill + the non-loop depth modules. **No loop, no Bosun, no UI.** (ship-pilot is the opt-in `pilot` module — `--modules pilot`, Chrome-MCP dep — not in any preset.) |
| **2 — autonomous** | `autonomous` | + the bg-Mate/Bosun heartbeat kernel: the two role agents (ship-mate, ship-bosun), `bosun.md`, the event-driven + bosun-loop doctrine, the mate/bosun hooks, mate-lock, bosun_emit, launchers, and the wake-monitor. |
| **3 — ui** | `ui` | + the status-surface PWA console. **Currently an empty slot** — its files ship on the stacked UI PR; the apply step says so loudly rather than silently installing nothing. |

Shared infra lives in `lib/` (`status_writer.py`, `classify_input.py`, `status.schema.md`) and
is pulled in automatically by whichever modules declare it in their `module.json` `lib[]`.

## Full interview (optional depth — for users who want more than `--defaults`)

AskUserQuestion-style, one decision at a time; skip anything a prior answer settles.

- **(a) Preset / tier** — core / autonomous / ui (or a custom `--modules` set). Core-first is
  the recommendation (bump later is a clean delta); autonomous when the user wants the full
  bg-Mate/Bosun Ship now.
- **(b) Ship-root** — the single ship-root for this machine: the shipkit clone, `.` (see the
  FAST PATH invariant). **One ship per machine** — never set up multiple ship-roots.
- **(c) Install method** — symlink (default macOS/Linux; `git pull` updates in place) vs copy
  (frozen snapshot; survives moving the repo but won't track upstream). Windows defaults to
  copy. (Agent defs are always *written* with `{SHIP_DIR}` substituted, never symlinked.)
- **(d) Behavioral prefs (taste)** → `mate.local.md`, from `core/mate.local.example.md`. Group
  into clusters (thresholds, model roster, review policy if `review-cycle` on, reporting,
  tools, repos/org, house notes); show defaults and let the Captain accept or set. Module-gated
  clusters appear only if that module is in the set.
- **(e) Track or ignore the overlay?** `mate.local.md` is gitignored by default — the shipkit
  convention is that the overlay is **operator-private** and `pull-upstream.sh` never touches
  it. But when **the ship directory itself IS the operator's durable record** (a personal ship
  the Captain version-controls, especially one where autonomous Mate rotations hand off through
  git), **tracking** the overlay is right — a fresh Mate rotation should inherit the accumulated
  house notes and dated decisions, and if the overlay is gitignored those are lost on rotation.
  Ask: *is this ship a version-controlled personal record whose rotations should inherit the
  overlay?* If yes, remove the `mate.local.md` line from `.gitignore` and commit the overlay
  (its house notes are ship history, not secrets — keep genuine secrets in a separate
  gitignored file / the OS keychain, never in the overlay either way). If no, leave it ignored.

## The apply step (call the script once)

**Always `--dry-run` first**, show the plan, then run for real.

```
python3 shipkit_init.py \
  [--defaults]                             # fresh one-shot: core, ship-root=., platform mode \
  --preset <core|autonomous|ui> \
  [--modules core autonomous ...]          # explicit set; requires[] resolved transitively \
  --ship-root <. | /abs/path>              # also the {SHIP_DIR} value for the agent defs \
  --install-mode <symlink|copy> \
  [--refresh-agents]                       # re-render EXISTING agent defs (broken-path recovery) \
  [--agents-target <dir>] [--skills-target <dir>]   # testing only \
  [--pref key=value ...] [--house-note "line" ...]
```

For the full taste block / repos / chat_surface, write a JSON answers file (shape at the top of
`shipkit_init.py`) and pass `--answers <path>` (taste under `"prefs"`, house notes under
`"house_notes"`). Any pref key you omit keeps the example default verbatim.

The apply step (mechanical, idempotent):
1. Writes `loop.config.json` from the example (gitignored; untouched unless `--force-config`).
2. Writes `mate.local.md` from `core/mate.local.example.md` (untouched unless `--force-prefs`).
3. Installs the selected tiers' agent defs, substituting `{SHIP_DIR}`. Hook commands render as
   `<interpreter> <abs-path>` as a **single-quoted YAML scalar** with **forward slashes**. The
   interpreter is **resolved at install time**: POSIX keeps a bare `bash`; Windows resolves an
   **absolute Git-Bash path** (a bare `bash` on Windows can resolve to WSL's `System32\bash.exe`
   stub, which can't see the Windows script path → silent fail-open) and FAILS the install if no
   Git-Bash is found. Enforcement works on POSIX AND Git-Bash without depending on the exec bit.
   Existing defs are left untouched unless `--refresh-agents`.
4. Sets +x on the selected hooks (POSIX belt-and-suspenders; commands invoke via `bash` so the
   exec bit is no longer load-bearing), then **asserts every installed agent-def hook command
   path resolves** and runs a **placeholder-verification pass**. **ANY `FAIL` in either — a
   broken hook path, a missing interpreter, or a leftover literal `{SHIP_DIR}` — exits
   non-zero** (the v1 footgun was a garbage hook path with enforcement silently OFF; an
   unenforced install must never be silent OR exit green). Fix the cause, re-run with
   `--refresh-agents`.
5. Verifies the unioned `lib/` deps are present (and preflights `jq`, which the hooks require).
6. Symlinks-or-copies the selected modules' skill dirs. (This setup skill itself is NOT
   installed to `~/.claude` — it lives project-level in the clone's `.claude/skills/`, so
   `/shipkit-setup` always resolves in the ship dir and can never go stale.)
7. Seeds `state/status.json` via `lib/status_writer.py --init`.
8. **Reports prior-install state** (orphans, copied-vs-symlinked, missing config keys) — you act
   on these per [`upgrade.md`](upgrade.md); the script does not.

## Acceptance details (beyond the one-screen verify)

> **RESTART the Claude session before the enforcement smoke.** Claude Code snapshots the
> agent-def registry AND their contents at session start — the install session holds the
> *pre-install* view, so an enforcement smoke run here validates **stale/cached defs**, not the
> ones you just wrote. **The tell:** dispatching a freshly-installed agent type (e.g.
> `ship-reviewer`) returns **"agent type not found"** while pre-existing types resolve → you're
> in a stale session. Quit and reopen Claude Code in the ship dir, THEN smoke.

- **(your stack) Expect to write `crew-allow-local.sh`.** The crew allow-list ships the common
  wrappers (devbox/bundle/npm/npx/rake/make/git-read); a foreign stack (`cargo`, `bun`, `go`,
  `pnpm`, …) is **blocked out of the box by design** — that's the intended per-deployment seam,
  not a bug. Copy `core/templates/crew-allow-local.sh` → `core/hooks/crew-allow-local.sh` and add
  the project's read/build commands to `check_allowed_local()`. Deny-precedence stays intact (the
  deny-list runs first; the local allow only widens, never overrides a block). This is normal
  bring-up work.
- **core tier:** the Mate reads `core/mate.md` and runs request/response; worker crew dispatch
  with the crew-safety hooks armed. No Bosun, no loop.
- **autonomous tier:** `/ship-watch-start` boots event-driven (re-anchor → mate-lock →
  wake-monitor → bootstrap Bosun → preflight → idle); it does **not** launch `/loop`. The Bosun
  is ticking (`tail state/bosun-heartbeat.log`). A directive wakes the Mate; a bookkeeping
  change does not.
- **ui tier:** the PWA renders `status.json` — once the UI files land (empty slot today).
- (upgrade) see [`upgrade.md`](upgrade.md) → "Upgrade verification".

**Sandbox guidance:** running the agent in a sandbox is recommended (defense-in-depth on top of
the hooks). On macOS, [agent-safehouse.dev](https://agent-safehouse.dev/) — point
`SHIP_SANDBOX_RUN` at its wrapper. Launch the bg Mate with
`modules/autonomous/scripts/ship-up.sh --check` then `--launch-mate`.

## Bounds
- Run as needed (onboarding / tier bump / upgrade). Not a per-tick skill.
- **One ship per machine** — never multiple ship-roots.
- **You carry the upgrade judgment; the script stays mechanical.** Never push divergence-
  resolution into the script.
- The preset → module mapping lives in `presets.json` + each `module.json` — if they and this
  doc disagree, the manifests win (update this doc to match).
- Always `--dry-run` and show the plan first; never hand-edit
  `loop.config.json`/`mate.local.md`/`state/status.json` outside the apply step during onboarding
  (config-key MIGRATION during an upgrade is the one judgment-led exception — `upgrade.md` item 3).
