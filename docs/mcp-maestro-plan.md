# MCP Maestro — Build Blueprint

> **Purpose:** A complete, self-contained plan. A fresh session should be able to start building
> immediately from this document alone without reading the conversation that produced it.

---

## 1. Goal & the "pi feeling"

MCP Maestro is a **coded-controller** orchestration harness implemented as a Claude Code MCP server.
It is a **faithful replica of pi+foreman** in the Claude Code world: the same A/C entry + B crew
pattern, the same guard boundary, the same gated loop — just expressed with different primitives.

**Settled architecture: A/C entry + B crew.** Pi+foreman itself is A/C at the founder↔CTO level (the
founder runs `pi` → a free CTO LLM agent that MUST INVOKE the `foreman` tool; the charter instructs
it and `guard.ts` backstops it — the CTO can "forget" and the guard catches the edit). Crew is pure B
(foreman, coded, drives bounded workers). Maestro mirrors this exactly:

- `claude` session = free CTO (type A/C entry, invoke-based like pi)
- SessionStart hook + CLAUDE.md/AGENTS.md charter = ambient identity (same role as AGENTS.md in pi)
- MCP `maestro` tool = coded controller (same role as `foreman` tool in pi)
- Guard hooks = boundary (same role as `guard.ts` in pi — turns "must remember to invoke" into
  "cannot actually escape to edit code outside the loop")
