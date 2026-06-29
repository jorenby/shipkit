---
name: shipkit-init
description: >
  The conversational onboarding interview for shipkit's two-agent autonomous kernel.
  Invoke once (`/shipkit-init`) when standing Ship up on a machine for the first time, or
  when adding modules. The agent CONDUCTS a short interview — preset, modules, ship-root,
  install method, watched repos, and the behavioral preferences (taste) that populate
  mate.local.md — using AskUserQuestion-style prompts, then calls the deterministic apply
  step (`scripts/shipkit_init.py`) which installs the agent defs (substituting {SHIP_DIR}),
  sets the +x bit on the hooks, installs the skills, seeds state, and prints the smoke
  test. Conversational front, deterministic apply. Runs ONCE and yields.
---

# /shipkit-init — onboarding interview for the two-agent kernel

You are conducting Ship bring-up for the Captain. This skill is the **main onboarding
experience**: you run a short conversational interview, then hand the answers to the
idempotent apply script. The script is plumbing — your job is the *interview*.

**What you're standing up:** Ship's autonomous shape is a **two-agent split** — a
**Bosun** that owns the heartbeat (periodic curate/reconcile sweeps) and an
**event-driven Mate** that boots, idles, and acts on wakes. The apply step installs both
agent defs (+ the worker agents), sets the execute bit on the bright-line hooks, installs
the skills, and seeds state.

**Install model:** **one ship per machine.** Don't ask about multiple ship-roots.

**The deal:** you ask (AskUserQuestion-style), the Captain answers, you call
`python3 scripts/shipkit_init.py` once, then print the smoke test. Idempotent — a second
run (e.g. adding a module later) is safe.

## What ships today (be honest in the interview)

The preset → module mapping is defined ONCE in `scripts/shipkit_init.py` (`PRESETS` +
`MODULES`) — that file is the source of truth; this mirrors it. **Only `core` and
`status-surface` exist as code today.** Other names are *framework slots* — they ship NO
code yet; the apply step skips planned modules with a clear note.

| Module | Status | What it is |
|---|---|---|
| `core` | **shipped** (always on) | the two-agent kernel: event-driven Mate (`ship-watch-start`) + heartbeat Bosun (`bosun-tick`), the status writer, input classifier, wake-monitor, mate-lock, launchers, and the bright-line hooks |
| `status-surface` | **shipped** | reference browser PWA console that renders `status.json` + a steer box (`examples/status-surface/`) |
| `pr-buddy` | *planned* | PR sensor — NOT YET IN SHIPKIT |
| `sentry-sweeps` | *planned* | error-tracker sweeps as a sensor — NOT YET IN SHIPKIT |

**Presets:** **minimal** (`core` — headless two-agent kernel) · **standard** (`core` +
`status-surface`, the recommended default) · **full** (everything today == standard) ·
**custom** (pick your own set).

## The interview (ask in this order)

Use AskUserQuestion-style prompts — one decision at a time. Adapt: skip a question a prior
answer settles.

### (a) Preset
Offer minimal / standard / full / custom. Recommend **standard** for a first install.

### (b) Modules
If **custom**, present the toggle list (`core` is mandatory). Otherwise show the preset's
set and let them adjust. Mark *planned* modules as not-yet-shipped.

### (c) Ship-root
Confirm the single ship-root for this machine. **Default: the shipkit dir / current working
directory** (`.`). This is where `queue.md`, `captain.md`, `projects/`, `logs/`, `state/`
live AND the absolute path the apply step substitutes for `{SHIP_DIR}` in the agent defs'
hook command paths (so the hooks resolve correctly). Capture the absolute path if the
Captain launches from elsewhere.

