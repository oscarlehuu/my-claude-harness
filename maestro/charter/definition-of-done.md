# Definition of Done

Maestro's Definition of Done is **tier-aware and machine-evaluated**: `task-status.sh` renders the
checklist from the ledger by code (not by the model's discipline), and `commit-gate` blocks a
`git commit` whose tier requirements are not recorded. Gate approval is necessary, but it never
overrides failed checks or ambiguous reviewer output.

## Checks by tier

| Check | direct | light | standard | full |
|---|---|---|---|---|
| Verify command green (recorded by `task-verify.sh`, exit code = ground truth) | ●¹ | ● | ● | ● |
| Tester verdict `PASS` | – | – | ● | ● |
| Plan approved (Gate 1) | – | – | – | ● |
| Reviewer cleanly `APPROVE` | – | – | – | ● |
| Founder ship approval (Gate 2) | – | –² | ● | ● |

¹ enforced by the `stop-dod` hook when a verify command is configured — a turn cannot end with code
changed after the last green verify.
² light tasks report done with a diff summary; commit happens on founder ask or a release gate, and
`commit-gate` re-runs verify regardless.

## Docs are a deliverable, not an afterthought

A change that alters **user-visible capability or the operating protocol is not done until its docs
are updated in the same task** — docs are a named deliverable the tester gates, exactly like code (a
missing or stale named doc deliverable is a FAIL of the same weight). This is the forcing function:
discipline alone let README drift while the test-gated lists stayed synced, so docs are now woven
into the steps that already run — a dimension of the planner's blast radius, a deliverable the
developer writes in-round, a thing the tester judges, and (for the structured name-lists) a
mechanical `doc-drift` check.

Which doc a change owes — the taxonomy the planner and the GOAL handoff point to:

| Change | Doc to update | Who writes it / how it's gated |
|---|---|---|
| capability / user-visible behavior | `README.md` | developer in-round → tester + `doc-drift` (structured blocks) |
| protocol / playbook change | `maestro/SKILL.md` | developer in-round → tester |
| new script / hook / crew member | `AGENTS.md` lists (+ `README.md` map) | `doc-drift` (mechanical name check) |
| rule / policy change | `AGENTS.md` contract · `maestro/charter/` | **CTO-drafted + founder-discussed at the decision stage — NEVER auto-written by a developer as a side effect** |
| architectural decision | `docs/` decision log | developer/CTO in-round — **conditional**: only on a genuine architectural decision, not every task |

The policy-doc row is load-bearing: the contract and this charter are policy artifacts. A developer
never edits them as a by-product of a feature — they change only through the Gate-1 / co-design
decision stage, drafted by the CTO and discussed with the founder. The other rows are ordinary
per-round deliverables the developer executes.

## Blocking semantics

`done` requires every check the tier demands to pass or be explicitly `n/a`. Each failure is a
blocker that withholds commit:

- A non-zero verify exit is FAIL regardless of any opinion; nothing overrides it into success.
- A new dev round (`task-record.sh round_started`) **invalidates previous verdicts** — they judged
  the old diff. The tester/reviewer must re-judge before commit.
- An inconclusive or missing reviewer verdict at full tier is not silently treated as approval — it
  blocks, and the fix is a live reviewer re-run.
- If Gate 2 is approved while blockers remain, **commit is withheld** and the blockers are reported.
  **There is no force-ship bypass.**

## Where the checklist is recorded

1. **Gate 2 relay** — the CTO pastes `task-status.sh` output (the rendered checklist + blockers)
   before the AskUserQuestion prompt.
2. **Ledger** — `.claude/maestro/<slug>/state.json` holds the latest verify/tester/reviewer state;
   `log.jsonl` holds the full event history.
3. **Commit message body** — when a release `commit` action runs, include the rendered checklist.

This makes ship rationale visible to the founder in conversation, durable in the task ledger, and
attached to git history.
