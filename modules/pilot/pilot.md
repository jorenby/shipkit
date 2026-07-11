# Module: Pilot (browser-interaction crew)

**Optional (opt-in). For watches that need a real browser** — screenshots, UI
verification, form testing, anything where "curl proves contracts, not paint." This module
ships the **`ship-pilot`** worker agent: standard crew tools + git-safety hook, *plus* the
`claude-in-chrome` MCP tools for browser automation.

## Why it's a module, not core

`ship-pilot` has a **hard external dependency** on the `claude-in-chrome` MCP server, which
most installs lack. Rather than ship a broken agent def in core, the pilot lives in its own
opt-in module: install it only where the Chrome MCP is available (`--modules pilot`), and
even then **dispatch it only when the Captain explicitly authorizes browser access**. Not in
any preset — request it deliberately.

## What it installs

- `agents/ship-pilot.md` — the pilot standing orders (browser-navigation discipline: get tab
  context first, avoid dialog-triggering actions, save screenshots to the orders' path, stop
  on repeated tool failures).

It carries **no hook of its own** — the pilot reuses core's crew-safety Bash hook
(`core/hooks/validate-crew-bash.sh`, same git/queue bright lines as `ship-crew`). So this
module `requires` only `core`.

## Dispatch

The Mate dispatches a `ship-pilot` (background, per `subagent-roster`) only after the Captain
authorizes a browser watch; the watch orders name the pages/URLs (local-dev domains for
cookie/session handling) and what to capture. The **browser-verify gate** for UI work lives
in the [review-cycle](../review-cycle/review-cycle.md) module.
