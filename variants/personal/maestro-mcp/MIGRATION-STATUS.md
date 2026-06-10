# MCP Maestro — migration status & verification

Faithful replica of pi `foreman` as a Claude Code MCP server. Build location:
`my-claude-harness/variants/personal/maestro-mcp/`. Blueprint: `../../docs/mcp-maestro-plan.md`.

## Settled decisions (this migration)

- **Crew = cliproxy HTTP, raw OpenAI completions. NOT the Agent SDK.** Verified live 2026-06-10: a
  trivial call reports ~2065 prompt tokens — cliproxy injects the Claude Code marker itself, so plain
  OpenAI completions draw the interactive **Max quota** (cap-free). This is the founder's verified
  billing decision (plan §4). (The stale `variants/personal/README.md` says "Agent SDK query()" — it
  is superseded by this; crew is raw HTTP.)
- **Agent SDK only at an optional host layer (pimote).** Out of scope here; pimote is a separate
  project, deferred.
- **CTO = interactive `claude` session** (Max quota), relays gates; the MCP server owns the loop.

## Verification strategy (3 tiers — how we PROVE faithfulness)

1. **Live milestone verify** — each milestone ships an executable check under `verify/` that runs the
   real thing against live cliproxy and asserts observable behavior. (M1 done below.)
2. **Pure-module reuse + foreman's own tests (the fidelity anchor).** The decision layer
   (scorer / planner-validation / gates / done / formatIntentContract / teampacket / approvalfriction
   / docdrift / ship / agent-timeouts) is **reused unchanged** from
   `my-pi-harness/extensions/foreman/*.ts`. Running foreman's existing 17 `test/*.sh` against the
   reused modules → green = **byte-identical**, not "faithful". Confirmed runnable 2026-06-10
   (done/scorer/gates green).
3. **Parity tests (orchestrator).** Once `controller.ts` exists, run the SAME task through pi-foreman
   and maestro-mcp and diff: dev-handoff text, Gate-1 payload, DoD checklist, ledger events, ship
   decision. Diff empty = faithful. Plus the 12 NEVER boundaries (foreman INTERNALS §09) ported as
   assertions.

## Milestones

| # | Goal | Status | Verify |
|---|------|--------|--------|
| **M1** | cliproxy crew-runner (tool-executing agent on Max quota) | ✅ **DONE + verified live** | `node verify/m1_crew_runner.mjs` → M1 PASS |
| **M2** | controller loop (scope→plan→dev→verify→test→review); reuses foreman pure modules | ✅ **DONE + verified live** | `verify/m2_controller.mjs` → M2 PASS · `verify/tier2_core_identical.mjs` → 10/10 |
| **M3** | gate/resume protocol + MCP server (`maestro` tool) | ✅ **DONE + verified live** | `verify/m3_gate_resume.mjs` → M3 PASS (start/approve/reject/halt + state persists across calls) |
| **M4** | code-rendered strict DoD + commit (no force-ship) | ✅ **DONE + verified live** | `verify/m4_dod_commit.mjs` → M4 PASS (clean→commit; not-done→withheld) |
| **M5** | multi-provider routing (opus judges / gpt-5.5 dev / gemini ui) | ✅ **DONE + verified live** | `verify/m5_routing.mjs` → M5 PASS (all 3 providers route via cliproxy) |
| **M6** | multi-tool harness platform (registerTool) | ✅ **DONE + verified live** | `verify/m6_tool_registry.mjs` → M6 PASS (2 tools via real MCP stdio) |
| **M7** | within-round loop-breaker / drift detector (developer + tester monitored; soft-warn-once / hard-abort / cross-round escalate) | ✅ **DONE + verified** | `verify/m7_loopbreaker.mjs` → M7 PASS (16 checks, incl. the REAL crew-runner aborting on an identical-tool-call loop) · tier-2 now **11/11** · dogfooded end-to-end through the installed `maestro` tool (shipped a real task; happy path did NOT trip the breaker) |

**Foreman catch-up (2026-06-10):** `core/` is **11 modules**, all byte-identical to their foreman
source (tier-2 = **11/11**) — `loopbreaker.ts` was added for M7 (foreman commit `68b7d49`, unchanged
since). foreman HEAD has since advanced to `2793a63` (background verification **daemon**, idea #8 —
new files `daemon.ts`/`daemon-runner.ts`); the 11 reused decision modules are unaffected, so tier-2
stays green, but the daemon is a NEW M-candidate beyond the list below. Runtime self-contained:
`core/` + `crew/` are copied into the project, so
maestro-mcp needs NO my-pi-harness at run time. Install: `bash install.sh` (registers via
`claude mcp add-json`, timeout 600000). The only foreman tie left is the tier-2 verify, which diffs
against my-pi-harness — keep that repo as a frozen reference even after pi is retired (the byte-identity
proof is already captured in `core/`).

## Remaining to RETIRE foreman completely (M7+)

M1–M6 migrate the **core gated loop** faithfully. Foreman has more of the alignment engine still to
wire (the pure modules for several are already copied into `core/`, just not driven by `controller.ts`
yet):

- **Crew escalation channel** — `escalate_question` → `awaiting_decision` resume (crew asks a fork; CTO
  answers). Currently crew run to completion only.
- **Gate-1 assumption scorer + team packet** — `scorer.ts`/`teampacket.ts` are in `core/` but the
  controller doesn't yet surface risky-assumption ranking / the team relay packet at Gate 1.
