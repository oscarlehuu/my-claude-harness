# The retro loop — tune components, not people

> Goal: continuous improvement of prompts, contracts, and workflow from real-usage evidence.
> The unit of analysis is the DEFECT, never the role: crew members are freshly-instantiated
> components — there is nobody to grade, only prompts and rules to patch. "Fairness" here means
> one thing: **attribution accuracy** — root-cause to the right component.

## The rubric is the contract

There is no separate scoring rubric. Every finding is judged against the rules that already
govern the work: the GOAL-handoff template, the tier DoD, each crew member's contract, the
company conventions. A defect either shows a contract line that FAILED (patch the component)
or a contract line that is MISSING (propose it). The criteria grow one line at a time, through
the normal flow: machine proposes, founder nods.

## Evidence rules (what makes retro possible)

1. **Verdicts are persisted verbatim.** The moment a judge's report arrives, the CTO saves it
   unedited to `.claude/maestro/<slug>/verdicts/round-<N>-<role>.md` — BEFORE recording the
   one-line summary via `task-record.sh`. The summary is the CTO's words; the file is the
   evidence. Drift between the two is itself a finding about the CTO.
2. **Lessons are recorded as they happen, WARM.** Anything that costs a round, blocks wrongly,
   breaks, or reveals a CTO error → `task-record.sh lesson summary="<what happened> + <suspected
   component>"` on the relevant task. This is the SINGLE learning store — the continual-learning
   process feeds the exact same `lesson` events (the crew emit durable learnings warm in their
   structured output; the CTO records them here; the consolidator later routes them). There is no
   parallel learning file. Cross-task observations wait for the retro itself.

## The loop

1. **Trigger:** after every full-tier task, and at least weekly.
2. **Run:** a fresh-context, read-only pass (today: the planner; never an agent who worked the
   tasks under review) over ledgers, verdict files, lessons, hook-log, and diffs — NOT the
   conversation. It root-causes each lesson/fix-round/escape to exactly ONE component:
   a crew prompt, the GOAL-handoff template, a hook, a script, a contract/convention line.
3. **Output:** a patch batch — per component at most ONE smallest change that targets the root
   cause, each with its receipt. Plus the health dials from `task-report.sh` (rounds/task,
   catches by stage, escapes, guard friction) read as trends, not grades.
4. **Decide:** the founder nods/edits the batch (policy artifacts always; mechanical patches may
   be pre-approved in bulk).
5. **Patch:** each approved change lands as a normal tiered task.
6. **Close the loop:** the next retro re-checks exactly the dimensions patched last cycle —
   did the defect class stop recurring? One change per component per cycle, or attribution is lost.

## Boundaries

- Retro never blocks shipping — it runs beside the pipeline, not inside it.
- Health metrics never become targets (Goodhart): they detect drift, they don't rank anyone.
- Per-role scorecards stay retired unless a comparison question genuinely needs them
  (two prompt variants, effort levels) — then build the comparison, not a grading culture.
