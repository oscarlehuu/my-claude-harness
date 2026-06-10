Task: Add a prose/no-impact carve-out to BOTH maestro guard hooks so the main session (CTO) may edit prose/docs and memory .md files directly, while real code stays blocked. This is a faithful port of pi foreman guard.ts.

FILES TO EDIT (both under hooks/):
- hooks/guard-block-main-edits.sh (bash; PreToolUse Edit/Write). Insert the carve-out right BEFORE the final block (the `cat >&2 <<'MSG' ... exit 2` near the end), AFTER the existing tmp/scratch carve-out. Reuse the already-computed canonical `$_check_path` and `$_canon_proj` variables.
- hooks/guard-block-main-bash.sh (python; PreToolUse Bash). Add the carve-out INSIDE the benign_target(t) function, before `return False`, using the already-canonicalized `ct` and the canonical project root `os.path.realpath(_proj)`.

EXACT SPEC (from pi guard.ts isProsePath / isRepoDocsPath / isNoImpactPath):
- PROSE_EXTENSIONS = {.md, .markdown, .mdx, .txt, .rst, .adoc} — compare the basename's extension case-insensitively → ALLOW.
- PROSE_KNOWN_NAMES = {LICENSE, LICENCE, COPYING, NOTICE, AUTHORS} — match the basename STEM (filename minus extension), uppercased → ALLOW.
- Repo docs: target under <repoRoot>/docs/ (repoRoot = the canonical project dir) → ALLOW.
- SECURITY (critical): the path is already canonicalized (realpath) into `_check_path` (edits hook) / `ct` (bash hook). Apply the prose/docs check ON THE CANONICAL path so a traversal like docs/../src/app.ts resolves to src/app.ts and STILL BLOCKS. Never match on the raw/un-canonicalized value.

CONSTRAINTS / NON-GOALS:
- Do NOT weaken any existing block: code files (.ts/.py/.js/Makefile/etc.), sed -i on code, redirects to code, and docs/../code traversal must STILL block.
- Keep the existing carve-outs (.claude/maestro*, tmp/$TMPDIR) working unchanged.
- Do NOT touch agent_id / engagement / tokenizer / analyze logic — only ADD the prose/docs allow path.
- Edits-hook prose check applies to file_path; bash-hook applies inside benign_target (covers redirect/tee/cp/dd targets). Do not try to also handle sed -i / interpreter-write on prose — out of scope.

ACCEPTANCE: the verify command `bash /tmp/maestro-prose-verify.sh` exits 0 (prose/docs ALLOW, code+traversal BLOCK, existing carve-outs intact).

Non-goals:
- Do not weaken any existing block (code files, sed -i on code, redirects to code, docs/../code traversal must still block).
- Do not modify agent_id / engagement / tokenizer / analyze logic.
- Do not handle sed -i or interpreter-write targeting prose (out of scope; bash carve-out only covers benign_target i.e. redirect/tee/cp/dd/mv/ln targets).
- Do not alter the existing .claude/maestro* or tmp/$TMPDIR carve-outs.

Implement the smallest change that satisfies the task on disk. End your final message with a ---DEV-JSON--- block: {"filesChanged":["path - what changed"]}.