## Recon complete

I've read both guards, the test battery, commit-gate (backstop, untouched), CLAUDE.md, SKILL.md, AGENTS.md, README.md, install.sh, settings.hooks.json, and the harness state. Key findings:

- **install.sh symlinks `hooks/*.sh` only** (install.sh:14) — a non-`.sh` helper would not deploy. So budget logic must be **inlined** into each guard (no new shared file), or I'd have to touch install.sh. I'll inline.
- The edit guard already invokes `python3` for realpath canonicalization and computes `_canon_proj` from `CLAUDE_PROJECT_DIR|PWD` (guard-block-main-edits.sh:62-65). Budget measurement should run `git -C "$proj"` against that same canonical root so it's testable via `CLAUDE_PROJECT_DIR`.
- The bash guard's `analyze()` returns only a reason string; to do the protected-path check I'll need it to also surface the mutation **target** where identifiable.
- **AGENTS.md** (lines 8-10, 30-33) also carries "never write production code yourself" absolutes. The task explicitly scopes prose changes to CLAUDE.md + SKILL.md only. I'll flag AGENTS.md as a consistency risk but keep it a non-goal unless the founder wants it included.
- Tests must run against **throwaway git repos** under `$TMPDIR` (with `CLAUDE_PROJECT_DIR` set) so budget/log assertions are deterministic and don't pollute the real `.claude/`.

