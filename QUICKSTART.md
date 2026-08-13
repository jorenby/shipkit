# Quickstart — prerequisites & troubleshooting

The step-by-step setup and first-watch walkthrough live in the README's [Getting started](README.md#getting-started) and in the interactive [`/ship-tour`](.claude/skills/ship-tour/SKILL.md) — this page doesn't repeat them. It covers the two things those don't: what to have in place *before* you start, and what to do when a step misbehaves.

New to the vocabulary (watch, drop, ticket, …)? Read [GLOSSARY.md](GLOSSARY.md) first. Want to see what a running ship looks like before you build one? See [`examples/`](examples/).

## Prerequisites

- **[Claude Code](https://code.claude.com/docs)** installed and working.
- **`git`, `python3`, `bash`, and `jq`.** The enforcement hooks parse their input with `jq` and the setup installer hard-fails without it (`brew install jq` / `apt-get install jq` / `winget install jqlang.jq`). On Windows the hooks run under Git-Bash.
- **Familiarity with two Claude Code features Ship builds on.** If you haven't used either, skim these before setup so the steps make sense — the setup won't re-explain them:
  - [Subagents](https://code.claude.com/docs/en/sub-agents) — what `core/agents/ship-crew.md` and `core/agents/ship-lookout.md` become once installed to `~/.claude/agents/`.
  - [Hooks](https://code.claude.com/docs/en/hooks) — what enforces the git-safety restrictions on Crew (`core/hooks/validate-crew-bash.sh`).

Then follow the README's [Getting started](README.md#getting-started): the clone **is** your ship, `/shipkit-setup` wires it (core tier — a request/response Mate + worker agents + safety hooks), and `/ship-tour` walks your first real cycle.

## Troubleshooting

**Setup fails partway through, or reports enforcement isn't armed.**
`/shipkit-setup` runs a skill that calls the deterministic installer (`shipkit_init.py`); it verifies enforcement is actually armed and **fails loudly if it isn't**, rather than leaving you a half-wired ship. Fix: re-run `/shipkit-setup` — it's idempotent, and it's the same path for first setup, tier bumps, and upgrades. If it hard-fails immediately, check `jq` is installed (the hooks need it). Upgrading a pre-v2 install goes through `/shipkit-setup` too — the runbook is [`UPGRADING.md`](UPGRADING.md).

**A Crew watch seems to hang or go silent.**
Crew runs in the background, so "no output yet" is often normal for anything more than a trivial task. If it's been unreasonably long: Crew's standing orders say to **stop and write a log rather than spin**, so a properly-behaving watch that's genuinely blocked (a destructive git operation it's not allowed to run, a missing permission, an ambiguous scope) should have already ended itself with a log explaining why. If there's no log and no output, treat it as a hung session: end it and re-dispatch with tighter watch orders. Bounded sessions hanging silently is exactly the failure mode Ship is designed to avoid — if it reproduces, that's worth reporting.

**"Role not assumed" — the session isn't behaving like Mate or Crew.**
Ship roles aren't automatic modes; a session becomes the Mate only when told to read its standing orders. Fix: restate the role and point it at the file — `core/mate.md` for the Mate (`/ship-tour` does this for you on lesson 1), or `core/crew.md` for a hand-run crew session. When you dispatch Crew through the Task tool, the standing orders are already baked into the `ship-crew` / `ship-lookout` subagent definitions, so the subagent has them without being told.

**The hook doesn't seem to block anything (Crew commits or pushes when it shouldn't).**
Enforcement is a PreToolUse hook on the Crew subagents. Check three things: the installed agent def at `~/.claude/agents/ship-crew.md` has your ship's absolute path substituted into its `hooks:` block (setup does this — a wrong or missing path disarms it); `core/hooks/validate-crew-bash.sh` is executable; and `jq` is present (the hook can't parse its input without it). Re-running `/shipkit-setup` re-installs the agent defs with the path substituted and re-checks that enforcement is armed. See the [hooks documentation](https://code.claude.com/docs/en/hooks) for how Claude Code resolves and runs PreToolUse hooks.
