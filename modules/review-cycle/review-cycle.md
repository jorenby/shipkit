# Module: Review Cycle (maker ≠ checker enforcement)

**Optional policy module.** Core `mate.md` ships the *principle* in one paragraph
("the maker should not be the only checker; significant crew-written work gets an
independent review before commit"). This module is the *enforcement mechanism* — the
concrete gate, the standards doc, and the policy knobs — for operators who want to
run it strictly. A solo or low-rate operator can run core with a lighter touch; a
team running hot will want the full gate.

## Why it's a module, not pure core

The maker≠checker principle is a strong loop-engineering antibody against
comprehension debt — code lands without its author's blind spots shipping with it.
But *enforcing* it has a real cost: every reviewed diff is an extra reviewer pass
(time + tokens). Whether you pay that cost on every crew diff, only on significant
ones, or gate it by rate is a **policy choice**. Core states the principle; you pick
the policy here.

## The two rules

**Maker rule (Mate judgment).** A quick/bounded change → the Mate does it inline. A
significant change (net-new logic, multi-file, customer-facing) → **dispatch a
crew** — don't hand-write significant code as the Mate. (The point of the gate is
that significant work is *crew* work, and crew work gets reviewed.)

**Review gate.** Any **crew-written code, before the Mate commits/pushes it, gets an
independent non-maker review**:

1. Dispatch a **`ship-reviewer`** (read-only, hook-blocked from `gh`/git writes)
   that is **NOT the maker crew**, against the uncommitted diff.
2. The reviewer checks (a) **correctness** and (b) **conformance to your standards
   doc** (`review_standards` in `mate.local.md`).
3. The Mate addresses findings — quick fixes inline; needs-rework → back to a crew —
   **then** commits/pushes.