---PLAN-JSON---
```json
{
  "summary": "Convert the two absolute main-session guards into risk-based BUDGET-GUARDS: after all existing carve-outs, add a protected-path block then a cumulative-diff budget gate (default <=50 lines AND <=2 files vs HEAD; edit guard also projects the incoming edit's size). Add per-repo .claude/maestro-budget config, JSONL guard logging on every block, and re-route the prose in CLAUDE.md + SKILL.md from 'never edit' to 'edit small within budget, else maestro'. Extend the 32-case test battery with budget/projection/protected/untracked/config/log cases.",
  "understanding": {
    "currentBehavior": "guard-block-main-edits.sh and guard-block-main-bash.sh are binary: a main session (no agent_id) is blocked from ALL mutations after a fixed set of carve-outs (agent_id, .claude/maestro-direct, .claude/maestro* state, tmp/scratch, prose/docs). commit-gate.sh re-runs verify on git commit as the final backstop.",
    "desiredBehavior": "Main session MAY make small direct edits within a deterministic per-task budget; large/risky/protected changes still route through maestro. The exit-2 message becomes a re-prompt stating usage-vs-budget and telling the model to run maestro for the remainder and never split a task.",
    "keyMechanics": "Budget = cumulative uncommitted diff vs HEAD measured with `git -C <proj> diff --numstat HEAD` (tracked add+del) plus untracked non-ignored files from `git status --porcelain` (counting their line counts). Edit guard ALSO adds projected incoming-edit size from tool_input (old_string/new_string for Edit, content for Write, edits[] for MultiEdit) so one oversized edit is caught before it lands. Bash guard uses current usage only (no diff projection possible). Protected paths block regardless of budget. Non-git/git-failure => fail-open ALLOW. Unparseable payload stays fail-open.",
    "securityInvariants": "realpath canonicalization BEFORE any path comparison (anti-traversal); protected-pattern matching operates on canonical paths; anchored maestro-state matching; prose carve-out on canonical path. The budget additions must not introduce any traversal bypass and prose/docs/tmp/state files must still NOT count toward budget."
  },
  "assumptions": [
    {"text": "Budget is measured against the repo at the canonical CLAUDE_PROJECT_DIR (falling back to PWD), using `git -C <proj>`, consistent with how the guards already resolve _canon_proj.", "confidence": "medium"},
    {"text": "'Changed lines' = sum of added+deleted from git diff --numstat (binary/`-` rows contribute 0 lines but still count as a changed file); untracked non-ignored files contribute their wc -l line count and 1 file each.", "confidence": "medium"},
    {"text": "Budget over = lines_used > LINES OR files_used > FILES (both limits enforced; exceeding either trips). Equality is within budget.", "confidence": "medium"},
    {"text": "Protected globs are matched against the target's path RELATIVE to the canonical repo root, supporting ** (any depth) and * (single segment) via a small glob->regex translation; absolute-form patterns also tolerated.", "confidence": "low"},
    {"text": "Budget logic is inlined into each guard (no new helper file) because install.sh only symlinks hooks/*.sh; this keeps deployment unchanged and honors the no-new-packages constraint.", "confidence": "high"},
    {"text": "For the bash guard, the protected/target check applies only when a single mutation target is cleanly identifiable from the tokens; otherwise it falls through to the current-usage budget gate.", "confidence": "medium"},
    {"text": "guard-log.jsonl ts is an ISO-8601/UTC timestamp; one compact JSON object per line; written best-effort (a log-write failure never changes the allow/block decision).", "confidence": "medium"},
    {"text": "Tests run against throwaway git repos under $TMPDIR with CLAUDE_PROJECT_DIR set, so budget and log assertions are deterministic and do not touch the real .claude/.", "confidence": "high"}
  ],
  "nonGoals": [
    "Do NOT modify hooks/commit-gate.sh or hooks/maestro-engage.sh.",
    "Do NOT touch variants/personal/maestro-mcp/** (MCP autonomy is a separate future task).",
    "No new runtime dependencies — bash/python3/jq/git only; no node, no packages, no new symlinked helper files.",
    "Not rewriting the bash guard's mutation classification, heredoc handling, or benign-target logic — only layering the budget/protected gate on top.",
    "Not editing AGENTS.md prose in this task (the deliverables scope prose to CLAUDE.md + SKILL.md); flagged as a consistency risk for founder call.",
    "Not making the budget account-aware or per-session-persistent beyond the live `git diff vs HEAD` measurement."
  ],
  "alternatives": [
    {"option": "Extract a shared hooks/guard-budget.py helper used by both guards.", "rejected_because": "install.sh only symlinks *.sh, so a .py helper would not deploy without also touching install.sh (extra blast radius); inlining keeps deployment untouched."},
    {"option": "Project incoming size for bash commands too.", "rejected_because": "A shell command's resulting diff is not statically estimable; spec explicitly says bash guard uses current usage only."},
    {"option": "Persist a running tally file instead of measuring live git diff.", "rejected_because": "git diff vs HEAD is the deterministic source of truth, self-resets on commit, and avoids stale-state bugs; matches the spec's 'cumulative uncommitted diff vs HEAD'."},
    {"option": "Use python fnmatch directly for protected globs.", "rejected_because": "fnmatch/Path.match do not handle ** depth semantics reliably; a small explicit glob->regex translation is predictable and testable."}
  ],
  "blastRadius": {
    "filesModified": ["hooks/guard-block-main-edits.sh", "hooks/guard-block-main-bash.sh", "hooks/test/guard_scratch_test.sh", "CLAUDE.md", "skills/maestro/SKILL.md", "README.md"],
    "filesCreatedAtRuntime": [".claude/maestro/guard-log.jsonl (append-only, harness state)", ".claude/maestro-budget (optional, founder-authored config)"],
    "behaviorChange": "Main session gains a bounded ability to edit directly; previously-blocked small edits now pass. All read-only classification and all existing carve-outs are preserved. commit-gate, tester, reviewer remain the backstops.",
    "deploymentImpact": "No install.sh / settings.hooks.json change; guards remain the same two symlinked *.sh files.",
    "riskLevel": "medium — guards are security boundary; a loosening bug could let oversized/protected edits through, but commit-gate + crew review remain final backstops."
  },
  "steps": [
    "Define the budget-config format and a tiny parser (KEY=VALUE: LINES, FILES ints; PROTECTED colon-separated globs; malformed -> defaults 50/2/empty). Implement once per guard (bash reads it via a python3 one-liner in the edit guard; python directly in the bash guard).",
    "Implement budget measurement: git -C <canon_proj> diff --numstat HEAD (sum add+del, collect changed files) + git status --porcelain untracked (?? entries: count file + wc -l lines), guarded so any git failure / non-repo => fail-open ALLOW.",
    "Implement protected-path matching on the canonical target path relative to repo root via a glob->regex translator supporting ** and *.",
    "Implement guard-log append: best-effort one compact JSON line {ts,hook,target,lines_used,files_used,reason} to <canon_proj>/.claude/maestro/guard-log.jsonl on every block (both reasons).",
    "guard-block-main-edits.sh: after the 5 existing carve-outs add (a) protected-path block (message: size doesn't matter on protected paths), then (b) budget check that adds projected incoming-edit size (Edit old/new_string, Write content, MultiEdit edits[]) to current usage; under -> exit 0, over -> exit 2 usage-vs-budget re-prompt. Remove the old unconditional block. Preserve set -eu safety around git calls.",
    "guard-block-main-bash.sh: have analyze() surface the mutation target where identifiable; after a mutating classification, apply protected-path block (if target identifiable) then current-usage budget gate; under -> allow, over -> block with usage-vs-budget re-prompt. Leave all read-only/benign classification untouched.",
    "Write the two re-prompt messages short and model-facing (usage vs budget; run maestro for the REMAINDER; never split a task to stay under the limit; protected-path variant states size is irrelevant).",
    "CLAUDE.md: replace 'The one rule: orchestrate, never implement' with a similar-length risk-routing rule (edit small within budget; 'diff in your head?' -> direct, 'verification needs running something?' -> maestro; protected always maestro; cumulative creep rule = ten small edits are one big change, on trip move remainder to maestro never split; uncertain -> maestro). Update the Engagement paragraph to match.",
    "skills/maestro/SKILL.md section 0: align engagement with the same routing in 2-3 sentences (budget-bounded direct edits; over-budget/protected -> loop; never split).",
    "README.md: document .claude/maestro-budget format (LINES/FILES/PROTECTED, defaults, malformed->defaults) and the guard-log.jsonl calibration artifact.",
    "hooks/test/guard_scratch_test.sh: add a temp-git-repo harness and new cases — under-budget edit ALLOW; cumulative creep (several small edits then one crossing the line) BLOCK; single oversized edit BLOCK via projection; protected path BLOCK at zero usage; untracked new file counted; custom .claude/maestro-budget respected; guard-log.jsonl line written on block; non-git dir fail-open ALLOW. Keep all 32 existing cases unchanged.",
    "Run bash hooks/test/guard_scratch_test.sh until the full extended battery passes; sanity-read the CLAUDE.md/SKILL.md diff for no leftover 'never edit' absolutes."
  ],
  "filesLikely": [
    "hooks/guard-block-main-edits.sh",
    "hooks/guard-block-main-bash.sh",
    "hooks/test/guard_scratch_test.sh",
    "CLAUDE.md",
    "skills/maestro/SKILL.md",
    "README.md"
  ],
  "risks": [
    "Security regression: a flaw in glob->regex or relative-path derivation could miss a protected path or allow a traversal bypass. Mitigation: match only on canonical paths, reuse existing realpath flow, add explicit traversal+protected test cases.",
    "Budget miscount on binary/renamed/untracked files (numstat '-' rows, R status) could over- or under-count. Mitigation: treat '-' as 0 lines but 1 file, test untracked counting explicitly.",
    "Edit-projection double-counting when the incoming edit targets an already-dirty file could falsely trip the budget. Mitigation: count target as a new file only if not already in the changed set; document the conservative behavior.",
    "Fail-open scope creep: a git error inside a real repo would silently allow edits. Mitigation: only fail-open when repo detection itself fails; comment the rationale (backstops remain).",
    "set -eu in the bash edit guard can abort on a non-zero git call; must wrap all git invocations to avoid turning a measurement failure into a hard error.",
    "Prose inconsistency: AGENTS.md retains 'never write production code' absolutes that will contradict the new CLAUDE.md/SKILL.md routing. Flagged for founder decision; out of scope as written.",
    "Tests writing to the real .claude/ if CLAUDE_PROJECT_DIR isn't isolated. Mitigation: all new cases use throwaway $TMPDIR git repos."
  ],
  "proposedGates": [
    {"name": "guard-battery", "kind": "command", "stage": "per-round", "command": "bash hooks/test/guard_scratch_test.sh"},
    {"name": "prose-consistency", "kind": "judge", "stage": "pre-ship", "agent": "reviewer"},
    {"name": "commit", "kind": "action", "stage": "release", "action": "commit"}
  ],
  "requirements": {
    "tools": ["bash", "python3", "jq", "git"],
    "env": [],
    "services": [],
    "missing": [],
    "notes": "All dependencies already present and used by the current hooks; no new packages. The test battery requires git to init throwaway repos under $TMPDIR."
  }
}
```