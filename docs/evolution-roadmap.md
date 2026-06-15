# Evolution Roadmap — Maestro

Status: design locked with the founder 2026-06-15. Source of this work: a study of the private
`claudekit/claudekit-engineer` harness (the `plan` → `cook` skill family) to learn its mature
prompt-craft and its phase-decomposition model, then adapt only what fits Maestro — without
importing its anti-patterns. This doc is the source of truth for the slate below; execute items
one at a time, each as its own ledger task.

> The claudekit clone studied was ephemeral (`/tmp`). All learnings worth keeping are captured
> inline here; re-clone `gh repo clone claudekit/claudekit-engineer` if deeper detail is needed.

## Guiding principle

Maestro's **stance and architecture are already ahead** of claudekit (executable ground truth +
fresh-context adversarial judges + code-enforced gates). Maestro reads "generic" in exactly one
layer: **PRINCIPLE → CHECKABLE.** We say "verify with real calls / avoid slop / judge
adversarially" (principles); claudekit says "re-grep don't copy · 8 binary boxes · 40 named slop
fingerprints · a cheat taxonomy" (mechanics). The whole slate is: **turn principles into named,
checkable lists — and keep enforcement in code (hooks/scripts), never prose.**

Two standing rules for every adaptation:
- **Steal mechanics, keep our architecture.** Where Maestro already has a hook (`verify`,
  `commit-gate`, `stop-dod`, guards), a claudekit prose `<HARD-GATE>` is a *downgrade* — do not
  substitute prose for a hook. Add checklists as a prevention layer *on top of* the hook that
  catches, never as the gate itself. Prevent + catch beats either alone.
- **Don't cargo-cult.** See "Anti-patterns" at the end — a deliberate do-not-adopt list.

## Locked design decisions

### 1. Phase-decomposition layer

The missing layer between planner and developer. A whole-project handoff today is one giant GOAL
to one developer run (un-resumable monolith). The fix:

- **A phase = a persistent GOAL handoff + a status checkbox.** Each `phase-NN-*.md` carries
  Overview / Requirements / Architecture / Related Files / Implementation Steps / **Success
  Criteria** / Risk + frontmatter (`status: pending|in-progress|done`, `dependencies`). It IS a
  ready-to-dispatch GOAL handoff (Maestro already defines that shape).
