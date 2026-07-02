---
name: shipkit-init
description: >
  The conversational onboarding AND upgrade interview for shipkit's tiered, manifest-driven
  install (core / autonomous / ui). Invoke (`/shipkit-init`) when standing Ship up on a
  machine for the first time, when progressing to a higher tier, or when upgrading an older
  (incl. pre-v2 "Mate-runs-/loop") install. The agent CONDUCTS the interview AND CARRIES THE
  UPGRADE JUDGMENT — it detects an existing install, reasons about how this instance has
  diverged, asks the user where unclear, cleans orphans, and migrates config — then calls the
  MINIMAL deterministic apply step (`shipkit_init.py`), which reads presets.json + each
  module.json, installs the selected tiers' files, substitutes {SHIP_DIR}, sets hook +x,
  asserts hook paths, and REPORTS prior-install state for the agent to act on. Conversational
  + judgment front; mechanical apply. Runs as needed, then yields.
---

# /shipkit-init — onboarding + upgrade interview (tiered, manifest-driven)

You are conducting Ship bring-up or upgrade for the Captain. **You carry the judgment; the
script is mechanical.** The script (`shipkit_init.py`) only does safe deterministic ops —
install files, set hook +x, write manifests-derived state, and *report* what it finds. It
**does not** auto-resolve how a particular machine has diverged. **That reasoning is your job
in this skill**, because ship instances diverge idiosyncratically and a script that guessed
would do the wrong thing silently.

## The tiers (a preset = "install these module folders")

shipkit is organized as folders, each a self-contained module with a `module.json`. A preset
selects a set of folders; tiers are **start-at OR progress-through** (re-run with a higher
preset to install the delta). `presets.json` is the source of truth; this mirrors it.

| Tier | Preset | What it installs |
|---|---|---|
| **1 — core** | `core` | plain **request/response** Mate (`core/mate.md`) + the worker agents (ship-crew/lookout/reviewer/pilot) + crew-safety hooks + the non-loop depth modules. **No loop, no Bosun, no UI.** |
| **2 — autonomous** | `autonomous` | + the bg-Mate/Bosun heartbeat kernel: the two role agents (ship-mate, ship-bosun), `bosun.md`, the event-driven + bosun-loop doctrine, the mate/bosun hooks, mate-lock, bosun_emit, launchers, and the wake-monitor. |
| **3 — ui** | `ui` | + the status-surface PWA console (the `ui/` tier; its files ship on the stacked UI PR). |

Shared infra lives in `lib/` (`status_writer.py`, `classify_input.py`, `status.schema.md`) and
is pulled in automatically by whichever modules declare it in their `module.json` `lib[]`.

## STEP 0 — Detect: is this a fresh machine, a tier bump, or an upgrade?

Before interviewing, **look at the machine.** Run the apply step in `--dry-run` once just to
get its REPORT (it prints a "prior-install state" section), and also inspect directly:

- `ls ~/.claude/skills/ | grep -E 'ship|bosun'` and `ls ~/.claude/agents/ | grep ship`
- For each installed skill/agent: **is it a symlink into this repo, a symlink elsewhere, or a
  COPY?** (`ls -l`). This is the load-bearing distinction — see the footgun below.
- `git log --oneline -1` in the ship dir vs the installed files' vintage.
- Read `loop.config.json` (if present) and compare its keys to `loop.config.example.json`.

Classify the machine:
- **Fresh** — no shipkit skills/agents installed. Straight onboarding; skip to STEP 1.
- **Tier bump** — current-generation install at a lower tier; the user wants more. Just re-run
  at the higher preset; the apply step installs the delta. Still do STEP 2 sanity checks.
- **Older / pre-v2 install** — the dangerous case. Do STEP 2 (reason about divergence) BEFORE
  installing.

## STEP 1 — Interview (fresh or tier-bump)

AskUserQuestion-style, one decision at a time; skip anything a prior answer settles.

- **(a) Preset / tier** — core / autonomous / ui (or a custom `--modules` set). Recommend
  **autonomous** for the full Ship experience; **core** for a plain request/response Mate.
- **(b) Ship-root** — the single ship-root for this machine (default: the shipkit dir, `.`).
  This is also the absolute path substituted for `{SHIP_DIR}` in the agent defs' hook commands.
  **One ship per machine** — never set up multiple ship-roots.
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

## STEP 2 — Reason about divergence (the judgment, for an older/diverged install)

**This is the part a script must not do for you.** Walk the machine's actual state and decide,
asking the user wherever it's unclear:

1. **The copied-skill footgun (call it out explicitly).** A *copied* old `ship-watch-start`
   keeps launching the OBSOLETE `/loop` body post-upgrade while everything else moved to
   event-driven — **and nothing errors.** If STEP 0 shows `ship-watch-start` (or `bosun-tick`)
   as a COPY, you MUST refresh it: remove the copy and re-install (or re-symlink) so the boot
   skill is the current event-driven one. If it's a symlink into this repo, `git pull` already
   refreshed it — fine.
