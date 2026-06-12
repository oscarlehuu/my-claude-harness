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

### Which repo governs an action: the five-hook anchor story

Each hook resolves "which repo am I governing?" from the **target of the action**, not the session
directory, so every repo is governed by ITS OWN budget, protected paths, carve-outs and ledger.

- **Target-rooted** (derive the repo from what the action touches):
  - `guard-block-main-edits.sh` → the edited file's repo (`git rev-parse --show-toplevel` from the
    file's nearest existing ancestor dir; a Write may create new dirs).
  - `guard-block-main-bash.sh` → the mutated path's repo (same resolution, per detected target).
  - `commit-gate.sh` → the commit's repo (the `git commit` segment's effective `cd`/`-C` context;
    the **last** `-C` wins, matching real git; unspaced operators like `cd r&&git commit` are
    pre-split before tokenizing). `cd`/`-C` path tokens are run through `os.path.expanduser` so a
    cross-repo commit written `cd ~/hq && git commit` routes to its real repo under `$HOME`; the
    boundary is deliberate — `~`/`~user` expand, but `$HOME`/`$VAR` forms stay literal (unresolvable
    → session fallback → over-block, the safe direction). **Engagement is a three-state decision so
    safety never depends on any enumeration** — prior evasions all came from the gate failing to
    *engage* because the parser
    did not recognize one more wrapper/prefix, and an enumeration can always lose that race:
      1. **TRIGGER (dumb, over-inclusive, unbeatable):** the gate engages when the raw command
         contains the `git commit` substring (the original baseline matcher) **or** any token whose
         basename is `git` is followed by a `commit` token in the same segment. No stripping, no
         understanding — just a trigger.
      2. **ROUTE (precise where possible):** once engaged, the clean parser (strip `VAR=val`,
         wrappers `env`/`command`/`nice`/`nohup`/`timeout <n>`/`xargs`/`sudo`/`exec`/`time -p`, then
         basename-match `git` and skip global options) classifies each git segment. A segment that
         cleanly parses as `git commit` is gated by its resolved target repo. **The wrapper list is
         routing precision, not the safety boundary** — a missed wrapper degrades to over-block,
         never under-block.
      3. **FALLBACK (the net that makes enumeration irrelevant):** engaged but no segment cleanly
         parses as a commit → still gate, and the resolver returns the **session repo** (over-block).
         This catches `time -p git commit`, `sudo time git commit`, and tomorrow's unknown wrapper.
    Three outcomes: a clean commit segment → gate by target; every git segment cleanly classified as
    a *non*-commit verb with no `git commit` substring (`git log --grep commit`, `git -C r
    commit-tree`) → exit 0; anything else → session gate. **Accepted over-blocks (baseline parity):**
    `echo git commit` and a `-m` message arg whose raw text contains `git commit` engage and fall
    back to session gating — the old substring matcher blocked these too; de-blocking them was the
    nicety that opened the enumeration hole class. Out of scope (a baseline limitation, not closed
    here): commits hidden inside opaque carriers — `bash file.sh`, `python -c "..."`, `eval "$x"` —
    which the substring matcher never inspected either.
- **Session-rooted** (no per-action target → anchor on `CLAUDE_PROJECT_DIR or PWD`): `stop-dod.sh`,
  `maestro-engage.sh`, `crew-context.sh`. (Whether the session anchor resolves to a worktree vs the
  main checkout is the open question the lanes work, task 2b, answers with a live session.)

### Context slots: the three identity layers

