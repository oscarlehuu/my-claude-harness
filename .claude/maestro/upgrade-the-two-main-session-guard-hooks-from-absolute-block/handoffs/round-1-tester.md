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

The developer reported filesChanged: [].
Per-round command gate result: pass. A non-zero command gate is FAIL regardless.

Judge whether the DIFF below genuinely satisfies the GOAL (catch cheats). End with VERDICT: PASS|FAIL|PARTIAL|BLOCKED.

DIFF:
diff --git a/.claude/maestro/upgrade-the-two-main-session-guard-hooks-from-absolute-block/handoffs/round-1-dev.md b/.claude/maestro/upgrade-the-two-main-session-guard-hooks-from-absolute-block/handoffs/round-1-dev.md
new file mode 100644
index 0000000..d4ff6bc
--- /dev/null
+++ b/.claude/maestro/upgrade-the-two-main-session-guard-hooks-from-absolute-block/handoffs/round-1-dev.md
@@ -0,0 +1,49 @@
+Task: Upgrade the two main-session guard hooks from absolute blocks into BUDGET-GUARDS, add per-repo budget config + guard logging, and align the routing prose (CLAUDE.md + SKILL.md).
+
+GOAL
+Today guard-block-main-edits.sh and guard-block-main-bash.sh block ALL main-session mutations (binary: agent_id or nothing). We want risk-based routing: the main session (CTO) MAY make small direct edits within a deterministic budget, while big/risky changes still route through the maestro loop. "Small" = cumulative uncommitted diff vs HEAD stays within budget (default ≤50 changed lines AND ≤2 files) and the target is not a protected path. The guard's exit-2 stderr message is the re-prompt: when the budget is exhausted it must state current usage vs budget and instruct the model to run maestro for the REMAINDER of the task and never split a task to stay under the limit. All existing carve-outs must be preserved exactly: agent_id crew bypass, .claude/maestro-direct direct-edit mode, .claude/maestro* harness-state writes, tmp/scratch paths, prose/docs files (these continue to not count toward budget either).
+
+CONTEXT TO READ FIRST
+- hooks/guard-block-main-edits.sh (138 lines) — current edit guard; note the SECURITY comments: realpath canonicalization BEFORE prefix checks (anti-traversal), anchored maestro-state matching (lines 36-76), prose carve-out (lines 101-124). These properties must survive.
+- hooks/guard-block-main-bash.sh (414 lines, python3) — quote-aware shlex tokenization, mutation classification, benign-target logic. Keep all classification; add the budget gate on top.
+- hooks/commit-gate.sh — DO NOT TOUCH (it stays the final backstop).
+- hooks/test/guard_scratch_test.sh (467 lines) — the existing 32-case battery; extend it.
+- CLAUDE.md lines 13-27 ("The one rule" + Engagement) and skills/maestro/SKILL.md section 0 — the prose to re-route.
+
+DELIVERABLES
+1. guard-block-main-edits.sh: after the existing carve-outs, add in order: (a) PROTECTED-PATH check — if the canonical target matches a protected pattern, block regardless of budget with a message saying size does not matter on protected paths; (b) BUDGET check — measure cumulative changed lines + distinct files vs HEAD (git diff --numstat for tracked changes, plus untracked non-ignored files via git status --porcelain with their line counts), ADD the projected size of the incoming edit estimated from tool_input (old_string/new_string/content line counts) so a single oversized edit is caught BEFORE it lands; under budget → exit 0 (allow the direct edit), over → exit 2 with the usage-vs-budget re-prompt message.
+2. guard-block-main-bash.sh: same budget gate for commands classified as mutating (current usage only, no projection — you cannot estimate a shell command's diff). Protected-path block when the mutation target is identifiable from the tokens. All read-only classification behavior unchanged.
+3. Budget config: read .claude/maestro-budget at repo root, simple KEY=VALUE lines: LINES=50, FILES=2, optional PROTECTED=colon-separated glob list (e.g. **/auth/**:**/migrations/**:.github/workflows/**). Defaults 50/2 and an empty protected list when the file is absent. Malformed values → fall back to defaults. Document the format in README.md.
+4. Guard log: every block (both guards, both reasons) appends one JSON line {ts, hook, target, lines_used, files_used, reason} to .claude/maestro/guard-log.jsonl so the founder can calibrate thresholds later. The log path is harness state (already allowed).
+5. CLAUDE.md: replace "The one rule: orchestrate, never implement" section with a routing rule of similar length: main session MAY edit directly within the guard budget; route by risk/verifiability ("can you write the complete diff in your head before opening the file?" → direct; "does verification require running something?" → maestro); protected paths always maestro; hard creep rule (budget is cumulative per task — ten small edits are one big change; when the guard trips, move the remainder to maestro, never split); uncertain → maestro.
+6. skills/maestro/SKILL.md section 0 (Engagement): align with the same routing in 2-3 sentences.
+7. hooks/test/guard_scratch_test.sh: extend the battery — new cases: under-budget edit allowed; cumulative creep (several small edits then one that crosses the line) blocked; single oversized edit blocked via projection; protected path blocked even at zero usage; untracked new file counted; custom .claude/maestro-budget respected; guard-log.jsonl line written on block; all existing 32 cases still pass unchanged (agent_id, maestro-direct, maestro-state, tmp, prose, traversal security cases).
+
+CONSTRAINTS / NON-GOALS
+- Do NOT touch variants/personal/maestro-mcp/** (the MCP autonomy parameter is a separate future task) and do NOT touch hooks/commit-gate.sh or hooks/maestro-engage.sh.
+- Dependency-light: bash/python3/jq/git only, as now. No node, no new packages.
+- The budget additions must not weaken the existing security properties: canonicalize before any path comparison; protected-pattern matching operates on canonical paths; no traversal bypass into or out of the budget logic.
+- Fail-open decision: if the cwd is not a git repo or git fails, the budget cannot be measured — in that case ALLOW the edit (comment why: tester/reviewer/commit-gate remain the backstops, and non-repo dirs have no production risk). Unparseable hook payload stays fail-open as today.
+- Keep the two block messages short and written FOR THE MODEL (they are re-prompts, not human error pages).
+
+ACCEPTANCE / VERIFY
+bash hooks/test/guard_scratch_test.sh — the full extended battery must pass (old 32 + new budget/protected/log/config cases). The tester should also sanity-read the CLAUDE.md/SKILL.md diff for consistency with the new guard behavior (no leftover "never edit" absolutes).
+
+Assumptions:
+- Budget is measured against the repo at the canonical CLAUDE_PROJECT_DIR (falling back to PWD), using `git -C <proj>`, consistent with how the guards already resolve _canon_proj. (confidence: medium)
+- 'Changed lines' = sum of added+deleted from git diff --numstat (binary/`-` rows contribute 0 lines but still count as a changed file); untracked non-ignored files contribute their wc -l line count and 1 file each. (confidence: medium)
+- Budget over = lines_used > LINES OR files_used > FILES (both limits enforced; exceeding either trips). Equality is within budget. (confidence: medium)
+- Protected globs are matched against the target's path RELATIVE to the canonical repo root, supporting ** (any depth) and * (single segment) via a small glob->regex translation; absolute-form patterns also tolerated. (confidence: low)
+- Budget logic is inlined into each guard (no new helper file) because install.sh only symlinks hooks/*.sh; this keeps deployment unchanged and honors the no-new-packages constraint. (confidence: high)
+- For the bash guard, the protected/target check applies only when a single mutation target is cleanly identifiable from the tokens; otherwise it falls through to the current-usage budget gate. (confidence: medium)
+- guard-log.jsonl ts is an ISO-8601/UTC timestamp; one compact JSON object per line; written best-effort (a log-write failure never changes the allow/block decision). (confidence: medium)
+- Tests run against throwaway git repos under $TMPDIR with CLAUDE_PROJECT_DIR set, so budget and log assertions are deterministic and do not touch the real .claude/. (confidence: high)
+Non-goals:
+- Do NOT modify hooks/commit-gate.sh or hooks/maestro-engage.sh.
+- Do NOT touch variants/personal/maestro-mcp/** (MCP autonomy is a separate future task).
+- No new runtime dependencies — bash/python3/jq/git only; no node, no packages, no new symlinked helper files.
+- Not rewriting the bash guard's mutation classification, heredoc handling, or benign-target logic — only layering the budget/protected gate on top.
+- Not editing AGENTS.md prose in this task (the deliverables scope prose to CLAUDE.md + SKILL.md); flagged as a consistency risk for founder call.
+- Not making the budget account-aware or per-session-persistent beyond the live `git diff vs HEAD` measurement.
+
+Implement the smallest change that satisfies the task on disk. End your final message with a ---DEV-JSON--- block: {"filesChanged":["path - what changed"]}.
\ No newline at end of file
diff --git a/.claude/maestro/upgrade-the-two-main-session-guard-hooks-from-absolute-block/log.jsonl b/.claude/maestro/upgrade-the-two-main-session-guard-hooks-from-absolute-block/log.jsonl
new file mode 100644
index 0000000..774f913
--- /dev/null
+++ b/.claude/maestro/upgrade-the-two-main-session-guard-hooks-from-absolute-block/log.jsonl
@@ -0,0 +1,193 @@
+{"t":"2026-06-10T06:07:20.944Z","type":"task_start","task":"Upgrade the two main-session guard hooks from absolute blocks into BUDGET-GUARDS, add per-repo budget config + guard logging, and align the routing prose (CLAUDE.md + SKILL.md).\n\nGOAL\nToday guard-block-main-edits.sh and guard-block-main-bash.sh block ALL main-session mutations (binary: agent_id or nothing). We want risk-based routing: the main session (CTO) MAY make small direct edits within a deterministic budget, while big/risky changes still route through the maestro loop. \"Small\" = cumulative uncommitted diff vs HEAD stays within budget (default ≤50 changed lines AND ≤2 files) and the target is not a protected path. The guard's exit-2 stderr message is the re-prompt: when the budget is exhausted it must state current usage vs budget and instruct the model to run maestro for the REMAINDER of the task and never split a task to stay under the limit. All existing carve-outs must be preserved exactly: agent_id crew bypass, .claude/maestro-direct direct-edit mode, .claude/maestro* harness-state writes, tmp/scratch paths, prose/docs files (these continue to not count toward budget either).\n\nCONTEXT TO READ FIRST\n- hooks/guard-block-main-edits.sh (138 lines) — current edit guard; note the SECURITY comments: realpath canonicalization BEFORE prefix checks (anti-traversal), anchored maestro-state matching (lines 36-76), prose carve-out (lines 101-124). These properties must survive.\n- hooks/guard-block-main-bash.sh (414 lines, python3) — quote-aware shlex tokenization, mutation classification, benign-target logic. Keep all classification; add the budget gate on top.\n- hooks/commit-gate.sh — DO NOT TOUCH (it stays the final backstop).\n- hooks/test/guard_scratch_test.sh (467 lines) — the existing 32-case battery; extend it.\n- CLAUDE.md lines 13-27 (\"The one rule\" + Engagement) and skills/maestro/SKILL.md section 0 — the prose to re-route.\n\nDELIVERABLES\n1. guard-block-main-edits.sh: after the existing carve-outs, add in order: (a) PROTECTED-PATH check — if the canonical target matches a protected pattern, block regardless of budget with a message saying size does not matter on protected paths; (b) BUDGET check — measure cumulative changed lines + distinct files vs HEAD (git diff --numstat for tracked changes, plus untracked non-ignored files via git status --porcelain with their line counts), ADD the projected size of the incoming edit estimated from tool_input (old_string/new_string/content line counts) so a single oversized edit is caught BEFORE it lands; under budget → exit 0 (allow the direct edit), over → exit 2 with the usage-vs-budget re-prompt message.\n2. guard-block-main-bash.sh: same budget gate for commands classified as mutating (current usage only, no projection — you cannot estimate a shell command's diff). Protected-path block when the mutation target is identifiable from the tokens. All read-only classification behavior unchanged.\n3. Budget config: read .claude/maestro-budget at repo root, simple KEY=VALUE lines: LINES=50, FILES=2, optional PROTECTED=colon-separated glob list (e.g. **/auth/**:**/migrations/**:.github/workflows/**). Defaults 50/2 and an empty protected list when the file is absent. Malformed values → fall back to defaults. Document the format in README.md.\n4. Guard log: every block (both guards, both reasons) appends one JSON line {ts, hook, target, lines_used, files_used, reason} to .claude/maestro/guard-log.jsonl so the founder can calibrate thresholds later. The log path is harness state (already allowed).\n5. CLAUDE.md: replace \"The one rule: orchestrate, never implement\" section with a routing rule of similar length: main session MAY edit directly within the guard budget; route by risk/verifiability (\"can you write the complete diff in your head before opening the file?\" → direct; \"does verification require running something?\" → maestro); protected paths always maestro; hard creep rule (budget is cumulative per task — ten small edits are one big change; when the guard trips, move the remainder to maestro, never split); uncertain → maestro.\n6. skills/maestro/SKILL.md section 0 (Engagement): align with the same routing in 2-3 sentences.\n7. hooks/test/guard_scratch_test.sh: extend the battery — new cases: under-budget edit allowed; cumulative creep (several small edits then one that crosses the line) blocked; single oversized edit blocked via projection; protected path blocked even at zero usage; untracked new file counted; custom .claude/maestro-budget respected; guard-log.jsonl line written on block; all existing 32 cases still pass unchanged (agent_id, maestro-direct, maestro-state, tmp, prose, traversal security cases).\n\nCONSTRAINTS / NON-GOALS\n- Do NOT touch variants/personal/maestro-mcp/** (the MCP autonomy parameter is a separate future task) and do NOT touch hooks/commit-gate.sh or hooks/maestro-engage.sh.\n- Dependency-light: bash/python3/jq/git only, as now. No node, no new packages.\n- The budget additions must not weaken the existing security properties: canonicalize before any path comparison; protected-pattern matching operates on canonical paths; no traversal bypass into or out of the budget logic.\n- Fail-open decision: if the cwd is not a git repo or git fails, the budget cannot be measured — in that case ALLOW the edit (comment why: tester/reviewer/commit-gate remain the backstops, and non-repo dirs have no production risk). Unparseable hook payload stays fail-open as today.\n- Keep the two block messages short and written FOR THE MODEL (they are re-prompts, not human error pages).\n\nACCEPTANCE / VERIFY\nbash hooks/test/guard_scratch_test.sh — the full extended battery must pass (old 32 + new budget/protected/log/config cases). The tester should also sanity-read the CLAUDE.md/SKILL.md diff for consistency with the new guard behavior (no leftover \"never edit\" absolutes).","track":"backend"}
+{"t":"2026-06-10T06:07:20.947Z","type":"crew","role":"planner","kind":"model_call","step":0}
+{"t":"2026-06-10T06:07:23.636Z","type":"crew","role":"planner","kind":"tool_call","name":"read_file","step":0}
+{"t":"2026-06-10T06:07:23.636Z","type":"crew","role":"planner","kind":"tool_result","name":"read_file","step":0}
+{"t":"2026-06-10T06:07:23.637Z","type":"crew","role":"planner","kind":"tool_call","name":"read_file","step":0}
+{"t":"2026-06-10T06:07:23.637Z","type":"crew","role":"planner","kind":"tool_result","name":"read_file","step":0}
+{"t":"2026-06-10T06:07:23.637Z","type":"crew","role":"planner","kind":"model_call","step":1}
+{"t":"2026-06-10T06:07:32.470Z","type":"crew","role":"planner","kind":"tool_call","name":"read_file","step":1}
+{"t":"2026-06-10T06:07:32.473Z","type":"crew","role":"planner","kind":"tool_result","name":"read_file","step":1}
+{"t":"2026-06-10T06:07:32.473Z","type":"crew","role":"planner","kind":"tool_call","name":"read_file","step":1}
+{"t":"2026-06-10T06:07:32.473Z","type":"crew","role":"planner","kind":"tool_result","name":"read_file","step":1}
+{"t":"2026-06-10T06:07:32.474Z","type":"crew","role":"planner","kind":"model_call","step":2}
+{"t":"2026-06-10T06:07:36.266Z","type":"crew","role":"planner","kind":"tool_call","name":"read_file","step":2}
+{"t":"2026-06-10T06:07:36.268Z","type":"crew","role":"planner","kind":"tool_result","name":"read_file","step":2}
+{"t":"2026-06-10T06:07:36.268Z","type":"crew","role":"planner","kind":"tool_call","name":"list_dir","step":2}
+{"t":"2026-06-10T06:07:36.268Z","type":"crew","role":"planner","kind":"tool_result","name":"list_dir","step":2}
+{"t":"2026-06-10T06:07:36.268Z","type":"crew","role":"planner","kind":"model_call","step":3}
+{"t":"2026-06-10T06:07:42.581Z","type":"crew","role":"planner","kind":"tool_call","name":"Bash","step":3}
+{"t":"2026-06-10T06:07:42.581Z","type":"crew","role":"planner","kind":"tool_result","name":"Bash","step":3}
+{"t":"2026-06-10T06:07:42.581Z","type":"crew","role":"planner","kind":"tool_call","name":"list_dir","step":3}
+{"t":"2026-06-10T06:07:42.582Z","type":"crew","role":"planner","kind":"tool_result","name":"list_dir","step":3}
+{"t":"2026-06-10T06:07:42.582Z","type":"crew","role":"planner","kind":"model_call","step":4}
+{"t":"2026-06-10T06:07:46.547Z","type":"crew","role":"planner","kind":"tool_call","name":"Bash","step":4}
+{"t":"2026-06-10T06:07:46.547Z","type":"crew","role":"planner","kind":"tool_result","name":"Bash","step":4}
+{"t":"2026-06-10T06:07:46.547Z","type":"crew","role":"planner","kind":"model_call","step":5}
+{"t":"2026-06-10T06:07:52.574Z","type":"crew","role":"planner","kind":"tool_call","name":"list_dir","step":5}
+{"t":"2026-06-10T06:07:52.575Z","type":"crew","role":"planner","kind":"tool_result","name":"list_dir","step":5}
+{"t":"2026-06-10T06:07:52.575Z","type":"crew","role":"planner","kind":"tool_call","name":"list_dir","step":5}
+{"t":"2026-06-10T06:07:52.575Z","type":"crew","role":"planner","kind":"tool_result","name":"list_dir","step":5}
+{"t":"2026-06-10T06:07:52.575Z","type":"crew","role":"planner","kind":"model_call","step":6}
+{"t":"2026-06-10T06:07:55.023Z","type":"crew","role":"planner","kind":"tool_call","name":"read_file","step":6}
+{"t":"2026-06-10T06:07:55.024Z","type":"crew","role":"planner","kind":"tool_result","name":"read_file","step":6}
+{"t":"2026-06-10T06:07:55.024Z","type":"crew","role":"planner","kind":"model_call","step":7}
+{"t":"2026-06-10T06:07:58.902Z","type":"crew","role":"planner","kind":"tool_call","name":"read_file","step":7}
+{"t":"2026-06-10T06:07:58.904Z","type":"crew","role":"planner","kind":"tool_result","name":"read_file","step":7}
+{"t":"2026-06-10T06:07:58.904Z","type":"crew","role":"planner","kind":"tool_call","name":"read_file","step":7}
+{"t":"2026-06-10T06:07:58.904Z","type":"crew","role":"planner","kind":"tool_result","name":"read_file","step":7}
+{"t":"2026-06-10T06:07:58.905Z","type":"crew","role":"planner","kind":"model_call","step":8}
+{"t":"2026-06-10T06:09:26.095Z","type":"crew","role":"planner","kind":"tool_call","name":"list_dir","step":8}
+{"t":"2026-06-10T06:09:26.096Z","type":"crew","role":"planner","kind":"tool_result","name":"list_dir","step":8}
+{"t":"2026-06-10T06:09:26.096Z","type":"crew","role":"planner","kind":"tool_call","name":"list_dir","step":8}
+{"t":"2026-06-10T06:09:26.096Z","type":"crew","role":"planner","kind":"tool_result","name":"list_dir","step":8}
+{"t":"2026-06-10T06:09:26.096Z","type":"crew","role":"planner","kind":"tool_call","name":"list_dir","step":8}
+{"t":"2026-06-10T06:09:26.096Z","type":"crew","role":"planner","kind":"tool_result","name":"list_dir","step":8}
+{"t":"2026-06-10T06:09:26.096Z","type":"crew","role":"planner","kind":"model_call","step":9}
+{"t":"2026-06-10T06:09:29.041Z","type":"crew","role":"planner","kind":"tool_call","name":"read_file","step":9}
+{"t":"2026-06-10T06:09:29.041Z","type":"crew","role":"planner","kind":"tool_result","name":"read_file","step":9}
+{"t":"2026-06-10T06:09:29.041Z","type":"crew","role":"planner","kind":"model_call","step":10}
+{"t":"2026-06-10T06:10:19.636Z","type":"crew","role":"planner","kind":"tool_call","name":"read_file","step":10}
+{"t":"2026-06-10T06:10:19.638Z","type":"crew","role":"planner","kind":"tool_result","name":"read_file","step":10}
+{"t":"2026-06-10T06:10:19.638Z","type":"crew","role":"planner","kind":"tool_call","name":"Grep","step":10}
+{"t":"2026-06-10T06:10:19.638Z","type":"crew","role":"planner","kind":"tool_result","name":"Grep","step":10}
+{"t":"2026-06-10T06:10:19.638Z","type":"crew","role":"planner","kind":"model_call","step":11}
+{"t":"2026-06-10T06:11:42.941Z","type":"crew","role":"planner","kind":"tool_call","name":"read_file","step":11}
+{"t":"2026-06-10T06:11:42.943Z","type":"crew","role":"planner","kind":"tool_result","name":"read_file","step":11}
+{"t":"2026-06-10T06:11:42.943Z","type":"crew","role":"planner","kind":"model_call","step":12}
+{"t":"2026-06-10T06:13:19.802Z","type":"crew","role":"planner","kind":"final","step":12}
+{"t":"2026-06-10T06:13:19.806Z","type":"gate1_awaiting","source":"planner","summary":"Convert the two absolute main-session guards into risk-based BUDGET-GUARDS: after all existing carve-outs, add a protected-path block then a cumulative-diff budget gate (default <=50 lines AND <=2 files vs HEAD; edit guard also projects the incoming edit's size). Add per-repo .claude/maestro-budget config, JSONL guard logging on every block, and re-route the prose in CLAUDE.md + SKILL.md from 'never edit' to 'edit small within budget, else maestro'. Extend the 32-case test battery with budget/projection/protected/untracked/config/log cases."}
+{"t":"2026-06-10T06:14:50.882Z","type":"gate1_approved"}
+{"t":"2026-06-10T06:14:50.885Z","type":"crew","role":"developer","kind":"model_call","step":0}
+{"t":"2026-06-10T06:14:53.255Z","type":"crew","role":"developer","kind":"tool_call","name":"list_dir","step":0}
+{"t":"2026-06-10T06:14:53.256Z","type":"crew","role":"developer","kind":"tool_result","name":"list_dir","step":0}
+{"t":"2026-06-10T06:14:53.256Z","type":"crew","role":"developer","kind":"model_call","step":1}
+{"t":"2026-06-10T06:14:56.878Z","type":"crew","role":"developer","kind":"tool_call","name":"read_file","step":1}
+{"t":"2026-06-10T06:14:56.881Z","type":"crew","role":"developer","kind":"tool_result","name":"read_file","step":1}
+{"t":"2026-06-10T06:14:56.881Z","type":"crew","role":"developer","kind":"tool_call","name":"read_file","step":1}
+{"t":"2026-06-10T06:14:56.881Z","type":"crew","role":"developer","kind":"tool_result","name":"read_file","step":1}
+{"t":"2026-06-10T06:14:56.881Z","type":"crew","role":"developer","kind":"tool_call","name":"read_file","step":1}
+{"t":"2026-06-10T06:14:56.882Z","type":"crew","role":"developer","kind":"tool_result","name":"read_file","step":1}
+{"t":"2026-06-10T06:14:56.882Z","type":"crew","role":"developer","kind":"tool_call","name":"read_file","step":1}
+{"t":"2026-06-10T06:14:56.883Z","type":"crew","role":"developer","kind":"tool_result","name":"read_file","step":1}
+{"t":"2026-06-10T06:14:56.883Z","type":"crew","role":"developer","kind":"tool_call","name":"read_file","step":1}
+{"t":"2026-06-10T06:14:56.883Z","type":"crew","role":"developer","kind":"tool_result","name":"read_file","step":1}
+{"t":"2026-06-10T06:14:56.883Z","type":"crew","role":"developer","kind":"tool_call","name":"read_file","step":1}
+{"t":"2026-06-10T06:14:56.883Z","type":"crew","role":"developer","kind":"tool_result","name":"read_file","step":1}
+{"t":"2026-06-10T06:14:56.883Z","type":"crew","role":"developer","kind":"model_call","step":2}
+{"t":"2026-06-10T06:17:40.620Z","type":"crew","role":"developer","kind":"tool_call","name":"write_file","step":2}
+{"t":"2026-06-10T06:17:40.622Z","type":"crew","role":"developer","kind":"tool_result","name":"write_file","step":2}
+{"t":"2026-06-10T06:17:40.622Z","type":"crew","role":"developer","kind":"model_call","step":3}
+{"t":"2026-06-10T06:19:38.959Z","type":"crew","role":"developer","kind":"tool_call","name":"write_file","step":3}
+{"t":"2026-06-10T06:19:38.962Z","type":"crew","role":"developer","kind":"tool_result","name":"write_file","step":3}
+{"t":"2026-06-10T06:19:38.962Z","type":"crew","role":"developer","kind":"model_call","step":4}
+{"t":"2026-06-10T06:20:07.093Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":4}
+{"t":"2026-06-10T06:20:07.228Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":4}
+{"t":"2026-06-10T06:20:07.228Z","type":"crew","role":"developer","kind":"model_call","step":5}
+{"t":"2026-06-10T06:20:13.151Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":5}
+{"t":"2026-06-10T06:20:13.226Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":5}
+{"t":"2026-06-10T06:20:13.226Z","type":"crew","role":"developer","kind":"model_call","step":6}
+{"t":"2026-06-10T06:20:22.394Z","type":"crew","role":"developer","kind":"tool_call","name":"list_dir","step":6}
+{"t":"2026-06-10T06:20:22.395Z","type":"crew","role":"developer","kind":"tool_result","name":"list_dir","step":6}
+{"t":"2026-06-10T06:20:22.395Z","type":"crew","role":"developer","kind":"model_call","step":7}
+{"t":"2026-06-10T06:20:32.801Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":7}
+{"t":"2026-06-10T06:20:32.876Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":7}
+{"t":"2026-06-10T06:20:32.876Z","type":"crew","role":"developer","kind":"model_call","step":8}
+{"t":"2026-06-10T06:21:04.159Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":8}
+{"t":"2026-06-10T06:21:04.638Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":8}
+{"t":"2026-06-10T06:21:04.638Z","type":"crew","role":"developer","kind":"model_call","step":9}
+{"t":"2026-06-10T06:21:17.397Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":9}
+{"t":"2026-06-10T06:21:17.614Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":9}
+{"t":"2026-06-10T06:21:17.614Z","type":"crew","role":"developer","kind":"model_call","step":10}
+{"t":"2026-06-10T06:21:31.022Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":10}
+{"t":"2026-06-10T06:21:31.049Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":10}
+{"t":"2026-06-10T06:21:31.050Z","type":"crew","role":"developer","kind":"model_call","step":11}
+{"t":"2026-06-10T06:24:15.347Z","type":"crew","role":"developer","kind":"tool_call","name":"write_file","step":11}
+{"t":"2026-06-10T06:24:15.351Z","type":"crew","role":"developer","kind":"tool_result","name":"write_file","step":11}
+{"t":"2026-06-10T06:24:15.351Z","type":"crew","role":"developer","kind":"model_call","step":12}
+{"t":"2026-06-10T06:24:19.188Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":12}
+{"t":"2026-06-10T06:24:19.208Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":12}
+{"t":"2026-06-10T06:24:19.208Z","type":"crew","role":"developer","kind":"model_call","step":13}
+{"t":"2026-06-10T06:24:21.135Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":13}
+{"t":"2026-06-10T06:24:27.205Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":13}
+{"t":"2026-06-10T06:24:27.206Z","type":"crew","role":"developer","kind":"model_call","step":14}
+{"t":"2026-06-10T06:24:36.948Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":14}
+{"t":"2026-06-10T06:24:37.301Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":14}
+{"t":"2026-06-10T06:24:37.301Z","type":"crew","role":"developer","kind":"model_call","step":15}
+{"t":"2026-06-10T06:24:56.276Z","type":"crew","role":"developer","kind":"tool_call","name":"edit_file","step":15}
+{"t":"2026-06-10T06:24:56.277Z","type":"crew","role":"developer","kind":"tool_result","name":"edit_file","step":15}
+{"t":"2026-06-10T06:24:56.277Z","type":"crew","role":"developer","kind":"model_call","step":16}
+{"t":"2026-06-10T06:25:01.409Z","type":"crew","role":"developer","kind":"tool_call","name":"edit_file","step":16}
+{"t":"2026-06-10T06:25:01.410Z","type":"crew","role":"developer","kind":"tool_result","name":"edit_file","step":16}
+{"t":"2026-06-10T06:25:01.410Z","type":"crew","role":"developer","kind":"model_call","step":17}
+{"t":"2026-06-10T06:25:03.527Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":17}
+{"t":"2026-06-10T06:25:11.569Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":17}
+{"t":"2026-06-10T06:25:11.571Z","type":"crew","role":"developer","kind":"model_call","step":18}
+{"t":"2026-06-10T06:25:18.148Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":18}
+{"t":"2026-06-10T06:25:18.311Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":18}
+{"t":"2026-06-10T06:25:18.311Z","type":"crew","role":"developer","kind":"model_call","step":19}
+{"t":"2026-06-10T06:25:22.446Z","type":"crew","role":"developer","kind":"tool_call","name":"edit_file","step":19}
+{"t":"2026-06-10T06:25:22.447Z","type":"crew","role":"developer","kind":"tool_result","name":"edit_file","step":19}
+{"t":"2026-06-10T06:25:22.447Z","type":"crew","role":"developer","kind":"model_call","step":20}
+{"t":"2026-06-10T06:25:25.693Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":20}
+{"t":"2026-06-10T06:25:25.693Z","type":"loop_warning","role":"developer","round":1,"pattern":"identical_tool_call","signature":"identical_tool_call:bash:2eb0266717e8e284","summary":"identical bash call x3: bash hooks/test/guard_scratch_test.sh"}
+{"t":"2026-06-10T06:25:32.726Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":20}
+{"t":"2026-06-10T06:25:32.726Z","type":"loop_warning","role":"developer","round":1,"pattern":"repeated_error_signature","signature":"repeated_error_signature:bash:1f09a1d5882e7fbb","summary":"repeated bash error x3: exit === edit-guard carve-out and protected-path tests === pass [write /tmp/bench.mjs (no agent_id) → allow] (exit ) pass [write $tmpdir/sc…"}
+{"t":"2026-06-10T06:25:32.726Z","type":"crew","role":"developer","kind":"model_call","step":21}
+{"t":"2026-06-10T06:25:41.744Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":21}
+{"t":"2026-06-10T06:25:41.919Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":21}
+{"t":"2026-06-10T06:25:41.919Z","type":"crew","role":"developer","kind":"model_call","step":22}
+{"t":"2026-06-10T06:25:46.147Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":22}
+{"t":"2026-06-10T06:25:46.201Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":22}
+{"t":"2026-06-10T06:25:46.202Z","type":"crew","role":"developer","kind":"model_call","step":23}
+{"t":"2026-06-10T06:25:57.199Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":23}
+{"t":"2026-06-10T06:25:57.258Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":23}
+{"t":"2026-06-10T06:25:57.259Z","type":"crew","role":"developer","kind":"model_call","step":24}
+{"t":"2026-06-10T06:26:19.948Z","type":"crew","role":"developer","kind":"tool_call","name":"edit_file","step":24}
+{"t":"2026-06-10T06:26:19.949Z","type":"crew","role":"developer","kind":"tool_result","name":"edit_file","step":24}
+{"t":"2026-06-10T06:26:19.949Z","type":"crew","role":"developer","kind":"model_call","step":25}
+{"t":"2026-06-10T06:26:23.957Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":25}
+{"t":"2026-06-10T06:26:32.063Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":25}
+{"t":"2026-06-10T06:26:32.064Z","type":"crew","role":"developer","kind":"model_call","step":26}
+{"t":"2026-06-10T06:26:37.689Z","type":"crew","role":"developer","kind":"tool_call","name":"edit_file","step":26}
+{"t":"2026-06-10T06:26:37.691Z","type":"crew","role":"developer","kind":"tool_result","name":"edit_file","step":26}
+{"t":"2026-06-10T06:26:37.692Z","type":"crew","role":"developer","kind":"model_call","step":27}
+{"t":"2026-06-10T06:26:51.003Z","type":"crew","role":"developer","kind":"tool_call","name":"edit_file","step":27}
+{"t":"2026-06-10T06:26:51.004Z","type":"crew","role":"developer","kind":"tool_result","name":"edit_file","step":27}
+{"t":"2026-06-10T06:26:51.004Z","type":"crew","role":"developer","kind":"model_call","step":28}
+{"t":"2026-06-10T06:26:53.636Z","type":"crew","role":"developer","kind":"tool_call","name":"grep","step":28}
+{"t":"2026-06-10T06:26:53.659Z","type":"crew","role":"developer","kind":"tool_result","name":"grep","step":28}
+{"t":"2026-06-10T06:26:53.660Z","type":"crew","role":"developer","kind":"model_call","step":29}
+{"t":"2026-06-10T06:26:58.859Z","type":"crew","role":"developer","kind":"tool_call","name":"edit_file","step":29}
+{"t":"2026-06-10T06:26:58.862Z","type":"crew","role":"developer","kind":"tool_result","name":"edit_file","step":29}
+{"t":"2026-06-10T06:26:58.862Z","type":"crew","role":"developer","kind":"model_call","step":30}
+{"t":"2026-06-10T06:27:06.530Z","type":"crew","role":"developer","kind":"tool_call","name":"edit_file","step":30}
+{"t":"2026-06-10T06:27:06.531Z","type":"crew","role":"developer","kind":"tool_result","name":"edit_file","step":30}
+{"t":"2026-06-10T06:27:06.532Z","type":"crew","role":"developer","kind":"model_call","step":31}
+{"t":"2026-06-10T06:27:13.928Z","type":"crew","role":"developer","kind":"tool_call","name":"edit_file","step":31}
+{"t":"2026-06-10T06:27:13.929Z","type":"crew","role":"developer","kind":"tool_result","name":"edit_file","step":31}
+{"t":"2026-06-10T06:27:13.929Z","type":"crew","role":"developer","kind":"model_call","step":32}
+{"t":"2026-06-10T06:27:17.132Z","type":"crew","role":"developer","kind":"tool_call","name":"grep","step":32}
+{"t":"2026-06-10T06:27:17.170Z","type":"crew","role":"developer","kind":"tool_result","name":"grep","step":32}
+{"t":"2026-06-10T06:27:17.171Z","type":"crew","role":"developer","kind":"model_call","step":33}
+{"t":"2026-06-10T06:27:21.461Z","type":"crew","role":"developer","kind":"tool_call","name":"edit_file","step":33}
+{"t":"2026-06-10T06:27:21.461Z","type":"crew","role":"developer","kind":"tool_result","name":"edit_file","step":33}
+{"t":"2026-06-10T06:27:21.461Z","type":"crew","role":"developer","kind":"model_call","step":34}
+{"t":"2026-06-10T06:27:34.237Z","type":"crew","role":"developer","kind":"tool_call","name":"edit_file","step":34}
+{"t":"2026-06-10T06:27:34.239Z","type":"crew","role":"developer","kind":"tool_result","name":"edit_file","step":34}
+{"t":"2026-06-10T06:27:34.240Z","type":"crew","role":"developer","kind":"model_call","step":35}
+{"t":"2026-06-10T06:27:38.023Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":35}
+{"t":"2026-06-10T06:27:45.491Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":35}
+{"t":"2026-06-10T06:27:45.491Z","type":"crew","role":"developer","kind":"model_call","step":36}
+{"t":"2026-06-10T06:27:48.319Z","type":"crew","role":"developer","kind":"tool_call","name":"grep","step":36}
+{"t":"2026-06-10T06:27:48.360Z","type":"crew","role":"developer","kind":"tool_result","name":"grep","step":36}
+{"t":"2026-06-10T06:27:48.361Z","type":"crew","role":"developer","kind":"model_call","step":37}
+{"t":"2026-06-10T06:27:51.196Z","type":"crew","role":"developer","kind":"tool_call","name":"grep","step":37}
+{"t":"2026-06-10T06:27:51.294Z","type":"crew","role":"developer","kind":"tool_result","name":"grep","step":37}
+{"t":"2026-06-10T06:27:51.294Z","type":"crew","role":"developer","kind":"model_call","step":38}
+{"t":"2026-06-10T06:27:53.666Z","type":"crew","role":"developer","kind":"tool_call","name":"bash","step":38}
+{"t":"2026-06-10T06:27:53.741Z","type":"crew","role":"developer","kind":"tool_result","name":"bash","step":38}
+{"t":"2026-06-10T06:27:53.741Z","type":"crew","role":"developer","kind":"model_call","step":39}
+{"t":"2026-06-10T06:28:06.962Z","type":"crew","role":"developer","kind":"tool_call","name":"list_dir","step":39}
+{"t":"2026-06-10T06:28:06.962Z","type":"crew","role":"developer","kind":"tool_result","name":"list_dir","step":39}
+{"t":"2026-06-10T06:28:06.963Z","type":"dev_done","round":1,"filesChanged":[]}
+{"t":"2026-06-10T06:28:14.365Z","type":"command_gates","round":1,"passed":true}
diff --git a/.claude/maestro/upgrade-the-two-main-session-guard-hooks-from-absolute-block/plan.json b/.claude/maestro/upgrade-the-two-main-session-guard-hooks-from-absolute-block/plan.json
new file mode 100644
index 0000000..73cd9b9
--- /dev/null
+++ b/.claude/maestro/upgrade-the-two-main-session-guard-hooks-from-absolute-block/plan.json
@@ -0,0 +1,103 @@
+{
+  "summary": "Convert the two absolute main-session guards into risk-based BUDGET-GUARDS: after all existing carve-outs, add a protected-path block then a cumulative-diff budget gate (default <=50 lines AND <=2 files vs HEAD; edit guard also projects the incoming edit's size). Add per-repo .claude/maestro-budget config, JSONL guard logging on every block, and re-route the prose in CLAUDE.md + SKILL.md from 'never edit' to 'edit small within budget, else maestro'. Extend the 32-case test battery with budget/projection/protected/untracked/config/log cases.",
+  "assumptions": [
+    {
+      "text": "Budget is measured against the repo at the canonical CLAUDE_PROJECT_DIR (falling back to PWD), using `git -C <proj>`, consistent with how the guards already resolve _canon_proj.",
+      "confidence": "medium"
+    },
+    {
+      "text": "'Changed lines' = sum of added+deleted from git diff --numstat (binary/`-` rows contribute 0 lines but still count as a changed file); untracked non-ignored files contribute their wc -l line count and 1 file each.",
+      "confidence": "medium"
+    },
+    {
+      "text": "Budget over = lines_used > LINES OR files_used > FILES (both limits enforced; exceeding either trips). Equality is within budget.",
+      "confidence": "medium"
+    },
+    {
+      "text": "Protected globs are matched against the target's path RELATIVE to the canonical repo root, supporting ** (any depth) and * (single segment) via a small glob->regex translation; absolute-form patterns also tolerated.",
+      "confidence": "low"
+    },
+    {
+      "text": "Budget logic is inlined into each guard (no new helper file) because install.sh only symlinks hooks/*.sh; this keeps deployment unchanged and honors the no-new-packages constraint.",
+      "confidence": "high"
+    },
+    {
+      "text": "For the bash guard, the protected/target check applies only when a single mutation target is cleanly identifiable from the tokens; otherwise it falls through to the current-usage budget gate.",
+      "confidence": "medium"
+    },
+    {
+      "text": "guard-log.jsonl ts is an ISO-8601/UTC timestamp; one compact JSON object per line; written best-effort (a log-write failure never changes the allow/block decision).",
+      "confidence": "medium"
+    },
+    {
+      "text": "Tests run against throwaway git repos under $TMPDIR with CLAUDE_PROJECT_DIR set, so budget and log assertions are deterministic and do not touch the real .claude/.",
+      "confidence": "high"
+    }
+  ],
+  "nonGoals": [
+    "Do NOT modify hooks/commit-gate.sh or hooks/maestro-engage.sh.",
+    "Do NOT touch variants/personal/maestro-mcp/** (MCP autonomy is a separate future task).",
+    "No new runtime dependencies — bash/python3/jq/git only; no node, no packages, no new symlinked helper files.",
+    "Not rewriting the bash guard's mutation classification, heredoc handling, or benign-target logic — only layering the budget/protected gate on top.",
+    "Not editing AGENTS.md prose in this task (the deliverables scope prose to CLAUDE.md + SKILL.md); flagged as a consistency risk for founder call.",
+    "Not making the budget account-aware or per-session-persistent beyond the live `git diff vs HEAD` measurement."
+  ],
+  "alternatives": [],
+  "blastRadius": [],
+  "steps": [
+    "Define the budget-config format and a tiny parser (KEY=VALUE: LINES, FILES ints; PROTECTED colon-separated globs; malformed -> defaults 50/2/empty). Implement once per guard (bash reads it via a python3 one-liner in the edit guard; python directly in the bash guard).",
+    "Implement budget measurement: git -C <canon_proj> diff --numstat HEAD (sum add+del, collect changed files) + git status --porcelain untracked (?? entries: count file + wc -l lines), guarded so any git failure / non-repo => fail-open ALLOW.",
+    "Implement protected-path matching on the canonical target path relative to repo root via a glob->regex translator supporting ** and *.",
+    "Implement guard-log append: best-effort one compact JSON line {ts,hook,target,lines_used,files_used,reason} to <canon_proj>/.claude/maestro/guard-log.jsonl on every block (both reasons).",
+    "guard-block-main-edits.sh: after the 5 existing carve-outs add (a) protected-path block (message: size doesn't matter on protected paths), then (b) budget check that adds projected incoming-edit size (Edit old/new_string, Write content, MultiEdit edits[]) to current usage; under -> exit 0, over -> exit 2 usage-vs-budget re-prompt. Remove the old unconditional block. Preserve set -eu safety around git calls.",
+    "guard-block-main-bash.sh: have analyze() surface the mutation target where identifiable; after a mutating classification, apply protected-path block (if target identifiable) then current-usage budget gate; under -> allow, over -> block with usage-vs-budget re-prompt. Leave all read-only/benign classification untouched.",
+    "Write the two re-prompt messages short and model-facing (usage vs budget; run maestro for the REMAINDER; never split a task to stay under the limit; protected-path variant states size is irrelevant).",
+    "CLAUDE.md: replace 'The one rule: orchestrate, never implement' with a similar-length risk-routing rule (edit small within budget; 'diff in your head?' -> direct, 'verification needs running something?' -> maestro; protected always maestro; cumulative creep rule = ten small edits are one big change, on trip move remainder to maestro never split; uncertain -> maestro). Update the Engagement paragraph to match.",
+    "skills/maestro/SKILL.md section 0: align engagement with the same routing in 2-3 sentences (budget-bounded direct edits; over-budget/protected -> loop; never split).",
+    "README.md: document .claude/maestro-budget format (LINES/FILES/PROTECTED, defaults, malformed->defaults) and the guard-log.jsonl calibration artifact.",
+    "hooks/test/guard_scratch_test.sh: add a temp-git-repo harness and new cases — under-budget edit ALLOW; cumulative creep (several small edits then one crossing the line) BLOCK; single oversized edit BLOCK via projection; protected path BLOCK at zero usage; untracked new file counted; custom .claude/maestro-budget respected; guard-log.jsonl line written on block; non-git dir fail-open ALLOW. Keep all 32 existing cases unchanged.",
+    "Run bash hooks/test/guard_scratch_test.sh until the full extended battery passes; sanity-read the CLAUDE.md/SKILL.md diff for no leftover 'never edit' absolutes."
+  ],
+  "filesLikely": [
+    "hooks/guard-block-main-edits.sh",
+    "hooks/guard-block-main-bash.sh",
+    "hooks/test/guard_scratch_test.sh",
+    "CLAUDE.md",
+    "skills/maestro/SKILL.md",
+    "README.md"
+  ],
+  "risks": [
+    "Security regression: a flaw in glob->regex or relative-path derivation could miss a protected path or allow a traversal bypass. Mitigation: match only on canonical paths, reuse existing realpath flow, add explicit traversal+protected test cases.",
+    "Budget miscount on binary/renamed/untracked files (numstat '-' rows, R status) could over- or under-count. Mitigation: treat '-' as 0 lines but 1 file, test untracked counting explicitly.",
+    "Edit-projection double-counting when the incoming edit targets an already-dirty file could falsely trip the budget. Mitigation: count target as a new file only if not already in the changed set; document the conservative behavior.",
+    "Fail-open scope creep: a git error inside a real repo would silently allow edits. Mitigation: only fail-open when repo detection itself fails; comment the rationale (backstops remain).",
+    "set -eu in the bash edit guard can abort on a non-zero git call; must wrap all git invocations to avoid turning a measurement failure into a hard error.",
+    "Prose inconsistency: AGENTS.md retains 'never write production code' absolutes that will contradict the new CLAUDE.md/SKILL.md routing. Flagged for founder decision; out of scope as written.",
+    "Tests writing to the real .claude/ if CLAUDE_PROJECT_DIR isn't isolated. Mitigation: all new cases use throwaway $TMPDIR git repos."
+  ],
+  "proposedGates": [
+    {
+      "name": "guard-battery",
+      "kind": "command",
+      "stage": "per-round",
+      "command": "bash hooks/test/guard_scratch_test.sh"
+    },
+    {
+      "name": "prose-consistency",
+      "kind": "judge",
+      "stage": "pre-ship",
+      "agent": "reviewer"
+    },
+    {
+      "name": "commit",
+      "kind": "action",
+      "stage": "release",
+      "action": "commit"
+    }
+  ],
+  "requirements": {
+    "env": [],
+    "tools": [],
+    "services": []
+  }
+}
\ No newline at end of file
diff --git a/.claude/maestro/upgrade-the-two-main-session-guard-hooks-from-absolute-block/plan.md b/.claude/maestro/upgrade-the-two-main-session-guard-hooks-from-absolute-block/plan.md
new file mode 100644
index 0000000..046a941
--- /dev/null
+++ b/.claude/maestro/upgrade-the-two-main-session-guard-hooks-from-absolute-block/plan.md
@@ -0,0 +1,96 @@
+## Recon complete
+
+I've read both guards, the test battery, commit-gate (backstop, untouched), CLAUDE.md, SKILL.md, AGENTS.md, README.md, install.sh, settings.hooks.json, and the harness state. Key findings:
+
+- **install.sh symlinks `hooks/*.sh` only** (install.sh:14) — a non-`.sh` helper would not deploy. So budget logic must be **inlined** into each guard (no new shared file), or I'd have to touch install.sh. I'll inline.
+- The edit guard already invokes `python3` for realpath canonicalization and computes `_canon_proj` from `CLAUDE_PROJECT_DIR|PWD` (guard-block-main-edits.sh:62-65). Budget measurement should run `git -C "$proj"` against that same canonical root so it's testable via `CLAUDE_PROJECT_DIR`.
+- The bash guard's `analyze()` returns only a reason string; to do the protected-path check I'll need it to also surface the mutation **target** where identifiable.
+- **AGENTS.md** (lines 8-10, 30-33) also carries "never write production code yourself" absolutes. The task explicitly scopes prose changes to CLAUDE.md + SKILL.md only. I'll flag AGENTS.md as a consistency risk but keep it a non-goal unless the founder wants it included.
+- Tests must run against **throwaway git repos** under `$TMPDIR` (with `CLAUDE_PROJECT_DIR` set) so budget/log assertions are deterministic and don't pollute the real `.claude/`.
+
+---PLAN-JSON---
+```json
+{
+  "summary": "Convert the two absolute main-session guards into risk-based BUDGET-GUARDS: after all existing carve-outs, add a protected-path block then a cumulative-diff budget gate (default <=50 lines AND <=2 files vs HEAD; edit guard also projects the incoming edit's size). Add per-repo .claude/maestro-budget config, JSONL guard logging on every block, and re-route the prose in CLAUDE.md + SKILL.md from 'never edit' to 'edit small within budget, else maestro'. Extend the 32-case test battery with budget/projection/protected/untracked/config/log cases.",
+  "understanding": {
+    "currentBehavior": "guard-block-main-edits.sh and guard-block-main-bash.sh are binary: a main session (no agent_id) is blocked from ALL mutations after a fixed set of carve-outs (agent_id, .claude/maestro-direct, .claude/maestro* state, tmp/scratch, prose/docs). commit-gate.sh re-runs verify on git commit as the final backstop.",
+    "desiredBehavior": "Main session MAY make small direct edits within a deterministic per-task budget; large/risky/protected changes still route through maestro. The exit-2 message becomes a re-prompt stating usage-vs-budget and telling the model to run maestro for the remainder and never split a task.",
+    "keyMechanics": "Budget = cumulative uncommitted diff vs HEAD measured with `git -C <proj> diff --numstat HEAD` (tracked add+del) plus untracked non-ignored files from `git status --porcelain` (counting their line counts). Edit guard ALSO adds projected incoming-edit size from tool_input (old_string/new_string for Edit, content for Write, edits[] for MultiEdit) so one oversized edit is caught before it lands. Bash guard uses current usage only (no diff projection possible). Protected paths block regardless of budget. Non-git/git-failure => fail-open ALLOW. Unparseable payload stays fail-open.",
+    "securityInvariants": "realpath canonicalization BEFORE any path comparison (anti-traversal); protected-pattern matching operates on canonical paths; anchored maestro-state matching; prose carve-out on canonical path. The budget additions must not introduce any traversal bypass and prose/docs/tmp/state files must still NOT count toward budget."
+  },
+  "assumptions": [
+    {"text": "Budget is measured against the repo at the canonical CLAUDE_PROJECT_DIR (falling back to PWD), using `git -C <proj>`, consistent with how the guards already resolve _canon_proj.", "confidence": "medium"},
+    {"text": "'Changed lines' = sum of added+deleted from git diff --numstat (binary/`-` rows contribute 0 lines but still count as a changed file); untracked non-ignored files contribute their wc -l line count and 1 file each.", "confidence": "medium"},
+    {"text": "Budget over = lines_used > LINES OR files_used > FILES (both limits enforced; exceeding either trips). Equality is within budget.", "confidence": "medium"},
+    {"text": "Protected globs are matched against the target's path RELATIVE to the canonical repo root, supporting ** (any depth) and * (single segment) via a small glob->regex translation; absolute-form patterns also tolerated.", "confidence": "low"},
+    {"text": "Budget logic is inlined into each guard (no new helper file) because install.sh only symlinks hooks/*.sh; this keeps deployment unchanged and honors the no-new-packages constraint.", "confidence": "high"},
+    {"text": "For the bash guard, the protected/target check applies only when a single mutation target is cleanly identifiable from the tokens; otherwise it falls through to the current-usage budget gate.", "confidence": "medium"},
+    {"text": "guard-log.jsonl ts is an ISO-8601/UTC timestamp; one compact JSON object per line; written best-effort (a log-write failure never changes the allow/block decision).", "confidence": "medium"},
+    {"text": "Tests run against throwaway git repos under $TMPDIR with CLAUDE_PROJECT_DIR set, so budget and log assertions are deterministic and do not touch the real .claude/.", "confidence": "high"}
+  ],
+  "nonGoals": [
+    "Do NOT modify hooks/commit-gate.sh or hooks/maestro-engage.sh.",
+    "Do NOT touch variants/personal/maestro-mcp/** (MCP autonomy is a separate future task).",
+    "No new runtime dependencies — bash/python3/jq/git only; no node, no packages, no new symlinked helper files.",
+    "Not rewriting the bash guard's mutation classification, heredoc handling, or benign-target logic — only layering the budget/protected gate on top.",
+    "Not editing AGENTS.md prose in this task (the deliverables scope prose to CLAUDE.md + SKILL.md); flagged as a consistency risk for founder call.",
+    "Not making the budget account-aware or per-session-persistent beyond the live `git diff vs HEAD` measurement."
+  ],
+  "alternatives": [
+    {"option": "Extract a shared hooks/guard-budget.py helper used by both guards.", "rejected_because": "install.sh only symlinks *.sh, so a .py helper would not deploy without also touching install.sh (extra blast radius); inlining keeps deployment untouched."},
+    {"option": "Project incoming size for bash commands too.", "rejected_because": "A shell command's resulting diff is not statically estimable; spec explicitly says bash guard uses current usage only."},
+    {"option": "Persist a running tally file instead of measuring live git diff.", "rejected_because": "git diff vs HEAD is the deterministic source of truth, self-resets on commit, and avoids stale-state bugs; matches the spec's 'cumulative uncommitted diff vs HEAD'."},
+    {"option": "Use python fnmatch directly for protected globs.", "rejected_because": "fnmatch/Path.match do not handle ** depth semantics reliably; a small explicit glob->regex translation is predictable and testable."}
+  ],
+  "blastRadius": {
+    "filesModified": ["hooks/guard-block-main-edits.sh", "hooks/guard-block-main-bash.sh", "hooks/test/guard_scratch_test.sh", "CLAUDE.md", "skills/maestro/SKILL.md", "README.md"],
+    "filesCreatedAtRuntime": [".claude/maestro/guard-log.jsonl (append-only, harness state)", ".claude/maestro-budget (optional, founder-authored config)"],
+    "behaviorChange": "Main session gains a bounded ability to edit directly; previously-blocked small edits now pass. All read-only classification and all existing carve-outs are preserved. commit-gate, tester, reviewer remain the backstops.",
+    "deploymentImpact": "No install.sh / settings.hooks.json change; guards remain the same two symlinked *.sh files.",
+    "riskLevel": "medium — guards are security boundary; a loosening bug could let oversized/protected edits through, but commit-gate + crew review remain final backstops."
+  },
+  "steps": [
+    "Define the budget-config format and a tiny parser (KEY=VALUE: LINES, FILES ints; PROTECTED colon-separated globs; malformed -> defaults 50/2/empty). Implement once per guard (bash reads it via a python3 one-liner in the edit guard; python directly in the bash guard).",
+    "Implement budget measurement: git -C <canon_proj> diff --numstat HEAD (sum add+del, collect changed files) + git status --porcelain untracked (?? entries: count file + wc -l lines), guarded so any git failure / non-repo => fail-open ALLOW.",
+    "Implement protected-path matching on the canonical target path relative to repo root via a glob->regex translator supporting ** and *.",
+    "Implement guard-log append: best-effort one compact JSON line {ts,hook,target,lines_used,files_used,reason} to <canon_proj>/.claude/maestro/guard-log.jsonl on every block (both reasons).",
+    "guard-block-main-edits.sh: after the 5 existing carve-outs add (a) protected-path block (message: size doesn't matter on protected paths), then (b) budget check that adds projected incoming-edit size (Edit old/new_string, Write content, MultiEdit edits[]) to current usage; under -> exit 0, over -> exit 2 usage-vs-budget re-prompt. Remove the old unconditional block. Preserve set -eu safety around git calls.",
+    "guard-block-main-bash.sh: have analyze() surface the mutation target where identifiable; after a mutating classification, apply protected-path block (if target identifiable) then current-usage budget gate; under -> allow, over -> block with usage-vs-budget re-prompt. Leave all read-only/benign classification untouched.",
+    "Write the two re-prompt messages short and model-facing (usage vs budget; run maestro for the REMAINDER; never split a task to stay under the limit; protected-path variant states size is irrelevant).",
+    "CLAUDE.md: replace 'The one rule: orchestrate, never implement' with a similar-length risk-routing rule (edit small within budget; 'diff in your head?' -> direct, 'verification needs running something?' -> maestro; protected always maestro; cumulative creep rule = ten small edits are one big change, on trip move remainder to maestro never split; uncertain -> maestro). Update the Engagement paragraph to match.",
+    "skills/maestro/SKILL.md section 0: align engagement with the same routing in 2-3 sentences (budget-bounded direct edits; over-budget/protected -> loop; never split).",
+    "README.md: document .claude/maestro-budget format (LINES/FILES/PROTECTED, defaults, malformed->defaults) and the guard-log.jsonl calibration artifact.",
+    "hooks/test/guard_scratch_test.sh: add a temp-git-repo harness and new cases — under-budget edit ALLOW; cumulative creep (several small edits then one crossing the line) BLOCK; single oversized edit BLOCK via projection; protected path BLOCK at zero usage; untracked new file counted; custom .claude/maestro-budget respected; guard-log.jsonl line written on block; non-git dir fail-open ALLOW. Keep all 32 existing cases unchanged.",
+    "Run bash hooks/test/guard_scratch_test.sh until the full extended battery passes; sanity-read the CLAUDE.md/SKILL.md diff for no leftover 'never edit' absolutes."
+  ],
+  "filesLikely": [
+    "hooks/guard-block-main-edits.sh",
+    "hooks/guard-block-main-bash.sh",
+    "hooks/test/guard_scratch_test.sh",
+    "CLAUDE.md",
+    "skills/maestro/SKILL.md",
+    "README.md"
+  ],
+  "risks": [
+    "Security regression: a flaw in glob->regex or relative-path derivation could miss a protected path or allow a traversal bypass. Mitigation: match only on canonical paths, reuse existing realpath flow, add explicit traversal+protected test cases.",
+    "Budget miscount on binary/renamed/untracked files (numstat '-' rows, R status) could over- or under-count. Mitigation: treat '-' as 0 lines but 1 file, test untracked counting explicitly.",
+    "Edit-projection double-counting when the incoming edit targets an already-dirty file could falsely trip the budget. Mitigation: count target as a new file only if not already in the changed set; document the conservative behavior.",
+    "Fail-open scope creep: a git error inside a real repo would silently allow edits. Mitigation: only fail-open when repo detection itself fails; comment the rationale (backstops remain).",
+    "set -eu in the bash edit guard can abort on a non-zero git call; must wrap all git invocations to avoid turning a measurement failure into a hard error.",
+    "Prose inconsistency: AGENTS.md retains 'never write production code' absolutes that will contradict the new CLAUDE.md/SKILL.md routing. Flagged for founder decision; out of scope as written.",
+    "Tests writing to the real .claude/ if CLAUDE_PROJECT_DIR isn't isolated. Mitigation: all new cases use throwaway $TMPDIR git repos."
+  ],
+  "proposedGates": [
+    {"name": "guard-battery", "kind": "command", "stage": "per-round", "command": "bash hooks/test/guard_scratch_test.sh"},
+    {"name": "prose-consistency", "kind": "judge", "stage": "pre-ship", "agent": "reviewer"},
+    {"name": "commit", "kind": "action", "stage": "release", "action": "commit"}
+  ],
+  "requirements": {
+    "tools": ["bash", "python3", "jq", "git"],
+    "env": [],
+    "services": [],
+    "missing": [],
+    "notes": "All dependencies already present and used by the current hooks; no new packages. The test battery requires git to init throwaway repos under $TMPDIR."
+  }
+}
+```
\ No newline at end of file
diff --git a/.claude/maestro/upgrade-the-two-main-session-guard-hooks-from-absolute-block/state.json b/.claude/maestro/upgrade-the-two-main-session-guard-hooks-from-absolute-block/state.json
new file mode 100644
index 0000000..da85915
--- /dev/null
+++ b/.claude/maestro/upgrade-the-two-main-session-guard-hooks-from-absolute-block/state.json
@@ -0,0 +1,15 @@
+{
+  "task": "Upgrade the two main-session guard hooks from absolute blocks into BUDGET-GUARDS, add per-repo budget config + guard logging, and align the routing prose (CLAUDE.md 