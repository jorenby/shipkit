# Skill evals

Behavioral eval cases for the ship's role doctrine. Each case is a directory with:

- `prompt.md`: the scenario, given to the model under test (with and without the role doc or skill loaded).
- `graders/*.md`: one rubric per behavior, each scored PASS/FAIL by a separate grading model reading the transcript.

| Case | Seat under test | What it checks |
|---|---|---|
| `01-dispatch-readiness-bar` | Mate (`core/mate.md`) | A Ready-looking but unshaped ticket is held back, and the gap is surfaced rather than silently parked. |
| `02-captain-facing-communication` | Mate or Navigator | A status message leads with the one item that needs the Captain and names work in plain English, not by ticket number. |
| `03-staying-in-shaping-seat` | Navigator (`modules/navigator`) | An advisory seat pauses and asks before making even a one-line edit. |

There is no runner in this repo. Run a case by giving `prompt.md` to a fresh session in each arm (doctrine loaded vs. not), then hand each transcript plus one grader file to a grading model. Graders that inspect tool calls (`holds-tools-not-just-words.md`) need the full transcript, not just the final message.

Add a case when a doctrine rule is worth protecting against regression: write the scenario so the wrong behavior is tempting, and keep each grader to one observable behavior.