- **Granularity rule (inverts claudekit's bias).** claudekit treats ">3 phases" as a merge smell
  (`scope-challenge.md`) — that is the bug that caps its plans at ~5-6 phases regardless of scope.
  Our rule: *each phase = one coherent, independently-verifiable, solo-executable unit, sized so one
  developer run completes it with its own acceptance test.* Decompose until each phase meets that
  bar. Phase **count is an output**: a project yields 10-20, a feature 3-6. Never force a number;
  never merge to hit a ceiling. Guardrails: a phase with >1 verifiable deliverable or too-wide
  reach → split; a phase with no independent acceptance → it is not a phase, merge it.
- **The checkbox strip = progress AND resume point.** Closes the implementer-resume gap: if a
  developer dies mid-phase, done phases are `[x]`, the dying phase is `in-progress`; resume =
  re-dispatch that phase's self-contained file (+ its `git diff`). True resume, not reconstruct.
- **Gate cadence (avoid N full gate cycles):** scoped-verify EVERY phase (cheap, = the done/resume
  signal); tester on risky phases + one final whole-plan pass; reviewer once pre-ship. Two-level
  DoD — phase-DoD = verify; plan-DoD = all phases `[x]` + final tester/reviewer + Gate 2.
- **Trigger:** a *mode of full tier* for project/large handoffs — not a 5th tier. Small tasks keep
  the single-GOAL flow (phasing a 3-file task is over-decomposition).
- **Parallelism:** sequential first; independent phases (per the dependency graph) run concurrently
  in worktrees under the WIP 2-3 limit as a later phase, once the sequential spine works.
- **Touches:** `planner.md` (emit N phase files + granularity rule), `task-record.sh`
  (`phase_started`/`phase_done` events), `task-status.sh` (render k/N + two-level DoD),
  `developer.md` (consume one phase file as GOAL), a `task-plan.sh` (or extend `task-init`) for
  scaffolding. Maps claudekit's `project-management`/sync-back role onto our ledger.

### 2. Open-Questions gate (invariant)

No load-bearing unknown may flow into planning/implementation. Today this does not exist: open
questions live as scattered prose (blind-mode assumption ledger `SKILL.md`, planner Assumptions,
runtime `NEEDS DECISION`) and **nothing enforces emptiness**. This promotes blind-mode's
assumption-routing into a universal, persisted, code-enforced gate.

- **Cost-gated, not all-or-nothing.** Tag each question by resolver (reuse blind-mode routing
  `code|history|founder|team`) AND `cost-if-wrong`. Resolution routes:
  - `code|history` → CTO/scout MUST resolve + cite (hard, before planning — scout-first).
  - deep-technical → route to the planner (it is the plan's job, not a blocker).
  - `founder|team` AND **high** cost-if-wrong → **hard-block** (the gate with teeth).
  - `founder|team` AND low/medium cost → **default + veto** (assume-unless-vetoed, blind-mode style).
- **Tie-breaker:** torn on high vs low for >10s → treat as high → block. (Mirrors the tier ratchet.)
- **Scout-first precondition** keeps the gate from becoming a crutch: the CTO must resolve by
  investigation first; only genuinely founder-decidable questions route to the founder, and only
  high-cost ones block. (Honors me.md: "bring decisions, not progress"; "don't ask what grep answers.")
- **Enforcement:** canonical `.claude/maestro/<slug>/questions.json` (`text · route · cost ·
  status: open|resolved|answered · resolution/cite`); `task-record.sh question add|resolve`;
  `task-status.sh` reports a blocker while any `open` (or any high-cost `founder` not `answered`)
  remains; the CTO cannot `gate1_approved` / cannot dispatch the planner with the sheet unclean. A
  new DoD line — empty (of what matters) or no downstream.
- **Placement:** checked at every commit-to-expensive-work boundary — scout→planner (new) AND
  Gate 1 (planner→dev, exists; add one DoD line).

### 3. Scout-first (scale-conditional)

Today the planner self-grounds; scout (Gabriel) is blind-mode/optional, not a pre-plan stage.
Make scout-first standard **for project/large handoffs** because it is the natural *producer* of
the Open-Questions ledger: Gabriel recon → emits `## Open Questions / Not Found` → populates
`questions.json` → the gate drains it → the planner plans on solid ground. Cheap (sonnet) recon
feeds the expensive (opus) planner so the planner spends tokens reasoning, not searching. Keep it
optional for contained full-tier (the planner self-grounds fine). The planner re-verifies
load-bearing facts anyway (its new "re-grep, scout goes stale" rule), so scout is a fast map +
question-surfacer, not trusted fact.

### 4. Plan red-team (full/project)

Adversarial review of the *plan/decomposition* BEFORE building — catch a wrong approach or a bad
20-phase breakdown at the cheapest point. A fresh-context adversarial pass on the plan just before
Gate 1. Reuse Petros (reviewer) in a red-team mode — no new crew member.

### 5. Security red-team (conditional on surface)

A proactive attack-surface enumeration that fires ONLY when the task touches a security surface
(auth/payments/crypto/secrets/PII/public-API — already the full-tier protected triggers). Not a
universal stage (the tier ladder + Petros's security dimension handle the common case). Evidence
this pays off: this session's 3 security bugs (denylist path-scope, case-insensitive bypass,
secrets-scrub gap) were found *reactively* by the tester over 5 rounds; a proactive
"enumerate denylist bypass vectors: case · path-traversal · encoding" pass would have surfaced them
up front and collapsed rounds. Security red-team = shift-left for security. Reuse Petros in a
security-attack mode.

## Prompt-craft slate (per crew — turn principles into checkable lists)

Each is a small, independent prose upgrade to one crew contract (+ maybe a test). Concrete ADOPTs
distilled from the claudekit study:

| Crew | ADOPT (concrete) |
|---|---|
| **Austin** (planner) | A "Verification discipline" block: re-grep don't copy (sources go stale) · cite `file:line` or tag `[UNVERIFIED]` · enumerate callers, never "all callers" (>10 → first 10 + total) · trace control flow for any "X calls/runs-before Y" claim · grep instantiation sites + classify lifetime before adding state. Plus numeric scope tripwires (>8 files / >2 new modules → name why). |
| **Faber** (developer) | A binary "Definition of Done — self-check" block (every error path handled · external input validated at boundary · no correctness-blocking TODO · verify run green · diff re-read vs edge-case ledger). Name the **contract-stability surfaces** explicitly (signature · exported type · API response shape · DB schema · env var · config key) + walk callers of any changed signature. Per-file compile, not end-only. One anti-rationalization line (named excuses → rebuttal). |
| **Thomas** (tester) | Name `.skip`/`xit`/commented-out/tautology-assertion as an explicit cheat class. A pre-flight compile/typecheck gate (a non-compiling diff is FAIL before the edge-case hunt). Diff-map pitfalls (barrel/`index.ts` = high fan-out → full; `fixtures/`/`mocks/` = config → full; renamed files → `git diff --name-status` R). Anti-tautology ("does the demanded test fail on the old code?"). |
| **Petros** (reviewer) | A named review-dimension checklist (concurrency/atomicity · error boundaries · trust boundaries/authz/secrets · input validation · contract stability · N+1/unbounded). An explicit suppressions / nit-floor list (don't flag: readability redundancy, consistency-only, already-fixed-in-diff, style→linter). A findings schema: severity + `file:line` + one-line problem + one-line fix-direction; nits separate; explicit empty form. |
| **Gabriel** (scout) | Add an `## Open Questions / Not Found` section to the output schema (this also feeds the Open-Questions gate). A one-line fact-vs-inference rule (every claim is a `file:line` fact or tagged `(inferred)`). A thin read-budget heuristic (grep-locate then read the span, not whole files — use Read offset/limit, never `cat`/`sed`). |
| **Lucia** (ui) | An AI-slop self-check gate (~8 boxes: not only Inter/Roboto · no default purple/blue gradient · no 3-equal-card row · off-black not `#000000` · organic names/numbers · no "Elevate/Seamless" copy · skeleton not bare spinner · hover+active+focus present). A greenfield "commit to an aesthetic direction first" clause offering luxury-leaning archetypes (Editorial Luxury ≈ the founder's taste). A short premium-pattern cue list (tinted shadows · concentric radii · true glass · tactile press · staggered reveal). A reasoned visual self-critique (judge beauty, not just that it builds). |
| **All crew** | Report hygiene (concision + "unresolved questions / NEEDS DECISION last"). **LLM-as-Judge bias armor** for Thomas + Petros (named: position/length/verbosity/self-enhancement bias — longer ≠ better) — directly hardens our same-model-judge bet. Audit each persona one-liner for a battle-scar (Faber is the exemplar). |

Plus: **lazy-load** — route the heaviest SKILL.md detail (blind mode, continual learning) into
`charter/` loaded on demand, to cut always-on token cost. Apply to SKILL/crew detail only — the
global-load of the AGENTS.md contract is intentional, leave it.

## Where Maestro already leads (keep, do not regress)

- **Faber's edge-case ledger** (enumerate → watch-it-fail → self-review, a persisted artifact) is
  more concrete than anything in claudekit.
- **Thomas is an adversarial intent-judge**; claudekit's "tester" is a QA-runner (run suite, measure
  coverage %). We are far ahead on judging.
- **Petros's ground-check-first** (git/ledger state, "the anomaly is the live incident") — no ck
  equivalent.
- **Hooks > prose:** exit-code ground truth beats `<HARD-GATE>` prose you can talk past.
- Read-only judge firewall, `opus[1m]` judges (ck uses haiku), no coverage-% gaming, single
  orchestrator (no per-agent "Team Mode" boilerplate).

## Ordered roadmap

Founder chose to ship these **separately** (each its own ledger task). Order = value descending;
#1 is grounded in this session's measured round-cost.

**Status (2026-06-15):** items 1-6 (the prose-craft slate) are DONE — all six crew contracts
upgraded, gated (verify + tester PASS + reviewer APPROVE), committed `ef9c0d6`, and **deployed to
~/.claude**. Lazy-load (6, second half) is deferred into the mechanism waves alongside
consolidator.md hygiene. Items 7-9 remain (each a full build); founder paused after Wave 1 to take
them fresh.

1. **Anti-rationalization + DoD self-check + contract-stability → Faber.** [light] — first; targets
   the green-but-wrong round problem measured this session.
2. **Judge hardening → Thomas + Petros.** [light] — bias armor + cheat-class + checklist/suppressions.
3. **Verification discipline + scope tripwires → Austin.** [light]
4. **Luxury archetype + anti-slop gate → Lucia.** [light]
5. **Open Questions slot + fact/inference → Gabriel.** [light]
6. **Report hygiene + lazy-load.** [light] — light touch across files; batch last of the prose work.
7. **Open-Questions gate** (artifact + gate). [standard/full] — mechanism; pairs with the planner cluster.
8. **Scout-first (conditional) + Plan red-team + Security red-team.** [full] — flow additions.
9. **Phase-decomposition layer.** [full] — the biggest; planner + ledger + dispatch + resume.

Items 1-6 are prose-craft (fast, independent). Items 7-9 are mechanism/flow (planner + ledger +
gates) and naturally cluster; the Open-Questions gate, scout-first, red-team, and phasing all touch
the planner/ledger and should be designed together when their turn comes.

## Proposed unified flow (project/large handoff)

```
triage → scout(recon → Open-Qs) → [Open-Q gate: drain] → planner(decompose N phases)
       → plan red-team → Gate 1
       → per-phase{ dev → scoped verify → (security red-team if surface) → tester(risky) → ✓ }
       → final tester + reviewer → Gate 2 → ship
```
Contained full-tier drops scout-first + phasing + plan-red-team; it keeps the Open-Questions gate
and security-red-team-if-surface.

## Anti-patterns NOT to adopt from claudekit

- **Prose-as-enforcement** — `<HARD-GATE>` markdown that relies on model discipline; our hooks +
  exit codes are strictly stronger. Checklists are a self-check layer on top, never the gate.
- **Minimization / YAGNI bias baked into agents** — a judge that auto-minimizes silently reverses
  founder decisions (collides with `rules/review-audit-self-decision.md`: audits are input to the
  founder, not orders). Keep "build only what the task needs" as a CTO rule, not a crew mandate.
- **Coverage-% as a quality proxy** — invites coverage-gaming, conflates lines-hit with
  behavior-verified.
- **Model down-tiering of judges** (ck runs tester/reviewer on haiku) — we keep `opus[1m]`; catching
  cheats is the hard reasoning task.
- **Tool/skill-soup + per-agent "Team Mode" boilerplate + external-CLI/`repomix` summary crutches +
  `cat`/`sed` chunking** (the last violates house style — use the Read tool).
- **Mandatory doc-artifact production every run · numeric self-confidence scores · reviewer that
  edits/auto-fixes · keyword-based intent detection.**

## Provenance

Crew/skill comparison performed by parallel research agents over the claudekit `agents/` and
`skills/{ck-plan,cook,test,ck-code-review,scout,research,frontend-design,context-engineering}` trees
against `maestro/crew/*` and `maestro/SKILL.md`. The continual-learning loop shipped earlier this
session (`maestro/crew/consolidator.md` et al.) is the live precedent for "the harness improving
itself"; this roadmap turns the same discipline on the harness's own crew prompts and flow.
