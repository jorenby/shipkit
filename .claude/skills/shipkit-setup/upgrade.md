# Upgrading an existing / diverged install — the judgment doc

Read this BEFORE applying when the machine is NOT fresh and NOT a simple current-generation
tier bump: an older (incl. pre-v2 "Mate-runs-/loop") install, or anything hand-edited. **You
carry the judgment; the script stays mechanical** — `shipkit_init.py` only installs files and
*reports* what it finds. It does not auto-resolve how a particular machine has diverged,
because ship instances diverge idiosyncratically and a script that guessed would do the wrong
thing silently. That reasoning is your job here.

(Fresh machine or tier bump? Go back to `SKILL.md` — you don't need this doc.)

## Classify the UPGRADE TOPOLOGY first — it changes everything below

- **(A) In-place git pull** — the operator's ship dir IS a shipkit clone, and they advance it by
  fetching upstream. If v1 and v2 share linear history this is a fast-forward; if they diverged
  (the usual case — v2 restructured flat→folders), a merge surfaces rename/edit CONFLICTS on any
  file the operator edited (e.g. `mate.md`, `scripts/validate-crew-bash.sh`). The new folder
  files (`core/`, `modules/*/`, `lib/`) arrive via git; the operator's OLD flat files may linger
  as untracked cruft alongside them. See divergence item 6.
- **(B) Fresh clone, carry values across** — the operator clones v2 shipkit fresh into a new dir
  and wants their v1 machine values (config, prefs, house notes, local hook edits) brought over.
  **The apply step's config-key report is USELESS here** — a fresh v2 clone's first apply writes
  a full `loop.config.json` with every key (placeholder values), so nothing shows as "missing,"
  yet the operator's real v1 values are NOT carried. YOU must diff the old ship dir's
  config/prefs/hooks against the fresh clone and port the machine-specific values by hand
  (items 3 and 6).

**Note the config-check limitation explicitly:** `detect_prior_state` reads
`loop.config.json` *in the shipkit repo you are running from*, not in some other old ship dir.
It catches missing keys only in topology (A) where that file IS the operator's evolving config.
In topology (B) you must point at the OLD dir yourself: read `<old-ship>/loop.config.json` and
diff its non-`_` keys against `loop.config.example.json`.

Beyond the dry-run report, inspect directly:

- `ls ~/.claude/skills/ | grep -E 'ship|bosun'` and `ls ~/.claude/agents/ | grep ship`
- For each installed skill/agent: **is it a symlink into this repo, a symlink elsewhere, or a
  COPY?** (`ls -l`). This is the load-bearing distinction — see item 1 below.
- `git log --oneline -1` in the ship dir vs the installed files' vintage.
- Read `loop.config.json` (if present) and compare its keys to `loop.config.example.json`.

## Reason about divergence (the judgment)

**This is the part a script must not do for you.** Walk the machine's actual state and decide,
asking the user wherever it's unclear:

1. **The copied-skill footgun (call it out explicitly).** A *copied* old `ship-watch-start`
   keeps launching the OBSOLETE `/loop` body post-upgrade while everything else moved to
   event-driven — **and nothing errors.** If the detect report shows `ship-watch-start` (or
   `bosun-tick`) as a COPY, you MUST refresh it: remove the copy and re-install (or re-symlink)
   so the boot skill is the current event-driven one. If it's a symlink into this repo,
   `git pull` already refreshed it — fine.
2. **Orphan skills from the old model.** The pre-v2 shape installed a `ship-tick` skill (the
   old Mate-runs-the-loop body). It is NOT in any current module → the apply step reports it as
   an ORPHAN. **Remove it** (`rm -rf ~/.claude/skills/ship-tick`) so no one can `/ship-tick`
   into the dead loop. Confirm with the user before removing anything you're unsure about.
   (The setup skill itself — `shipkit-setup` — is never an orphan; it's in the core manifest.)
3. **`loop.config.json` key migration.** v2 added `agents` / `hooks` / `launch` / `github_org`
   blocks. The apply step REPORTS missing keys; it does NOT migrate them (all-or-nothing
   `--force-config` would clobber the user's machine values). **You** merge the missing keys:
   read the user's existing config, add the missing keys from `loop.config.example.json` with
   sensible values (ask for machine-specific ones), preserve everything they already set.
   The v2 hook paths are now tiered (`core/hooks/...`, `modules/autonomous/hooks/...`) — make
   sure a migrated config uses the new paths, not the old flat `scripts/...`.
   **Topology caveat (from above):** the apply step's "missing keys" report only fires in
   topology (A) where the shipkit repo's own `loop.config.json` IS the operator's evolving
   config. In topology (B) (fresh v2 clone), the freshly-written config already has every key
   with placeholder values, so NOTHING reports as missing — but the operator's real machine
   values (repos, github_org, chat_surface, headroom path, hosts_ports) are NOT carried. Read
   the OLD dir's `loop.config.json` yourself and port those values into the fresh clone's
   config by hand.
4. **Stale prefs.** An old `mate.local.md` may carry a `loop_skill` key (e.g.
   `loop_skill: "/loop /ship-tick"`) — removed in v2 (the Mate doesn't run a loop). Harmless but
   wrong; clean it or note it.
5. **Stale agent defs — and the sharper "lingering flat hook" trap.** An old `ship-crew` /
   `ship-mate` / `ship-bosun` def carries a hook command path baked at v1 install time, e.g.
   `.../scripts/validate-crew-bash.sh` (flat). Two sub-cases, and the second is the dangerous one:
   - **(a) The old flat hook file is GONE** (v2 moved it to `core/hooks/`). The baked path no
     longer resolves → the apply step's hook-path assertion prints `FAIL ... NOT FOUND` and
     **exits non-zero** → the hook FAILS OPEN. Loud; easy to catch. Re-run with
     `--refresh-agents` so the apply step rewrites the def with the correct tiered path.
   - **(b) The old flat hook file STILL EXISTS** (topology A: `git pull` added `core/hooks/...`
     but left the operator's old `scripts/validate-crew-bash.sh` lingering). Now the stale def's
     baked flat path STILL RESOLVES and is executable → **the hook-path assertion prints `ok`**
     → but it is enforcing the OLD v1 rules (including any operator edits made to the flat hook),
     NOT the current v2 hook. The assertion checks existence + executability, NOT vintage, so a
     green assertion does NOT prove the current hook is wired. **You** must catch this: if any
     agent def's hook path points at a flat `scripts/...` location, re-render the def
     (`--refresh-agents` rewrites it to `core/hooks/...`) AND delete the lingering flat hook
     file so nothing can source it. Verify the rewritten def's path lands under `core/hooks/` /
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

## The clean reinstall (usually the lowest-risk move)

When the picture is genuinely ambiguous (e.g. a hand-edited install), **ask the user** rather
than guess. **The lowest-risk move for a single machine is almost always a clean reinstall** —
and for a diverged flat→folder (pre-v2) install it is the RECOMMENDED path, because v1↔v2 do not
fast-forward and an in-place merge produces rename conflicts on every edited file. Procedure:

1. Capture the operator's divergence first (item 6 diffs) — you re-home these AFTER.
2. Point the ship dir at v2 shipkit cleanly: either `git fetch && git checkout loop-mode-v2`
   into the same dir (accept the new folder layout; delete leftover flat files), or clone v2
   fresh and move the operator's project state (`captain.md`, `queue.md`, `projects/`, `logs/`,
   `inbox/`, `state/`) across — these are never framework files.
3. Remove installed skills/agents: `rm -rf ~/.claude/skills/ship-* ~/.claude/skills/bosun-tick`
   `~/.claude/skills/shipkit-setup ~/.claude/agents/ship-*` (this clears the orphan `ship-tick`,
   the copied `ship-watch-start`, and every stale flat-hook agent def in one move).
4. Run the setup fresh at the target preset — it sidesteps every divergence above. (Step 3
   removed the installed skill, so `/shipkit-setup` won't resolve: open Claude Code in the
   clone and say "run the setup per skills/shipkit-setup/SKILL.md", same as first bootstrap.)
5. Re-home the captured edits into the v2 seams (overlay / `*-allow-local.sh`), never back into
   the synced framework files.

## Upgrade verification (on top of SKILL.md's acceptance)

- The orphan `ship-tick` is gone; any copied boot skill was refreshed.
- `loop.config.json` has the new keys with the user's values preserved.
- Every agent def's hook path lands under `core/hooks/` / `modules/*/hooks/` — no flat
  `scripts/...` path survives, and no old flat hook file lingers on disk.

See also [`UPGRADING.md`](../../UPGRADING.md) at the repo root — the runnable-verbatim runbook
form of this doc (clone/fetch commands, rollback, platform assumptions).
