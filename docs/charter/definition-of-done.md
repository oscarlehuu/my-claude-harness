# Definition of Done

Maestro's Definition of Done is strict and machine-evaluated. Gate 2 approval is necessary, but it is
not enough to override failed checks or ambiguous reviewer output.

## Six checks

A task is done only when all six pass or are explicitly not applicable:

1. **Plan approval** — Gate 1 was approved by the founder.
2. **Per-round command gates** — the latest per-round command gates passed, or `n/a` because none ran.
3. **Tester judgment** — the latest tester verdict is `PASS`; `FAIL`, `PARTIAL`, `BLOCKED`, or missing
   is not done.
4. **Pre-ship command gates** — declared pre-ship command gates passed, or `n/a` because none ran.
5. **Reviewer gate** — if a pre-ship reviewer judge gate is declared, the latest reviewer verdict must
   cleanly be `APPROVE`. `REQUEST_CHANGES`, missing output, or inconclusive/unknown reviewer output
   blocks done. If no reviewer gate is declared, this check is `n/a`.
6. **Founder ship approval** — Gate 2 was approved by the founder.

## Blocking semantics

`done=true` only when there are no blockers. Each failed check becomes a blocker that keeps the task
out of the `done` state. An inconclusive reviewer verdict is not silently treated as approval: it is
surfaced as a checklist item and blocks commit, because strict DoD requires a clean reviewer `APPROVE`
whenever a reviewer gate is declared.

If Gate 2 is approved while blockers remain, **withhold commit**, keep the task at Gate 2, and report
the blockers. To rerun reviewer work, reject the ship gate with feedback asking for a live reviewer
rerun. **There is no force-ship bypass for strict DoD.**

## Where the checklist is recorded

1. **CTO Gate 2 relay** — state the DoD rationale in conversation before/with the `AskUserQuestion`
   Gate 2 prompt: which checks passed or are `n/a`, that founder sign-off is the only remaining item,
   or that commit is WITHHELD and why.
2. **Ledger** — record a `done_evaluated` entry (`done`, `blockers`, full `checklist`) under
   `.claude/maestro/<slug>/`.
3. **Auto-commit message body** — when a release `commit` action runs, include the rendered
   `Definition of Done:` block in the commit message body.

This makes ship rationale visible to the founder, durable in the task ledger, and attached to git
history when release auto-commit is enabled.
