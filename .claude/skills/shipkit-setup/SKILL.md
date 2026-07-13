---
name: shipkit-setup
description: >
  The conversational onboarding AND upgrade interview for shipkit's tiered, manifest-driven
  install. Invoke (`/shipkit-setup`) when standing Ship up on a machine for the first time,
  when progressing to a higher tier, or when upgrading an older (incl. pre-v2
  "Mate-runs-/loop") install. Fresh machines take the FAST PATH: three questions — the first
  asks INTENT (show me the ropes / the full ship / custom), and the tier (core / autonomous /
  a module set) falls out of the answer — two commands, one verify screen. The agent CONDUCTS
  the interview AND CARRIES THE UPGRADE JUDGMENT (see upgrade.md for diverged installs) —
  then calls the MINIMAL deterministic apply step (`shipkit_init.py`), which reads
  presets.json + each module.json, installs the selected tiers' files, substitutes
  {SHIP_DIR}, asserts hook paths (non-zero exit on any FAIL), and REPORTS prior-install
  state for the agent to act on. Conversational + judgment front; mechanical apply. Runs as
  needed, then yields.
---

# /shipkit-setup — onboarding + upgrade interview (tiered, manifest-driven)

You are conducting Ship bring-up or upgrade for the Captain. **You carry the judgment; the
script is mechanical.** The script (`shipkit_init.py`) only does safe deterministic ops —
install files, verify enforcement, and *report* what it finds.

## FAST PATH — fresh machine (most users; start here)

**Freshness check** (three commands; the first is authoritative when it exists):

```
cat state/install.json 2>/dev/null
ls ~/.claude/skills/ 2>/dev/null | grep -E 'ship|bosun'
ls ~/.claude/agents/ 2>/dev/null | grep ship
```

`state/install.json` is the semantic install record (preset + enabled modules) — present
means a current-generation install already ran here. All three empty → **fresh machine,
stay on this path.** Anything found → jump to "NOT FRESH?" below.

**Three questions** (one at a time; accept the default on a shrug):

1. **How do you want to start?** — ask INTENT, not architecture; the tier falls out of the
   answer. (A shrug = **(a)**.)
   - **(a) Show me the ropes** → installs the **core** tier (a request/response Mate +
     worker crew + safety hooks — no background autonomy) and, after the verify, hands
     you to **lesson 1 of `/ship-tour`** for a guided first watch. The right answer for
     nearly everyone: a tier bump later is a clean, pure delta (re-run at the higher
     preset; existing files untouched — tested).
   - **(b) The full ship — I'll find my way** → installs the **autonomous** tier
     (everything in core + the bg-Mate/Bosun heartbeat kernel). You get **the map**
     (below), not the tour — minimal narration.
   - **(c) Custom** → pick modules yourself. Jump to the full interview's item (a) and
     drive the apply step with `--modules` (prerequisites resolve transitively).
2. **Ship dir?** → **this clone IS your ship** (`--ship-root .`). The hooks live in this
   repo and the installed agent defs' hook paths point into it — any other ship-root
   breaks enforcement (the apply step will fail loudly if you try).
3. **Set taste now?** → default **no**. `mate.local.md` is generated with sane defaults
   and is hand-editable anytime; the full interview below exists for people who want it.

**Apply** (dry-run, show the plan, then real) — the command follows from question 1:

```
# (a) Show me the ropes — the core tier:
python3 shipkit_init.py --defaults --dry-run
python3 shipkit_init.py --defaults

# (b) The full ship — the autonomous tier:
python3 shipkit_init.py --preset autonomous --ship-root . --dry-run
python3 shipkit_init.py --preset autonomous --ship-root .

# (c) Custom — your module set (requires[] resolved transitively):
python3 shipkit_init.py --modules <name> ... --ship-root . --dry-run
```

(`--defaults` = `--preset core --ship-root . --install-mode <platform default>`. Chose
taste or a non-default install mode? Use the explicit flags — see "The apply step" below.)

**Verify** (one screen):

- The report's hook-path assertion + placeholder verification sections are all `ok` — no
  `FAIL` lines. (Any FAIL now exits non-zero; if it does, read its remediation, fix, re-run
  with `--refresh-agents`.)
- `grep -rl '{SHIP_DIR}' ~/.claude/agents/` prints **nothing** (adapt the path if you set a
  non-default `agents.install_target`).
- **RESTART the Claude Code session** — the agent-def registry is snapshotted at session
  start, so the session that ran the install can't see the defs it just wrote.

Done. Now hand off by intent:

## After the verify — the handoff (by question-1 answer)

**(a) Show me the ropes** → after the restart, the operator's next move is **lesson 1 of the
tour**: open Claude Code in the ship dir and say **`/ship-tour`**. Tell them this explicitly —
it's the single next action, and the tour (`.claude/skills/ship-tour/`) conducts the guided
first watch (boot the Mate, read state, one inbox item through the loop, wind down). Don't
walk the first watch here; the tour owns it.

**(b) The full ship** → print **the map** and get out of the way:

- **Boot**: restart, open Claude Code in the ship dir, run `/ship-watch-start` (the
  event-driven Mate boot: re-anchor → mate-lock → wake-monitor → bootstrap Bosun →
  preflight → idle). `tail state/bosun-heartbeat.log` to see the heartbeat.