Identity arrives in three layers, in reading order. **Framework** (`AGENTS.md`, the harness's law) is
already loaded by Claude Code via the `CLAUDE.md` `@AGENTS.md` import. On top of that the two
context hooks load two optional **slots** at fire time — `maestro-engage.sh` for the main session
(SessionStart: startup/resume/clear/compact) and `crew-context.sh` for every crew subagent
(SubagentStart), so main and crew see the same context:

- **Company slot** — *how this company works.* The HQ root resolves exactly like `team-board.sh`
  (`$MAESTRO_HQ`, else the `~/.claude/maestro-hq` pointer file); the target is
  `$HQ/knowledge/conventions.md`, printed under `[maestro] Company conventions:`.
- **Personal slot** — *who the human at this machine is.* Target `~/.claude/me.md`, overridable via
  the `$MAESTRO_ME` test seam, printed under `[maestro] About the human:`.

The hooks define only the slots, not the source files (the CTO and founder author those). Each slot
loads only if its file exists, is readable, and is non-blank; at most the first 60 lines print
(plus one truncation notice) so a runaway file can't tax every session and subagent. Company prints
before personal. Everything is read-only and fail-silent — a missing pointer, dead HQ path,
unreadable or non-UTF-8 file prints nothing for that slot and never breaks the hook (always exit 0),
mirroring the registry/staleness nudges.

**Nested repos — union of gates, never union of exemptions.** A git repo nested inside a protected
subtree of an outer repo (vendored dep with its own `.git`, accidental `git init`, fixture repo
under `src/`) resolves only to the **inner** root — which carries none of the outer repo's PROTECTED
config. The guards close this by walking the **enclosing-repo chain** (innermost → outermost, bounded
by the filesystem root):

- The **PROTECTED check is a union**: if ANY enclosing repo's protected list matches the target by
  THAT repo's own relative path, BLOCK.
- **Exemptions never flow across a repo boundary**: an inner repo's carve-outs (`docs/`,
  `.claude/maestro*` ledger, `.md` prose) or `maestro-direct` must NOT defeat an outer repo's
  PROTECTED — the outer-protection check runs before those exemptions apply. Within a *single* repo,
  that repo's own `maestro-direct` still exempts its own protected paths (round-1 per-repo carve-out).
- **`maestro-direct` is a per-repo property resolved per TARGET, never per session**: the guards
  carry no session-anchored direct-mode early-exit — a session in repo A (direct mode) cannot edit
  or shell-write repo B's PROTECTED files (that would union the exemption outward). The session
  repo's marker applies exactly where the session repo IS the governing repo: same-repo actions
  (the target resolves to the session repo, the common case) and the no-target fallback (`git reset
  --hard`, an empty `file_path` → the session repo governs and its own marker is honored).
- **Budget accounting stays anchored to the innermost (target) repo** — usage is computed against
  that repo's HEAD. Invariant on the safety spine: every failure/ambiguity over-blocks, never
  under-blocks; fail-open is reserved for "git unavailable / not a repo at all". `commit-gate` needs
  no nesting fix — committing in an inner repo is a commit to THAT repo, governed by its own
  ledger/verify; an inner commit cannot smuggle changes into an outer repo's history.

**One source for the shared guard logic.** Both guards make the same decisions from the same pure
helpers — protected-config load, glob/segment matching, the repo-root and enclosing-repo walks — so
those live ONCE in `maestro/hooks/guard_lib.py` (underscore name so it imports as a module; a
documented exception to the kebab-case rule). Each guard resolves its own real directory and imports
the lib from beside itself, so it is found in both the repo tree and the deployed `~/.claude/hooks/`
copy (install.sh copies it alongside the `.sh` hooks). A guard.test.sh assertion fails if any shared
helper is ever redefined inside a guard again — the divergence that bit us before (an ordering fix
landed in one copy, not the other) is now a test failure, not a latent bug.

## Crew management (matches pi)

Verified: pi foreman does NOT live-supervise the developer — it dispatches, the developer runs to
completion, then the controller checks the **output** (diff + tester judges it). Native Claude Code
subagents work the same way. No behavioral regression in moving off pi.

## What Workflow unlocks beyond pi's sequential loop

Pi foreman = sequential, one-agent-per-role, fixed cap. The Workflow tool adds parallel/dynamic
patterns pi can't do: parallel multi-file dev (worktree isolation), adversarial-verify panels
(N skeptics, majority vote), implementation tournaments (N approaches → judges → best), multi-lens
parallel review (correctness/security/perf/a11y), loop-until-dry, and budget-scaled rigor.
