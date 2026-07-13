# Lesson 3 — The review gate

*Why crew can't commit, who checks the maker's work, and where the bright lines are.*

**The idea to land.** **Maker ≠ checker.** An agent that writes code is the worst-placed
agent to judge it — and crew-written work that lands without a second set of eyes
accumulates *comprehension debt*: code nobody on the ship actually understands. So Ship
separates the roles structurally. Crew **make**: they write code and logs, and a hook —
not a promise — blocks them from committing, pushing, or touching `queue.md`. A
**non-maker reviewer** checks. The **Mate** commits only after the gate, and the
**Captain** keeps the outermost ring: merges, PR-ready flips, and every word posted
outside the ship happen on the Captain's say-so, never autonomously. Trust here is
layered — and be exact about the layers, because Ship is: read-only agents are
**structural** (the tools simply aren't there); the hooks on writable agents are
**fail-loud guardrails** against accidental violations, not a sandbox (an allowed build
script can do anything the process can); the actual security boundary for unattended
writable agents is the **sandbox + credential scoping**. Guardrails catch mistakes;
the sandbox bounds malice.

**Walk it:**

1. **See the guardrails — live.** Run the hooks' own test suites
   (they need `jq`, same as the hooks themselves — setup already checked it):
   `bash core/tests/test-crew-bash.sh` and `bash core/tests/test-crew-write.sh`. Watch
   what a crew agent is actually allowed and denied: git reads pass,
   `git commit`/`push`/`reset` blocked, `gh` writes blocked, destructive `rm` blocked —
   and direct Write/Edit calls to `queue.md`/`captain.md`/`inbox/` blocked by the path
   guard. Then open one installed agent def (`~/.claude/agents/ship-crew.md`) and find
   the PreToolUse hook lines — the operator should see that the rules are wired into the
   agent itself, not written on a wall.
2. **Run one review.** Take a real diff — the work from lesson 2 if it produced one,
   otherwise any small uncommitted change on the operator's plate — and have the Mate
   dispatch a `ship-reviewer` against it (read-only, enforced; it can't "fix it while
   it's in there," which is the point). Read the findings together; have the Mate address
   what's real and push back on what isn't. *Then* commit.
3. **Name the bright lines.** Read `core/mate.md` → "Autonomy & Bright Lines" with the
   operator, out loud, down to the "Never autonomous, full stop" list: PR
   comments/reviews/approve/merge, tracker and chat messages, customer-facing anything,
   deploys. The Mate drafts; the Captain posts. This is the line that makes it safe to
   let everything *inside* the ship run fast.
4. **Calibrate the gate.** The gate has a cost, so it's a dial, not a dogma: a one-line
   inline fix doesn't need a dispatched reviewer; net-new logic and multi-file changes
   do. The operator's policy lives in `mate.local.md`; the mechanism and its options in
   `modules/review-cycle/review-cycle.md`. Have them set (or consciously accept) their
   default now.

**Point at:** `core/mate.md` → "Maker ≠ Checker" and "Autonomy & Bright Lines",
`modules/review-cycle/review-cycle.md`, `core/hooks/validate-crew-bash.sh` +
`validate-crew-write.sh` (the guardrails themselves — they're readable), and
`DECISIONS.md` for why the layers are drawn exactly there.

**Next:** Lesson 4 — going autonomous: the same ship, running between your visits. Take
it when the request/response rhythm feels solid — there's no hurry; core is complete.
