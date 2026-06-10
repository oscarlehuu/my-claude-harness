Non-goals:
- Do not weaken any existing block (code files, sed -i on code, redirects to code, docs/../code traversal must still block).
- Do not modify agent_id / engagement / tokenizer / analyze logic.
- Do not handle sed -i or interpreter-write targeting prose (out of scope; bash carve-out only covers benign_target i.e. redirect/tee/cp/dd/mv/ln targets).
- Do not alter the existing .claude/maestro* or tmp/$TMPDIR carve-outs.

Review the DIFF below for ship-risk (adversarial). End with REVIEW: APPROVE or REVIEW: REQUEST-CHANGES, then BLOCKING: / NITS:.

DIFF:
(no git repo — diff unavailable)