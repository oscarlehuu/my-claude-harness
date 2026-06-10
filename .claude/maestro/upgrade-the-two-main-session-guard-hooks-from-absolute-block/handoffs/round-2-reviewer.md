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

Review the DIFF below for ship-risk (adversarial). End with REVIEW: APPROVE or REVIEW: REQUEST-CHANGES, then BLOCKING: / NITS:.

DIFF:
diff --git a/CLAUDE.md b/CLAUDE.md
index 06e46a8..e77a205 100644
--- a/CLAUDE.md
+++ b/CLAUDE.md
@@ -3,28 +3,31 @@
 This is a **native Claude Code** orchestration harness — a port of the pi `foreman` kernel. The model
 you are talking to is the **CTO**; the human is the **founder** (decision altitude: ideas, priorities,
 taste). The CTO runs engineering on the founder's behalf, talks to them **only at decision points**,
-and **never writes production code itself** — all code changes flow through the **maestro** gated loop,
-run by crew subagents.
+and routes implementation by risk: tiny direct edits may stay in the main session inside the guard
+budget; larger/riskier work flows through the **maestro** gated loop, run by crew subagents.
 
 > Company variant = 100% native Claude Code (subagents + hooks + skill). No proxy, no MCP required.
 > A separate `personal/` variant adds an MCP maestro + cliproxy when multi-provider/process-100% is
 > needed — out of scope here.
 
-## The one rule: orchestrate, never implement
+## Routing rule: direct only while small, safe, and obvious
 
-- The CTO (main session) is **read-only on production code**: it may Read/Grep/Glob/ask, plan, and
-  delegate — it must **not** Edit/Write/MultiEdit or run mutating Bash on code. PreToolUse hooks
-  (`guard-block-main-edits.sh`, `guard-block-main-bash.sh`) block those in the main session (even
-  under `--dangerously-skip-permissions`). The CTO **may** write its own harness state under
-  `.claude/maestro*` (manifest, verify command, ledger) — that is bookkeeping, not production code.
-- To make any code change: **invoke the `maestro` skill** (`/maestro <task>`). Do not hand-edit. When
-  about to edit code in the main session for anything beyond a trivial change, stop and run maestro.
+- The CTO (main session) may edit directly only inside the guard budget (default ≤50 changed lines and
+  ≤2 files cumulative uncommitted diff vs HEAD) and never on protected paths. Use direct edit only when
+  you can write the complete diff in your head before opening the file; if verification requires running
+  something, or the blast radius is unclear, invoke the `maestro` skill (`/maestro <task>`).
+- Budget is cumulative per task: ten small edits are one big change. When the guard trips, run maestro
+  for the **remainder** of the task; never split a task to stay under the limit. Protected paths always
+  go to maestro, size does not matter. Uncertain → maestro. The CTO may still write its own harness
+  state under `.claude/maestro*` (manifest, verify command, ledger) — that is bookkeeping, not
+  production code.
 
 ## Engagement (per repo)
 
 Maestro is **ON by default**. `.claude/maestro-direct` present → **direct-edit mode** (guard off, hand
 edits allowed) for that repo. Disengage: `echo 1 > .claude/maestro-direct`; re-engage: `rm` it. Use the
-loop for non-trivial changes; skip it for trivial one-liners, pure questions, reading/explaining, recon.
+loop for changes that exceed budget, touch protected paths, need verification, or carry non-obvious
+risk; skip it for trivial budgeted tweaks, pure questions, reading/explaining, recon.
 
 ## The maestro loop (skill: `/maestro`)
 
diff --git a/README.md b/README.md
index 13a5df8..aab0008 100644
--- a/README.md
+++ b/README.md
@@ -2,8 +2,8 @@
 
 **Maestro** — a gated orchestration harness for **Claude Code**, a native port of the pi `foreman`
 kernel. The orchestrator (the CTO) plans and delegates to a crew (planner / developer / ui-developer /
-tester / reviewer / scout); it never hand-edits. Hard gates: plan (Gate 1), verify (exit code), ship
-(Gate 2) with a strict Definition of Done.
+tester / reviewer / scout), while allowing only tiny main-session edits inside the guard budget. Hard
+gates: plan (Gate 1), verify (exit code), ship (Gate 2) with a strict Definition of Done.
 
 ## Layout
 
@@ -32,11 +32,26 @@ existing global `~/.claude/CLAUDE.md`.
 ## How it works
 
 The CTO drives a gated loop and delegates implementation to crew subagents. Three PreToolUse hooks make
-the rules hard: `guard-block-main-edits` + `guard-block-main-bash` block main-session code edits
-(forcing delegation; crew subagents carry an `agent_id` and are allowed), and `commit-gate` re-runs the
-verify command on `git commit`. A SessionStart hook (`maestro-engage`) auto-engages maestro so you
-never type `/maestro`. Per-repo direct-edit escape hatch: `echo 1 > .claude/maestro-direct`.
+the rules hard: `guard-block-main-edits` + `guard-block-main-bash` budget-gate main-session code edits
+(crew subagents carry an `agent_id` and are allowed), and `commit-gate` re-runs the verify command on
+`git commit`. A SessionStart hook (`maestro-engage`) auto-engages maestro so you never type `/maestro`.
+Per-repo direct-edit escape hatch: `echo 1 > .claude/maestro-direct`.
+
+The default main-session direct-edit budget is ≤50 changed lines and ≤2 files in the cumulative
+uncommitted diff vs HEAD. Configure per repo with `.claude/maestro-budget`:
+
+```ini
+LINES=50
+FILES=2
+PROTECTED=**/auth/**:**/migrations/**:.github/workflows/**
+```
+
+`LINES` and `FILES` are non-negative integers; malformed/missing values fall back to defaults.
+`PROTECTED` is optional and uses colon-separated globs matched against canonical repo paths (relative
+patterns are repo-relative; `**` spans directories). Protected paths always route to maestro regardless
+of size. Guard blocks append JSONL calibration records to `.claude/maestro/guard-log.jsonl`.
 
 The harness state (`.claude/maestro.json` gate manifest, `.claude/maestro-verify`, `.claude/maestro/<slug>/`
 ledger) is the CTO's own bookkeeping — the guard allows the main session to write `.claude/maestro*`,
-but nothing else. See `docs/architecture.md` for the design and the Workflow-tool upgrade path.
+and those docs/prose/state paths do not count toward the budget. See `docs/architecture.md` for the
+design and the Workflow-tool upgrade path.
diff --git a/hooks/__pycache__/guard-block-main-bash.cpython-314.pyc b/hooks/__pycache__/guard-block-main-bash.cpython-314.pyc
new file mode 100644
index 0000000..61a42f0
Binary files /dev/null and b/hooks/__pycache__/guard-block-main-bash.cpython-314.pyc differ
diff --git a/hooks/guard-block-main-bash.sh b/hooks/guard-block-main-bash.sh
index 3efc507..9fbd7fa 100755
--- a/hooks/guard-block-main-bash.sh
+++ b/hooks/guard-block-main-bash.sh
@@ -1,31 +1,30 @@
 #!/usr/bin/env python3
-"""PreToolUse(Bash) guard — close the orchestrate-only gap.
+"""PreToolUse(Bash) guard — budget-gate main-session shell mutations.
 
-The Edit/Write guard blocks the main session from the editing TOOLS, but a shell
-command (`echo >> f`, `sed -i`, `tee`, `cp`, `patch`, `git apply`, `bash -c "...>>f"`,
-`python3 -c "open(...,'w')"`) can mutate the working tree and bypass it. This hook
-classifies the Bash command and blocks the MAIN session (no agent_id) from any
-file-mutating shell. Subagents (developer/ui-developer/... carry an agent_id) pass.
-Read-only commands (ls, grep, cat, git status/log/diff, test runners, redirects to
-/dev/null or $TMPDIR) pass through.
+The Edit/Write guard covers editing TOOLS, but a shell command (`echo >> f`,
+`sed -i`, `tee`, `cp`, `patch`, `git apply`, `bash -c "...>>f"`,
+`python3 -c "open(...,'w')"`) can mutate the working tree. This hook classifies
+Bash commands, preserves benign/read-only carve-outs, and lets the MAIN session
+(no agent_id) mutate only within the deterministic repo budget. Subagents pass.
 
 Robust tokenization via shlex (respects quotes) — mirrors pi foreman guard.ts.
 Not a perfect seal (a determined model can use exotic paths); the commit-gate +
 human review are the ultimate "can't ship broken" backstops.
 """
-import sys, json, shlex, os, re, functools
+import sys, json, shlex, os, re, functools, subprocess, datetime, fnmatch
+
+
+HOOK = "guard-block-main-bash"
 
 
 def allow():
     sys.exit(0)
 
 
-def block(reason):
-    sys.stderr.write(
-        "BLOCKED: the orchestrator must not modify files via shell (%s).\n"
-        "Drive the change through the maestro MCP tool instead — "
-        "maestro({task, cwd, verifyCommand?}) and let the gated dev->test->review loop make it.\n" % reason
-    )
+def short_block(message):
+    sys.stderr.write(message)
+    if not message.endswith("\n"):
+        sys.stderr.write("\n")
     sys.exit(2)
 
 
@@ -85,10 +84,15 @@ _CANON_TMP_ROOTS = _build_tmp_roots()
 
 @functools.lru_cache(maxsize=256)
 def _canon(t):
-    """Return the canonical (realpath-normalized) form of path t."""
+    """Return the canonical (realpath-normalized) form of path t.
+
+    Relative mutation targets are interpreted relative to the project root, matching
+    the repo used for budget/protected checks rather than the hook process cwd.
+    """
     try:
+        base = t if os.path.isabs(t) else os.path.join(_proj, t)
         # os.path.realpath resolves symlinks and .. segments without requiring the path to exist.
-        return os.path.realpath(t)
+        return os.path.realpath(base)
     except Exception:
         return t
 
@@ -116,7 +120,10 @@ def benign_target(t):
     _maestro_ledger_prefix = os.path.join(_canon_proj, ".claude", "maestro") + os.sep
     if ct in _maestro_exact or ct.startswith(_maestro_ledger_prefix):
         return True
-    if any(ct.startswith(r) for r in _CANON_TMP_ROOTS):
+    _canon_proj = os.path.realpath(_proj)
+    # Scratch carve-out is for no-impact files outside the repo. If the project itself
+    # lives under TMPDIR during tests, keep repo paths budget/protected-gated.
+    if any(ct.startswith(r) for r in _CANON_TMP_ROOTS) and not (ct == _canon_proj or ct.startswith(_canon_proj + os.sep)):
         return True
 
     # Prose/docs/no-impact carve-out — allow direct writes to documentation/memory files.
@@ -147,12 +154,10 @@ def strip_heredocs(s):
     the bare delimiter (with optional leading tabs for <<-) is removed.
     CRITICALLY: content on the intro line BEFORE and AFTER the <<DELIM token
     is preserved so that:
-      cat <<'EOF' > ./src/app.ts   →  cat > ./src/app.ts   (repo redirect → BLOCK)
-      cat <<'EOF' | tee ./src/app.ts →  cat | tee ./src/app.ts  (repo write → BLOCK)
+      cat <<'EOF' > ./src/app.ts   →  cat > ./src/app.ts   (repo redirect → budget gate)
+      cat <<'EOF' | tee ./src/app.ts →  cat | tee ./src/app.ts  (repo write → budget gate)
       cat <<'EOF' > /tmp/x         →  cat > /tmp/x          (tmp redirect → ALLOW)
     """
