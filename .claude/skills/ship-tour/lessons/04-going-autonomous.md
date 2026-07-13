# Lesson 4 — Going autonomous (a guided transition)

*The tier bump, walked: what the autonomous shape is, the clean delta that installs it,
and the first event-driven boot.*

**The idea to land.** Autonomy is **additive, not a different ship**. Everything from
lessons 1–3 stays true; the tier bump adds two long-running role agents so the ship works
*between* the Captain's visits. The shape is a deliberate split: the **Bosun** owns the
heartbeat — a read-only loop of curate/reconcile sweeps that *surfaces* findings but
decides nothing — and the **Mate** becomes **event-driven**: it boots once, idles, and
wakes only when something happens (a Captain drop, a crew completion, a Bosun finding).
Nobody burns context polling. And the bright lines from lesson 3 don't loosen when the
human steps back — they tighten: the autonomous Mate's `never` list is enforced by its
own hooks, a structural backstop for exactly the moment no one's watching.

**Before walking it, ask the honest question:** does the operator *want* a ship running
between visits? Core is complete, not a trial version. If the answer is "not yet," this
lesson keeps — that's the design.

**Walk it** (the transition is `/shipkit-setup`'s tier-bump path — you narrate, it applies):

1. **Preview the delta.** From the ship dir:
   `python3 shipkit_init.py --preset autonomous --ship-root . --dry-run`
   Read the plan together: two new role agents (`ship-mate`, `ship-bosun`), the
   autonomous doctrine docs, hooks, mate-lock, launchers, the wake-monitor. Note what's
   *not* in the plan: everything already installed is untouched — a tier bump is a pure
   delta.
2. **Apply and verify.** Run it for real, then the setup skill's one-screen verify (no
   `FAIL` lines, no literal `{SHIP_DIR}` in the agent defs). Act on any prior-install
   findings the report raises. Then **restart Claude Code** — the session that installed
   the defs can't see them.
3. **Boot the event-driven Mate.** In the fresh session: `/ship-watch-start`. Narrate
   what it does as it goes: re-anchor → mate-lock (single instance) → arm the
   wake-monitor → bootstrap the Bosun → preflight → **idle**. Idle is the success state,
   not a stall — prove the ship is alive with `tail state/bosun-heartbeat.log` (the
   Bosun, ticking).
4. **Trigger one wake.** Have the operator drop a line into `inbox/captain.md` and watch
   the cycle: wake → handle that one event → reconcile → back to idle. That loop is the
   whole autonomous rhythm; everything else is doctrine detail.
5. **Sandbox, seriously.** For an agent that runs unattended and writes, the sandbox +
   credential/filesystem scoping IS the security boundary — the hooks are fail-loud
   guardrails against accidental violations, not a container (lesson 3). Run the
   background agents sandboxed (on macOS, agent-safehouse.dev; launch via
   `modules/autonomous/scripts/ship-up.sh`, which resolves a sandbox wrapper if present).

**Point at:** `modules/autonomous/mate-event-driven.md` (the event-driven doctrine),
`modules/autonomous/bosun.md` (the heartbeat's standing orders), `core/mate.md` →
"Event-Driven Mode" (the short inline version).

**Next:** Lesson 5 — staying current: keeping your ship in sync with upstream shipkit
without losing a single local edit.
