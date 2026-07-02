---
name: shipkit-setup
description: >
  The conversational onboarding AND upgrade interview for shipkit's tiered, manifest-driven
  install (core / autonomous / ui). Invoke (`/shipkit-setup`) when standing Ship up on a
  machine for the first time, when progressing to a higher tier, or when upgrading an older
  (incl. pre-v2 "Mate-runs-/loop") install. The agent CONDUCTS the interview AND CARRIES THE
  UPGRADE JUDGMENT — it detects an existing install, reasons about how this instance has
  diverged, asks the user where unclear, cleans orphans, and migrates config — then calls the
  MINIMAL deterministic apply step (`shipkit_init.py`), which reads presets.json + each
  module.json, installs the selected tiers' files, substitutes {SHIP_DIR}, sets hook +x,
  asserts hook paths, and REPORTS prior-install state for the agent to act on. Conversational
  + judgment front; mechanical apply. Runs as needed, then yields.
---

# /shipkit-setup — onboarding + upgrade interview (tiered, manifest-driven)

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

**For an older install, also classify the UPGRADE TOPOLOGY — it changes everything below:**

- **(A) In-place git pull** — the operator's ship dir IS a shipkit clone, and they advance it by
  fetching upstream. If v1 and v2 share linear history this is a fast-forward; if they diverged
  (the usual case — v2 restructured flat→folders), a merge surfaces rename/edit CONFLICTS on any
  file the operator edited (e.g. `mate.md`, `scripts/validate-crew-bash.sh`). The new folder
  files (`core/`, `modules/*/`, `lib/`) arrive via git; the operator's OLD flat files may linger
  as untracked cruft alongside them. See STEP 2.6.
- **(B) Fresh clone, carry values across** — the operator clones v2 shipkit fresh into a new dir
  and wants their v1 machine values (config, prefs, house notes, local hook edits) brought over.
  **The apply step's config-key report is USELESS here** — a fresh v2 clone already has a full
  `loop.config.json` with every key (placeholder values), so nothing shows as "missing," yet the
  operator's real v1 values are NOT carried. YOU must diff the old ship dir's config/prefs/hooks
  against the fresh clone and port the machine-specific values by hand (STEP 2.3, 2.6).

**Note the config-check limitation explicitly:** `detect_prior_state` reads
`loop.config.json` *in the shipkit repo you are running from*, not in some other old ship dir.
It catches missing keys only in topology (A) where that file IS the operator's evolving config.
In topology (B) you must point at the OLD dir yourself: read `<old-ship>/loop.config.json` and
diff its non-`_` keys against `loop.config.example.json`.

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
   **Topology caveat (from STEP 0):** the apply step's "missing keys" report only fires in
   topology (A) where the shipkit repo's own `loop.config.json` IS the operator's evolving
   config. In topology (B) (fresh v2 clone), that file already has every key with placeholder
   values, so NOTHING reports as missing — but the operator's real machine values (repos,
   github_org, chat_surface, headroom path, hosts_ports) are NOT carried. Read the OLD dir's
   `loop.config.json` yourself and port those values into the fresh clone's config by hand.