### (d) Install method
Ask **symlink vs copy** for the skill dirs into `~/.claude/skills`:
- **symlink** (default on macOS/Linux) — tracks this repo; `git pull` updates in place.
- **copy** — a frozen snapshot; survives moving the repo but won't pick up upstream changes.
On **Windows** the apply step defaults to copy (symlinks need admin/Developer Mode).
(Note: the **agent defs** are always *written* (copied with `{SHIP_DIR}` substituted),
never symlinked — a symlink wouldn't get the substitution.)

### (e) Watched repos — ONLY if a sensor-type module is selected
Since no sensor module ships today, you will normally **skip this**. If one is selected,
gather repo paths for `loop.config.json`'s `repos`; otherwise leave it empty.

### (f) Behavioral preferences (taste) — write `mate.local.md`
Populate the Mate's behavioral-prefs overlay. Core `mate.md` refers to values generically
("your configured X") and force-loads this overlay via `@mate.local.md`; this phase fills
in the Captain's taste. (Machine specifics went into `loop.config.json` above.)

**Don't fire separate prompts for every key.** Group into clusters mirroring
`mate.local.example.md`. For each, show the default and let the Captain accept-default (the
common path) or set their own. A Captain who accepts every default still gets a complete,
valid overlay.

Module-gated clusters appear only if that module is in the set (Dispatch bands →
`dispatch-bands`; Review policy → `review-cycle`).

| Cluster | Always? | keys it sets |
|---|---|---|
| **Thresholds** | always | `max_concurrent_crew` |
| **Dispatch bands** | only if `dispatch-bands` on | the `band_*` roster (defaults usually fine) + FIXED guardrails (not tunable) |
| **Model roster** | always | `model_default` (+ `model_escalate`/`model_lookout`/`model_speed`) |
| **Review policy** | only if `review-cycle` on | `review_policy` (+ `review_model`, `review_standards`) |
| **Reporting & surfaces** | always | `report_format`, `chat_surface` |
| **Tools** | always | `search_tool`, `pr_review_cmd` |
| **Repos & org** | always | `github_org`, `pr_template` |
| **House notes** | always (optional) | free-form lines |

Notes:
- `max_concurrent_crew` and `chat_surface` are **shared** with `loop.config.json` (machine
  code reads the config copy; the Mate reads the overlay copy). Ask once; the apply step
  writes both.
- There is **no `loop_skill`** — the Mate doesn't run a loop; the Bosun owns the heartbeat
  and the Mate enters autonomous mode via `ship-watch-start`.
- Sub-tier model keys + `review_*` rarely change — present as part of their cluster's
  "or tweak the roster?" and accept defaults unless adjusted.

## Apply — call the script once

**Always preview first** (`--dry-run`), show the plan, then run for real.

```
python3 scripts/shipkit_init.py \
  --preset <minimal|standard|full|custom> \
  [--modules core status-surface ...]      # required iff preset=custom \
  --ship-root <. | /abs/path>              # also the {SHIP_DIR} value for the agent defs \
  --install-mode <symlink|copy> \
  [--max-concurrent-crew N] \
  [--agents-target <dir>] [--skills-target <dir>]   # testing only \
  [--pref key=value ...] [--house-note "line" ...]
```

For richer answers (chat_surface, repos, the full taste block) write a JSON answers file
(shape at the top of `scripts/shipkit_init.py`) and pass `--answers <path>`, with taste in
a `"prefs"` object and house notes in `"house_notes"`. Any pref key you omit keeps the
example default verbatim.

The apply step (idempotent):
1. Writes `loop.config.json` from the example, populated (leaves an existing one untouched
   unless `--force-config`).
2. Writes `mate.local.md` from the example, populated with taste (untouched unless
   `--force-prefs`).
3. **Installs the agent defs** (`agents/ship-*.md`) into `~/.claude/agents`, substituting
   `{SHIP_DIR}` with the absolute ship_root in each def's hook command paths.
4. **Sets the execute bit on every hook** (a non-exec hook fails OPEN — silent zero
   enforcement).
5. Symlinks-or-copies the selected modules' skill dirs into `~/.claude/skills`.
6. Seeds `state/status.json` via `status_writer.py --init`.
7. Prints the smoke test.

## After applying — print the smoke test + sandbox guidance

Relay the script's smoke test and confirm the acceptance:
- Both agent defs are installed with `{SHIP_DIR}` substituted (spot-check a hook path).
- `/ship-watch-start` boots event-driven (re-anchor → mate-lock → wake-monitor → bootstrap
  Bosun → preflight → idle); it does **not** launch `/loop`.
- The Bosun is ticking (`tail state/bosun-heartbeat.log`).
- A directive (inbox edit / drop) **wakes** the Mate; a bookkeeping change does **not**.
- (If `status-surface`) the PWA renders `status.json`.

**Sandbox guidance (mention it):** running the agent in a sandbox is recommended
(defense-in-depth on top of the bright-line hooks). On macOS,
[agent-safehouse.dev](https://agent-safehouse.dev/) is a good option — point
`SHIP_SANDBOX_RUN` at its wrapper. Bare `claude` is the no-sandbox fallback. Launch the bg
Mate with `scripts/ship-up.sh --check` then `--launch-mate`.

## Bounds
- Run **once** per onboarding/module-add. Not a per-tick skill.
- **One ship per machine** — never set up multiple ship-roots.
- **Be honest about shipped vs planned.** Never imply a planned module works.
- The preset → module mapping lives in `scripts/shipkit_init.py` — if it and this doc
  disagree, the script wins (update this doc to match).
- Always `--dry-run` and show the plan first.
- Don't hand-edit `loop.config.json` / `mate.local.md` / `state/status.json` here — the
  apply step owns those writes during onboarding.
