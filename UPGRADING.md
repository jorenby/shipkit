# UPGRADING — bring a foreign Ship instance onto shipkit v2

This is the runbook a **foreign machine's First Mate** follows to point its Ship at the shipkit
v2 code and migrate itself, using the `/shipkit-setup` skill. It is written to be run
**verbatim**. It covers a fresh stand-up, a tier bump, and the hard case — upgrading an older
(pre-v2, "Mate-runs-`/loop`") install that has operator divergence.

> **What this proves.** shipkit is a deployable, repeatable thing: a second machine clones the
> repo, checks out the branch, runs one skill, reasons about its own divergence, and comes up
> with the bright-line hooks armed and a smoke-tested Mate. This document is the exact sequence
> that was dry-run end-to-end (fresh install both tiers + a walked upgrade over a reconstructed
> diverged v1 install) before you got here.

---

## Platform assumptions (READ FIRST)

- **macOS / Linux / Windows-with-Git-Bash.** The bright-line enforcement is a set of **bash**
  PreToolUse hooks (`core/hooks/validate-*.sh`, `modules/autonomous/hooks/validate-*.sh`). The
  installed agent defs invoke each hook as **`<bash> <absolute-path>`** where `<bash>` is
  **resolved at install time** — on POSIX a bare `bash`; on Windows an **absolute Git-Bash path**
  (see below). So the outer shell runs bash against the script — **enforcement does NOT depend on
  the exec bit or shebang resolution.** That makes **Git-Bash a sufficient substrate on Windows** —
  you do NOT need WSL for the hooks. macOS/Linux is the most-tested path; Git-Bash is now a
  supported substrate too.
