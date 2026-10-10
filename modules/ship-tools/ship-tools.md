# Module: Ship Tools

**Optional. Mate-side helpers for keeping ship state tidy.** None of them dispatches,
pushes or edits a template.

| Piece | Kind | What it does |
|---|---|---|
| `skills/drops` (`/drops`) | skill, Mate-only, mutating | Flushes Mate-addressed drops in `inbox/drops/` into `queue.md` and tickets, mints real IDs for `NEXT` placeholders, leaves drops addressed to other seats, never promotes into Ready, then commits only the files it touched. The procedure is `core/mate.md` → "Processing Inbox" → Drops, packaged as a command. |
| `scripts/initiative-index.py` | read-only report | Groups tickets under `projects/*/tickets/` by their `**Epic:**` field and prints, per initiative, `done/total`, each blocked ticket with the first line of its `## Blocked on`, and the lowest-numbered ticket that is neither done nor blocked. Project tags default to the directory name upper-cased; override with `--tag dir=TAG`. |
| `scripts/seed-conformance-check.py` | read-only sensor | Diffs the heading structure (`#`–`###` headings and `**Label:**` lines) of `captain.md`, `queue.md` and every ticket against `core/templates/`, both directions. Findings go to one `batch`-class drop, `inbox/drops/<date>-seed-conformance-report.md`; it won't write another while one is pending. Structure only: a wrong value inside a correctly named section is invisible to it. |

## Usage

```bash
python3 modules/ship-tools/scripts/initiative-index.py projects
python3 modules/ship-tools/scripts/initiative-index.py projects --initiative "Billing rework"
python3 modules/ship-tools/scripts/seed-conformance-check.py
```

`seed-conformance-check.py` takes its ship root from `SHIP_ROOT`, else from its own location.
Run it by hand or from any scheduler; a divergence it reports may be deliberate, so the Mate
accepts or rejects each one rather than "fixing" it.

## Install

Opt-in: `python3 shipkit_init.py --modules ship-tools` (or the `personal` preset). The
installer links the `drops` skill into `~/.claude/skills/`.

## Test

`python3 modules/ship-tools/tests/test_ship_tools.py`