-    # Match the heredoc introduction: optional fd, <<-?, then the delimiter
-    # (which may be bare, single-quoted, or double-quoted).
     heredoc_intro = re.compile(
         r'(?P<redir>(?:\d+)?<<(?P<strip>-?))'
         r"(?P<q>['\"]?)(?P<delim>[A-Za-z0-9_]+)(?P=q)"
@@ -166,43 +171,24 @@ def strip_heredocs(s):
         if m:
             delim = m.group("delim")
             strip_tabs = m.group("strip") == "-"
-            # Keep the part of the line BEFORE the <<DELIM marker AND everything
-            # AFTER the marker (e.g. "> target" or "| tee target") for redirect analysis.
-            # Only the <<DELIM token itself (and its body) is elided.
-            intro_part = line[:m.start()]    # before <<DELIM
-            tail_part  = line[m.end():]      # after <<DELIM (redirect/pipe target lives here)
+            intro_part = line[:m.start()]
+            tail_part  = line[m.end():]
             result.append(intro_part + tail_part)
             i += 1
-            # Skip lines until we find the closing delimiter line.
-            # The closing delimiter is normally the bare word on its own line.
-            # When the heredoc is embedded inside a quoted shell argument
-            # (e.g. bash -c "cat <<'EOF'\nbody\nEOF"), the final delimiter
-            # line may have a trailing quote character (e.g. 'EOF"') because
-            # the closing quote of the outer argument immediately follows.
-            # Accept delim with an optional trailing ' or " as the terminator;
-            # when a trailing quote is found, append it to the intro_part so
-            # that the outer quoting context is preserved for shlex parsing.
             while i < len(lines):
                 body_line = lines[i]
                 check = body_line.lstrip("\t") if strip_tabs else body_line
                 if check == delim:
-                    i += 1  # consume the closing delimiter line too
+                    i += 1
                     break
-                # Accept delimiter followed by any run of trailing quote/backslash chars.
-                # This handles escaped-quote terminators like EOF\", EOF\"\", EOF'', EOF\'
-                # that appear when a heredoc is embedded inside a quoted shell argument.
-                # Capturing the trailing run and re-appending it preserves the outer
-                # quoting context so shlex can still parse the surrounding command.
-                trailing_pat = re.escape(delim) + r'[\\\'"]*'
+                trailing_pat = re.escape(delim) + r'[\\\'\"]*'
                 tm = re.fullmatch(trailing_pat, check)
-                if tm and check != delim:  # bare delim already handled above
-                    # Trailing chars close the outer quoting context — preserve them.
+                if tm and check != delim:
                     trailing_chars = check[len(delim):]
                     result[-1] = result[-1] + trailing_chars
                     i += 1
                     break
                 i += 1
-            # Heredoc body consumed; continue scanning the rest of the command.
         else:
             result.append(line)
             i += 1
@@ -229,7 +215,7 @@ def mask_quotes(s):
                     i += 2
                     continue
                 i += 1
-            out.append("Q")  # whole quoted region → single inert placeholder
+            out.append("Q")
             i += 1
         else:
             out.append(c)
@@ -256,45 +242,24 @@ def lead_command(seg):
 
 
 def coarse_reason(s):
-    """Regex fallback when shlex can't parse (unbalanced quotes, etc.).
-
-    Redirect detection must mirror the REDIR set used by the parseable path:
-      {">", ">>", ">|", "&>", "&>>"}
-    plus fd-numbered forms N> and N>> (e.g. 1>, 2>).
-
-    Exclusions (must NOT flag):
-    - Targets matching /dev/(null|stdout|stderr|tty) — truly benign.
-    - fd-duplication: N>&M, >&N, &>&N — these redirect to a descriptor, not a file.
-      The telltale is the target (or the character immediately after the operator)
-      starting with '&'.
-    """
+    """Regex fallback when shlex can't parse (unbalanced quotes, etc.)."""
     _dev_re = r"/dev/(null|stdout|stderr|tty)\b"
-
-    # Pattern A: &> and &>> (stdout+stderr redirect) — NOT fd-dup (&>&N).
-    # A &> followed by & means fd-dup (e.g. &>&1) — skip.
-    if re.search(r"&>>?\s*(?!&)(?!" + _dev_re + r")\S", s):
-        return "shell redirection (heuristic)"
-
-    # Pattern B: >| (clobber redirect) — always a file write (shell never uses >|& for fd-dup).
-    if re.search(r">\|\s*(?!" + _dev_re + r")\S", s):
-        return "shell redirection (heuristic)"
-
-    # Pattern C: plain > or >> and fd-numbered N> or N>> (e.g. 1>, 2>, 1>>, 2>>).
-    # Must exclude:
-    #   - &>  (already handled above, but &>> ? would be caught above; lone > preceded by & is fd-dup '>&')
-    #   - N>& (fd-dup like 2>&1) — target starts with &
-    #   - >|  (clobber — handled above; plain > followed by | is not a redirect to a file)
-    # The negative lookbehind (?<!&) prevents matching the > in >&N fd-dup.
-    # The negative lookahead (?!&|/) with /dev check prevents flagging fd-dup targets.
-    if re.search(
-        r"(?<![&|])\d*>>?(?!\|)\s*(?!&)(?!" + _dev_re + r")\S",
+    m = re.search(r"&>>?\s*(?!&)(?!" + _dev_re + r")(?P<t>\S+)", s)
+    if m:
+        return ("shell redirection (heuristic)", m.group("t").rstrip("\\'\""))
+    m = re.search(r">\|\s*(?!" + _dev_re + r")(?P<t>\S+)", s)
+    if m:
+        return ("shell redirection (heuristic)", m.group("t").rstrip("\\'\""))
+    m = re.search(
+        r"(?<![&|])\d*>>?(?!\|)\s*(?!&)(?!" + _dev_re + r")(?P<t>\S+)",
         s,
-    ):
-        return "shell redirection (heuristic)"
+    )
+    if m:
+        return ("shell redirection (heuristic)", m.group("t").rstrip("\\'\""))
 
     if re.search(r"\b(sed|gsed)\s+-i|\bperl\s+-i|\btee\b|\bdd\b|\b(cp|mv|ln)\b"
                  r"|\bpatch\b|\b(truncate|install)\b|\bgit\s+(apply|restore|stash|clean)\b", s):
-        return "file-mutating command (heuristic)"
+        return ("file-mutating command (heuristic)", None)
     return None
 
 
@@ -305,29 +270,14 @@ def analyze(cmd, depth=0):
         # would produce false-positives for benign recursive calls; the commit-gate and
         # human review remain the ultimate backstops for anything this exotic.
         return None
-    # Strip heredoc bodies first so their contents (which may contain >, <, etc.)
-    # are never mistaken for shell operators or redirects.
-    # strip_heredocs is idempotent on heredoc-free input, so it is safe to call
-    # unconditionally at every recursion level (including bash -c / sh -c inlines).
     cmd = strip_heredocs(cmd)
     try:
         tokens = tokenize(cmd)
     except ValueError:
-        # Fail CLOSED: the command cannot be cleanly tokenized (dangling open quote,
-        # unbalanced heredoc markers, etc.).  mask_quotes() erases content inside
-        # unterminated quote regions, which means a redirect like > repo/file hidden
-        # inside a dangling-quote can become invisible → coarse_reason returns None → ALLOW.
-        # Instead, run coarse_reason on the RAW (unmasked) command so that any
-        # redirect or file-mutating pattern is still visible.  If there is ANY
-        # mutation evidence → BLOCK.  Only if the raw command is cleanly benign
-        # (no mutation pattern at all) do we allow it through.
         raw_reason = coarse_reason(cmd)
         if raw_reason:
             return raw_reason
-        # No mutation evidence in the raw command; fall back to the masked check as
-        # a secondary signal (extra-cautious: if masking reveals a new reason, block).
-        masked_reason = coarse_reason(mask_quotes(cmd))
-        return masked_reason
+        return coarse_reason(mask_quotes(cmd))
 
     # 1) Output redirection to a real file. Detect on the quote-masked command so
     #    a quoted '>' inside an argument is not read as a redirect operator.
@@ -339,7 +289,7 @@ def analyze(cmd, depth=0):
         if t in REDIR:
             tgt = masked_tokens[i + 1] if i + 1 < len(masked_tokens) else None
             if not benign_target(tgt):
-                return "output redirection to %s" % tgt
+                return ("output redirection to %s" % tgt, tgt)
 
     # 2) Per-segment leading-command classification.
     segments, seg = [], []
@@ -363,35 +313,43 @@ def analyze(cmd, depth=0):
         if name in ("sed", "gsed") and any(
             a == "-i" or a.startswith("-i") or a == "--in-place" for a in args
         ):
-            return "sed in-place edit"
+            tgt = nonopt[-1] if nonopt else None
+            return ("sed in-place edit", tgt)
         if name == "perl" and any(a == "-i" or a.startswith("-i") for a in args):
-            return "perl in-place edit"
+            tgt = nonopt[-1] if nonopt else None
+            return ("perl in-place edit", tgt)
         if name == "tee" and any(not benign_target(a) for a in nonopt):
-            return "tee writes a file"
+            tgt = next((a for a in nonopt if not benign_target(a)), None)
+            return ("tee writes a file", tgt)
         if name == "dd" and any(
             a.startswith("of=") and not benign_target(a[3:]) for a in args
         ):
-            return "dd writes a file"
+            tgt = next((a[3:] for a in args if a.startswith("of=") and not benign_target(a[3:])), None)
+            return ("dd writes a file", tgt)
         if name in ("cp", "mv", "ln"):
             tgt = nonopt[-1] if nonopt else None
             if not benign_target(tgt):
-                return "%s writes %s" % (name, tgt)
+                return ("%s writes %s" % (name, tgt), tgt)
         if name in ("truncate", "install", "patch"):
-            return "%s modifies files" % name
+            tgt = nonopt[-1] if nonopt else None
+            return ("%s modifies files" % name, tgt)
         if name in EDITORS:
-            return "interactive editor %s" % name
+            tgt = nonopt[-1] if nonopt else None
+            return ("interactive editor %s" % name, tgt)
         if name == "git":
             sub = nonopt[0] if nonopt else ""
             if sub in ("apply", "restore"):
-                return "git %s mutates the tree" % sub
+                tgt = nonopt[-1] if len(nonopt) > 1 else None
+                return ("git %s mutates the tree" % sub, tgt)
             if sub == "checkout" and "--" in args:
-                return "git checkout -- mutates files"
+                tgt = args[-1] if args else None
+                return ("git checkout -- mutates files", tgt)
             if sub == "reset" and "--hard" in args:
-                return "git reset --hard discards changes"
+                return ("git reset --hard discards changes", None)
             if sub == "stash":
-                return "git stash mutates the tree"
+                return ("git stash mutates the tree", None)
             if sub == "clean":
-                return "git clean deletes files"
+                return ("git clean deletes files", None)
         # Shell -c: recurse into the inline script.
         if name in SHELLS:
             for j, a in enumerate(args):
@@ -402,13 +360,181 @@ def analyze(cmd, depth=0):
         # Interpreter -c/-e/-i with a language file-write API.
         if name in LANGS:
             if any(a == "-i" or a.startswith("-i") for a in args):
-                return "%s in-place edit" % name
+                return ("%s in-place edit" % name, nonopt[-1] if nonopt else None)
             if WRITE_API.search(" ".join(args)):
-                return "%s inline file write" % name
+                return ("%s inline file write" % name, None)
     return None
 
 
-reason = analyze(command)
-if reason:
-    block(reason)
+def git(repo, *args):
+    return subprocess.check_output(["git", "-C", repo, *args], stderr=subprocess.DEVNULL)
+
+
+def load_config(repo):
+    lines, files, protected = 50, 2, []
+    path = os.path.join(repo, ".claude", "maestro-budget")
+    try:
+        with open(path, "r", encoding="utf-8") as f:
+            for raw in f:
+                raw = raw.strip()
+                if not raw or raw.startswith("#") or "=" not in raw:
+                    continue
+                k, v = raw.split("=", 1)
+                k, v = k.strip().upper(), v.strip()
+                if k == "LINES":
+                    try:
+                        n = int(v)
+                        if n >= 0:
+                            lines = n
+                    except Exception:
+                        lines = 50
+                elif k == "FILES":
+                    try:
+                        n = int(v)
+                        if n >= 0:
+                            files = n
+                    except Exception:
+                        files = 2
+                elif k == "PROTECTED":
+                    protected = [p for p in v.split(":") if p]
+    except FileNotFoundError:
+        pass
+    except Exception:
+        return 50, 2, []
+    return lines, files, protected
+
+
+def rel_for(repo, path):
+    try:
+        return os.path.relpath(os.path.realpath(path), repo).replace(os.sep, "/")
+    except Exception:
+        return (path or "").replace(os.sep, "/")
+
+
+def match_segments(psegs, ssegs):
+    if not psegs:
+        return not ssegs
+    head = psegs[0]
+    if head == "**":
+        return match_segments(psegs[1:], ssegs) or (bool(ssegs) and match_segments(psegs, ssegs[1:]))
+    return bool(ssegs) and fnmatch.fnmatchcase(ssegs[0], head) and match_segments(psegs[1:], ssegs[1:])
+
+
+def glob_match(repo, pattern, abs_path):
+    pat = pattern.strip().replace("\\", "/")
+    if not pat:
+        return False
+    if os.path.isabs(pat):
+        subject = os.path.realpath(abs_path).lstrip(os.sep).replace(os.sep, "/")
+        pat = os.path.realpath(pat).lstrip(os.sep).replace(os.sep, "/")
+    else:
+        subject = rel_for(repo, abs_path)
+    return match_segments([p for p in pat.split("/") if p != ""], [p for p in subject.split("/") if p != ""])
+
+
+def is_no_count_rel(rel):
+    rel = rel.replace("\\", "/")
+    base = os.path.basename(rel)
+    stem, ext = os.path.splitext(base)
+    if rel in {".claude/maestro.json", ".claude/maestro-verify", ".claude/maestro-direct"}:
+        return True
+    if rel.startswith(".claude/maestro/"):
+        return True
+    if ext.lower() in {".md", ".markdown", ".mdx", ".txt", ".rst", ".adoc"}:
+        return True
+    if stem.upper() in {"LICENSE", "LICENCE", "COPYING", "NOTICE", "AUTHORS"}:
+        return True
+    if rel.startswith("docs/"):
+        return True
+    return False
+
+
+def line_count_file(path):
+    try:
+        with open(path, "rb") as f:
+            data = f.read()
+        if not data:
+            return 0
+        return len(data.splitlines())
+    except Exception:
+        return 0
+
+
+def current_usage(repo):
+    changed = set()
+    lines = 0
+    out = git(repo, "diff", "--numstat", "HEAD", "--").decode("utf-8", "replace")
+    for row in out.splitlines():
+        parts = row.split("\t")
+        if len(parts) < 3:
+            continue
+        rel = parts[-1]
+        if is_no_count_rel(rel):
+            continue
+        changed.add(rel)
+        try:
+            add = 0 if parts[0] == "-" else int(parts[0])
+            dele = 0 if parts[1] == "-" else int(parts[1])
+        except Exception:
+            add = dele = 0
+        lines += add + dele
+    out = git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all")
+    for b in out.split(b"\0"):
+        if not b or not b.startswith(b"?? "):
+            continue
+        rel = b[3:].decode("utf-8", "replace")
+        if is_no_count_rel(rel):
+            continue
+        changed.add(rel)
+        lines += line_count_file(os.path.join(repo, rel))
+    return lines, changed
+
+
+def write_log(repo, target, reason, lines_used, files_used):
+    try:
+        log_dir = os.path.join(repo, ".claude", "maestro")
+        os.makedirs(log_dir, exist_ok=True)
+        rec = {
+            "ts": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
+            "hook": HOOK,
+            "target": os.path.realpath(target) if target else "",
+            "lines_used": lines_used,
+            "files_used": files_used,
+            "reason": reason,
+        }
+        with open(os.path.join(log_dir, "guard-log.jsonl"), "a", encoding="utf-8") as f:
+            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
+    except Exception:
+        pass
+
+
+result = analyze(command)
+if not result:
+    allow()
+reason, target = result
+
+# If git cannot be queried, fail open: tester/reviewer/commit-gate remain the
+# backstops, and non-repo directories have no production-risk budget.
+try:
+    repo = os.path.realpath(git(os.path.realpath(_proj), "rev-parse", "--show-toplevel").decode().strip())
+    max_lines, max_files, protected = load_config(repo)
+    cur_lines, changed_files = current_usage(repo)
+except Exception:
+    allow()
+
+if target:
+    ctarget = _canon(target)
+    if any(glob_match(repo, p, ctarget) for p in protected):
+        write_log(repo, ctarget, "protected", cur_lines, len(changed_files))
+        short_block("BLOCKED: protected path. Size does not matter on protected paths; run maestro for this task.\n")
+
+used_lines = cur_lines
+used_files = len(changed_files)
+if used_lines > max_lines or used_files > max_files:
+    write_log(repo, target or "", "budget", used_lines, used_files)
+    short_block(
+        f"BLOCKED: direct-edit budget exhausted (lines {used_lines}/{max_lines}, files {used_files}/{max_files}).\n"
+        "Run maestro for the REMAINDER of this task; never split a task to stay under the limit.\n"
+    )
+
 allow()
diff --git a/hooks/guard-block-main-edits.sh b/hooks/guard-block-main-edits.sh
index 36d36af..aee5664 100755
--- a/hooks/guard-block-main-edits.sh
+++ b/hooks/guard-block-main-edits.sh
@@ -1,8 +1,10 @@
 #!/usr/bin/env bash
-# PreToolUse guard — the orchestrator (main session) must DELEGATE implementation to
-# the maestro crew, never edit code directly. Crew subagents (which carry an agent_id)
-# are allowed to edit. Blocks even under --dangerously-skip-permissions (exit 2 ignores
-# permission mode).
+# PreToolUse guard — budget-gate main-session edits.
+#
+# Crew subagents (which carry an agent_id) are allowed to edit. The main session
+# may make small direct edits inside the deterministic per-repo budget; protected
+# paths and over-budget changes route to maestro. Blocks even under
+# --dangerously-skip-permissions (exit 2 ignores permission mode).
 #
 # Carve-outs that let the main session through:
 #   1. Engagement OFF — `.claude/maestro-direct` exists in the repo → direct-edit mode.
@@ -49,8 +51,14 @@ _canon_path=""
 if [ -n "$file_path" ] && command -v python3 >/dev/null 2>&1; then
   # os.path.realpath resolves symlinks in existing path components (e.g. /tmp → /private/tmp
   # on macOS) even when the final path does not yet exist.  This is exactly what we need to
-  # prevent traversal attacks like /tmp/../../<repo>/file.
-  _canon_path="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$file_path" 2>/dev/null || true)"
+  # prevent traversal attacks like /tmp/../../<repo>/file. Relative tool paths are resolved
+  # against the project root, matching the repo used for budget/protected checks.
+  _canon_input_path="$file_path"
+  case "$file_path" in
+    /*) ;;
+    *) _canon_input_path="$proj/$file_path" ;;
+  esac
+  _canon_path="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$_canon_input_path" 2>/dev/null || true)"
 fi
 # Fall back to original path if canonicalization fails (fail-open).
 _check_path="${_canon_path:-$file_path}"
@@ -94,12 +102,17 @@ for _pfx in "${_canon_tmp_roots[@]}"; do
     "$_pfx"*) is_scratch=1; break ;;
   esac
 done
+# Scratch carve-out is for no-impact files outside the repo. If the project itself
+# lives under TMPDIR during tests, keep repo paths budget/protected-gated.
+case "$_check_path" in
+  "$_canon_proj"|"$_canon_proj/"*) is_scratch=0 ;;
+esac
 if [ "$is_scratch" -eq 1 ]; then
   exit 0
 fi
 
 # Prose/docs/no-impact carve-out — the CTO may edit documentation and memory files
-# directly, but code remains blocked.  SECURITY: use the canonical _check_path so
+# directly, but code remains budget-gated.  SECURITY: use the canonical _check_path so
 # docs/../src/app.ts resolves to src/app.ts and does NOT match the docs prefix.
 _base="${_check_path##*/}"
 _ext=""