- **Doctrine**: `core/mate.md` (the request/response base) + `modules/autonomous/mate-event-driven.md`
  (the event-driven overlay) + `modules/autonomous/bosun.md` (the heartbeat). Crew contract:
  `core/crew.md`.
- **State**: `queue.md` (Mate-owned), `captain.md` (your priorities), `inbox/captain.md`
  (your drop point), `logs/` (the handoff record), `state/` (reconciled mirrors).
- **Taste**: `mate.local.md` (hand-editable anytime). Machine config: `loop.config.json`.
- **Sandbox**: recommended for the bg agents — see "Sandbox guidance" below.
- The lessons exist if wanted, piecemeal, anytime: `/ship-tour` (each is self-contained).

**(c) Custom** → point at the docs of whichever modules they chose (each folder's
`module.json` names its `doc`), plus `/ship-tour` for the shared spine.

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

Shared infra lives in `lib/` (`status_writer.py`, `classify_input.py`, `status.schema.md`) and
is pulled in automatically by whichever modules declare it in their `module.json` `lib[]`.

## Full interview (optional depth — for users who want more than `--defaults`)

AskUserQuestion-style, one decision at a time; skip anything a prior answer settles.

- **(a) Preset / tier** — core / autonomous (or a custom `--modules` set — the picker: walk
  `modules/README.md` + each folder's `module.json` description; `requires[]` pulls
  prerequisites transitively). Core-first is the recommendation (bump later is a clean
  delta); autonomous when the user wants the full bg-Mate/Bosun Ship now.
- **(b) Ship-root** — the single ship-root for this machine: the shipkit clone, `.` (see the
  FAST PATH invariant). **One ship per machine** — a current limitation, not a virtue: agent
  defs install globally with a single baked ship path, so a second ship-root would fight
  over them. Never set up multiple.
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
  The same answer applies to `DECISIONS.local.md` (the ship's own dated incidents/rulings log,
  seeded from `DECISIONS.local.example.md`) — track or ignore the two together.

## The apply step (call the script once)

**Always `--dry-run` first**, show the plan, then run for real.

```
python3 shipkit_init.py \
  [--defaults]                             # fresh one-shot: core, ship-root=., platform mode \
  --preset <core|autonomous> \
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
   `<interpreter> <abs-path>` (single-quoted YAML scalar, forward slashes), with the interpreter
   **resolved at install time** — POSIX keeps a bare `bash`; Windows requires an absolute
   Git-Bash path and the install FAILS without one (the WSL-stub scar: `DECISIONS.md`).
   Enforcement works on POSIX AND Git-Bash without depending on the exec bit. Existing defs are
   left untouched unless `--refresh-agents`.
4. Sets +x on the selected hooks (POSIX belt-and-suspenders; commands invoke via `bash` so the
   exec bit is no longer load-bearing), then **asserts every installed agent-def hook command
   path resolves** and runs a **placeholder-verification pass**. **ANY `FAIL` in either — a
   broken hook path, a missing interpreter, or a leftover literal `{SHIP_DIR}` — exits
   non-zero**: an unenforced install must never be silent or exit green (history:
   `DECISIONS.md`). Fix the cause, re-run with `--refresh-agents`.
5. Verifies the unioned `lib/` deps are present (and preflights `jq`, which the hooks require).
6. Symlinks-or-copies the selected modules' skill dirs. (This setup skill itself is NOT
   installed to `~/.claude` — it lives project-level in the clone's `.claude/skills/`, so
   `/shipkit-setup` always resolves in the ship dir and can never go stale.)
7. Seeds `state/status.json` via `lib/status_writer.py --init`.
8. **Reports prior-install state** (orphans, copied-vs-symlinked, missing config keys, the
   recorded install state) — you act on these per [`upgrade.md`](upgrade.md); the script does not.
9. **Records the enabled set** in `state/install.json` (schema, preset, resolved modules,
   source commit) — after the gates pass, never on a failed install. Re-runs union
   additively; this record is what runtime integrations and upgrades consult.

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
- (upgrade) see [`upgrade.md`](upgrade.md) → "Upgrade verification".

**Sandbox guidance:** running the agent in a sandbox is recommended (defense-in-depth on top of
the hooks). On macOS, [agent-safehouse.dev](https://agent-safehouse.dev/) — point
`SHIP_SANDBOX_RUN` at its wrapper. Launch the bg Mate with
`modules/autonomous/scripts/ship-up.sh --check` then `--launch-mate`.

## Bounds
- Run as needed (onboarding / tier bump / upgrade). Not a per-tick skill.
- **One ship per machine** — never multiple ship-roots (agent defs are global; see (b) above).
- **You carry the upgrade judgment; the script stays mechanical.** Never push divergence-
  resolution into the script.
- The preset → module mapping lives in `presets.json` + each `module.json` — if they and this
  doc disagree, the manifests win (update this doc to match).
- Always `--dry-run` and show the plan first; never hand-edit
  `loop.config.json`/`mate.local.md`/`state/status.json` outside the apply step during onboarding
  (config-key MIGRATION during an upgrade is the one judgment-led exception — `upgrade.md` item 3).