4. The Mate's own quick edits don't need the gate (significant work is a crew
   dispatch → reviewed; trivial Mate edits aren't "significant").

The reviewer model is a pref (`review_model`, default a strong model — a weak
reviewer is a weak gate). Where a fast model *was* the implementer on a watch,
pairing it with a strong-model reviewer is the corollary that keeps quality up.

## A review that isn't reported didn't happen

The reviewer's job isn't done when it forms a verdict — it's done when the verdict
**reaches the Mate.** A reviewer that finishes its analysis and goes idle **without
sending its findings back** has silently stalled the gate: the Mate is waiting on a
verdict that will never arrive, and the natural failure is that the Mate eventually
gives up waiting and commits *un-reviewed* — the exact thing the gate exists to prevent.
This is the same failure shape as an autonomous heartbeat that surfaces nothing on its
return channel: **work with no return channel is work that didn't happen.**

Two defenses, both cheap:

- **Bake "report or you didn't review" into the reviewer dispatch.** The reviewer's
  orders must end with an explicit instruction to send the verdict back (a message to the
  dispatching Mate / a written verdict at a known path), framed as the *deliverable* — not
  a nicety. "LGTM" held only in the reviewer's head is not a passed gate.
- **The Mate must not commit on silence.** If a dispatched reviewer goes quiet, the Mate
  **nudges it** (a direct message asking for the verdict) rather than treating no-news as
  good-news. On the live ship this exact miss happened — a reviewer formed a full verdict
  and idled without reporting; a nudge recovered the complete report. Silence is a prompt
  to poke, never a green light.

## Browser-verify gate for UI work (curl proves contracts, not paint)

Code review + a `curl` check prove the **contract** — that the server returns the right
bytes, that a POST writes the right file. They do **not** prove the **rendered result**:
whether the page actually paints, whether an interaction works on a real device, whether a
CSS rule silently blanks the feed. A whole class of UI defects is invisible to both the
reviewer's diff-read and a headless request — and they ship anyway unless something *looks
at the page*.

So for any change to a browser-facing surface, add a **browser-verify gate** on top of the
code review, before declaring the change live:

- **Load the changed page in a real browser** — the Mate via a browser-automation tool, or
  a browser-capable crew (the `ship-pilot` type; Captain-authorized). Not curl, not a
  contract test — an actual render.
- **Exercise the changed feature end-to-end** in that browser: click the button, submit the
  form, install the PWA, toggle offline — whatever the change touches.
- **Never test-write real state.** When the interaction has a write path (a steer box, a
  form POST), point the server at a **scratch ship-root** (a throwaway `SHIP_ROOT`) so the
  test doesn't mutate the live thread / queue / drops. Verify the write landed *in the
  scratch tree*, then tear it down.
- **Screenshot at least once.** The screenshot is the evidence the page paints; it's the
  one artifact a code review can't produce.

Why this earns its own gate: on the live ship a UI watch passed code review clean and
shipped four browser-only defects at once — a CSS `content-visibility` rule that rendered a
blank feed (zero paint on 600+ live DOM nodes), a strict file-picker `accept` list that
silently dropped iPhone photos, a `scroll-behavior:smooth` rule that hijacked programmatic
scroll so the app opened at the wrong end, and an optimistic-send reconcile race. All four
were invisible to curl and to the diff; all four surfaced in a single browser session.
**curl proves contracts, not paint.** (A headless smoke test — e.g. Playwright — is a
reasonable future automation of this gate, but the gate itself is the standing rule.)

## Policy knobs (`mate.local.md`)

```
review_policy:    off | significant-only | all-crew-code-every-time | rate-gated
review_model:     <the non-maker reviewer model>
review_standards: <path to your crew-code-standards doc>
```

- **`off`** — run core's principle as judgment only, no enforced gate. Fine for a
  solo operator who reviews their own dispatched diffs by hand.
- **`significant-only`** — gate net-new-logic / multi-file / customer-facing diffs;
  skip trivial crew changes.
- **`all-crew-code-every-time`** — every crew diff gets a reviewer pass before
  commit. The strictest, highest-assurance setting.
- **`rate-gated`** — full gate when capacity is abundant, relax toward
  significant-only when rate-pressured (pairs with the dispatch-bands module).

## The standards doc

The reviewer checks crew diffs against a standards doc you maintain (e.g.
`docs/knowledge/crew-code-standards.md`): your conventions, comment economy,
test expectations, "load-bearing comments only," and any house rules. Keeping it a
separate doc (rather than inline in the reviewer prompt) lets it evolve and lets
both crew (as guidance) and the reviewer (as a checklist) reference the same source.

## Applying crew work cleanly (commit hygiene)

The gate ends with the Mate committing the crew's diff. Two hazards at that seam, both
learned the hard way:

- **Never `git add -A` while a crew is still editing the shared checkout.** Crew and Mate
  can share one working tree; a blanket `git add -A` (or `git add .`) sweeps in whatever
  the crew has half-written mid-edit, committing a partial or unrelated change under the
  Mate's name. **Stage surgically** (name the files you reviewed) or **isolate the crew in
  its own worktree** so the Mate's staging can't collide with a live edit. When you dispatch
  parallel crew against overlapping paths, worktree isolation isn't optional.
- **Apply files, not a branch, from a stale worktree.** A crew that branched from an old
  base may have authored *correct* files against current `main`'s content while sitting on a
  stale branch — merging that branch wholesale drags `main` backward. When a crew flags "I
  authored against main, my worktree base is stale," **copy the reviewed file contents onto
  a fresh branch off current `main`** rather than merging the crew's branch. Read the crew's
  handoff for this flag; it's a load-bearing distinction the log will call out.

## Where it plugs into core

Core's **Reviewing Completed Watches** step 3 is the hook: "before committing
crew-written code, dispatch a non-maker `ship-reviewer` against your standards +
correctness; address findings, then commit." That step is a no-op when
`review_policy: off` and the full gate when `all-crew-code-every-time`.