- Crew via cliproxy = B crew (bounded workers, same mechanism as pi's foreman subprocess crew)

**The "must remember to invoke" is INHERENT and only mitigated — not eliminated.** Pi doesn't
eliminate it either. The guard + charter reduce the probability; the guard makes escaping the loop
a hard block rather than a soft miss. This is the same guarantee pi provides, no more, no less.

> **Retraction of prior framing:** this is NOT "pure B / controller-as-sole-entrypoint." The entry
> is the `claude` session — a free CTO agent — not the MCP server. The MCP server is the coded
> controller the CTO invokes. Framing it as pure B would erase the ambient identity layer that gives
> the system its pi feel.

The key property pi has — and that this variant must have — is deep customizability: just as
`pi.registerTool(name, handler)` lets the founder wire arbitrary harness tools into the pi session,
the MCP server can **register many harness tools** so the founder can customize any harness, not just
the gated dev loop. That is the "pi feeling": the platform is extensible by code, not configuration.

The MCP variant lives at `variants/personal/` (see `variants/personal/README.md`).

---

## 2. Why MCP — not Workflow, not skill-only

Pi's "tightness" comes from three structural properties:

| Property | Pi | Native skill | Workflow | **MCP** |
|---|---|---|---|---|
| Ambient orchestrator identity | charter in session env at start | SessionStart hook | ephemeral, re-loaded per call | MCP server always present |
| Standing first-class tool | `pi.registerTool` | `/maestro` slash-command | action invoked on demand | `maestro` tool, always registered |
| Coded controller | `foreman/index.ts` is TS, not a prompt | model-driven (near-100%) | deterministic JS but lives in throwaway context | controller.ts is server-side TS |

**Workflow** is an ephemeral opt-in action. Its controller brain lives in throwaway JS; the session
doesn't embody the harness between calls → loose. Use Workflow only as a parallel-fan-out helper
inside a controller loop, not as the controller itself.

**Native skill** already provides ambient identity (SessionStart hook + guard) but its loop is
model-driven: the CTO renders the DoD checklist by discipline, not by code, so structure drifts under
load (that is why `docs/architecture.md` calls the skill "near-100%", not "process-100%"). MCP adds
coded determinism on top of the identity without removing it.

**MCP tool + SessionStart prompt WITHOUT the guard hooks = pure workflow** — the CTO agent could
simply edit code and bypass the loop. The guard hooks are what make the boundary real. They are
MANDATORY, not optional hardening.

The MCP variant and the native skill are **complementary**, not competing. The guard hooks stay; the
CTO identity stays; the crew prompts are reused. The MCP server wraps the loop in a coded shell.

---

## 3. Verified feasibility

### cliproxy is live and reachable

Process `cliproxyapi/cli-proxy-api --config .../config.yaml` listens on `:8317`.  
`GET http://localhost:8317/v1/models` returns: Opus 4.8, Gemini 3.5 Flash, and additional
providers (GPT-5.5, Grok) on subscription quota.  
Source: `config/models.json` in `my-pi-harness` — provider `cliproxy`, `baseUrl http://localhost:8317/v1`,
`api openai-completions` (`my-pi-harness/config/models.json:3-7`).

Any process — including an MCP server — can POST to `localhost:8317/v1/chat/completions` using the
OpenAI completions wire format and draw from Max subscription quota.

### MCP servers have full subprocess + filesystem access

Claude Code does not sandbox MCP server processes. The server can spawn child processes, read and
write files, and open sockets freely. This is the same execution environment pi tools run in.

### Resume pattern is well-supported in MCP

MCP tools support a stateful request/response pattern: persist state to disk between calls and accept
a `resume` parameter on subsequent calls. This maps exactly to foreman's
`foreman({ resume, approve })` model. Each call is short (one phase or gate round), so MCP's default
~60 s per-call timeout is not a concern; it can be raised to 600 000 ms in `.mcp.json`
(`"timeout": 600000`) if a crew round ever needs more time.

### One server, many tools

One MCP server can register an arbitrary number of tools. Tool definitions can be deferred or
loaded on demand (tool search), keeping context cost low even as the tool registry grows. This is
the "register any harness" property.

---

## 4. THE BILLING CRUX — read this first

> **Most important design constraint. State it prominently in every crew-runner discussion.**

From **2026-06-15**, `claude -p` / Agent SDK headless invocations draw a **separate, capped
Agent-SDK credit bucket** — not the interactive Max quota. This bucket is limited and runs dry
independently of how much interactive quota remains.

**MCP Maestro avoids this entirely by never using `claude -p` or the Agent SDK for crew.**

Crew calls hit **cliproxy directly over HTTP**, using the OpenAI completions wire format. Cliproxy
holds the Claude Code session auth and routes calls to the interactive Max quota. Every provider
(Opus, GPT-5.5, Gemini) is served from the same subscription bucket.

**Proof this works today:** pi foreman already runs its entire crew this way — it spawns a subprocess
that calls cliproxy (`my-pi-harness/extensions/foreman/index.ts:236-281`), never `claude -p`. The
multi-provider crew (Opus CTO/judges, GPT developer, Gemini UI) runs on Max quota at zero API cost.
MCP Maestro is the same architecture surfaced as an MCP tool instead of a pi tool.

This is the founder's verified decision: "crew qua cliproxyapi" = cap-free path.

---

## 5. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Claude Code session  (interactive, Max quota)                  │
│                                                                 │
│  CTO identity  [A/C entry — free agent, invoke-based like pi]  │
│  ├── SessionStart hook → charter (CLAUDE.md/AGENTS.md) loaded  │
│  ├── guard-block-main-edits.sh  ← MANDATORY BOUNDARY           │
│  │   (turns "must remember to invoke" into hard block;          │
│  │    equivalent to pi's guard.ts)                              │
│  └── guard-block-main-bash.sh   (no shell writes in main)       │
│                                                                 │
│  CTO invokes MCP tool ────────────────────────────────────────┐ │
└──────────────────────────────────────────────────────────────┐│ │
                                                               ││ │
┌── MCP server "maestro"  (TypeScript, Node/Bun process) ──────┘│ │
│   [B crew controller — same role as foreman tool in pi]       │ │
│                                                               │ │
│  Tool registry (many harness tools, loaded on demand)         │ │
│  ├── maestro(task, resume?, approve?, slug?)                  │ │
│  ├── [future] maestro-hotfix(...)                             │ │
│  └── [future] maestro-review(...)                             │ │
│                                                               │ │
│  ┌── Coded controller (controller.ts) ──────────────────────┐ │ │
│  │   loop: scope → plan → Gate1 → dev rounds → Gate2 → ship │ │ │
│  │   renders DoD checklist by code (no model drift)         │ │ │
│  │   writes ledger / state.json / handoffs / log.jsonl      │ │ │
│  └──────────────────────────────────────────────────────────┘ │ │
│                                                               │ │
│  ┌── Crew runner (crew-runner.ts) ──────────────────────────┐ │ │
│  │   builds messages: system=crew/*.md + GOAL handoff       │ │ │
│  │   POSTs to cliproxy /v1/chat/completions                 │ │ │
│  │   parses tool_calls → executes (fs + child_process)      │ │ │
│  │   loops until final text or step cap                     │ │ │
│  └──────────────────────────────────────────────────────────┘ │ │
│            │                                                  │ │
└────────────┼──────────────────────────────────────────────────┘ │
             │  HTTP POST  (OpenAI completions wire format)        │
             ▼                                                     │
┌── cliproxy  :8317  ──────────────────────────────────────────┐  │
│   routes by model id, holds CC session auth                  │  │
│   ├── claude-opus-4-8   → Anthropic  (CTO / tester / reviewer│  │
│   ├── gpt-5.5           → OpenAI     (developer)             │  │
│   └── gemini-3.5-flash  → Google     (ui-developer)          │  │
│   All served on interactive Max subscription quota           │◄─┘
└──────────────────────────────────────────────────────────────┘
```

The CTO session is interactive and never calls `claude -p`. The crew lives entirely inside the MCP
server's crew runner, calling cliproxy over HTTP. The MCP server process has no sandbox restrictions.

---

## 6. Crew runner design

### Option A — hand-roll the agentic tool loop (recommended)

Implement `crew-runner.ts` as a self-contained agentic loop:

1. **Build the initial message list:** `[{role:"system", content: <crew/*.md system prompt>}, {role:"user", content: <GOAL handoff>}]`
2. **POST** to `http://localhost:8317/v1/chat/completions` with the model id for the role
   (see routing table below) and an OpenAI-style tools array containing the permitted tool schemas
   (Read, Write, Edit, Bash — scoped per role; tester/reviewer get no mutating tools).
3. **Parse the response:** if `finish_reason` is `tool_calls`, execute each tool call in-process
   (`fs` for file ops, `child_process.execSync` for Bash) and append a `tool` result message.
4. **Loop** back to step 2 until `finish_reason` is `stop` or a per-role step cap is hit.
5. **Extract the final text** (the `## Completed` / `VERDICT` / `REVIEW` block) and return it to the
   controller.

**Why Option A is recommended:** maximum control over tool schemas, role isolation (read-only roles
never get write/edit/bash-mutate tools), step caps, output parsing, and token budgets. This is the
"deepest pi feeling" — the controller owns every knob.

**Quota-safety note:** cliproxy requires the Claude Code system prompt marker to be present in the
`system` field so it keeps drawing Max quota. Append the crew system prompt to that marker — same
`--append-system-prompt` convention pi uses at `my-pi-harness/extensions/foreman/index.ts:257-258`.

**Per-role model routing:**

| Role | Model id | Rationale |
|---|---|---|
| planner | `claude-opus-4-8` | high-stakes reasoning, read-only |
| developer | `gpt-5.5` (or `claude-sonnet`) | implementation throughput |
| ui-developer | `gemini-3.5-flash-low` | UI taste + speed |
| tester | `claude-opus-4-8` | adversarial judgment, read-only |
| reviewer | `claude-opus-4-8` | adversarial review, read-only |
| scout | `gemini-3.5-flash-low` | fast read-only recon |

Model ids come from `my-pi-harness/config/models.json`. GPT-5.5 and Grok are also served by
cliproxy but not yet listed in that config — add them when routing GPT as developer.

### Option B — reuse the pi subprocess (fallback)

Invoke the `pi` binary as a subprocess (same as `my-pi-harness/extensions/foreman/index.ts:271`):
`piInvocation(args)` → `spawn(command, args, { env: { FOREMAN_CREW: "1" } })`. This is proven today
but couples MCP Maestro to a running pi installation. Prefer Option A for independence.

---

## 7. Gate / resume protocol (mirrors foreman)

### Call shape

```ts
// First call — start a task
maestro({ task: string, verifyCommand?: string, track?: "backend"|"frontend" })
// Resume after Gate 1 approval
maestro({ resume: true, slug: string, approve: true })
// Resume after Gate 1 with revision
maestro({ resume: true, slug: string, reject: string })
// Resume after Gate 2
maestro({ resume: true, slug: string, gate: 2, approve: true })
```

### Loop sequence

```
maestro(task)
  → spawn planner → persist plan.md + plan.json + state.json
  → return { status: "awaiting_gate1", plan, understandingLayer, slug }

CTO receives → renders understanding layer in conversation
  → AskUserQuestion { header: "Gate 1", options: ["Approve","Revise"] }
  → founder approves

maestro({ resume, slug, approve })
  → spawn developer → per-round command gates → spawn tester (≤3 rounds)
  → on PASS: spawn reviewer (pre-ship)
  → return { status: "awaiting_gate2", dod_checklist, blockers }

CTO receives → renders DoD checklist BY CODE (6-check block, no drift)
  → AskUserQuestion { header: "Gate 2", options: ["Approve","Revise"] }
  → founder approves

maestro({ resume, slug, gate: 2, approve })
  → run release actions (commit)
  → return { status: "done", commit }
```

State is durable: a crash or restart resumes from `state.json`. The CTO never holds loop state in
conversation memory — it only relays gates and founder decisions.

---

## 8. State schema

All task state lives under `.claude/maestro/<slug>/`:

```
.claude/
  maestro.json          gate pipeline manifest (per-repo declaration)
  maestro-verify        per-round verify command string (for commit-gate)
  maestro/
    <slug>/
      state.json        task, round, gates[], verdicts[], gate1Approved, gate2Approved,
                        pendingDecision, dodChecklist, blockers
      plan.md           human-readable plan (for the record)
      plan.json         structured plan (understanding layer, requirements, track)
      handoffs/
        round-1-dev.md  GOAL handoff sent to developer round 1
        round-1-tester.md
        ...
      log.jsonl         append-only event log (agent_start, tool_call, verdict,
                        gate_result, done_evaluated)
```

`state.json` schema (mirrors foreman's ledger discipline):

```jsonc
{
  "task": "...",
  "slug": "add-auth-middleware",
  "track": "backend",
  "round": 2,
  "gate1Approved": true,
  "gate2Approved": false,
  "pendingDecision": null,
  "gates": [{ "name": "unit", "kind": "command", "stage": "per-round", "command": "npm test" }],
  "verdicts": [{ "round": 1, "tester": "FAIL", "reviewer": null }, { "round": 2, "tester": "PASS", "reviewer": "APPROVE" }],
  "dodChecklist": {
    "planApproval": true,
    "perRoundGates": true,
    "testerJudgment": true,
    "preShipGates": true,
    "reviewerGate": true,
    "founderShipApproval": false
  },
  "blockers": []
}
```

---

## 9. What we reuse — pi+foreman ↔ Claude Code equivalence

The faithful A/C+B replica maps cleanly:

| Pi+foreman concept | Claude Code / Maestro equivalent |
|---|---|
| `pi` (entrypoint, free CTO) | `claude` session (interactive, A/C entry) |
| AGENTS.md charter | SessionStart hook + CLAUDE.md/AGENTS.md (injected at session start) |
| `foreman` tool (coded controller) | MCP `maestro` tool + controller.ts |
| `guard.ts` (boundary enforcement) | guard hooks: `guard-block-main-edits.sh` + `guard-block-main-bash.sh` |
| pi subprocess crew via cliproxy | server agentic-loop crew via cliproxy (crew-runner.ts) |
| AskUserQuestion extension | AskUserQuestion tool (native to Claude Code) |
| `.pi/plans` + dashboard | `.claude/maestro/` + state.json + log.jsonl + statusLine |

**What the MCP variant drops vs the native skill** (because the controller absorbs them):

- `SKILL.md` loop logic — the loop is now controller.ts, not a prose protocol the CTO reads
- `~/.claude/agents` registration — crew runs inside the server via cliproxy, NOT via Claude Code's
  Task tool; no agent files needed
- Render-discipline templates — the controller renders DoD/handoff BY CODE; no model templates needed

**What stays, unchanged:**

- `crew/*.md` — the server reads them as crew system prompts (same content, new reader)
- Charter (CLAUDE.md/AGENTS.md) — injected via SessionStart, same as before
- Guard hooks — MANDATORY; they are the boundary (see §2); removing them degrades to pure workflow
- Gate pipeline schema (`.claude/maestro.json`) — identical shape
- Strict DoD (evaluated by code in controller.ts)

The native skill continues to work in repos that don't register the MCP server. MCP Maestro is opt-in
via `.mcp.json` registration.

---

## 10. Deep customization — what only the coded controller unlocks

The MCP controller unlocks four powers a prose skill or native Task tool cannot: **coded logic,
owned persistent state, multi-provider via cliproxy, and being a process** (headless / async /
parallel / fleet). These capabilities are not expressible in a prompt-driven skill alone.

### Walk-away CTO (headless + async gates)

Run a task with no live session; pause at gates by pinging the founder's phone (the Pimote bridge)
and resume on async reply.  
*Why only the coded controller:* a skill needs a live interactive session to relay gates. A
controller-process can run headless and gate on async I/O (webhook, phone reply, cron).

### Adversarial panel + implementation tournament (true multi-provider)

N refute-biased skeptics across Opus / GPT / Gemini in parallel with a CODED vote/debate tally; or
N developers in parallel git worktrees scored objectively (tests + diff size + reviewer) and the
winner picked by code.  
*Why only the coded controller:* a skill cannot run parallel cross-provider calls with objective
coded selection of a winner.

### Token / cost budget governor

Controller meters tokens per crew call and enforces a per-task budget in code — downgrade to cheaper
models at 80% of budget, stop + escalate to founder at 100%.  
*Why only the coded controller:* a model cannot reliably self-meter or enforce hard caps.

### Forkable / replayable task ledger (git for tasks)

Replay from any gate, fork at Gate 1 to try two plans in parallel, diff two runs, time-travel a
round.  
*Why only the coded controller:* needs durable structured state that a skill session lacks between
calls.

### Self-tuning routing + codebase knowledge graph

Controller learns per-task-type which model / round / gate config wins and auto-tunes routing; a
knowledge graph (doc-er) is injected into crew before each task so they get smarter about THIS
codebase over time.  
*Why only the coded controller:* skill subagents start fresh each call; only a controller accumulates
policy in code and applies it on the next run.

### Custom gate KINDS beyond shell exit codes

Canary-deploy gate (deploy → smoke → auto-rollback), perf-regression gate (bench, block >5% slower),
screenshot-diff gate, cost gate.  
*Why only the coded controller:* skill gates are shell exit codes; coded gates are arbitrary code +
side effects + UI interactions.

### Harness-of-harnesses

The founder declares NEW harnesses (research / migration / design-review), each registered as its
own MCP tool — i.e. `pi.registerTool` but owned by you. `maestro` becomes a harness PLATFORM, not
one harness.  
*Why only the coded controller:* this is the literal "custom any harness" — each tool is a
first-class coded controller, not a prompt variant.

### The full alignment engine

2-axis P×cost scorer, async team-channel routing, assume-unless-vetoed — all require coded logic +
persistent state + channels that a prose skill can only gesture at.

---

## 11. Build milestones

Each milestone is a maestro task with its own Gate 1 / Gate 2. Run them sequentially; each builds on
the last.

### M1 — cliproxy client + single-role crew runner

**Goal:** prove a tool-executing agent (developer role) runs on Max quota via cliproxy.  
**Deliverable:** `crew-runner.ts` that POSTs to `localhost:8317/v1/chat/completions` with the
developer system prompt + a GOAL handoff, executes returned tool_calls (Read, Write, Bash), loops to
stop, returns final text.  
**Verify:** run the crew runner against a trivial task ("write hello-world.ts"); confirm the file
appears on disk and the call never touches `claude -p`.

### M2 — controller loop, single-shot

**Goal:** full scope → plan → dev → verify → test → review sequence, no gates.  
**Deliverable:** `controller.ts` + minimal `server.ts` exposing one `maestro` tool. Reads
`crew/*.md` for prompts. Writes `state.json` and `log.jsonl`. Runs command gates from
`.claude/maestro.json` via `child_process`. Returns final tester verdict.  
**Verify:** call `maestro({ task: "..." })` from a Claude Code session with the MCP server
registered; confirm dev wrote a file, tester ran, state.json reflects rounds.

### M3 — gate / resume protocol + AskUserQuestion relay

**Goal:** the two human gates (Gate 1, Gate 2) wired end-to-end.  
**Deliverable:** `maestro` tool returns `{ status: "awaiting_gate1", ... }` and persists; CTO relays
via AskUserQuestion; `maestro({ resume, slug, approve })` resumes correctly from state.  
**Verify:** run a task interactively; confirm Gate 1 prompt appears, founder approves, loop continues,
Gate 2 prompt appears, founder approves, commit fires.

### M4 — code-rendered DoD checklist + ledger

**Goal:** strict DoD evaluated and rendered by code at Gate 2, never by model memory.  
**Deliverable:** controller.ts evaluates all 6 DoD checks from `state.json`, serialises the checklist
to `state.json`, returns it in the Gate 2 response. CTO renders the 6-check block verbatim from that
data. Commit gate re-runs verify command as final hard gate.  
**Verify:** force a reviewer `REQUEST_CHANGES` and confirm commit is withheld; force PASS on all 6
and confirm commit fires.

### M5 — multi-provider routing

**Goal:** Opus for judges, GPT-5.5 for developer, Gemini for ui-developer — decorrelated crew on one
subscription, matching foreman.  
**Deliverable:** crew-runner.ts reads a `roleModelMap` config (can live in `server.ts` or
`.claude/maestro-models.json`) and routes each role to its cliproxy model id.  
**Verify:** run a task with `track: "frontend"`; confirm network traffic goes to gemini model id;
run with `track: "backend"`; confirm GPT model id.

### M6 — multi-tool harness platform

**Goal:** MCP server can register additional harness tools beyond `maestro`; founder can wire custom
harnesses.  
**Deliverable:** `tool-registry.ts` with `registerTool(name, schema, handler)`. At least one
example second tool (e.g. `maestro-hotfix` — a no-Gate-1 fast path for trivial patches).
Tool definitions loaded on demand (tool search) to keep context cost low.  
**Verify:** register `maestro-hotfix`; call it from a Claude Code session; confirm it appears in tool
search and executes correctly.

---

## 12. Risks & open questions

| Risk | Severity | Mitigation |
|---|---|---|
| cliproxy not running at session start | High — all crew calls fail silently | controller.ts pings `GET /v1/models` at startup; returns actionable error if unreachable |
| MCP per-call timeout on long dev rounds | Medium | per-round chunking (one round = one call) keeps each call short; raise to 600 000 ms in `.mcp.json` |
| Option A hand-roll effort (tool schema maintenance, parse edge cases) | Medium | start with Read/Write/Edit/Bash only; expand tool set per role iteratively |
| Option B (pi subprocess) coupling to pi installation | Low-medium if chosen | prefer Option A; keep Option B as a fallback stub in crew-runner.ts |
| `.mcp.json` registration — stdio vs HTTP server | Low | start with stdio (simpler, no port conflicts); HTTP if the tool needs to be callable from Workflow/ultracode across sessions |
| Crew read-only role enforcement | Medium | tester and reviewer tool schemas omit Write, Edit, MultiEdit, and mutating Bash patterns; verified in crew-runner.ts before dispatch |
| GPT-5.5 / Grok model ids not yet in `config/models.json` | Low | add them to the roleModelMap in server.ts when routing GPT as developer; do not block M1-M4 on this |
| Guard hooks absent or disabled | CRITICAL — degrades to pure workflow (CTO can edit directly) | treat guard hooks as MANDATORY; validate presence in onboarding/setup script |
| AskUserQuestion gates don't fire in headless `claude -p` | Known, not a risk | MCP Maestro is the personal/interactive variant; headless walk-away mode is a §10 advanced feature, not default |

### Open questions (decisions to make before or during milestones)

1. **stdio vs HTTP server** — stdio is simpler for M1-M4; upgrade to HTTP for M6 if cross-session
   tool-search is needed. Decision: defer to M6.
2. **Where roleModelMap lives** — hardcoded in `server.ts` (simplest) vs `.claude/maestro-models.json`
   (founder-editable). Recommended: start hardcoded in server.ts, extract to JSON at M5.
3. **Step cap per role** — how many tool-call iterations before the crew runner hard-stops a role.
   Recommended default: 40 steps for developer/ui-developer, 20 for planner/tester/reviewer/scout.
4. **Token budget per round** — whether to pass `max_tokens` per call or let cliproxy use model
   defaults. Recommended: use model `maxTokens` from `config/models.json` as the cap.
5. **Crew prompt path** — crew-runner.ts should resolve `crew/*.md` relative to the harness root
   (`my-claude-harness`), not the target repo. Confirm the server knows its own install path at
   startup.

---

## File map for the implementation

```
variants/personal/
  maestro-mcp/
    server.ts           MCP server entry point; registers all harness tools
    controller.ts       coded loop: scope→plan→Gate1→dev rounds→Gate2→ship
    crew-runner.ts      agentic tool loop over cliproxy HTTP (Option A)
    tool-registry.ts    registerTool() — the "pi feeling" extensibility layer  [M6]
    types.ts            shared types: GateKind, Stage, DodChecklist, StateJson, etc.
  .claude/
    settings.json       ANTHROPIC_BASE_URL=http://localhost:8317/v1 (if needed)
    .mcp.json           register maestro-mcp (stdio); "timeout": 600000
```

Source files to read when building:
- `my-pi-harness/extensions/foreman/index.ts:117` — `piInvocation` (subprocess spawn pattern)
- `my-pi-harness/extensions/foreman/index.ts:235-281` — `runAgent` (the pi crew runner; Option A
  replaces this with a direct HTTP call instead of a subprocess)
- `my-pi-harness/config/models.json:3-7` — cliproxy provider / baseUrl / model ids
- `my-claude-harness/crew/*.md` — crew system prompts (used verbatim as `system` messages)
- `my-claude-harness/docs/charter/gate-pipeline.md` — gate shape and stage semantics
- `my-claude-harness/docs/charter/definition-of-done.md` — the 6 DoD checks, blocking semantics
- `my-claude-harness/skills/maestro/SKILL.md` — the full CTO loop protocol (Gate 1/2 relay,
  handoff contract, fix loop rules) — read for context; loop logic moves to controller.ts in MCP
- `my-claude-harness/docs/architecture.md` — decision log, enforcement layer, what Workflow adds
