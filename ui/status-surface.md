# Module: Status Surface (TIER 3 — ui)

The status-surface is shipkit's reference browser console: a PWA that renders
`state/status.json` and offers a steer box. It is **tier 3** — it sits on top of the
autonomous kernel (tier 2), which produces the `status.json` it reads.

> **The implementation files live on the stacked UI PR**, which fills this `ui/` folder
> (`server.py`, `index.html`, the icons, `_make_icons.py`, and the surface README). This
> `ui/` folder + its `module.json` reserve the tier slot in the manifest/preset system so
> `--preset ui` resolves; the UI PR adds the actual files here.

## What it consumes (the contract, not the code)

- **`state/status.json`** — rendered live. The field contract is [../lib/status.schema.md](../lib/status.schema.md);
  the UI renders the contract and never imports the writer Python.
- **`inbox/drops/`** — the steer box writes a drop here; `lib/classify_input.py` routes it
  to a `wake`-class item the Mate's wake-monitor picks up.

This makes the UI a **runtime-orders-after** dependency on the autonomous tier (a
`status.json` must exist to render), expressed as `requires: ["autonomous"]` in `module.json`.
Frozen contract, disposable render: swap the render surface freely as long as it reads the
schema and writes well-formed drops.