- **Gate-2 approval friction** — `approvalfriction.ts` copied; not yet wired (high-risk → confirm token).
- ✅ **Loop-breaker / drift detector (M7 — DONE)** — `core/loopbreaker.ts` (byte-identical, foreman
  `68b7d49`) wired via `loop-monitor.ts` (the maestro equivalent of foreman's `createLoopRunMonitor`)
  into `crew-runner.ts` (emits `tool_call`/`tool_result` telemetry + obeys a hard-trip `AbortSignal`)
  and `controller.ts` (developer: hard trip → re-plan note + retry once, then escalate; same signature
  across 2 rounds → escalate; tester hard trip → BLOCKED). planner/reviewer stay unmonitored, matching
  foreman. Soft never aborts/injects; hard aborts; never infinite-loops a stuck role (INTERNALS §09).
- **Doc-er stage** — soft doc refresh after reviewer APPROVE (crew/doc-er.md copied; stage not wired).
- **Calibration (Tier 3)** + **continual-learning** — cross-task/advisory; lowest priority.
- **`.claude/maestro.json` manifest** — multi-gate pipeline (per-round/pre-ship/release, judge/action
  kinds). M1–M6 use the single `verifyCommand` path; the manifest loader needs a maestro path wrapper
  around the byte-identical `gates.ts` execution.

When these land, foreman can be retired and maestro-mcp is the harness. The CORE loop is already
fully migrated + verified.

## M1 — what was built & proven (2026-06-10)

- `crew-runner.ts` — agentic tool loop over cliproxy. Loads `crew/<role>.md` as system prompt, routes
  role→cliproxy model (`ROLE_MODEL`), exposes OpenAI function tools (read/list/grep/bash for all;
  write/edit for implementers only; read-only roles get a mutation-guarded bash), runs the
  `tool_calls` loop to a final message. Cap-free billing (cliproxy injects CC marker).
- `verify/m1_crew_runner.mjs` — drives a real `developer` crew on a trivial GOAL handoff in a temp
  repo. **Result: M1 PASS** — model called via cliproxy, tools executed (`write_file` + `bash`),
  `hello.ts` written and runs printing `Hello, Maestro`, stopped cleanly. Evidence: `gpt-5.5`,
  3 steps, 2 tool calls, `stopped=stop`.

## M2 — what was built & proven (2026-06-10)

- `state-store.ts` — maestro ledger (`.claude/maestro/<slug>/`: state.json, log.jsonl, plan.json,
  handoffs). Checkpoints after each stage → long-running/crash resilience.
- `core/` — **10 foreman decision modules reused byte-identical** (planner, scorer, teampacket,
  gates, reviewer, done, ship, approvalfriction, docdrift, agent-timeouts). Proven by
  `verify/tier2_core_identical.mjs` → 10/10.
- `controller.ts` — the rewritten orchestrator: scope→**plan** (planner→PLAN-JSON→`validatePlannerPlan`
  /`fallbackPlannerPlan`)→**intent contract** (`formatIntentContract` flows down to dev)→**developer**
  (DEV-JSON)→**per-round command gate** (`runCommandGates`, exit code = ground truth, overrides a
  PASS)→**tester** (VERDICT)→**reviewer** (`parseReviewVerdict`/`decideReviewOutcome`). Faithful
  `extractJsonBlock` (scan-every-marker NEVER boundary).
- `verify/m2_controller.mjs` — **M2 PASS**: live end-to-end on a real task — `planSource=planner`,
  developer wrote a working `math.mjs`, command gate passed, tester PASS, reviewer approve, ledger
  written. 9/9 checks.

### Finding & fix (faithfulness): planner schema dilution

The planner first fell to `fallback` because cliproxy injects a ~2000-token Claude Code system prompt
that diluted the planner's complex 11-key contract — opus emitted its own `objective/track/files`
schema. Fix: the controller appends an exact-keys reminder to the planner call. **Output is now the
byte-identical foreman PLAN-JSON** (validated by `core/planner.ts`), so the understanding layer +
intent contract flow correctly. This is transport reinforcement, not a decision-logic change. (Watch
for the same dilution on any future complex-schema crew contract; dev/tester/reviewer were unaffected.)

## Cliproxy contract (verified live, for crew-runner)

- `POST http://localhost:8317/v1/chat/completions`, `Authorization: Bearer <api-keys[0] from
  ~/cliproxyapi/config.yaml>`, `Content-Type: application/json`.
- Body: `{ model, messages, tools?, max_tokens, reasoning_effort? }`. `reasoning_effort` = thinking
  level (verified gpt-5.5 + "low"). Response: standard OpenAI; `choices[0].finish_reason` ∈
  `stop|tool_calls`; `message.tool_calls[].function.{name, arguments(JSON string)}`.
- Models present (GET /v1/models): `claude-opus-4-8`, `gpt-5.5`, `gemini-3.5-flash-low`,
  `claude-sonnet-4-6`, `claude-fable-5`, … (gpt-5.5 IS available; plan's routing holds).

## Next session: M2

Build `controller.ts` + `server.ts` (one `maestro` tool). REUSE foreman pure modules (copy or import
from `my-pi-harness/extensions/foreman/`) so tier-2 verification applies. Wire `runCrew` for
developer→tester. Write `state.json` + `log.jsonl` per plan §8. Then run foreman's 17 tests against
the reused modules + a single-task end-to-end.
