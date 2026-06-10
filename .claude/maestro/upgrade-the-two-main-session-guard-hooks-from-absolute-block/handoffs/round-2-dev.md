Task: Upgrade the two main-session guard hooks from absolute blocks into BUDGET-GUARDS, add per-repo budget config + guard logging, and align the routing prose (CLAUDE.md + SKILL.md).

GOAL
Today guard-block-main-edits.sh and guard-block-main-bash.sh block ALL main-session mutations (binary: agent_id or nothing). We want risk-based routing: the main session (CTO) MAY make small direct edits within a deterministic budget, while big/risky changes still route through the maestro loop. "Small" = cumulative uncommitted diff vs HEAD stays within budget (default ≤50 changed lines AND ≤2 files) and the target is not a protected path. The guard's exit-2 stderr message is the re-prompt: when the budget is exhausted it must state current usage vs budget and instruct the model to run maestro for the REMAINDER of the task and never split a task to stay under the limit. All existing carve-outs must be preserved exactly: agent_id crew bypass, .claude/maestro-direct direct-edit mode, .claude/maestro* harness-state writes, tmp/scratch paths, prose/docs files (these continue to not count toward budget either).

CONTEXT TO READ FIRST
- hooks/guard-block-main-edits.sh (138 lines) — current edit guard; note the SECURITY comments: realpath canonicalization BEFORE prefix checks (anti-traversal), anchored maestro-state matching (lines 36-76), prose carve-out (lines 101-124). These properties must survive.
- hooks/guard-block-main-bash.sh (414 lines, python3) — quote-aware shlex tokenization, mutation classification, benign-target logic. Keep all classification; add the budget gate on top.
- hooks/commit-gate.sh — DO NOT TOUCH (it stays the final backstop).
- hooks/test/guard_scratch_test.sh (467 lines) — the existing 32-case battery; extend it.
- CLAUDE.md lines 13-27 ("The one rule" + Engagement) and skills/maestro/SKILL.md section 0 — the prose to re-route.