@@ -123,16 +136,218 @@ case "$_check_path" in
   "$_docs_prefix"*) exit 0 ;;
 esac
 
-# No agent_id, engaged, real repo file → this is the orchestrator → block direct edits.
-cat >&2 <<'MSG'
-BLOCKED: the orchestrator does not edit files directly.
+# Protected-path + budget gate. If git cannot be queried, fail open: tester/reviewer/
+# commit-gate remain backstops, and non-repo directories have no production-risk budget.
+set +e
+python3 - "$_check_path" "$_canon_proj" 3<<<"$input" <<'PY'
+import datetime, fnmatch, json, os, subprocess, sys
+
+HOOK = "guard-block-main-edits"
+target = os.path.realpath(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] else ""
+proj = os.path.realpath(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else os.getcwd()
+try:
+    payload = json.load(os.fdopen(3))
+except Exception:
+    sys.exit(0)  # unparseable hook payload stays fail-open
+
+
+def git(*args):
+    return subprocess.check_output(["git", "-C", proj, *args], stderr=subprocess.DEVNULL)
+
+try:
+    repo = os.path.realpath(git("rev-parse", "--show-toplevel").decode().strip())
+except Exception:
+    sys.exit(0)
+
+
+def load_config():
+    lines, files, protected = 50, 2, []
+    path = os.path.join(repo, ".claude", "maestro-budget")
+    try:
+        with open(path, "r", encoding="utf-8") as f:
+            for raw in f:
+                raw = raw.strip()
+                if not raw or raw.startswith("#") or "=" not in raw:
+                    continue
+                k, v = raw.split("=", 1)
+                k, v = k.strip().upper(), v.strip()
+                if k == "LINES":
+                    try:
+                        n = int(v)
+                        if n >= 0:
+                            lines = n
+                    except Exception:
+                        lines = 50
+                elif k == "FILES":
+                    try:
+                        n = int(v)
+                        if n >= 0:
+                            files = n
+                    except Exception:
+                        files = 2
+                elif k == "PROTECTED":
+                    protected = [p for p in v.split(":") if p]
+    except FileNotFoundError:
+        pass
+    except Exception:
+        return 50, 2, []
+    return lines, files, protected
+
+max_lines, max_files, protected = load_config()
+
+
+def rel_for(path):
+    try:
+        return os.path.relpath(os.path.realpath(path), repo).replace(os.sep, "/")
+    except Exception:
+        return path.replace(os.sep, "/")
+
+
+def match_segments(psegs, ssegs):
+    if not psegs:
+        return not ssegs
+    head = psegs[0]
+    if head == "**":
+        return match_segments(psegs[1:], ssegs) or (bool(ssegs) and match_segments(psegs, ssegs[1:]))
+    return bool(ssegs) and fnmatch.fnmatchcase(ssegs[0], head) and match_segments(psegs[1:], ssegs[1:])
+
+
+def glob_match(pattern, abs_path):
+    pat = pattern.strip().replace("\\", "/")
+    if not pat:
+        return False
+    if os.path.isabs(pat):
+        subject = os.path.realpath(abs_path).lstrip(os.sep).replace(os.sep, "/")
+        pat = os.path.realpath(pat).lstrip(os.sep).replace(os.sep, "/")
+    else:
+        subject = rel_for(abs_path)
+    return match_segments([p for p in pat.split("/") if p != ""], [p for p in subject.split("/") if p != ""])
+
+
+def is_protected(path):
+    return any(glob_match(p, path) for p in protected)
+
+
+def is_no_count_rel(rel):
+    rel = rel.replace("\\", "/")
+    base = os.path.basename(rel)
+    stem, ext = os.path.splitext(base)
+    if rel in {".claude/maestro.json", ".claude/maestro-verify", ".claude/maestro-direct"}:
+        return True
+    if rel.startswith(".claude/maestro/"):
+        return True
+    if ext.lower() in {".md", ".markdown", ".mdx", ".txt", ".rst", ".adoc"}:
+        return True
+    if stem.upper() in {"LICENSE", "LICENCE", "COPYING", "NOTICE", "AUTHORS"}:
+        return True
+    if rel.startswith("docs/"):
+        return True
+    return False
+
+
+def line_count_file(path):
+    try:
+        with open(path, "rb") as f:
+            data = f.read()
+        if not data:
+            return 0
+        return len(data.splitlines())
+    except Exception:
+        return 0
+
+
+def current_usage():
+    changed = set()
+    lines = 0
+    out = git("diff", "--numstat", "HEAD", "--").decode("utf-8", "replace")
+    for row in out.splitlines():
+        parts = row.split("\t")
+        if len(parts) < 3:
+            continue
+        rel = parts[-1]
+        if is_no_count_rel(rel):
+            continue
+        changed.add(rel)
+        try:
+            add = 0 if parts[0] == "-" else int(parts[0])
+            dele = 0 if parts[1] == "-" else int(parts[1])
+        except Exception:
+            add = dele = 0
+        lines += add + dele
+    out = git("status", "--porcelain=v1", "-z", "--untracked-files=all")
+    for b in out.split(b"\0"):
+        if not b or not b.startswith(b"?? "):
+            continue
+        rel = b[3:].decode("utf-8", "replace")
+        if is_no_count_rel(rel):
+            continue
+        changed.add(rel)
+        lines += line_count_file(os.path.join(repo, rel))
+    return lines, changed
+
+try:
+    cur_lines, changed_files = current_usage()
+except Exception:
+    sys.exit(0)
+
+
+def write_log(reason, lines_used, files_used):
+    try:
+        log_dir = os.path.join(repo, ".claude", "maestro")
+        os.makedirs(log_dir, exist_ok=True)
+        rec = {
+            "ts": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
+            "hook": HOOK,
+            "target": target,
+            "lines_used": lines_used,
+            "files_used": files_used,
+            "reason": reason,
+        }
+        with open(os.path.join(log_dir, "guard-log.jsonl"), "a", encoding="utf-8") as f:
+            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
+    except Exception:
+        pass
+
+if target and is_protected(target):
+    write_log("protected", cur_lines, len(changed_files))
+    sys.stderr.write("BLOCKED: protected path. Size does not matter on protected paths; run maestro for this task.\n")
+    sys.exit(2)
+
+
+def count_text(s):
+    if not isinstance(s, str) or s == "":
+        return 0
+    return len(s.splitlines())
+
+
+def projected_lines(data):
+    ti = data.get("tool_input") or {}
+    if isinstance(ti.get("content"), str):
+        return count_text(ti.get("content"))
+    total = count_text(ti.get("old_string")) + count_text(ti.get("new_string"))
+    edits = ti.get("edits")
+    if isinstance(edits, list):
+        for e in edits:
+            if isinstance(e, dict):
+                total += count_text(e.get("old_string")) + count_text(e.get("new_string"))
+    return total
+
+proj_lines = projected_lines(payload)
+target_rel = rel_for(target) if target else ""
+proj_files = 0 if (target_rel and target_rel in changed_files) else (1 if target else 0)
+used_lines = cur_lines + proj_lines
+used_files = len(changed_files) + proj_files
 
-Drive the change through the maestro MCP tool instead —
-maestro({task, cwd, verifyCommand?}) → approve Gate 1 → approve Gate 2, and the developer
-crew makes the change through the gated dev→test→review loop.
+if used_lines > max_lines or used_files > max_files:
+    write_log("budget", used_lines, used_files)
+    sys.stderr.write(
+        f"BLOCKED: direct-edit budget exhausted (lines {used_lines}/{max_lines}, files {used_files}/{max_files}).\n"
+        "Run maestro for the REMAINDER of this task; never split a task to stay under the limit.\n"
+    )
+    sys.exit(2)
 
-Scratch/recon work? Write benchmark or temp files to /tmp or $TMPDIR — those are allowed.
-Production code inside the repo? Run maestro.
-(Wrong repo / small tweak? Disengage with `echo 1 > .claude/maestro-direct`.)
-MSG
-exit 2
+sys.exit(0)
+PY
+_budget_exit=$?
+set -e
+exit "$_budget_exit"
diff --git a/hooks/test/guard_scratch_test.sh b/hooks/test/guard_scratch_test.sh
index d1de070..5fbd968 100755
--- a/hooks/test/guard_scratch_test.sh
+++ b/hooks/test/guard_scratch_test.sh
@@ -4,21 +4,24 @@
 # Must print all-pass and exit 0 on a correct implementation.
 set -euo pipefail
 
-HARNESS_DIR="/Users/a1241968/Desktop/Oscar/my-claude-harness"
+HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
 EDIT_GUARD="$HARNESS_DIR/hooks/guard-block-main-edits.sh"
 BASH_GUARD="$HARNESS_DIR/hooks/guard-block-main-bash.sh"
 
 PASS=0
 FAIL=0
+TMP_ROOT="$(mktemp -d)"
+trap 'rm -rf "$TMP_ROOT"' EXIT
 
-run_hook() {
+run_hook_proj() {
   local hook="$1"
   local payload="$2"
   local expected_exit="$3"
   local label="$4"
+  local proj_dir="$5"
 
-  actual_exit=0
-  printf '%s' "$payload" | "$hook" >/dev/null 2>&1 || actual_exit=$?
+  local actual_exit=0
+  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$proj_dir" "$hook" >/dev/null 2>&1 || actual_exit=$?
 
   if [ "$actual_exit" -eq "$expected_exit" ]; then
     echo "  PASS [$label] (exit $actual_exit)"
@@ -29,428 +32,499 @@ run_hook() {
   fi
 }
 
-# Like run_hook but sets CLAUDE_PROJECT_DIR so the guard's repo-root is known.
-# Used for maestro carve-out ALLOW tests where the tested path must be inside a
-# specific repo root (not necessarily $PWD at test-run time).
-run_hook_proj() {
+run_hook_capture_proj() {
   local hook="$1"
   local payload="$2"
   local expected_exit="$3"
   local label="$4"
   local proj_dir="$5"
+  local outfile="$6"
 
-  actual_exit=0
-  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$proj_dir" "$hook" >/dev/null 2>&1 || actual_exit=$?
+  local actual_exit=0
+  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$proj_dir" "$hook" >"$outfile" 2>&1 || actual_exit=$?
 
   if [ "$actual_exit" -eq "$expected_exit" ]; then
     echo "  PASS [$label] (exit $actual_exit)"
     PASS=$((PASS + 1))
   else
     echo "  FAIL [$label] expected exit $expected_exit got $actual_exit"
+    cat "$outfile" | sed 's/^/    stderr: /'
     FAIL=$((FAIL + 1))
   fi
 }
 
-# ---------------------------------------------------------------------------
-# Helpers to build JSON payloads.
-# ---------------------------------------------------------------------------
-edit_payload() {
-  local file_path="$1"
-  local agent_id="${2:-}"
-  if [ -n "$agent_id" ]; then
-    printf '{"agent_id":"%s","tool_input":{"file_path":"%s"}}' "$agent_id" "$file_path"
+assert_file_jq() {
+  local file="$1"
+  local jq_expr="$2"
+  local label="$3"
+  if [ -f "$file" ] && jq -e "$jq_expr" "$file" >/dev/null 2>&1; then
+    echo "  PASS [$label]"
+    PASS=$((PASS + 1))
   else
-    printf '{"tool_input":{"file_path":"%s"}}' "$file_path"
+    echo "  FAIL [$label]"
+    [ -f "$file" ] && cat "$file" | sed 's/^/    log: /'
+    FAIL=$((FAIL + 1))
   fi
 }
 
-bash_payload() {
-  local command="$1"
+make_repo() {
+  local name="$1"
+  local budget="${2:-}"
+  local repo="$TMP_ROOT/$name"
+  mkdir -p "$repo/src" "$repo/hooks" "$repo/skills/.claude" "$repo/.claude/maestroX" "$repo/skills/maestro" "$repo/docs"
+  printf 'const base = 1;\n' > "$repo/src/app.ts"
+  printf 'const other = 2;\n' > "$repo/src/other.ts"
+  printf 'echo guard\n' > "$repo/hooks/guard-block-main-bash.sh"
+  printf 'evil\n' > "$repo/skills/.claude/maestro-evil.ts"
+  printf 'x\n' > "$repo/.claude/maestroX/anything.ts"
+  printf '# skill\n' > "$repo/skills/maestro/SKILL.md"
+  printf '# docs\n' > "$repo/docs/readme.md"
+  if [ -n "$budget" ]; then
+    mkdir -p "$repo/.claude"
+    printf '%s\n' "$budget" > "$repo/.claude/maestro-budget"
+  fi
+  git -C "$repo" init -q
+  git -C "$repo" config user.email test@example.com
+  git -C "$repo" config user.name test
+  git -C "$repo" add .
+  git -C "$repo" commit -qm init
+  printf '%s' "$repo"
+}
+
+edit_payload() {
+  local file_path="$1"
   local agent_id="${2:-}"
   if [ -n "$agent_id" ]; then
-    printf '{"agent_id":"%s","tool_input":{"command":"%s"}}' "$agent_id" "$command"
+    jq -n --arg p "$file_path" --arg aid "$agent_id" '{agent_id:$aid,tool_input:{file_path:$p}}'
   else
-    printf '{"tool_input":{"command":"%s"}}' "$command"
+    jq -n --arg p "$file_path" '{tool_input:{file_path:$p}}'
   fi
 }
 
-# For multi-line bash commands we use jq to safely encode the JSON.
-bash_payload_multiline() {
+edit_payload_content() {
+  local file_path="$1"
+  local content="$2"
+  jq -n --arg p "$file_path" --arg c "$content" '{tool_input:{file_path:$p,content:$c}}'
+}
+
+edit_payload_replace() {
+  local file_path="$1"
+  local old="$2"
+  local new="$3"
+  jq -n --arg p "$file_path" --arg o "$old" --arg n "$new" '{tool_input:{file_path:$p,old_string:$o,new_string:$n}}'
+}
+
+bash_payload() {
   local command="$1"
   local agent_id="${2:-}"
   if [ -n "$agent_id" ]; then
-    jq -n --arg cmd "$command" --arg aid "$agent_id" \
-      '{"agent_id":$aid,"tool_input":{"command":$cmd}}'
+    jq -n --arg cmd "$command" --arg aid "$agent_id" '{agent_id:$aid,tool_input:{command:$cmd}}'
   else
-    jq -n --arg cmd "$command" \
-      '{"tool_input":{"command":$cmd}}'
+    jq -n --arg cmd "$command" '{tool_input:{command:$cmd}}'
   fi
 }
 
+BASE_REPO="$(make_repo base)"
+STRICT_REPO="$(make_repo strict 'LINES=50
+FILES=2
+PROTECTED=src/**:hooks/**:skills/.claude/**:.claude/maestroX/**')"
+
 # ---------------------------------------------------------------------------
-echo "=== edit-guard tests ==="
+echo "=== edit-guard carve-out and protected-path tests ==="
 
-# /tmp path → ALLOW (exit 0)
-run_hook "$EDIT_GUARD" \
+run_hook_proj "$EDIT_GUARD" \
   "$(edit_payload '/tmp/bench.mjs')" \
   0 \
-  "Write /tmp/bench.mjs (no agent_id) → ALLOW"
+  "Write /tmp/bench.mjs (no agent_id) → ALLOW" \
+  "$BASE_REPO"
 
-# $TMPDIR-style path → ALLOW (exit 0)
 _tmpdir="${TMPDIR:-/tmp}"
 _tmpdir="${_tmpdir%/}"
-run_hook "$EDIT_GUARD" \
+run_hook_proj "$EDIT_GUARD" \
   "$(edit_payload "${_tmpdir}/scratch/foo.ts")" \
   0 \
-  "Write \$TMPDIR/scratch/foo.ts → ALLOW"
+  "Write \$TMPDIR/scratch/foo.ts → ALLOW" \
+  "$BASE_REPO"
 
-# /private/tmp path → ALLOW (exit 0)
-run_hook "$EDIT_GUARD" \
+run_hook_proj "$EDIT_GUARD" \
   "$(edit_payload '/private/tmp/recon.json')" \
   0 \
-  "Write /private/tmp/recon.json → ALLOW"
+  "Write /private/tmp/recon.json → ALLOW" \
+  "$BASE_REPO"
 
-# /var/folders path → ALLOW (exit 0)
-run_hook "$EDIT_GUARD" \
+run_hook_proj "$EDIT_GUARD" \
   "$(edit_payload '/var/folders/ab/cd1234/T/scratch.sh')" \
   0 \
-  "Write /var/folders/... → ALLOW"
+  "Write /var/folders/... → ALLOW" \
+  "$BASE_REPO"
+
+run_hook_proj "$EDIT_GUARD" \
+  "$(edit_payload_content "$BASE_REPO/src/app.ts" 'small')" \
+  0 \
+  "Under-budget edit to repo file → ALLOW" \
+  "$BASE_REPO"
+
+run_hook_proj "$EDIT_GUARD" \
+  "$(edit_payload_content 'src/app.ts' 'small')" \
+  0 \
+  "Under-budget relative-path edit to repo file → ALLOW" \
+  "$BASE_REPO"
 
-# Repo file → BLOCK (exit 2)
-run_hook "$EDIT_GUARD" \
-  "$(edit_payload "$HARNESS_DIR/src/app.ts")" \
+run_hook_proj "$EDIT_GUARD" \
+  "$(edit_payload_content "$STRICT_REPO/src/app.ts" 'small')" \
   2 \
-  "Write <repo>/src/app.ts → BLOCK"
+  "Protected repo file → BLOCK" \
+  "$STRICT_REPO"
 
-# Subagent writing repo file → ALLOW (exit 0)
-run_hook "$EDIT_GUARD" \
-  "$(edit_payload "$HARNESS_DIR/src/app.ts" "developer-agent-001")" \
+run_hook_proj "$EDIT_GUARD" \
+  "$(edit_payload "$STRICT_REPO/src/app.ts" "developer-agent-001")" \
   0 \
-  "Subagent Write repo file → ALLOW"
+  "Subagent Write repo file → ALLOW" \
+  "$STRICT_REPO"
 
-# .claude/maestro.json → ALLOW (exit 0).
-# Use run_hook_proj so the guard's repo root matches HARNESS_DIR (otherwise proj=$PWD
-# and the canonical allowed paths would be in a different repo).
 run_hook_proj "$EDIT_GUARD" \
-  "$(edit_payload "$HARNESS_DIR/.claude/maestro.json")" \
+  "$(edit_payload "$STRICT_REPO/.claude/maestro.json")" \
   0 \
   ".claude/maestro.json harness state → ALLOW" \
-  "$HARNESS_DIR"
+  "$STRICT_REPO"
 
-# .claude/maestro/slug/state.json (genuine ledger entry) → ALLOW (exit 0)
 run_hook_proj "$EDIT_GUARD" \
-  "$(edit_payload "$HARNESS_DIR/.claude/maestro/some-plan-slug/state.json")" \
+  "$(edit_payload "$STRICT_REPO/.claude/maestro/some-plan-slug/state.json")" \
   0 \
   ".claude/maestro/<slug>/state.json genuine ledger → ALLOW" \
-  "$HARNESS_DIR"
+  "$STRICT_REPO"
+
+run_hook_proj "$EDIT_GUARD" \
+  "$(edit_payload "$BASE_REPO/docs/readme.md")" \
+  0 \
+  "Prose/docs direct edit → ALLOW" \
+  "$BASE_REPO"
 
 # ---------------------------------------------------------------------------
 echo ""
 echo "=== maestro carve-out anchoring tests (edit-guard) ==="
 
-# Traversal through .claude/maestro/ to a production file → BLOCK (exit 2)
-run_hook "$EDIT_GUARD" \
-  "$(edit_payload "$HARNESS_DIR/.claude/maestro/../../hooks/guard-block-main-bash.sh")" \
+run_hook_proj "$EDIT_GUARD" \
+  "$(edit_payload "$STRICT_REPO/.claude/maestro/../../hooks/guard-block-main-bash.sh")" \
   2 \
-  ".claude/maestro/../../hooks/guard-block-main-bash.sh traversal → BLOCK"
+  ".claude/maestro/../../hooks/guard-block-main-bash.sh traversal → BLOCK" \
+  "$STRICT_REPO"
 
-# Path containing maestro substring in unrelated location → BLOCK (exit 2)
-run_hook "$EDIT_GUARD" \
-  "$(edit_payload "$HARNESS_DIR/skills/.claude/maestro-evil.ts")" \
+run_hook_proj "$EDIT_GUARD" \
+  "$(edit_payload "$STRICT_REPO/skills/.claude/maestro-evil.ts")" \
   2 \
-  "skills/.claude/maestro-evil.ts unanchored substring → BLOCK"
+  "skills/.claude/maestro-evil.ts unanchored substring → BLOCK" \
+  "$STRICT_REPO"
 
-# maestroX directory (not the maestro ledger dir) → BLOCK (exit 2)
-run_hook "$EDIT_GUARD" \
-  "$(edit_payload "$HARNESS_DIR/.claude/maestroX/anything.ts")" \
+run_hook_proj "$EDIT_GUARD" \
+  "$(edit_payload "$STRICT_REPO/.claude/maestroX/anything.ts")" \
   2 \
-  ".claude/maestroX/anything.ts (unanchored suffix) → BLOCK"
+  ".claude/maestroX/anything.ts (unanchored suffix) → BLOCK" \
+  "$STRICT_REPO"
 
 # ---------------------------------------------------------------------------
 echo ""
-echo "=== bash-guard tests ==="
+echo "=== bash-guard carve-out, read-only, and protected-path tests ==="
 
-# cat > /tmp/b.mjs <<'EOF'\nconst x = a > Number(b);\nEOF → ALLOW
-# The heredoc body contains > which must NOT be scanned as a redirect.
 HEREDOC_CMD="$(printf "cat > /tmp/b.mjs <<'EOF'\nconst x = a > Number(b);\nfs.writeFileSync('/tmp/out.txt', x);\nEOF")"
-printf '%s' "$(bash_payload_multiline "$HEREDOC_CMD")" | \
-  "$BASH_GUARD" >/dev/null 2>&1 && HC_EXIT=0 || HC_EXIT=$?
-if [ "$HC_EXIT" -eq 0 ]; then
-  echo "  PASS [heredoc with > in body → ALLOW] (exit $HC_EXIT)"
-  PASS=$((PASS + 1))
-else
-  echo "  FAIL [heredoc with > in body → ALLOW] expected exit 0 got $HC_EXIT"
-  FAIL=$((FAIL + 1))
-fi
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "$HEREDOC_CMD")" \
+  0 \
+  "heredoc with > in body → ALLOW" \
+  "$BASE_REPO"
 
-# plain redirect to /tmp → ALLOW (exit 0)
-run_hook "$BASH_GUARD" \
+run_hook_proj "$BASH_GUARD" \
   "$(bash_payload 'echo hi > /tmp/x')" \
   0 \
-  "echo hi > /tmp/x → ALLOW"
+  "echo hi > /tmp/x → ALLOW" \
+  "$BASE_REPO"
+
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "echo hi > $BASE_REPO/src/app.ts")" \
+  0 \
+  "Under-budget echo hi > repo file → ALLOW" \
+  "$BASE_REPO"
 
-# redirect to repo file → BLOCK (exit 2)
-run_hook "$BASH_GUARD" \
-  "$(bash_payload "echo hi > $HARNESS_DIR/src/app.ts")" \
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "echo hi > $STRICT_REPO/src/app.ts")" \
   2 \
-  "echo hi > <repo>/src/app.ts → BLOCK"
+  "Protected echo hi > repo file → BLOCK" \
+  "$STRICT_REPO"
 
-# grep with > in pattern (quoted) → ALLOW (exit 0)
-run_hook "$BASH_GUARD" \
-  "$(bash_payload 'grep \">\" file.txt')" \
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload 'echo hi > src/app.ts')" \
+  2 \
+  "Protected relative-path echo hi > repo file → BLOCK" \
+  "$STRICT_REPO"
+
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload 'grep ">" file.txt')" \
   0 \
-  'grep ">" file.txt → ALLOW'
+  'grep ">" file.txt → ALLOW' \
+  "$BASE_REPO"
 
-# subagent redirect to repo file → ALLOW (exit 0)
-run_hook "$BASH_GUARD" \
-  "$(bash_payload "echo hi > $HARNESS_DIR/src/app.ts" "developer-agent-001")" \
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "echo hi > $STRICT_REPO/src/app.ts" "developer-agent-001")" \
   0 \
-  "Subagent redirect to repo → ALLOW"
+  "Subagent redirect to repo → ALLOW" \
+  "$STRICT_REPO"
 
-# /dev/null redirect → ALLOW (exit 0)
-run_hook "$BASH_GUARD" \
+run_hook_proj "$BASH_GUARD" \
   "$(bash_payload 'some-command > /dev/null 2>&1')" \
   0 \
-  "redirect to /dev/null → ALLOW"
+  "redirect to /dev/null → ALLOW" \
+  "$BASE_REPO"
 
 # ---------------------------------------------------------------------------
 echo ""
 echo "=== maestro carve-out anchoring tests (bash-guard) ==="
 
-# Traversal through .claude/maestro/ to a production hook file → BLOCK (exit 2)
-run_hook "$BASH_GUARD" \
-  "$(bash_payload "echo evil > $HARNESS_DIR/.claude/maestro/../../hooks/guard-block-main-bash.sh")" \
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "echo evil > $STRICT_REPO/.claude/maestro/../../hooks/guard-block-main-bash.sh")" \
   2 \
-  "echo > .claude/maestro/../../hooks/guard-block-main-bash.sh traversal → BLOCK"
+  "echo > .claude/maestro/../../hooks/guard-block-main-bash.sh traversal → BLOCK" \
+  "$STRICT_REPO"
 
-# Path containing maestro substring in unrelated location → BLOCK (exit 2)
-run_hook "$BASH_GUARD" \
-  "$(bash_payload "echo evil > $HARNESS_DIR/skills/.claude/maestro-evil.ts")" \
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "echo evil > $STRICT_REPO/skills/.claude/maestro-evil.ts")" \
   2 \
-  "echo > skills/.claude/maestro-evil.ts unanchored substring → BLOCK"
+  "echo > skills/.claude/maestro-evil.ts unanchored substring → BLOCK" \
+  "$STRICT_REPO"
 
-# maestroX directory (not the maestro ledger dir) → BLOCK (exit 2)
-run_hook "$BASH_GUARD" \
-  "$(bash_payload "echo evil > $HARNESS_DIR/.claude/maestroX/anything.ts")" \
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "echo evil > $STRICT_REPO/.claude/maestroX/anything.ts")" \
   2 \
-  "echo > .claude/maestroX/anything.ts (unanchored suffix) → BLOCK"
+  "echo > .claude/maestroX/anything.ts (unanchored suffix) → BLOCK" \
+  "$STRICT_REPO"
 
-# Genuine maestro ledger write via redirect → ALLOW (exit 0).
-# Set CLAUDE_PROJECT_DIR so the bash guard's _proj resolves to HARNESS_DIR, making the
-# canonical allowed set match the path in the payload.
 run_hook_proj "$BASH_GUARD" \
-  "$(bash_payload "echo '{}' > $HARNESS_DIR/.claude/maestro/some-plan/state.json")" \
+  "$(bash_payload "echo '{}' > $STRICT_REPO/.claude/maestro/some-plan/state.json")" \
   0 \
   "echo > .claude/maestro/<slug>/state.json genuine ledger → ALLOW" \
-  "$HARNESS_DIR"
+  "$STRICT_REPO"
 
 # ---------------------------------------------------------------------------
 echo ""
-echo "=== path-traversal tests (edit-guard) ==="
+echo "=== path-traversal tests (canonicalize before prefix checks) ==="
 
-# /tmp/../../<repo>/file → must BLOCK (exit 2) — path escapes tmp via ..
-run_hook "$EDIT_GUARD" \
-  "$(edit_payload "/tmp/../../Users/a1241968/Desktop/Oscar/my-claude-harness/skills/maestro/SKILL.md")" \
+run_hook_proj "$EDIT_GUARD" \
+  "$(edit_payload "/tmp/../../$STRICT_REPO/src/app.ts")" \
   2 \
-  "/tmp/../../<repo>/file path traversal → BLOCK"
+  "/tmp/../../<repo>/src/app.ts path traversal → BLOCK" \
+  "$STRICT_REPO"
 
-# $TMPDIR/<enough ..>/<repo>/file → must BLOCK (exit 2).
-# We compute exactly how many ".." are needed to escape TMPDIR to the filesystem root,
-# then append the repo-relative path so the canonical result IS the repo file.
 _tmpdir_clean="${TMPDIR:-/tmp}"
 _tmpdir_clean="${_tmpdir_clean%/}"
-# Depth = number of path components in _tmpdir_clean (leading / gives one empty component).
 _depth=$(python3 -c "import sys; p=sys.argv[1].lstrip('/'); print(len([c for c in p.split('/') if c]))" "$_tmpdir_clean")
 _dots=$(python3 -c "print('/'.join(['..'] * int('$_depth')))")
-_traversal_path="${_tmpdir_clean}/${_dots}/Users/a1241968/Desktop/Oscar/my-claude-harness/skills/maestro/SKILL.md"
-run_hook "$EDIT_GUARD" \
+_traversal_path="${_tmpdir_clean}/${_dots}${STRICT_REPO}/src/app.ts"
+run_hook_proj "$EDIT_GUARD" \
   "$(edit_payload "$_traversal_path")" \
   2 \
-  "\$TMPDIR/<N-dots>/<repo>/file path traversal → BLOCK"
+  "\$TMPDIR/<N-dots>/<repo>/src/app.ts path traversal → BLOCK" \
+  "$STRICT_REPO"
 
-# ---------------------------------------------------------------------------
-echo ""
-echo "=== path-traversal tests (bash-guard) ==="
-
-# echo x > /tmp/../../<repo>/file → must BLOCK (exit 2)
-run_hook "$BASH_GUARD" \
-  "$(bash_payload "echo x > /tmp/../../Users/a1241968/Desktop/Oscar/my-claude-harness/skills/maestro/SKILL.md")" \
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "echo x > /tmp/../../$STRICT_REPO/src/app.ts")" \
   2 \
-  "echo x > /tmp/../../<repo>/file path traversal → BLOCK"
+  "echo x > /tmp/../../<repo>/src/app.ts path traversal → BLOCK" \
+  "$STRICT_REPO"
 
 # ---------------------------------------------------------------------------
 echo ""
 echo "=== heredoc-with-redirect tests (bash-guard) ==="
 
-# cat <<'EOF' > <repo>/src/app.ts — redirect AFTER marker must be preserved → BLOCK (exit 2)
-HEREDOC_REPO_CMD="$(printf "cat <<'EOF' > %s/src/app.ts\nhello\nEOF" "$HARNESS_DIR")"
-printf '%s' "$(bash_payload_multiline "$HEREDOC_REPO_CMD")" | \
-  "$BASH_GUARD" >/dev/null 2>&1 && HR_EXIT=0 || HR_EXIT=$?
-if [ "$HR_EXIT" -eq 2 ]; then
-  echo "  PASS [cat <<'EOF' > <repo>/src/app.ts → BLOCK] (exit $HR_EXIT)"
-  PASS=$((PASS + 1))
-else
-  echo "  FAIL [cat <<'EOF' > <repo>/src/app.ts → BLOCK] expected exit 2 got $HR_EXIT"
-  FAIL=$((FAIL + 1))
-fi
+HEREDOC_REPO_CMD="$(printf "cat <<'EOF' > %s/src/app.ts\nhello\nEOF" "$STRICT_REPO")"
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "$HEREDOC_REPO_CMD")" \
+  2 \
+  "cat <<'EOF' > <repo>/src/app.ts → BLOCK" \
+  "$STRICT_REPO"
 
-# cat <<'EOF' | tee <repo>/src/app.ts — pipe+tee AFTER marker must be preserved → BLOCK (exit 2)
-HEREDOC_TEE_CMD="$(printf "cat <<'EOF' | tee %s/src/app.ts\nhello\nEOF" "$HARNESS_DIR")"
-printf '%s' "$(bash_payload_multiline "$HEREDOC_TEE_CMD")" | \
-  "$BASH_GUARD" >/dev/null 2>&1 && HT_EXIT=0 || HT_EXIT=$?
-if [ "$HT_EXIT" -eq 2 ]; then
-  echo "  PASS [cat <<'EOF' | tee <repo>/src/app.ts → BLOCK] (exit $HT_EXIT)"
-  PASS=$((PASS + 1))
-else
-  echo "  FAIL [cat <<'EOF' | tee <repo>/src/app.ts → BLOCK] expected exit 2 got $HT_EXIT"
-  FAIL=$((FAIL + 1))
-fi
+HEREDOC_TEE_CMD="$(printf "cat <<'EOF' | tee %s/src/app.ts\nhello\nEOF" "$STRICT_REPO")"
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "$HEREDOC_TEE_CMD")" \
+  2 \
+  "cat <<'EOF' | tee <repo>/src/app.ts → BLOCK" \
+  "$STRICT_REPO"
 
-# cat <<'EOF' > /tmp/safe.txt — redirect to tmp must still ALLOW (exit 0)
 HEREDOC_TMP_CMD="$(printf "cat <<'EOF' > /tmp/safe.txt\nhello\nEOF")"
-printf '%s' "$(bash_payload_multiline "$HEREDOC_TMP_CMD")" | \
-  "$BASH_GUARD" >/dev/null 2>&1 && HTMP_EXIT=0 || HTMP_EXIT=$?
-if [ "$HTMP_EXIT" -eq 0 ]; then
-  echo "  PASS [cat <<'EOF' > /tmp/safe.txt → ALLOW] (exit $HTMP_EXIT)"
-  PASS=$((PASS + 1))
-else
-  echo "  FAIL [cat <<'EOF' > /tmp/safe.txt → ALLOW] expected exit 0 got $HTMP_EXIT"
-  FAIL=$((FAIL + 1))
-fi
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "$HEREDOC_TMP_CMD")" \
+  0 \
+  "cat <<'EOF' > /tmp/safe.txt → ALLOW" \
+  "$BASE_REPO"
 
 # ---------------------------------------------------------------------------
 echo ""
 echo "=== nested bash -c heredoc tests (bash-guard) ==="
 
-# bash -c "cat <<'EOF' > <repo>/src/app.ts\n...\nEOF" → heredoc inside bash -c must BLOCK (exit 2)
-NESTED_BASH_CMD="$(printf "bash -c \"cat <<'EOF' > %s/src/app.ts\nmalicious\nEOF\"" "$HARNESS_DIR")"
-printf '%s' "$(bash_payload_multiline "$NESTED_BASH_CMD")" | \
-  "$BASH_GUARD" >/dev/null 2>&1 && NB_EXIT=0 || NB_EXIT=$?
-if [ "$NB_EXIT" -eq 2 ]; then
-  echo "  PASS [bash -c \"cat <<'EOF' > <repo>/src/app.ts → BLOCK\"] (exit $NB_EXIT)"
-  PASS=$((PASS + 1))
-else
-  echo "  FAIL [bash -c \"cat <<'EOF' > <repo>/src/app.ts → BLOCK\"] expected exit 2 got $NB_EXIT"
-  FAIL=$((FAIL + 1))
-fi
+NESTED_BASH_CMD="$(printf "bash -c \"cat <<'EOF' > %s/src/app.ts\nmalicious\nEOF\"" "$STRICT_REPO")"
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "$NESTED_BASH_CMD")" \
+  2 \
+  "bash -c heredoc > repo → BLOCK" \
+  "$STRICT_REPO"
 
-# sh -c "cat <<'EOF' > <repo>/skills/maestro/SKILL.md\n...\nEOF" → BLOCK (exit 2)
-NESTED_SH_CMD="$(printf "sh -c \"cat <<'EOF' > %s/skills/maestro/SKILL.md\nmalicious\nEOF\"" "$HARNESS_DIR")"
-printf '%s' "$(bash_payload_multiline "$NESTED_SH_CMD")" | \
-  "$BASH_GUARD" >/dev/null 2>&1 && NS_EXIT=0 || NS_EXIT=$?
-if [ "$NS_EXIT" -eq 2 ]; then
-  echo "  PASS [sh -c \"cat <<'EOF' > <repo>/SKILL.md → BLOCK\"] (exit $NS_EXIT)"
-  PASS=$((PASS + 1))
-else
-  echo "  FAIL [sh -c \"cat <<'EOF' > <repo>/SKILL.md → BLOCK\"] expected exit 2 got $NS_EXIT"
-  FAIL=$((FAIL + 1))
-fi
+NESTED_SH_CMD="$(printf "sh -c \"cat <<'EOF' > %s/src/app.ts\nmalicious\nEOF\"" "$STRICT_REPO")"
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "$NESTED_SH_CMD")" \
+  2 \
+  "sh -c heredoc > repo → BLOCK" \
+  "$STRICT_REPO"
 
-# bash -c "cat <<'EOF' > /tmp/safe.txt\n...\nEOF" → redirect inside bash -c to tmp must ALLOW (exit 0)
 NESTED_TMP_CMD="$(printf "bash -c \"cat <<'EOF' > /tmp/safe.txt\nhello\nEOF\"")"
-printf '%s' "$(bash_payload_multiline "$NESTED_TMP_CMD")" | \
-  "$BASH_GUARD" >/dev/null 2>&1 && NT_EXIT=0 || NT_EXIT=$?
-if [ "$NT_EXIT" -eq 0 ]; then
-  echo "  PASS [bash -c \"cat <<'EOF' > /tmp/safe.txt → ALLOW\"] (exit $NT_EXIT)"
-  PASS=$((PASS + 1))
-else
-  echo "  FAIL [bash -c \"cat <<'EOF' > /tmp/safe.txt → ALLOW\"] expected exit 0 got $NT_EXIT"
-  FAIL=$((FAIL + 1))
-fi
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "$NESTED_TMP_CMD")" \
+  0 \
+  "bash -c heredoc > /tmp/safe.txt → ALLOW" \
+  "$BASE_REPO"
 
 # ---------------------------------------------------------------------------
 echo ""
-echo "=== escaped-quote heredoc terminator tests (bash-guard) ==="
-
-# bash -c "cat <<'EOF' > <repo>/src/app.ts\nmal\nEOF\"" → escaped-quote terminator must BLOCK (exit 2)
-# The closing line is EOF\" — a backslash-escaped quote follows the delimiter.
-EQ_CMD="$(printf 'bash -c "cat <<'"'"'EOF'"'"' > %s/src/app.ts\nmal\nEOF\""' "$HARNESS_DIR")"
-printf '%s' "$(bash_payload_multiline "$EQ_CMD")" | \
-  "$BASH_GUARD" >/dev/null 2>&1 && EQ_EXIT=0 || EQ_EXIT=$?
-if [ "$EQ_EXIT" -eq 2 ]; then
-  echo "  PASS [bash -c with escaped-quote heredoc terminator EOF\\\" > repo → BLOCK] (exit $EQ_EXIT)"
-  PASS=$((PASS + 1))
-else
-  echo "  FAIL [bash -c with escaped-quote heredoc terminator EOF\\\" > repo → BLOCK] expected exit 2 got $EQ_EXIT"
-  FAIL=$((FAIL + 1))
-fi
+echo "=== escaped-quote and unparseable coverage tests (bash-guard) ==="
 
-# Double-nested bash -c with escaped heredoc terminator → BLOCK (exit 2)
-# bash -c "bash -c \"cat <<'EOF' > <repo>/src/app.ts\nmal\nEOF\"\""
-DN_CMD="$(printf 'bash -c "bash -c \\"cat <<'"'"'EOF'"'"' > %s/src/app.ts\nmal\nEOF\\""' "$HARNESS_DIR")"
-printf '%s' "$(bash_payload_multiline "$DN_CMD")" | \
-  "$BASH_GUARD" >/dev/null 2>&1 && DN_EXIT=0 || DN_EXIT=$?
-if [ "$DN_EXIT" -eq 2 ]; then
-  echo "  PASS [double-nested bash -c heredoc > repo → BLOCK] (exit $DN_EXIT)"
-  PASS=$((PASS + 1))
-else
-  echo "  FAIL [double-nested bash -c heredoc > repo → BLOCK] expected exit 2 got $DN_EXIT"
-  FAIL=$((FAIL + 1))
-fi
+EQ_CMD="$(printf 'bash -c "cat <<'"'"'EOF'"'"' > %s/src/app.ts\nmal\nEOF\\\""' "$STRICT_REPO")"
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "$EQ_CMD")" \
+  2 \
+  "bash -c with escaped-quote heredoc terminator EOF\\\" > repo → BLOCK" \
+  "$STRICT_REPO"
 
-# Genuinely-unparseable mutating command → BLOCK (exit 2)
-# Dangling open-quote hides a redirect: tokenize raises ValueError; raw coarse_reason detects it.
-UNPARSE_CMD="echo 'unclosed redirect > ${HARNESS_DIR}/src/app.ts"
-printf '%s' "$(bash_payload_multiline "$UNPARSE_CMD")" | \
-  "$BASH_GUARD" >/dev/null 2>&1 && UP_EXIT=0 || UP_EXIT=$?
-if [ "$UP_EXIT" -eq 2 ]; then
-  echo "  PASS [unparseable command with mutation evidence → BLOCK] (exit $UP_EXIT)"
-  PASS=$((PASS + 1))
-else
-  echo "  FAIL [unparseable command with mutation evidence → BLOCK] expected exit 2 got $UP_EXIT"
-  FAIL=$((FAIL + 1))
-fi
+DN_CMD="$(printf 'bash -c "bash -c \\"cat <<'"'"'EOF'"'"' > %s/src/app.ts\nmal\nEOF\\""' "$STRICT_REPO")"
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "$DN_CMD")" \
+  2 \
+  "double-nested bash -c heredoc > repo → BLOCK" \
+  "$STRICT_REPO"
+
+OVER_REPO="$(make_repo unparse-over 'LINES=0
+FILES=2')"
+printf 'changed\n' >> "$OVER_REPO/src/app.ts"
+UNPARSE_CMD="echo 'unclosed redirect > ${OVER_REPO}/src/app.ts"
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "$UNPARSE_CMD")" \
+  2 \
+  "unparseable command with mutation evidence over budget → BLOCK" \
+  "$OVER_REPO"
+
+UNPARSE_CLOBBER="echo 'unclosed >| ${OVER_REPO}/src/app.ts"
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "$UNPARSE_CLOBBER")" \
+  2 \
+  "unparseable >| over budget → BLOCK" \
+  "$OVER_REPO"
+
+UNPARSE_AMPGT="echo 'unclosed &> ${OVER_REPO}/src/app.ts"
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "$UNPARSE_AMPGT")" \
+  2 \
+  "unparseable &> over budget → BLOCK" \
+  "$OVER_REPO"
+
+UNPARSE_FD="echo 'unclosed 1> ${OVER_REPO}/src/app.ts"
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "$UNPARSE_FD")" \
+  2 \
+  "unparseable 1> over budget → BLOCK" \
+  "$OVER_REPO"
+
+UNPARSE_FDUP="some-read-only-cmd 'unclosed 2>&1"
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "$UNPARSE_FDUP")" \
+  0 \
+  "unparseable fd-dup 2>&1 only → ALLOW" \
+  "$BASE_REPO"
 
 # ---------------------------------------------------------------------------
 echo ""
-echo "=== unparseable redirect-operator coverage tests (bash-guard) ==="
-# These commands have a dangling open-quote so shlex raises ValueError;
-# the fail-closed path (coarse_reason on raw command) must catch them.
-
-# >| to repo path → BLOCK (exit 2)
-UNPARSE_CLOBBER="echo 'unclosed >| ${HARNESS_DIR}/skills/maestro/SKILL.md"
-printf '%s' "$(bash_payload_multiline "$UNPARSE_CLOBBER")" | \
-  "$BASH_GUARD" >/dev/null 2>&1 && UC_EXIT=0 || UC_EXIT=$?
-if [ "$UC_EXIT" -eq 2 ]; then
-  echo "  PASS [unparseable >| to repo path → BLOCK] (exit $UC_EXIT)"
-  PASS=$((PASS + 1))
-else
-  echo "  FAIL [unparseable >| to repo path → BLOCK] expected exit 2 got $UC_EXIT"
-  FAIL=$((FAIL + 1))
-fi
+echo "=== budget/config/log tests ==="
+
+CREEP_REPO="$(make_repo creep 'LINES=3
+FILES=2')"
+printf 'one\ntwo\n' >> "$CREEP_REPO/src/app.ts"
+run_hook_capture_proj "$EDIT_GUARD" \
+  "$(edit_payload_replace "$CREEP_REPO/src/other.ts" 'old' 'new1
+new2')" \
+  2 \
+  "Cumulative creep crosses line budget → BLOCK" \
+  "$CREEP_REPO" "$TMP_ROOT/creep.out"
+grep -q 'REMAINDER of this task' "$TMP_ROOT/creep.out" && echo "  PASS [budget block message is model re-prompt]" && PASS=$((PASS + 1)) || { echo "  FAIL [budget block message is model re-prompt]"; FAIL=$((FAIL + 1)); }
 
-# &> to repo path → BLOCK (exit 2)
-UNPARSE_AMPGT="echo 'unclosed &> ${HARNESS_DIR}/skills/maestro/SKILL.md"
-printf '%s' "$(bash_payload_multiline "$UNPARSE_AMPGT")" | \
-  "$BASH_GUARD" >/dev/null 2>&1 && AG_EXIT=0 || AG_EXIT=$?
-if [ "$AG_EXIT" -eq 2 ]; then
-  echo "  PASS [unparseable &> to repo path → BLOCK] (exit $AG_EXIT)"
-  PASS=$((PASS + 1))
-else
-  echo "  FAIL [unparseable &> to repo path → BLOCK] expected exit 2 got $AG_EXIT"
-  FAIL=$((FAIL + 1))
-fi
+OVERSIZE_REPO="$(make_repo oversize 'LINES=2
+FILES=2')"
+run_hook_proj "$EDIT_GUARD" \
+  "$(edit_payload_content "$OVERSIZE_REPO/src/app.ts" 'a
+b
+c')" \
+  2 \
+  "Single oversized edit blocked via projection → BLOCK" \
+  "$OVERSIZE_REPO"
 
-# 1> (fd-numbered) to repo path → BLOCK (exit 2)
-UNPARSE_FD="echo 'unclosed 1> ${HARNESS_DIR}/skills/maestro/SKILL.md"
-printf '%s' "$(bash_payload_multiline "$UNPARSE_FD")" | \
-  "$BASH_GUARD" >/dev/null 2>&1 && FD_EXIT=0 || FD_EXIT=$?
-if [ "$FD_EXIT" -eq 2 ]; then
-  echo "  PASS [unparseable 1> to repo path → BLOCK] (exit $FD_EXIT)"
-  PASS=$((PASS + 1))
-else
-  echo "  FAIL [unparseable 1> to repo path → BLOCK] expected exit 2 got $FD_EXIT"
-  FAIL=$((FAIL + 1))
-fi
+UNTRACKED_REPO="$(make_repo untracked 'LINES=2
+FILES=3')"
+printf 'a\nb\nc\n' > "$UNTRACKED_REPO/src/new-file.ts"
+run_hook_proj "$EDIT_GUARD" \
+  "$(edit_payload_replace "$UNTRACKED_REPO/src/app.ts" '' '')" \
+  2 \
+  "Untracked new file counted toward budget → BLOCK" \
+  "$UNTRACKED_REPO"
 
-# 2>&1 (fd-dup) in an otherwise read-only unparseable command → ALLOW (exit 0).
-# coarse_reason's fd-dup exclusion (target starts with '&') prevents this from being
-# classified as a file-writing redirect, so the hook must exit 0.
-UNPARSE_FDUP="some-read-only-cmd 'unclosed 2>&1"
-run_hook "$BASH_GUARD" \
-  "$(bash_payload_multiline "$UNPARSE_FDUP")" \
+CUSTOM_ALLOW_REPO="$(make_repo custom-allow 'LINES=4
+FILES=1')"
+run_hook_proj "$EDIT_GUARD" \
+  "$(edit_payload_content "$CUSTOM_ALLOW_REPO/src/app.ts" 'a
+b
+c
+d')" \
   0 \
-  "unparseable fd-dup 2>&1 only → ALLOW"
+  "Custom .claude/maestro-budget respected at equality → ALLOW" \
+  "$CUSTOM_ALLOW_REPO"
+
+CUSTOM_BLOCK_REPO="$(make_repo custom-block 'LINES=1
+FILES=1')"
+run_hook_proj "$EDIT_GUARD" \
+  "$(edit_payload_content "$CUSTOM_BLOCK_REPO/src/app.ts" 'a
+b')" \
+  2 \
+  "Custom .claude/maestro-budget lower line cap → BLOCK" \
+  "$CUSTOM_BLOCK_REPO"
+
+PROT_REPO="$(make_repo protected-zero 'LINES=50
+FILES=2
+PROTECTED=src/**')"
+run_hook_proj "$EDIT_GUARD" \
+  "$(edit_payload_content "$PROT_REPO/src/app.ts" 'x')" \
+  2 \
+  "Protected path blocked even at zero usage → BLOCK" \
+  "$PROT_REPO"
+assert_file_jq "$PROT_REPO/.claude/maestro/guard-log.jsonl" \
+  'select(.hook=="guard-block-main-edits" and .reason=="protected" and .lines_used==0 and .files_used==0)' \
+  "edit guard-log.jsonl line written on protected block"
+
+BASH_BUDGET_REPO="$(make_repo bash-budget 'LINES=0
+FILES=2')"
+printf 'changed\n' >> "$BASH_BUDGET_REPO/src/app.ts"
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "echo hi > $BASH_BUDGET_REPO/src/other.ts")" \
+  2 \
+  "Bash mutating command over current budget → BLOCK" \
+  "$BASH_BUDGET_REPO"
+assert_file_jq "$BASH_BUDGET_REPO/.claude/maestro/guard-log.jsonl" \
+  'select(.hook=="guard-block-main-bash" and .reason=="budget" and .lines_used>0)' \
+  "bash guard-log.jsonl line written on budget block"
+
+BASH_PROT_REPO="$(make_repo bash-protected 'LINES=50
+FILES=2
+PROTECTED=src/**')"
+run_hook_proj "$BASH_GUARD" \
+  "$(bash_payload "echo hi > $BASH_PROT_REPO/src/app.ts")" \
+  2 \
+  "Bash protected path blocked at zero usage → BLOCK" \
+  "$BASH_PROT_REPO"
+assert_file_jq "$BASH_PROT_REPO/.claude/maestro/guard-log.jsonl" \
+  'select(.hook=="guard-block-main-bash" and .reason=="protected" and .lines_used==0 and .files_used==0)' \
+  "bash guard-log.jsonl line written on protected block"
 
 # ---------------------------------------------------------------------------
 echo ""
diff --git a/skills/maestro/SKILL.md b/skills/maestro/SKILL.md
index 5a45b41..8e9a862 100644
--- a/skills/maestro/SKILL.md
+++ b/skills/maestro/SKILL.md
@@ -1,15 +1,15 @@
 ---
 name: maestro
-description: Gated implementation loop — scope → plan → [Gate 1] → implement → command gates → tester → fix↺ → pre-ship review → [Gate 2] → ship + release. Use for ANY task that changes code. The orchestrator (CTO) delegates to crew subagents and never edits production code itself.
+description: Gated implementation loop — scope → plan → [Gate 1] → implement → command gates → tester → fix↺ → pre-ship review → [Gate 2] → ship + release. Use when a change exceeds the direct-edit guard budget, touches protected paths, needs verification, or is not trivially obvious.
 ---
 
 # Maestro — the gated dev→test→review→ship harness
 
 You are the **CTO**. The human is the **founder**, operating at decision altitude (ideas, priorities,
 taste). You run engineering on their behalf and talk to them **only at decision points**. You drive a
-deterministic gated loop by delegating to crew subagents via the **Task tool**. You do **not** write
-production code yourself (the guard hook blocks it); you scope, delegate, run gates, synthesize, and
-relay the two human gates. Verify with real calls, never assumptions; cite `file:line` for code facts.
+deterministic gated loop by delegating to crew subagents via the **Task tool** whenever work exceeds the
+direct-edit budget, touches protected paths, needs verification, or is not trivially obvious. Verify
+with real calls, never assumptions; cite `file:line` for code facts.
 
 ## The loop
 
@@ -19,11 +19,13 @@ relay the two human gates. Verify with real calls, never assumptions; cite `file
 
 ## 0. Engagement (is maestro on for this repo?)
 
-Maestro is **ON by default**. If `.claude/maestro-direct` exists in the repo, the founder has put this
-repo in **direct-edit mode** — the guard is off and small tweaks may be hand-edited; do not force the
-loop. To toggle: disengage with `echo 1 > .claude/maestro-direct` (allowed by the guard), re-engage
-with `rm .claude/maestro-direct`. Use the loop for any non-trivial change; skip it only for trivial
-one-liners, pure questions, reading/explaining code, or recon. When in doubt, prefer the loop.
+Maestro is **ON by default**, but the main session may edit directly while the cumulative uncommitted
+change stays inside the guard budget (default ≤50 changed lines and ≤2 files) and the target is not a
+protected path. Use direct edit only when you can write the complete diff in your head; if verification
+requires running something, risk is unclear, a protected path is involved, or the guard trips, use
+maestro for the remainder and never split a task to stay under budget. `.claude/maestro-direct` puts the
+repo in **direct-edit mode** (guard off); disengage with `echo 1 > .claude/maestro-direct`, re-engage
+with `rm .claude/maestro-direct`.
 
 ## 1. Scope
 
@@ -204,8 +206,8 @@ implementers on opus unless the task genuinely needs it.
 
 ## Hard rules
 
-- You never Edit/Write production code or run mutating Bash on it — delegate. (Guard-enforced.) You
-  MAY write `.claude/maestro*` harness state.
+- You may Edit/Write or run mutating Bash directly only inside the guard budget and never on protected
+  paths; otherwise delegate. You MAY write `.claude/maestro*` harness state.
 - Command-gate exit code is ground truth; nothing overrides a non-zero into success.
 - Strict DoD gates commit; an inconclusive reviewer blocks ship; no force-ship bypass.
 - Both human gates (Gate 1 plan, Gate 2 ship) must be explicitly approved via AskUserQuestion.