4. **Stale prefs.** An old `mate.local.md` may carry a `loop_skill` key (e.g.
   `loop_skill: "/loop /ship-tick"`) — removed in v2 (the Mate doesn't run a loop). Harmless but
   wrong; clean it or note it.
5. **Stale agent defs — and the sharper "lingering flat hook" trap.** An old `ship-crew` /
   `ship-mate` / `ship-bosun` def carries a hook command path baked at v1 install time, e.g.
   `.../scripts/validate-crew-bash.sh` (flat). Two sub-cases, and the second is the dangerous one:
   - **(a) The old flat hook file is GONE** (v2 moved it to `core/hooks/`). The baked path no
     longer resolves → the apply step's hook-path assertion prints `FAIL ... NOT FOUND` → the
     hook FAILS OPEN. Loud; easy to catch. Remove the stale def so the apply step rewrites it
     with the correct tiered path.
   - **(b) The old flat hook file STILL EXISTS** (topology A: `git pull` added `core/hooks/...`
     but left the operator's old `scripts/validate-crew-bash.sh` lingering). Now the stale def's
     baked flat path STILL RESOLVES and is executable → **the hook-path assertion prints `ok`**
     → but it is enforcing the OLD v1 rules (including any operator edits made to the flat hook),
     NOT the current v2 hook. The assertion checks existence + executability, NOT vintage, so a
     green assertion does NOT prove the current hook is wired. **You** must catch this: if STEP 0
     shows any agent def whose hook path points at a flat `scripts/...` location, remove the def
     (apply rewrites it to `core/hooks/...`) AND delete the lingering flat hook file so nothing
     can source it. Verify the rewritten def's path lands under `core/hooks/` /
     `modules/*/hooks/`, not `scripts/`.
6. **Flat→folder relocation of operator-EDITED framework files (the core divergence job).** v2
   moved `mate.md`→`core/mate.md`, `crew.md`→`core/crew.md`, `scripts/validate-*.sh`→
   `core/hooks/`, `scripts/{status_writer,classify_input}.py`→`lib/`, and `modules/*.md`→
   `modules/*/` folders. If the operator EDITED any of these in place (a customized standing
   order in `mate.md`, a local allow rule added directly into `validate-crew-bash.sh`), the edit
   lives in the OLD flat location and the NEW file is the pristine upstream version — the
   operator's change is silently lost unless you carry it. Walk it:
   - **Diff old-flat vs new-folder** for every framework file the operator might have touched
     (`diff <old>/mate.md <new>/core/mate.md`, etc.). Anything non-trivial that isn't just the
     v2 rewrite = an operator edit to reconcile.
   - **Re-home edits, don't copy files.** A customized `mate.md` standing order belongs in the v2
     overlay `mate.local.md` (house notes / dated decisions), NOT pasted back into `core/mate.md`
     (which `pull-upstream.sh` will overwrite on the next sync). A local hook allow rule belongs
     in `core/hooks/crew-allow-local.sh` (from `core/templates/crew-allow-local.sh`), NOT edited
     into `core/hooks/validate-crew-bash.sh` (synced from upstream — your edit is lost). This is
     the whole point of the v2 overlay/`*-allow-local.sh` seams: they survive upstream pulls.
   - **A local-only doc** the operator added (e.g. `docs/knowledge/env-config.md`) is not a
     framework file → it's never synced and never conflicts → leave it exactly where it is.
   - **Delete the leftover flat files** once their content is re-homed, so nothing reads the dead
     copy (see 5b — a lingering flat hook is actively dangerous).

When the picture is genuinely ambiguous (e.g. a hand-edited install), **ask the user** rather
than guess. **The lowest-risk move for a single machine is almost always a clean reinstall** —
and for a diverged flat→folder (pre-v2) install it is the RECOMMENDED path, because v1↔v2 do not
fast-forward and an in-place merge produces rename conflicts on every edited file. Procedure:
1. Capture the operator's divergence first (STEP 2.6 diffs) — you re-home these AFTER.
2. Point the ship dir at v2 shipkit cleanly: either `git fetch && git checkout loop-mode-v2`
   into the same dir (accept the new folder layout; delete leftover flat files), or clone v2
   fresh and move the operator's project state (`captain.md`, `queue.md`, `projects/`, `logs/`,
   `inbox/`, `state/`) across — these are never framework files.
3. Remove installed skills/agents: `rm -rf ~/.claude/skills/ship-* ~/.claude/skills/bosun-tick`
   `~/.claude/skills/shipkit-setup ~/.claude/agents/ship-*` (this clears the orphan `ship-tick`,
   the copied `ship-watch-start`, and every stale flat-hook agent def in one move).
4. `/shipkit-setup` fresh at the target preset — it sidesteps every divergence above.
5. Re-home the captured edits into the v2 seams (overlay / `*-allow-local.sh`), never back into
   the synced framework files.

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
3. Installs the selected tiers' agent defs, substituting `{SHIP_DIR}`. Hook commands render as
   `<interpreter> <abs-path>` as a **single-quoted YAML scalar** with **forward slashes**. The
   interpreter is **resolved at install time**: POSIX keeps a bare `bash`; Windows resolves an
   **absolute Git-Bash path** (a bare `bash` on Windows can resolve to WSL's `System32\bash.exe`
   stub, which can't see the Windows script path → silent fail-open) and FAILS the install if no
   Git-Bash is found. Enforcement works on POSIX AND Git-Bash without depending on the exec bit.
4. Sets +x on the selected hooks (POSIX belt-and-suspenders; commands invoke via `bash` so the
   exec bit is no longer load-bearing), then **asserts every installed agent-def hook command
   path resolves** (a broken hook path = silent zero enforcement; on Windows it also asserts the
   resolved interpreter path exists), and runs a **placeholder-verification pass that FAILS LOUDLY
   (non-zero exit) if any installed agent def still carries a literal `{SHIP_DIR}` OR a rendered
   interpreter path that doesn't exist** — the v1 footgun where the substitution/resolution never
   landed and enforcement was silently OFF. Read both sections — any `FAIL` line is a disarmed
   bright line; fix it (remove the stale def and re-run; on Windows, install Git-Bash) before
   relying on the install.
5. Verifies the unioned `lib/` deps are present.
6. Symlinks-or-copies the selected modules' skill dirs.
7. Seeds `state/status.json` via `lib/status_writer.py --init`.
8. **Reports prior-install state** (orphans, copied-vs-symlinked, missing config keys) — you act
   on these per STEP 2; the script does not.

## STEP 4 — Verify (the acceptance)

> **RESTART the Claude session before the enforcement smoke.** Claude Code snapshots the
> agent-def registry AND their contents at session start — the install session holds the
> *pre-install* view, so an enforcement smoke run here validates **stale/cached defs**, not the
> ones you just wrote. **The tell:** dispatching a freshly-installed agent type (e.g.
> `ship-reviewer`) returns **"agent type not found"** while pre-existing types resolve → you're
> in a stale session. Quit and reopen Claude Code in the ship dir, THEN smoke.

Relay the script's smoke test and confirm:
- The hook-path assertion AND the placeholder-verification pass are all `ok` (no `FAIL`). Then
  spot-check by hand: `grep -rl '{SHIP_DIR}' ~/.claude/agents/` (adapt to `agents.install_target`)
  **MUST print nothing** — a hit = a garbage hook path = enforcement silently OFF; remove the stale
  def and re-run the apply step.
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