2. **Orphan skills from the old model.** The pre-v2 shape installed a `ship-tick` skill (the
   old Mate-runs-the-loop body). It is NOT in any current module → the apply step reports it as
   an ORPHAN. **Remove it** (`rm -rf ~/.claude/skills/ship-tick`) so no one can `/ship-tick`
   into the dead loop. Confirm with the user before removing anything you're unsure about.
3. **`loop.config.json` key migration.** v2 added `agents` / `hooks` / `launch` / `github_org`
   blocks. The apply step REPORTS missing keys; it does NOT migrate them (all-or-nothing
   `--force-config` would clobber the user's machine values). **You** merge the missing keys:
   read the user's existing config, add the missing keys from `loop.config.example.json` with
   sensible values (ask for machine-specific ones), preserve everything they already set.
   The v2 hook paths are now tiered (`core/hooks/...`, `modules/autonomous/hooks/...`) — make
   sure a migrated config uses the new paths, not the old flat `scripts/...`.
4. **Stale prefs.** An old `mate.local.md` may carry a `loop_skill` key (e.g.
   `loop_skill: "/loop /ship-tick"`) — removed in v2 (the Mate doesn't run a loop). Harmless but
   wrong; clean it or note it.
5. **Stale agent defs.** If the machine somehow has old `ship-mate`/`ship-bosun` defs with flat
   `scripts/validate-*.sh` hook paths, those paths no longer exist (tiered now) → the hook
   FAILS OPEN. The apply step's hook-path assertion catches this; remove the stale def so the
   apply step rewrites it with the correct tiered path.

When the picture is genuinely ambiguous (e.g. a hand-edited install), **ask the user** rather
than guess. The lowest-risk move for a single machine is often a clean reinstall: remove
`~/.claude/skills/ship-* ~/.claude/skills/bosun-tick ~/.claude/agents/ship-*` then `/shipkit-init`
fresh — it sidesteps every divergence above. Offer it when divergence is deep.

## STEP 3 — Apply (call the script once)

**Always `--dry-run` first**, show the plan, then run for real.

```
python3 shipkit_init.py \
  --preset <core|autonomous|ui> \
  [--modules core autonomous ...]          # explicit set; requires[] resolved transitively \
  --ship-root <. | /abs/path>              # also the {SHIP_DIR} value for the agent defs \
  --install-mode <symlink|copy> \
  [--agents-target <dir>] [--skills-target <dir>]   # testing only \
  [--pref key=value ...] [--house-note "line" ...]
```

For the full taste block / repos / chat_surface, write a JSON answers file (shape at the top of
`shipkit_init.py`) and pass `--answers <path>` (taste under `"prefs"`, house notes under
`"house_notes"`). Any pref key you omit keeps the example default verbatim.

The apply step (mechanical, idempotent):
1. Writes `loop.config.json` from the example (untouched unless `--force-config`).
2. Writes `mate.local.md` from `core/mate.local.example.md` (untouched unless `--force-prefs`).
3. Installs the selected tiers' agent defs, substituting `{SHIP_DIR}`.
4. Sets +x on the selected hooks, then **asserts every installed agent-def hook command path
   resolves and is executable** (a broken hook path = silent zero enforcement). Read this
   section — any `FAIL` line is a disarmed bright line; fix it before relying on the install.
5. Verifies the unioned `lib/` deps are present.
6. Symlinks-or-copies the selected modules' skill dirs.
7. Seeds `state/status.json` via `lib/status_writer.py --init`.
8. **Reports prior-install state** (orphans, copied-vs-symlinked, missing config keys) — you act
   on these per STEP 2; the script does not.

## STEP 4 — Verify (the acceptance)

Relay the script's smoke test and confirm:
- The hook-path assertion is all `ok` (no `FAIL`).
- **core tier:** the Mate reads `core/mate.md` and runs request/response; worker crew dispatch
  with the crew-safety hooks armed. No Bosun, no loop.
- **autonomous tier:** `/ship-watch-start` boots event-driven (re-anchor → mate-lock →
  wake-monitor → bootstrap Bosun → preflight → idle); it does **not** launch `/loop`. The Bosun
  is ticking (`tail state/bosun-heartbeat.log`). A directive wakes the Mate; a bookkeeping
  change does not.
- **ui tier:** the PWA renders `status.json` (UI files ship on the stacked UI PR).
- (upgrade) the orphan `ship-tick` is gone; any copied boot skill was refreshed; the config has
  the new keys with the user's values preserved.

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
  (config-key MIGRATION during an upgrade is the one judgment-led exception — STEP 2.3).