- **Windows / NTFS specifics (Git-Bash substrate):**
  - Claude Code runs shell-form hook commands through **cmd/Git Bash on Windows**. A **bare `bash`
    is a footgun on Windows**: `where bash` on a dev box often returns `C:\Windows\System32\bash.exe`
    (the **WSL** stub) FIRST, and WSL's bash cannot see a Windows-style script path (`C:\...`) → the
    hook errors → PreToolUse doesn't block → **enforcement FAILS OPEN, silently.** The installer
    therefore **resolves an absolute Git-Bash path at install time** (probes
    `%ProgramFiles%\Git\bin\bash.exe`, then `%ProgramFiles(x86)%\...`, then a `where bash` scan with
    System32 filtered out) and renders that quoted path into the hook command. If it finds **no**
    Git-Bash it **FAILS THE INSTALL LOUDLY** rather than shipping a silently-unenforced ship.
    Install **Git for Windows** (ships Git Bash) — that is the one requirement.
  - **The exec bit is POSIX-only and no longer load-bearing.** NTFS has no `+x`; `shipkit_init.py`
    still `chmod +x`es the hooks as POSIX belt-and-suspenders (a no-op where the FS ignores it), and
    its hook-path assertion now checks **existence** (not `+x`) since the `bash` invocation carries
    execution. A non-exec hook on Git-Bash still enforces.
  - Symlinks need admin/Developer Mode on Windows, so the installer defaults to **copy** mode
    there (a frozen snapshot that won't track `git pull`). Agent defs are always *written* (never
    symlinked) so the `{SHIP_DIR}` substitution lands regardless.
  - The Python installer, `status_writer.py`, `classify_input.py`, and `wake_monitor.py` are
    stdlib-only and cross-platform — the Python layer is fine. WSL still works too (it's Linux),
    but is **not required** just for the hooks.
- **peer-comms receive-side guard is layout-relative.** `lib/classify_input.py` resolves
  `peer_envelope` from its own location (`lib/ → ../modules/peer-comms/`). If a deployment
  relocates `classify_input.py` away from a sibling `modules/`, the peer pre-filter silently
  degrades to a no-op (fail-safe: no quarantine, classification exactly as without the module)
  — but the receive-side validation guarantee weakens without an error. Keep the sibling
  layout, or re-verify quarantine fires after any relocation.
- **bg-Mate boot: `worktree.bgIsolation` must be `none`** (F11, first Windows autonomous
  rotation). The harness's bg worktree-isolation guard forces a `--bg` agent's Edit/Write into
  an isolated git worktree — wrong for the Mate, which writes LIVE shared state (`queue.md`,
  `status.json`, mate log, drops) that the Bosun/wake-monitor/status UI read in real time. It
  even blocks the settings Write that disables it (create the file via bash redirection if
  you're stuck mid-boot; the guard reads settings dynamically — no restart needed).
  `ship-up.sh` preflight now **self-heals** this (`.claude/settings.json` →
  `{"worktree":{"bgIsolation":"none"}}`) — after the `{SHIP_DIR}`/interpreter footguns, this
  is the biggest first-foreign-bg-Mate-boot gotcha.
- **Rotation hygiene: monitor processes outlive `TaskStop`** (F10). Stopping the outgoing
  Mate's session halts a Monitor's re-invocation but does NOT kill the detached OS process it
  spawned — `wake_monitor.py` survives as an orphan. The incoming Mate's watch-start step-4
  kill-sweep self-heals this (PowerShell variant on Git-Bash — `pkill` doesn't exist there),
  and `ship-up.sh --rotate-mate` now sweeps orphans OS-level before launching the replacement.
- **Prereqs:** `git`, `python3` (3.10+), and Claude Code. For the autonomous tier you also want
  `gh` if you use PRs.

---

## STEP 0 — Make the target recoverable FIRST (rollback insurance)

**Do not upgrade a dirty tree.** Git is the rollback mechanism; it only works if the starting
point is committed clean.

**First, stop any detached processes that write into the ship tree** — a background UI server,
a log writer redirecting stdout into `logs/`, a bg Mate/Bosun. On Windows especially, an open
file handle makes `git checkout` fail mid-carry with unlink errors (files can't be replaced while
held open). Stop them before you touch git:

```bash
# find + stop anything writing into the tree (adapt to your setup): UI server, log tail, bg
# Mate/Bosun. E.g. list Ship-related processes, then stop them:
ps aux | grep -Ei 'ship-|bosun|mate|node .*ui' | grep -v grep   # identify, then kill the PIDs
# (a bg Mate/Bosun holds a mate-lock too — clearing state/mate-lock.json is part of a clean stop)
```

Then, in the target ship dir:

```bash
cd <your-ship-dir>
git status --porcelain        # MUST be empty. If not: commit or stash before continuing.
git rev-parse HEAD            # write this down — your rollback point
git branch pre-shipkit-v2-upgrade   # a named bookmark you can return to
```

If anything below goes wrong, you roll back with:

```bash
git checkout pre-shipkit-v2-upgrade   # or: git reset --hard <the HEAD you wrote down>
# then remove any freshly-installed agent/skill artifacts (see the reinstall block in STEP 3B)
```

> **No-remote installs (a v1 `init` that COPIED files instead of cloning): the bookmark is
> LOCAL and that is enough.** Many v1 ships were stood up by copying files, so the repo has no
> `origin` — `git branch pre-shipkit-v2-upgrade` and `git tag`/`git rev-parse HEAD` all live in
> the **local** repo and need no remote to push to. **Rollback is entirely local** (`git checkout
> pre-shipkit-v2-upgrade` / `git reset --hard <HEAD>`). You do not need a remote for rollback
> insurance; you only need one to *fetch v2* (STEP 1). Verify you actually have a repo with
> `git rev-parse --is-inside-work-tree`; if it prints `false`, `git init && git add -A && git
> commit -m "pre-shipkit-v2 snapshot"` first so there's a commit to bookmark and return to.

The installer itself is conservative — it never overwrites an existing `loop.config.json`,
`mate.local.md`, or `state/status.json` without an explicit `--force-*` flag, and it leaves
existing agent defs / skills untouched. The recoverable-first rule is belt-and-suspenders for
the parts git touches (the framework files that move flat→folder).

---

## STEP 1 — Get the shipkit v2 code onto the machine

Until PR #8 (`loop-mode-v2`) merges to the default branch, check out the branch explicitly.

**If this machine has never had shipkit (fresh):**

```bash
git clone git@github.com:wstrinz/shipkit.git <your-ship-dir>
cd <your-ship-dir>
git checkout loop-mode-v2
```

**If this machine already has a shipkit clone WITH a remote (in-place):**

```bash
cd <your-ship-dir>
git fetch origin
git checkout loop-mode-v2      # or: git merge origin/loop-mode-v2 if you track a branch
```

**If this machine has a v1 ship with NO remote (v1 `init` copied files — very common):**
The repo has local history (your logs/tickets/queue/state are all committed) but no `origin` to
fetch v2 from. Add one, fetch, and check out the branch — your local history is untouched by this:

```bash
cd <your-ship-dir>
git remote -v                                  # likely empty → no remote configured
git remote add origin git@github.com:wstrinz/shipkit.git   # (or https://github.com/wstrinz/shipkit.git)
git fetch origin
git checkout loop-mode-v2                       # creates a local branch tracking origin/loop-mode-v2
```

> If `git fetch` brings in an entirely unrelated history (v2's clone vs. your copied v1 tree share
> no commits), `git checkout loop-mode-v2` may refuse with "unrelated histories." That is expected
> for a copied v1 install — **take the clean-reinstall path (STEP 3B)**: you're not merging trees,
> you're adopting the v2 framework files and re-homing your edits. Your ship STATE
> (`captain.md`, `queue.md`, `projects/`, `logs/`, `inbox/`, `state/`) is what matters and it is
> **preserved** — the clean reinstall only replaces framework scaffolding, never your state.
> (`git checkout -f loop-mode-v2` if you've captured your divergence and want the v2 tree; your
> state dirs aren't tracked by the framework and survive.)

> **Note on the ship dir.** In v2 the ship directory **IS the shipkit clone** — one dir holds
> both the framework (`core/`, `modules/`, `lib/`) and your ship state (`captain.md`, `queue.md`,
> `projects/`, `logs/`, `inbox/`, `state/`). This is load-bearing: the hooks live in this dir,
> and the agent defs' hook command paths are built from it. **One ship per machine; ship-root =
> this dir.** (See the topology warning in STEP 3.)

---

## STEP 2 — Run the interview + reason about divergence

Open Claude Code **in the ship dir** and run the skill:

```
/shipkit-setup
```

The skill (`.claude/skills/shipkit-setup/SKILL.md`; the upgrade judgment lives in
`.claude/skills/shipkit-setup/upgrade.md`) carries the judgment; `shipkit_init.py` is the
mechanical apply step. The skill will:

1. **Detect** whether this is fresh, a tier bump, or an older/diverged install — it runs the
   apply step in `--dry-run` to read the "prior-install state" report and inspects
   `~/.claude/skills` + `~/.claude/agents` directly (symlink vs copy — the load-bearing
   distinction).
2. **Interview** you (fresh / tier-bump): preset (`core` / `autonomous` / `ui`), ship-root
   (default `.`), install method (symlink vs copy), behavioral prefs → `mate.local.md`, and
   whether to **track or gitignore** the overlay.
3. **Reason about divergence** (older install) BEFORE applying — this is the conversation below.

### The reason-about-divergence conversation (older / pre-v2 install)

If you're upgrading a pre-v2 ("Mate-runs-`/loop`") install, the skill walks these with you.
The **recommended path for a diverged pre-v2 install is a clean reinstall** — v1↔v2 do not
fast-forward (v2 restructured flat files into folders), so an in-place merge produces rename
conflicts on every file you edited. The clean-reinstall order:

- **Capture your divergence first.** Diff your edited framework files against their v2 homes so
  you can re-home the changes AFTER:
  ```bash
  diff mate.md core/mate.md                              # a customized standing order?
  diff scripts/validate-crew-bash.sh core/hooks/validate-crew-bash.sh   # a local allow rule?
  ```
  Anything that isn't just the v2 rewrite is an operator edit to carry.
- **Re-home edits into the v2 SEAMS, never back into synced framework files.** A customized
  `mate.md` standing order → the overlay `mate.local.md` (house notes / dated decisions). A
  local hook allow rule → `core/hooks/crew-allow-local.sh` (copy it from
  `core/templates/crew-allow-local.sh`) — NOT edited into `validate-crew-bash.sh`, which
  `pull-upstream.sh` overwrites on the next sync. These seams are `.gitignore`d and survive
  upstream pulls; that's their whole purpose.
- **A local-only doc** you added (e.g. `docs/knowledge/env-config.md`) is not a framework file
  — it's never synced and never conflicts. Leave it where it is.
- **Clear the old installed skills/agents** so the orphan dead-loop skill and stale flat-hook
  agent defs are gone:
  ```bash
  rm -rf ~/.claude/skills/ship-* ~/.claude/skills/bosun-tick ~/.claude/skills/shipkit-setup \
         ~/.claude/agents/ship-*
  ```
  This removes the `ship-tick` orphan (the dead `/loop` body), the copied `ship-watch-start`
  (which would otherwise silently keep launching `/loop /ship-tick` post-upgrade), and every
  agent def whose hook path still points at the old flat `scripts/...` location.
- **Two footguns the skill will name explicitly:**
  1. *The copied boot skill.* A **copied** (not symlinked) old `ship-watch-start` keeps
     launching the obsolete `/loop` body after the upgrade — and nothing errors. Removing it
     (above) and reinstalling fixes it.
  2. *The lingering flat hook.* If a `git pull` added `core/hooks/...` but left your old
     `scripts/validate-crew-bash.sh` behind, a stale agent def's baked flat hook path **still
     resolves** — so the hook-path assertion prints `ok`, yet it's enforcing your OLD v1 rules,
     not the v2 hook. A green assertion does not prove the current hook is wired. Delete the
     lingering flat hook files after re-homing their content.
- **`loop.config.json` migration.** v2 added `github_org` / `agents` / `hooks` / `launch`
  blocks. If your ship dir IS the evolving clone, the apply step reports the missing keys and
  the skill merges them (preserving your values, using the new tiered hook paths). If you
  cloned v2 fresh into a new dir, the config is gitignored and the first apply writes a
  `loop.config.json` with every key at placeholder values — nothing reports as missing, so
  **port your real machine values (repos, github_org, chat_surface, headroom path,
  hosts_ports) from the old config by hand.**

When divergence is genuinely ambiguous, the skill asks rather than guesses.

---

## STEP 3 — Apply

### 3A. The normal (fresh / tier-bump) apply

The skill always `--dry-run`s first and shows you the plan, then runs for real. The invocation
it uses (sanctioned topology — ship-root is the shipkit dir):

```bash
# dry-run first — read the plan, especially the hook-path assertion section
python3 shipkit_init.py --preset autonomous --ship-root . --install-mode symlink --dry-run

# then for real
python3 shipkit_init.py --preset autonomous --ship-root . --install-mode symlink
```

Presets: `core` (request/response Mate + worker agents + crew hooks), `autonomous`
(+ the bg-Mate/Bosun kernel). (Tier 3, the thread-first UI, arrives on the stacked UI PR.) Tiers are start-at OR
progress-through — re-run at a higher preset any time and only the delta installs (idempotent).

> **Topology warning (load-bearing).** Keep `--ship-root .` — the ship-root MUST be the shipkit
> dir. The hooks live in this repo, and the agent defs' hook command paths are built from
> ship-root. If ship-root points elsewhere, every installed agent def gets a hook path that
> **doesn't exist → the bright-line hooks FAIL OPEN.** The installer now prints a loud WARNING
> when ship-root diverges from the shipkit dir, and the hook-path assertion will print `FAIL`.
> Do not diverge unless you have deliberately mirrored the hooks under ship-root.

### 3B. The clean-reinstall apply (recommended for a diverged pre-v2 install)

> **The state is the ship; the scaffolding is replaceable.** The clean reinstall replaces
> framework files (`core/`, `modules/`, `lib/`, the installed agent defs/skills) and preserves your
> **ship state** — `captain.md`, `queue.md`, `projects/`, `logs/`, `inbox/`, `state/`. Those are
> never framework files, so nothing below touches them. On a **no-remote v1 install** this is
> especially the recommended path: you're adopting the v2 tree in place (or fresh-cloning v2 into a
> new dir and copying your state dirs across), not merging unrelated histories. Rollback stays
> local (the `pre-shipkit-v2-upgrade` branch from STEP 0).

After capturing + re-homing your divergence (STEP 2) and clearing old skills/agents:

```bash
# 1. accept the v2 layout in place; delete leftover flat files after re-homing their content
git checkout loop-mode-v2       # (already done in STEP 1)
# rm the leftover flat framework files ONLY after you've re-homed their edits:
#   rm mate.md crew.md scripts/validate-*.sh scripts/status_writer.py scripts/classify_input.py
#   (keep captain.md, queue.md, projects/, logs/, inbox/, state/ — those are your ship state)

# 2. reinstall fresh
python3 shipkit_init.py --preset autonomous --ship-root . --install-mode symlink --dry-run
python3 shipkit_init.py --preset autonomous --ship-root . --install-mode symlink
```

---

## STEP 3.5 — RESTART the Claude session (MANDATORY before the STEP 4 smoke)

> **RESTART the Claude session now.** Claude Code **snapshots the agent-def registry AND their
> contents at session start** — the install session you just ran the apply from is holding the
> *pre-install* view. If you run the STEP 4 enforcement smoke in this same session, you'll be
> validating **stale/cached agent defs**, not the ones you just wrote, and the result is
> meaningless (it can "fail" on defs that no longer exist, or "pass" on old ones).
>
> **The tell:** dispatch a freshly-installed agent type (e.g. `ship-reviewer` on a first
> autonomous install). If you get **"agent type not found"** while pre-existing types resolve,
> you're in a **stale session** — restart before smoking.
>
> Quit and reopen Claude Code in the ship dir, re-say "you're First Mate," THEN do STEP 4.

---

## STEP 4 — Post-install verification checklist

Confirm each before trusting the install:

- [ ] **Hook-path assertion is all `ok`.** In the apply output, the
      `== hook path assertion ==` section shows `ok` for every agent def — **zero `FAIL`
      lines.** A `FAIL` = a disarmed bright line (fails open). Fix before relying on the install.
- [ ] **Hooks are `+x`.** The `== hooks ==` section shows each hook `already +x` or
      `chmod +x (was non-exec — fixed)`. Spot-check: `ls -l core/hooks/*.sh` — all executable.
- [ ] **Agents installed with `{SHIP_DIR}` substituted.** `ls ~/.claude/agents/ship-*.md`, and
      `grep 'command:' ~/.claude/agents/ship-crew.md` shows an **absolute** path into this
      shipkit dir's `core/hooks/` — **not** a literal `{SHIP_DIR}`. The rendered form is a
      **single-quoted** scalar: on POSIX `command: 'bash /abs/.../validate-crew-bash.sh'`; on
      Windows `command: '"C:/Program Files/Git/bin/bash.exe" C:/.../validate-crew-bash.sh'`
      (resolved Git-Bash interpreter, forward slashes). On Windows, confirm the interpreter path
      in that command actually exists — the installer's placeholder pass now checks this and
      FAILs the install if it doesn't.
- [ ] **(your stack) You may need to write `crew-allow-local.sh`.** The crew allow-list ships
      the common wrappers (devbox/bundle/npm/npx/rake/make/git-read); a foreign stack (`cargo`,
      `bun`, `go`, `pnpm`, …) is **blocked out of the box by design**. That's the intended seam —
      copy `core/templates/crew-allow-local.sh` to `core/hooks/crew-allow-local.sh` (next to
      `validate-crew-bash.sh`) and add your project's read/build commands to
      `check_allowed_local()`. Deny-precedence stays intact (the deny-list runs first; the local
      allow only *widens* the allow-list, never overrides a block). Expect to do this as part of
      bring-up — it is not a bug.
- [ ] **NO literal `{SHIP_DIR}` (or any `{...}` token) survives in any installed agent def.**
      This is the v1 CRITICAL footgun — a leftover placeholder = a garbage hook path = enforcement
      **silently OFF**. The installer now runs this check and FAILS LOUDLY, but verify it yourself:
      ```bash
      grep -rl '{SHIP_DIR}' ~/.claude/agents/     # MUST print nothing (empty output)
      # adapt the path if your agents install elsewhere (loop.config.json → agents.install_target)
      ```
      Any hit = re-render: `rm ~/.claude/agents/ship-*.md && python3 shipkit_init.py ... ` (the
      installer leaves existing defs untouched, so you must remove the stale one to refresh it).
- [ ] **Skills installed.** `ls ~/.claude/skills/` shows the tier's skills (`ship-compound`
      always; `ship-watch-start` + `ship-watch-rotate` + `bosun-tick` on autonomous). For an
      upgrade, confirm the old **`ship-tick` orphan is GONE** and any copied boot skill was
      refreshed to a symlink. `ship-watch-rotate` is **new** — an upgrade from a pre-rotation
      install adds it (and `modules/autonomous/scripts/rotation_prep.py`) with no migration
      needed; nothing consumes it until you actually rotate a watch.
- [ ] **State seeded.** `python3 -c "import json;print(json.load(open('state/status.json'))['tick'])"`
      prints `0` on a fresh seed (or your existing tick on an upgrade — it's a no-op if already
      seeded).
- [ ] **A smoke watch (the acceptance):**
  - **core tier:** open Claude Code in the ship dir, say "you're First Mate." It reads
    `core/mate.md`, runs request/response, and can dispatch a worker crew — verify a trivial
    `ship-lookout` dispatch runs with the crew-safety hook armed (try a blocked command, e.g.
    ask it to `git commit` in a repo — the hook should refuse).
  - **autonomous tier:** run `/ship-watch-start`. It boots event-driven (re-anchor → mate-lock →
    wake-monitor → bootstrap the Bosun → preflight → idle) and does **not** launch `/loop`.
    Confirm the Bosun is ticking: `tail state/bosun-heartbeat.log` (a fresh line). Drop a
    directive (`inbox/drops/` or an `inbox/captain.md` edit) → the Mate WAKES. Flip a
    bookkeeping-only item → NO wake.
- [ ] **(sandbox, recommended)** Run the agent in a sandbox for defense-in-depth on top of the
      hooks. On macOS, [agent-safehouse.dev](https://agent-safehouse.dev/) — point
      `SHIP_SANDBOX_RUN` / `launch.sandbox_wrapper` at its wrapper. Bare `claude` is the
      no-sandbox fallback. Launch the bg Mate:
      `modules/autonomous/scripts/ship-up.sh --check` then `--launch-mate`.

---

## Rollback

If the smoke watch fails or the install looks wrong:

```bash
# 1. restore the framework files git touched
cd <your-ship-dir>
git checkout pre-shipkit-v2-upgrade      # the bookmark from STEP 0 (or reset --hard <old HEAD>)

# 2. remove the freshly-installed agent/skill artifacts
rm -rf ~/.claude/skills/ship-* ~/.claude/skills/bosun-tick ~/.claude/skills/shipkit-setup \
       ~/.claude/agents/ship-*

# 3. (if you re-installed the OLD versions, re-run /shipkit-setup against the old checkout)
```

Because the installer never force-overwrites your `loop.config.json` / `mate.local.md` /
`state/status.json`, and you committed clean in STEP 0, the target is fully recoverable.

---

## What could still bite the real foreign run (known residual risk)

- **v1↔v2 is not a fast-forward.** An in-place `git merge origin/loop-mode-v2` over a diverged
  pre-v2 tree WILL conflict on any edited framework file. The clean-reinstall path (3B)
  sidesteps this; prefer it.
- **A lingering flat hook enforces stale rules silently** (STEP 2 footgun #2). The hook-path
  assertion cannot detect vintage — only existence + `+x`. Delete leftover `scripts/*.sh` hooks.
- **Fresh-clone config migration is manual** — the automated "missing keys" report is a no-op
  when you clone v2 fresh (STEP 2, config migration). Port your machine values by hand.
- **Windows runs on Git-Bash, and the interpreter is resolved at install time** — a bare `bash`
  on Windows can resolve to WSL's `System32\bash.exe` stub, which can't see the Windows script
  path → silent fail-open. The installer resolves an **absolute Git-Bash path** and renders it
  (and FAILs the install if it finds no Git-Bash). WSL is not required. The exec bit is no longer
  load-bearing. Install Git for Windows (ships Git Bash). Symlinks still need admin/Developer Mode,
  so the installer defaults to **copy** mode there (a frozen snapshot that won't track `git pull`)
  — re-run the installer after a pull to refresh. **A hand-patched agent def is lost on a def
  refresh** — the interpreter resolution lives in the renderer, so let the installer render it.
