Recon complete. I have everything needed. Both hooks already canonicalize paths (`_check_path` in edits, `ct` + `_canon_proj` in bash) and have tmp/maestro carve-outs. The verify script confirms expected ALLOW/BLOCK cases including the external memory `.md` and `docs/../code` traversal.

## Gate 1 Plan

**Edits hook** (`guard-block-main-edits.sh`): Insert a prose/docs carve-out right before the final `cat >&2 <<'MSG' ... exit 2`, after the tmp/scratch block. Use bash parameter expansion on `$_check_path` to get basename + extension (lowercased) and stem (uppercased), compare against the prose extension/known-name sets, and check `$_check_path` prefix against `$_canon_proj/docs/`.

**Bash hook** (`guard-block-main-bash.sh`): Inside `benign_target(t)`, before `return False`, add the same check on the already-canonical `ct`, reusing the in-function `_canon_proj` (= `os.path.realpath(_proj)`) for the `docs/` prefix.

Both operate strictly on the canonical path, so `docs/../src/x.ts` resolves to `src/x.ts` and still blocks.

---PLAN-JSON---
```json
{
  "summary": "Port pi foreman guard.ts's prose/no-impact carve-out into both maestro guard hooks so the main (CTO) session can directly edit prose/docs and memory .md files while real code edits stay blocked, applying the check only on the already-canonicalized path so traversal (docs/../code) still blocks.",
  "understanding": {
    "editsHook": "hooks/guard-block-main-edits.sh canonicalizes file_path into $_check_path (python3 realpath) and $_canon_proj for the project root, then runs maestro-state and tmp/scratch carve-outs (each exit 0) before a final 'cat >&2 <<MSG ... exit 2' block. The new carve-out goes after tmp/scratch, before the final block.",
    "bashHook": "hooks/guard-block-main-bash.sh has benign_target(t) which canonicalizes t into ct (via _canon/realpath), computes _canon_proj=os.path.realpath(_proj), allows exact maestro paths + ledger prefix + canonical tmp roots, then 'return False'. The new carve-out goes just before 'return False', reusing ct and _canon_proj.",
    "spec": "PROSE_EXTENSIONS={.md,.markdown,.mdx,.txt,.rst,.adoc} matched case-insensitively on basename extension; PROSE_KNOWN_NAMES={LICENSE,LICENCE,COPYING,NOTICE,AUTHORS} matched on uppercased basename stem; repo docs = target under <canonProjRoot>/docs/. All checks on the canonical path.",
    "verify": "/tmp/maestro-prose-verify.sh creates ~/.maestro-prose-test-repo (not under /tmp) with docs/ and src/, asserts prose/docs/memory.md + existing carve-outs ALLOW (rc 0) and code + docs/../code traversal BLOCK (rc 2) for both hooks; exits 0 only if all assertions pass."
  },
  "assumptions": [
    "python3 is available (already a hard dependency of the edits hook for canonicalization).",
    "The in-function _canon_proj in the bash hook is identical to os.path.realpath(_proj) as the spec requests; reusing it is faithful.",
    "docs/ prefix match uses the canonical project root plus '/docs/' with a trailing slash to avoid matching sibling dirs like docs-old."
  ],
  "nonGoals": [
    "Do not weaken any existing block (code files, sed -i on code, redirects to code, docs/../code traversal must still block).",
    "Do not modify agent_id / engagement / tokenizer / analyze logic.",
    "Do not handle sed -i or interpreter-write targeting prose (out of scope; bash carve-out only covers benign_target i.e. redirect/tee/cp/dd/mv/ln targets).",
    "Do not alter the existing .claude/maestro* or tmp/$TMPDIR carve-outs."
  ],
  "alternatives": [
    "Implement prose-extension detection inline in bash via case-pattern lowercasing vs. a small helper function — chosen inline minimal additions to mirror existing style and avoid new abstractions.",
    "Compute the prose check in a shared sourced file used by both hooks — rejected: the two hooks are different languages and the spec mandates editing each in place."
  ],
  "blastRadius": "Two hook files only. Behavior change is additive: a new ALLOW path for prose/docs in PreToolUse Edit/Write and Bash for the main session. No change to subagent path, engagement detection, or block messaging.",
  "steps": [
    "In hooks/guard-block-main-edits.sh, after the tmp/scratch 'if [ \"$is_scratch\" -eq 1 ]; then exit 0; fi' block and before the final 'cat >&2 <<MSG', add a prose/docs carve-out: derive basename from $_check_path, lowercase its extension and compare to {md,markdown,mdx,txt,rst,adoc} → exit 0; uppercase its stem and compare to {LICENSE,LICENCE,COPYING,NOTICE,AUTHORS} → exit 0; if $_check_path is under \"$_canon_proj/docs/\" → exit 0. Operate strictly on $_check_path.",
    "In hooks/guard-block-main-bash.sh benign_target(t), just before 'return False', add the equivalent check on ct: compute basename (reuse module basename()), test the lowercased extension against the prose extensions set, the uppercased stem against the known-names set, and ct.startswith(os.path.join(_canon_proj,'docs')+os.sep) → return True.",
    "Run the verify command to confirm exit 0."
  ],
  "filesLikely": [
    "hooks/guard-block-main-edits.sh",
    "hooks/guard-block-main-bash.sh"
  ],
  "risks": [
    "Case-insensitive extension matching in bash must use a portable lowercasing approach (e.g. tr or ${var,,} — bash 4+); macOS default bash is 3.2, so use tr for portability to avoid silently failing the case-insensitive requirement.",
    "Forgetting the trailing slash on the docs/ prefix could wrongly allow sibling dirs; the plan uses '$_canon_proj/docs/'.",
    "Extracting the stem/extension must handle dotless names (LICENSE) and names with multiple dots; use basename + last-dot split consistent with pi guard semantics."
  ],
  "proposedGates": [
    "Gate 2: After edits, run `bash /tmp/maestro-prose-verify.sh` and confirm it prints 'PROSE CARVE-OUT VERIFY: PASS' and exits 0; visually diff both hooks to confirm only additive carve-out blocks were inserted and no existing logic changed."
  ],
  "requirements": [
    "Prose by extension (.md/.markdown/.mdx/.txt/.rst/.adoc, case-insensitive) ALLOW in both hooks.",
    "Prose by known name (LICENSE/LICENCE/COPYING/NOTICE/AUTHORS, stem uppercased) ALLOW in both hooks.",
    "Target under <canonProjRoot>/docs/ ALLOW (including non-prose like docs/diagram.png) in both hooks.",
    "All checks on the canonical path (_check_path / ct) so docs/../src/x.ts BLOCKS.",
    "Code files and sed -i/redirects to code still BLOCK; existing maestro + tmp carve-outs unchanged.",
    "`bash /tmp/maestro-prose-verify.sh` exits 0."
  ]
}
```