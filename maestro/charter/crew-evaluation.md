# Crew evaluation — scoring each position from ledger evidence

> The workflow is judged by the gate pipeline; the PEOPLE are judged by this rubric. Every score
> must cite a receipt: a ledger event, a verdict text, a hook-log line, or a commit. No vibes.
> Cadence: after every full-tier task and at least weekly; scorecards live in HQ `knowledge/`.

## Shared mechanics (computed from ledgers — `task-report.sh` gives the base numbers)

| Metric | Source |
|---|---|
| Rounds per task (lower = better dev/spec quality) | `state.json` round counter |
| Catch attribution — who found each defect, at which stage | verdict summaries in `log.jsonl` |
| Escape chain — defects that survived a PASS/APPROVE to a later stage | cross-reference verdicts → later findings |
| Escapes to production | incidents after `task_done` (target: 0) |
| Verify wall-time, guard friction | hook-log + task-report |

## Per-role dimensions

**Faber — developer.** (1) First-round acceptance rate. (2) Regressions introduced per fix round —
especially *spec-shape* regressions (implementing a weaker rule than the GOAL stated). (3)
Edge-case ledger discipline: the ledger must exist **as a task-dir artifact at development time**,
rows honest, applicable rows becoming tests. (4) Self-found defects (finding an adjacent hole
unprompted scores high). (5) Surgical discipline: did the diff stay inside the round's scope.

**Lucia — ui-developer.** Same as Faber, plus: visual/interaction acceptance judged against the
GOAL's user-facing intent, accessibility basics present without being asked.

**Thomas — tester.** (1) Independent evidence rate: verdicts built on OWN fixtures, not re-running
the developer's tests. (2) Real catches per round (post-dev defects found). (3) **Escapes**: defects
a later stage (reviewer, incident, fork) finds after a Thomas PASS — the key counter-metric. (4)
Calibration: FAILs must be real (no false FAILs), PASSes must survive later scrutiny. (5) Honesty
markers: reporting his own probe errors, separating in-scope vs baseline-also-missed.

**Petros — reviewer.** (1) Catches beyond the tester (ship-risk the test lens missed). (2)
**Misses at his altitude**: anything in the shipped diff a later stage finds; also *state-model
errors* (misreading tree/ledger state during review). (3) Severity calibration: BLOCKER vs
SHOULD-FIX vs NIT judged correctly in hindsight. (4) Follow-up quality: deferred items must be
real tasks with rationale, not parking.

**Austin — planner.** (1) Assumption honesty: low-confidence assumptions flagged WITH a
verification plan. (2) **Risk-class coverage**: count the defect classes that ate fix rounds but
never appeared in the plan's risk map. (3) Decomposition quality: did the split ship independently
as designed. (4) Gate-1 usefulness: did the founder decide from the plan alone.

**Gabriel — scout.** (1) Utilization (an idle scout = CTO doing recon inline — sometimes right,
worth watching). (2) Compression quality: does the next agent act without re-reading. (3)
`file:line` receipt accuracy.

**Maestro — CTO (self-score, same rules).** (1) Handoff quality: GOAL stated a rule the
implementation then weakened = handoff failed to pin the load-bearing constraint. (2) Triage
accuracy: tier raised/lowered later = mis-triage. (3) Escalation discipline: round caps and
founder decision points honored. (4) Bookkeeping integrity: ledger events correct (a `done` note
instead of `task_done` is a CTO error).

## Scoring

Per dimension: **strong / adequate / weak** + one-line receipt. No numeric theater — three levels
force a judgment. A dimension with no evidence this period is `n/a`, never extrapolated.

## Tuning loop

Weak dimension → smallest contract change that targets it (a line in the crew .md, a checklist
item, a reasoning-effort setting) → applied as a normal tiered task → next scorecard checks the
same dimension moved. One change per role per cycle — otherwise attribution is lost.
