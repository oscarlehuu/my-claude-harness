Non-goals:
- Do not weaken any existing block (code files, sed -i on code, redirects to code, docs/../code traversal must still block).
- Do not modify agent_id / engagement / tokenizer / analyze logic.
- Do not handle sed -i or interpreter-write targeting prose (out of scope; bash carve-out only covers benign_target i.e. redirect/tee/cp/dd/mv/ln targets).
- Do not alter the existing .claude/maestro* or tmp/$TMPDIR carve-outs.

The developer reported filesChanged: ["hooks/guard-block-main-edits.sh - added canonical prose extension, known prose name, and repo docs/ allow checks before final block","hooks/guard-block-main-bash.sh - added matching canonical prose/docs allow logic inside benign_target(t)"].
Per-round command gate result: pass. A non-zero command gate is FAIL regardless.

Judge whether the DIFF below genuinely satisfies the GOAL (catch cheats). End with VERDICT: PASS|FAIL|PARTIAL|BLOCKED.

DIFF:
(no git repo — diff unavailable)