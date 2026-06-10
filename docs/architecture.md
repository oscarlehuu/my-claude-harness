# Architecture — Maestro

Maestro is a port of the pi `foreman` harness onto Claude Code. The orchestration **logic** is
provider-agnostic; only the **surface** (how maestro is invoked + how crew run) differs per variant.

## Decision log (why native company is primary)

- Goal: native Claude Code, presentable/portable for a company, conserve Claude Max.
- Verified: cliproxy injects the **genuine** Claude Code system prompt (no behavior change vs
  native); routing to gpt/gemini works on subscription (no API key); gpt-as-developer (with the CC
  prompt) **does tasks correctly and honors the maestro MACHINE BLOCK** — mismatch is cosmetic.
- On **pure subscription** you cannot have BOTH process-100% AND full interactive allowance via the
  Agent SDK / `claude -p` (those draw the capped Agent SDK credit). Two native ways out:
  - **Skill** (interactive + Task subagents + hooks) → full allowance + near-100%.
  - **Workflow tool** → process-100% (deterministic JS) AND full interactive allowance (verified: the
    interactive Workflow tool is NOT in the capped Agent-SDK-credit bucket — only the Agent SDK
    library, `claude -p`, GitHub Actions, and third-party apps are).
  → Company = **native** (skill now; Workflow is the process-100% upgrade path).

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
