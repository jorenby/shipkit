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

## Where it plugs into core

Core's **Reviewing Completed Watches** step 3 is the hook: "before committing
crew-written code, dispatch a non-maker `ship-reviewer` against your standards +
correctness; address findings, then commit." That step is a no-op when
`review_policy: off` and the full gate when `all-crew-code-every-time`.
