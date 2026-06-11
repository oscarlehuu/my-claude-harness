# Architecture — Maestro

Maestro evolved from the pi `foreman` harness onto Claude Code, then grew the **tier ladder** the
fixed pipeline lacked. The orchestration **logic** is provider-agnostic; only the **surface** (how
maestro is invoked + how crew run) differs per variant.

## Core design: prose decides, scripts record, hooks enforce

The model (CTO) makes the judgment calls — which tier, what handoff, when to escalate. Everything
that must be exactly right is code:

- **Ledger = state machine.** `task-init/record/verify/status` scripts own the JSON schema under
  `.claude/maestro/<slug>/`. The CTO never hand-writes ledger files.
- **Ground truth.** `task-verify.sh` is the only writer of verify records — a recorded pass means
  the command really exited 0, not that a model said so.
- **Hooks = transition guards.** The guards budget-gate main-session edits; `commit-gate` reads the
  active task's tier DoD from the ledger and re-runs verify on `git commit`; `stop-dod` blocks
  ending a turn with code changed after the last green verify. All hard (exit 2 survives bypass
  mode), all readable shell.
- **Tier ratchet is one-way, in code** — `task-record.sh` refuses tier downgrades; a new round
  invalidates stale verdicts.

This recovers foreman's "deterministic controller" guarantees without a controller process: the
state machine became files + shell, and the loop runs in the conversation where the founder can
watch every step.

## Decision log

- **Why native (over the MCP replica).** An MCP server owning the loop was built and verified
  (M1–M7, multi-provider crew via cliproxy) — then retired: the founder couldn't see inside it.
  Native subagents + ledger files + hooks give the same hard outcomes with full observability;
  that chapter is preserved in this repo's git history (pre-restructure).
- **Why all-Claude crew.** Cross-model dev (gpt-as-developer) was verified working, but dropped with
  the second subscription. The lost model-diversity is compensated in process: mandatory edge-case
  enumeration → executable tests (`crew/developer.md`), an edge-case-hunter adversarial tester
  (`crew/tester.md`), and exit-code ground truth — tests don't share any model's blind spots.
- **Why tiers.** The fixed pipeline taxed every task the same; small tasks paid a 5-LLM-call,
  2-human-gate toll. Triage by risk × size (the boss doesn't call a meeting to fix a typo, but does
  call the lawyer for one line in a contract) with a one-way escalation ratchet keeps small things
  fast and risky things gated.
- On **pure subscription** you cannot have BOTH process-100% AND full interactive allowance via the
  Agent SDK / `claude -p` (those draw the capped Agent SDK credit). Two native ways out:
  - **Skill** (interactive + Task subagents + hooks) → full allowance + near-100%.
  - **Workflow tool** → process-100% (deterministic JS) AND full interactive allowance (verified: the
    interactive Workflow tool is NOT in the capped Agent-SDK-credit bucket — only the Agent SDK
    library, `claude -p`, GitHub Actions, and third-party apps are).
  → **skill now; Workflow is the process-100% upgrade path.**

## Enforcement (the "100% maestro")

- **Orchestrate-only (edit tools):** PreToolUse hook `guard-block-main-edits.sh` blocks
  Edit/Write/MultiEdit/NotebookEdit in the **main session** (no `agent_id`) → forces delegation.
  Survives bypass mode (exit 2).
- **Orchestrate-only (shell):** `guard-block-main-bash.sh` closes the gap where shell could mutate the
  tree (`echo >> f`, `sed -i`, `tee`, `cp/mv`, `patch`, `git apply/restore/checkout --`,
  `bash -c "...>>f"`, `python3 -c "open(...,'w')"`). It tokenizes the command (shlex, quote-aware so
  `grep ">"` is NOT a false positive), blocks the main session on any file-writing pattern, and lets
  read-only commands + `/dev/null` + `$TMPDIR` writes through. Not a perfect seal (an exotic path could
  slip) — `commit-gate` + review are the ultimate backstops.
- **Can't ship broken:** `commit-gate.sh` re-runs the verify command on `git commit`; non-zero → block.
- **Verified empirically (this build):** unit battery 32/32 (mutating→exit2, read-only/subagent→exit0);
  e2e `claude -p` with the live config ran the **full loop** — main-session `echo > f` blocked
  (`agent_id` absent), then `/maestro` spawned `agent_type` planner→developer→tester→reviewer, the
  **developer** subagent (agent_id present) wrote the file, reviewer APPROVE. commit-gate blocks a
  failing-verify commit. Note: AskUserQuestion gates don't fire in headless `-p` (no UI) — they work in
  interactive `claude`.
- **Human gates:** Gate 1 (plan) + Gate 2 (ship) via AskUserQuestion in the skill protocol.
- Skill loop sequencing is **model-driven** → near-100%. The **Workflow** loop is **process-100%**
  (deterministic JS). Hooks make the *outcomes* hard (no self-edit, no broken ship) regardless.

## Crew management (matches pi)

Verified: pi foreman does NOT live-supervise the developer — it dispatches, the developer runs to
completion, then the controller checks the **output** (diff + tester judges it). Native Claude Code
subagents work the same way. No behavioral regression in moving off pi.

## What Workflow unlocks beyond pi's sequential loop

Pi foreman = sequential, one-agent-per-role, fixed cap. The Workflow tool adds parallel/dynamic
patterns pi can't do: parallel multi-file dev (worktree isolation), adversarial-verify panels
(N skeptics, majority vote), implementation tournaments (N approaches → judges → best), multi-lens
parallel review (correctness/security/perf/a11y), loop-until-dry, and budget-scaled rigor.
