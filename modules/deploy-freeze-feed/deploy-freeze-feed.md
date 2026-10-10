# Module: Deploy-Freeze Feed

**Optional. For ships whose product has a deploy pipeline with an alert channel.** An
out-of-session sensor for one failure mode: a critical deploy alert fired, nobody
acknowledged it, and work kept landing behind a frozen pipeline.

## How it works

`deploy_freeze_feed.py` polls a **signal snapshot file** (default
`~/.ship-sensors/deploy_freeze_signal.json`, override `DEPLOY_FREEZE_SIGNAL_PATH`). When the
snapshot says a critical condition is unattended, the feed writes a candidate drop into
`inbox/drops/` and classifies it through `lib/classify_input.py`:

| Observation | Drop | Class |
|---|---|---|
| First sight of an incident | `kind: steer` | `wake` |
| Same incident, earlier drop still unconsumed | none | — |
| Same incident still open after the drop was consumed | `kind: sensor-redrop` | `batch` (no re-nag) |
| Signal clears | none; the incident is forgotten, so a later refire wakes again | — |

File count stays bounded: one unconsumed drop per open incident. State (open incidents and
their drop names) lives outside the ship tree at `~/.ship-sensors/deploy_freeze_feed_state.json`
and is written atomically.

## The signal file is yours to produce

The feed ships the mechanism, not a binding to any particular chat or CI system. Point
whatever already watches your deploy alerts (a CI status poll, a chat-channel watcher, a
pager webhook) at the snapshot file:

```json
{
  "critical_unattended": true,
  "incident_id": "deploy-freeze-1",
  "channel": "#deploy-alerts",
  "condition": "main not deploying; backlog building",
  "fired_at": "2026-06-28T14:00:00Z",
  "link": "https://example.com/alert/1"
}
```

Only `critical_unattended` is required. Without `incident_id`, identity is a hash of
`channel`, `condition` and `fired_at`. Write `{"critical_unattended": false}` (or remove the
file) when the condition clears.

## Run

`python3 modules/deploy-freeze-feed/deploy_freeze_feed.py` polls every 60 s
(`DEPLOY_FREEZE_POLL_SECS`). Run it under launchd, systemd or `nohup`; it pairs with the
`wake-monitor` module, which wakes the event-driven Mate on the `wake`-class drop.

## Test

`python3 modules/deploy-freeze-feed/tests/test_deploy_freeze_feed.py`
