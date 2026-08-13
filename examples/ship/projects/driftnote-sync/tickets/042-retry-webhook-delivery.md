# 042: Retry failed webhook delivery

**Status:** in-review
**Source:** Captain (2026-07-23) — three support tickets this week reporting missed sync notifications
**Branch:** 042-retry-webhook-delivery
**Goal:** Failed outbound webhook deliveries get retried with backoff instead of silently dropped.

## Acceptance
- [x] Reproduce the drop: confirm webhook POSTs aren't retried on non-2xx response
- [x] Add retry with exponential backoff (3 attempts, 1s/4s/16s) for failed deliveries
- [x] Failed-after-retries deliveries are logged, not just swallowed
- [x] Tests cover the retry path and the give-up-after-3 path
- [ ] Captain reviews and merges [driftnote-sync#118](https://github.com/lumen-craft/driftnote-sync/pull/118)

## Current state
Implementation complete and tested locally. `WebhookDelivery#send` now wraps the POST in a retry loop (`lib/webhook_delivery.rb`), logging each failed attempt and a final `webhook_delivery_exhausted` event if all three attempts fail. Full test suite passes. PR #118 opened as a draft, waiting on Captain review — small diff, one file plus tests, should be a quick read.

## Blocked on
Captain review of PR #118. No other blockers.

## Watch history
- **2026-07-25-1430** - [Log](../../../logs/driftnote-sync/042-retry-webhook-delivery/2026-07-25-1430.md) - Implemented retry-with-backoff, added tests, opened draft PR