DELIVERABLES
1. guard-block-main-edits.sh: after the existing carve-outs, add in order: (a) PROTECTED-PATH check — if the canonical target matches a protected pattern, block regardless of budget with a message saying size does not matter on protected paths; (b) BUDGET check — measure cumulative changed lines + distinct files vs HEAD (git diff --numstat for tracked changes, plus untracked non-ignored files via git status --porcelain with their line counts), ADD the projected size of the incoming edit estimated from tool_input (old_string/new_string/content line counts) so a single oversized edit is caught BEFORE it lands; under budget → exit 0 (allow the direct edit), over → exit 2 with the usage-vs-budget re-prompt message.
2. guard-block-main-bash.sh: same budget gate for commands classified as mutating (current usage only, no projection — you cannot estimate a shell command's diff). Protected-path block when the mutation target is identifiable from the tokens. All read-only classification behavior unchanged.
3. Budget config: read .claude/maestro-budget at repo root, simple KEY=VALUE lines: LINES=50, FILES=2, optional PROTECTED=colon-separated glob list (e.g. **/auth/**:**/migrations/**:.github/workflows/**). Defaults 50/2 and an empty protected list when the file is absent. Malformed values → fall back to defaults. Document the format in README.md.
4. Guard log: every block (both guards, both reasons) appends one JSON line {ts, hook, target, lines_used, files_used, reason} to .claude/maestro/guard-log.jsonl so the founder can calibrate thresholds later. The log path is harness state (already allowed).
5. CLAUDE.md: replace "The one rule: orchestrate, never implement" section with a routing rule of similar length: main session MAY edit directly within the guard budget; route by risk/verifiability ("can you write the complete diff in your head before opening the file?" → direct; "does verification require running something?" → maestro); protected paths always maestro; hard creep rule (budget is cumulative per task — ten small edits are one big change; when the guard trips, move the remainder to maestro, never split); uncertain → maestro.
6. skills/maestro/SKILL.md section 0 (Engagement): align with the same routing in 2-3 sentences.
7. hooks/test/guard_scratch_test.sh: extend the battery — new cases: under-budget edit allowed; cumulative creep (several small edits then one that crosses the line) blocked; single oversized edit blocked via projection; protected path blocked even at zero usage; untracked new file counted; custom .claude/maestro-budget respected; guard-log.jsonl line written on block; all existing 32 cases still pass unchanged (agent_id, maestro-direct, maestro-state, tmp, prose, traversal security cases).

CONSTRAINTS / NON-GOALS
- Do NOT touch variants/personal/maestro-mcp/** (the MCP autonomy parameter is a separate future task) and do NOT touch hooks/commit-gate.sh or hooks/maestro-engage.sh.
- Dependency-light: bash/python3/jq/git only, as now. No node, no new packages.
- The budget additions must not weaken the existing security properties: canonicalize before any path comparison; protected-pattern matching operates on canonical paths; no traversal bypass into or out of the budget logic.
- Fail-open decision: if the cwd is not a git repo or git fails, the budget cannot be measured — in that case ALLOW the edit (comment why: tester/reviewer/commit-gate remain the backstops, and non-repo dirs have no production risk). Unparseable hook payload stays fail-open as today.
- Keep the two block messages short and written FOR THE MODEL (they are re-prompts, not human error pages).

ACCEPTANCE / VERIFY
bash hooks/test/guard_scratch_test.sh — the full extended battery must pass (old 32 + new budget/protected/log/config cases). The tester should also sanity-read the CLAUDE.md/SKILL.md diff for consistency with the new guard behavior (no leftover "never edit" absolutes).

Assumptions:
- Budget is measured against the repo at the canonical CLAUDE_PROJECT_DIR (falling back to PWD), using `git -C <proj>`, consistent with how the guards already resolve _canon_proj. (confidence: medium)
- 'Changed lines' = sum of added+deleted from git diff --numstat (binary/`-` rows contribute 0 lines but still count as a changed file); untracked non-ignored files contribute their wc -l line count and 1 file each. (confidence: medium)
- Budget over = lines_used > LINES OR files_used > FILES (both limits enforced; exceeding either trips). Equality is within budget. (confidence: medium)
- Protected globs are matched against the target's path RELATIVE to the canonical repo root, supporting ** (any depth) and * (single segment) via a small glob->regex translation; absolute-form patterns also tolerated. (confidence: low)
- Budget logic is inlined into each guard (no new helper file) because install.sh only symlinks hooks/*.sh; this keeps deployment unchanged and honors the no-new-packages constraint. (confidence: high)
- For the bash guard, the protected/target check applies only when a single mutation target is cleanly identifiable from the tokens; otherwise it falls through to the current-usage budget gate. (confidence: medium)
- guard-log.jsonl ts is an ISO-8601/UTC timestamp; one compact JSON object per line; written best-effort (a log-write failure never changes the allow/block decision). (confidence: medium)
- Tests run against throwaway git repos under $TMPDIR with CLAUDE_PROJECT_DIR set, so budget and log assertions are deterministic and do not touch the real .claude/. (confidence: high)
Non-goals:
- Do NOT modify hooks/commit-gate.sh or hooks/maestro-engage.sh.
- Do NOT touch variants/personal/maestro-mcp/** (MCP autonomy is a separate future task).
- No new runtime dependencies — bash/python3/jq/git only; no node, no packages, no new symlinked helper files.
- Not rewriting the bash guard's mutation classification, heredoc handling, or benign-target logic — only layering the budget/protected gate on top.
- Not editing AGENTS.md prose in this task (the deliverables scope prose to CLAUDE.md + SKILL.md); flagged as a consistency risk for founder call.
- Not making the budget account-aware or per-session-persistent beyond the live `git diff vs HEAD` measurement.

Implement the smallest change that satisfies the task on disk. End your final message with a ---DEV-JSON--- block: {"filesChanged":["path - what changed"]}.