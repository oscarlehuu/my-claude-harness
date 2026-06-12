#!/usr/bin/env bash
# PreToolUse guard — budget-gate main-session edits.
#
# Crew subagents (which carry an agent_id) are allowed to edit. The main session
# may make small direct edits inside the deterministic per-repo budget; protected
# paths and over-budget changes route to maestro. Blocks even under
# --dangerously-skip-permissions (exit 2 ignores permission mode).
#
# Carve-outs that let the main session through:
#   1. Engagement OFF — `.claude/maestro-direct` exists in the repo → direct-edit mode.
#   2. Harness state — paths under `.claude/maestro*` (manifest, verify cmd, ledger) are
#      maestro's own bookkeeping, not production code, so the CTO may write them.
#   3. Scratch/tmp paths — writes under /tmp/, /private/tmp/, /var/folders/, or $TMPDIR
#      are no-impact (outside the repo) and must not be blocked; the orchestrator needs
#      these for recon/benchmark files that never touch production code.
#
# ⚠️ VERIFY before trusting in production: confirm `agent_id` is populated for subagents
# on your Claude Code version (run the agent_id probe). If it is NOT reliable, switch
# enforcement to the coded-controller (MCP) variant, where crew run as separate processes
# and this main-vs-subagent distinction is moot.
set -eu
_src="${BASH_SOURCE[0]}"; while [ -L "$_src" ]; do _src="$(readlink "$_src")"; done
. "$(cd "$(dirname "$_src")" && pwd)/lib-log.sh" 2>/dev/null && mlog_init guard-block-main-edits PreToolUse || true


input="$(cat)"
agent_id="$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null || true)"

# A subagent (developer/ui-developer/...) carries an agent_id → allow it to edit.
if [ -n "$agent_id" ]; then
  exit 0
fi

# Direct-edit mode is a per-TARGET-repo property, resolved per target below — NEVER a session
# early-exit. A session-anchored marker check here would let a CTO session in repo A (direct mode)
# edit repo B's PROTECTED files before B's gate ever runs (exemptions must never union outward
# across a repo boundary). The session repo's marker still applies exactly where the session repo
# IS the governing repo: same-repo edits (the common case — resolution finds the session repo as
# the target's repo and honors its marker at _anchor:227) and the no-target fallback (handled at
# the fallback-marker check below). proj is the session root, used only as the fallback anchor.
proj="${CLAUDE_PROJECT_DIR:-$PWD}"

# Extract file_path; canonicalization (with realpath) happens below before any carve-out check.
# SECURITY: do NOT apply the .claude/maestro carve-out on the raw path — an unanchored
# substring match on the raw value would (a) allow traversal out of .claude/maestro/ into
# production code via "..", and (b) match unrelated paths that merely contain the substring
# (e.g. skills/.claude/maestro-evil.ts, .claude/maestroX/anything).
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"

# Scratch/tmp paths are outside the repo and no-impact → allow.
# Mirrors the bash guard's benign_target() and foreman's guard.ts "no-impact paths" policy.
#
# SECURITY: canonicalize file_path via python3 realpath BEFORE the prefix check to prevent
# path-traversal attacks like /tmp/../../<repo>/file which starts with /tmp/ but resolves
# into the repository.  On macOS /tmp → /private/tmp; we also canonicalize the tmp roots.
_canon_path=""
if [ -n "$file_path" ] && command -v python3 >/dev/null 2>&1; then
  # os.path.realpath resolves symlinks in existing path components (e.g. /tmp → /private/tmp
  # on macOS) even when the final path does not yet exist.  This is exactly what we need to
  # prevent traversal attacks like /tmp/../../<repo>/file. Relative tool paths are resolved
  # against the project root, matching the repo used for budget/protected checks.
  _canon_input_path="$file_path"
  case "$file_path" in
    /*) ;;
    *) _canon_input_path="$proj/$file_path" ;;
  esac
  _canon_path="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$_canon_input_path" 2>/dev/null || true)"
fi
# Fall back to original path if canonicalization fails (fail-open).
_check_path="${_canon_path:-$file_path}"

# Resolve the governing repo from the TARGET FILE, not the session dir. A CTO session
# in a parent folder (or spanning two sibling repos) must govern each edit by ITS OWN
# repo's budget, protected paths, and carve-outs. The anchor moves as ONE piece: every
# carve-out below (.claude/maestro*, docs/, scratch) AND the python budget/protected
# lookup all key off this same root. Session proj is only the fallback when no target
# resolves (empty/unparseable file_path) — preserving today's behavior for those cases.
#
# git -C <nonexistent-dir> fails, and a Write can target a brand-new file in a
# brand-new directory, so we walk the target's dirname up to the nearest EXISTING
# ancestor before querying git (probe-verified). Fail-open to session proj on any miss.
_anchor=""
if [ -n "$_check_path" ] && command -v python3 >/dev/null 2>&1; then
  _anchor_dir="$(python3 -c '
import os, sys
d = os.path.dirname(os.path.realpath(sys.argv[1])) or "/"
while d and d != "/" and not os.path.isdir(d):
    d = os.path.dirname(d)
print(d)
' "$_check_path" 2>/dev/null || true)"
  if [ -n "$_anchor_dir" ] && [ -d "$_anchor_dir" ]; then
    _anchor="$(git -C "$_anchor_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$_anchor" ] && _anchor="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$_anchor" 2>/dev/null || echo "$_anchor")"
  fi
fi

# Harness state writes are maestro's own bookkeeping → allow.
# SECURITY: compare against CANONICAL paths anchored to the TARGET's real repo root so
# that traversal paths (.claude/maestro/../../hooks/...) and unrelated paths that contain
# the substring (skills/.claude/maestro-evil.ts, .claude/maestroX/anything) are NOT
# incorrectly classified as harness state. Falls back to the session proj when the target
# is outside any repo / unresolvable, so non-repo scratch carve-outs still work.
_session_proj="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$proj" 2>/dev/null || echo "$proj")"
_canon_proj="${_anchor:-$_session_proj}"

# UNION-OF-GATES protected check across STRICTLY OUTER enclosing repos, BEFORE any carve-out
# or direct-mode exemption. A repo nested inside a protected subtree of an outer repo (vendored
# dep with its own .git, accidental `git init`, fixture repo under src/) resolves only to the
# inner root via _anchor — which carries none of the outer repo's PROTECTED config. If ANY
# enclosing repo OUTSIDE the innermost protects the target by THAT repo's own relative path,
# BLOCK here. The innermost repo's own protected list is still enforced by the main gate below
# (with accurate usage in its log), so this only adds the missing outer-repo gate. Exemptions
# never union outward: running first means an inner docs/ or maestro-direct carve-out cannot
# defeat an outer repo's protection. git-unavailable / not-a-repo → no outer chain → falls
# through to the normal carve-outs + single-repo gate below (fail-open preserved).
if [ -n "$_anchor" ] && command -v python3 >/dev/null 2>&1; then
  set +e
  _outer_repo="$(GUARD_LIB_DIR="$(cd "$(dirname "$_src")" && pwd)" python3 - "$_check_path" "$_anchor" <<'PY'
import os, sys

sys.path.insert(0, os.environ.get("GUARD_LIB_DIR", os.path.dirname(os.path.abspath(__file__))))
# ANY failure to load guard_lib.py is a broken safety component, not "git unavailable" —
# over-block (exit 2). This block previously DISCARDED the python exit code (only stdout was
# captured), so a load failure fell silently through to the single-repo gate below. We exit 2
# here and the bash side now reads the exit code; a broken lib in the OUTER-union seam blocks
# too. Catch the BROAD Exception, not just ImportError: a PRESENT-BUT-CORRUPT lib (truncated
# mid-copy) raises SyntaxError, which is NOT an ImportError subclass — a narrow except would
# let it propagate to exit 1, which the seam _outer_exit-eq-2 check never matches, so it would
# fall through to the single-repo gate (whose own corrupt lib then exits 1 = ALLOW). NOTE: this
# heredoc body sits inside a $(...) command substitution, so apostrophes in comments here would
# desync bash quote-tracking — keep this body apostrophe-free.
try:
    from guard_lib import outer_repos, load_config, glob_match
except Exception as _e:
    sys.stderr.write(
        "BLOCKED: guard helper library 'guard_lib.py' could not be imported beside this hook "
        "(%s). Over-blocking to stay safe; re-run install.sh to restore the deployed copy.\n" % _e
    )
    sys.exit(2)

target = os.path.realpath(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] else ""
inner = os.path.realpath(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else ""
if not target or not inner:
    sys.exit(0)

# EVALUATION on a RESOLVED target (round-4 inversion). outer_repos / load_config / glob_match
# can RAISE at call time even from a cleanly-imported but broken lib. The old code left this
# loop unwrapped, so a raise died with exit 1 — which the bash seam _outer_exit-eq-2 check
# never matches, so it fell through to the single-repo gate (whose own raise then exited 1 =
# ALLOW). Per the spine invariant a protected decision we cannot compute is NEVER an allow:
# catch broadly and exit 2, naming the component. The bash side reads exit 2 and blocks here.
# NOTE: this heredoc body sits inside a $(...) command substitution, so apostrophes in comments
# here would desync bash quote-tracking — keep this body apostrophe-free.
try:
    for repo in outer_repos(inner):
        if any(glob_match(repo, p, target) for p in load_config(repo)[2]):
            print(repo)
            sys.exit(0)
except SystemExit:
    raise
except Exception as _outer_e:
    sys.stderr.write(
        "BLOCKED: the outer-repo protected-path check could not be evaluated for this target "
        "(%r). Over-blocking to stay safe; the guard helper raised mid-decision.\n" % _outer_e
    )
    sys.exit(2)
sys.exit(0)
PY
)"
  _outer_exit=$?
  set -e
  # A broken-lib import in the outer-union heredoc exits 2 → block here, BEFORE the normal
  # single-repo gate (whose own heredoc would also exit 2, but the message would name the
  # main seam; blocking here keeps the failure attributed to the first seam reached). Any
  # OTHER nonzero (e.g. a genuine git error inside the block) is left to fall through to the
  # single-repo gate, preserving today's fail-open for real git-unavailable conditions.
  if [ "$_outer_exit" -eq 2 ]; then
    # The heredoc already wrote a stderr line naming guard_lib; just propagate the block.
    exit 2
  fi
  if [ -n "$_outer_repo" ]; then
    # Log against the innermost repo (its .claude is the one nearest the target). Size is
    # irrelevant on protected paths, so 0/0 usage in the log is honest here.
    python3 - "$_check_path" "$_anchor" <<'PYLOG' 2>/dev/null || true
import datetime, json, os, sys
target, repo = os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])
try:
    d = os.path.join(repo, ".claude", "maestro")
    os.makedirs(d, exist_ok=True)
    rec = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
           "hook": "guard-block-main-edits", "target": target,
           "lines_used": 0, "files_used": 0, "reason": "protected"}
    with open(os.path.join(d, "guard-log.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, separators=(",", ":")) + "\n")
except Exception:
    pass
PYLOG
    echo "BLOCKED: protected path. Size does not matter on protected paths; run maestro for this task." >&2
    exit 2
  fi
fi

# Direct-edit mode is a per-TARGET-repo carve-out. A founder who put repoB in direct mode wants
# direct edits to repoB files even from a parent session. Runs AFTER the protected union so an
# inner direct-mode marker cannot defeat outer protection (exemptions never union outward).
#   - Target resolved (_anchor set): honor the TARGET repo's marker — same-repo edits land here
#     too, since the target's repo IS the session repo and its marker is the session's.
#   - No target resolved (_anchor empty: empty/unparseable file_path): the session repo governs
#     (_canon_proj fell back to it), so honor the SESSION repo's marker on this fallback path.
if [ -n "$_anchor" ]; then
  if [ -f "$_anchor/.claude/maestro-direct" ]; then exit 0; fi
elif [ -f "$_canon_proj/.claude/maestro-direct" ]; then
  exit 0
fi
_maestro_json="${_canon_proj}/.claude/maestro.json"
_maestro_verify="${_canon_proj}/.claude/maestro-verify"
_maestro_direct_file="${_canon_proj}/.claude/maestro-direct"
_maestro_ledger_prefix="${_canon_proj}/.claude/maestro/"
if [ "$_check_path" = "$_maestro_json" ] \
   || [ "$_check_path" = "$_maestro_verify" ] \
   || [ "$_check_path" = "$_maestro_direct_file" ]; then
  exit 0
fi
case "$_check_path" in
  # Note trailing slash: matches <repo>/.claude/maestro/<anything> but NOT maestroX or maestro-evil
  "$_maestro_ledger_prefix"*) exit 0 ;;
esac

_tmpdir="${TMPDIR:-}"
_tmpdir="${_tmpdir%/}"  # strip trailing slash for consistent prefix matching
# Canonicalize the tmp roots too (macOS: /tmp → /private/tmp).
_canon_tmp_roots=()
for _root in /tmp /private/tmp /var/folders; do
  _cr="$(python3 -c "import os; print(os.path.realpath('$_root'))" 2>/dev/null || true)"
  [ -n "$_cr" ] && _canon_tmp_roots+=("$_cr/")
done
if [ -n "$_tmpdir" ]; then
  _cr="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$_tmpdir" 2>/dev/null || true)"
  [ -n "$_cr" ] && _canon_tmp_roots+=("$_cr/")
fi

is_scratch=0
for _pfx in "${_canon_tmp_roots[@]}"; do
  case "$_check_path" in
    "$_pfx"*) is_scratch=1; break ;;
  esac
done
# Scratch carve-out is for no-impact files outside the repo. If the project itself
# lives under TMPDIR during tests, keep repo paths budget/protected-gated.
case "$_check_path" in
  "$_canon_proj"|"$_canon_proj/"*) is_scratch=0 ;;
esac
if [ "$is_scratch" -eq 1 ]; then
  exit 0
fi

# Prose/docs/no-impact carve-out — the CTO may edit documentation and memory files
# directly, but code remains budget-gated.  SECURITY: use the canonical _check_path so
# docs/../src/app.ts resolves to src/app.ts and does NOT match the docs prefix.
_base="${_check_path##*/}"
_ext=""
_stem="$_base"
case "$_base" in
  *.*)
    _ext=".${_base##*.}"
    _stem="${_base%.*}"
    ;;
esac
_lower_ext="$(printf '%s' "$_ext" | tr '[:upper:]' '[:lower:]')"
case "$_lower_ext" in
  .md|.markdown|.mdx|.txt|.rst|.adoc) exit 0 ;;
esac
_upper_stem="$(printf '%s' "$_stem" | tr '[:lower:]' '[:upper:]')"
case "$_upper_stem" in
  LICENSE|LICENCE|COPYING|NOTICE|AUTHORS) exit 0 ;;
esac
_docs_prefix="${_canon_proj}/docs/"
case "$_check_path" in
  "$_docs_prefix"*) exit 0 ;;
esac

# Protected-path + budget gate. If git cannot be queried, fail open: tester/reviewer/
# commit-gate remain backstops, and non-repo directories have no production-risk budget.
set +e
GUARD_LIB_DIR="$(cd "$(dirname "$_src")" && pwd)" python3 - "$_check_path" "$_canon_proj" 3<<<"$input" <<'PY'
import datetime, json, os, subprocess, sys

sys.path.insert(0, os.environ.get("GUARD_LIB_DIR", os.path.dirname(os.path.abspath(__file__))))
# ANY failure to load guard_lib.py is a broken safety component, not "git unavailable" —
# over-block (exit 2), never fall through to this heredoc's final exit 0. An unwrapped
# exception would exit 1, which the bash wrapper captures into _budget_exit and exits with: per
# the hook contract any nonzero other than 2 is a non-blocking error → the protected edit slips
# through. So we catch it and exit 2 (which _budget_exit then propagates), naming the lib for
# debug. Catch the BROAD Exception, not just ImportError: a PRESENT-BUT-CORRUPT lib (truncated
# mid-copy) raises SyntaxError, which is NOT an ImportError subclass — a narrow except would let
# it propagate to exit 1 = ALLOW on a protected edit.
try:
    from guard_lib import load_config, glob_match, rel_for
except Exception as _e:
    sys.stderr.write(
        "BLOCKED: guard helper library 'guard_lib.py' could not be imported beside this hook "
        "(%s). Over-blocking to stay safe; re-run install.sh to restore the deployed copy.\n" % _e
    )
    sys.exit(2)

HOOK = "guard-block-main-edits"
target = os.path.realpath(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] else ""
proj = os.path.realpath(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else os.getcwd()
try:
    payload = json.load(os.fdopen(3))
except Exception:
    sys.exit(0)  # unparseable hook payload stays fail-open


def git(*args):
    return subprocess.check_output(["git", "-C", proj, *args], stderr=subprocess.DEVNULL)

# RESOLUTION — the ONE legitimate fail-open: git unavailable / not a repo → nothing to govern.
# Everything AFTER this (config load + protected match) is EVALUATION on a RESOLVED target and
# must over-block, not fall open, when it throws (round-4 inversion; see the protected block).
try:
    repo = os.path.realpath(git("rev-parse", "--show-toplevel").decode().strip())
except Exception:
    sys.exit(0)


# load_config is EVALUATION (it reads the resolved repo's policy). A raise here is a decision we
# could not compute → over-block (exit 2), naming the cause. The bash wrapper captures this exit
# into _budget_exit and propagates it; exit 2 is the only value the contract reads as BLOCK.
try:
    max_lines, max_files, protected = load_config(repo)
except Exception as _cfg_e:
    sys.stderr.write(
        "BLOCKED: the protected-path policy could not be loaded for this repo "
        "(%r). Over-blocking to stay safe; the guard helper raised mid-decision.\n" % _cfg_e
    )
    sys.exit(2)


def is_protected(path):
    return any(glob_match(repo, p, path) for p in protected)


def is_no_count_rel(rel):
    rel = rel.replace("\\", "/")
    base = os.path.basename(rel)
    stem, ext = os.path.splitext(base)
    if rel in {".claude/maestro.json", ".claude/maestro-verify", ".claude/maestro-direct"}:
        return True
    if rel.startswith(".claude/maestro/"):
        return True
    if ext.lower() in {".md", ".markdown", ".mdx", ".txt", ".rst", ".adoc"}:
        return True
    if stem.upper() in {"LICENSE", "LICENCE", "COPYING", "NOTICE", "AUTHORS"}:
        return True
    if rel.startswith("docs/"):
        return True
    return False


def line_count_file(path):
    try:
        with open(path, "rb") as f:
            data = f.read()
        if not data:
            return 0
        return len(data.splitlines())
    except Exception:
        return 0


def current_usage():
    changed = set()
    lines = 0
    out = git("diff", "--numstat", "HEAD", "--").decode("utf-8", "replace")
    for row in out.splitlines():
        parts = row.split("\t")
        if len(parts) < 3:
            continue
        rel = parts[-1]
        if is_no_count_rel(rel):
            continue
        changed.add(rel)
        try:
            add = 0 if parts[0] == "-" else int(parts[0])
            dele = 0 if parts[1] == "-" else int(parts[1])
        except Exception:
            add = dele = 0
        lines += add + dele
    out = git("status", "--porcelain=v1", "-z", "--untracked-files=all")
    for b in out.split(b"\0"):
        if not b or not b.startswith(b"?? "):
            continue
        rel = b[3:].decode("utf-8", "replace")
        if is_no_count_rel(rel):
            continue
        changed.add(rel)
        lines += line_count_file(os.path.join(repo, rel))
    return lines, changed

def write_log(reason, lines_used, files_used):
    try:
        log_dir = os.path.join(repo, ".claude", "maestro")
        os.makedirs(log_dir, exist_ok=True)
        rec = {
            "ts": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
            "hook": HOOK,
            "target": target,
            "lines_used": lines_used,
            "files_used": files_used,
            "reason": reason,
        }
        with open(os.path.join(log_dir, "guard-log.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
    except Exception:
        pass


# PROTECTED (innermost repo's own list) must evaluate to completion INDEPENDENT of usage —
# is_protected needs only the work tree + config + glob, never HEAD. Running it BEFORE
# current_usage (which queries `git diff HEAD` and RAISES on a HEAD-less repo with no commit
# yet) is the spine invariant: a repo-state exception in usage must not skip protection. This
# mirrors the strictly-outer union above (which already runs before any HEAD query) and the
# bash guard's ordering. Size is irrelevant on protected paths → log 0/0, as the outer union
# does. Budget (below) still fails open when usage is unknowable; protection never does.
# When the innermost repo's budget was UNREADABLE, load_config failed closed to "**"
# (protect everything). Surface that cause so the over-block self-explains instead of
# showing the generic protected-path text for a path the operator never listed.
_cause = getattr(protected, "fail_closed_reason", "")
_cause_suffix = (" (%s)" % _cause) if _cause else ""
# EVALUATION on a RESOLVED target (round-4 inversion). is_protected calls glob_match; if a
# helper RAISES at call time (clean import, broken body) the protected decision could not be
# computed. Per the spine invariant that is NEVER an ALLOW: over-block (exit 2), naming the
# component. The old code left this call unwrapped → a raise propagated to exit 1 = ALLOW (the
# bash _budget_exit reads any nonzero-but-2 as a non-blocking error and the edit proceeds).
try:
    _hit = bool(target) and is_protected(target)
except Exception as _prot_e:
    sys.stderr.write(
        "BLOCKED: the protected-path check could not be evaluated for this target "
        "(%r). Over-blocking to stay safe; the guard helper raised mid-decision.\n" % _prot_e
    )
    sys.exit(2)
if _hit:
    write_log("protected", 0, 0)
    sys.stderr.write("BLOCKED: protected path. Size does not matter on protected paths; run maestro for this task.%s\n" % _cause_suffix)
    sys.exit(2)

try:
    cur_lines, changed_files = current_usage()
except Exception:
    sys.exit(0)


def count_text(s):
    if not isinstance(s, str) or s == "":
        return 0
    return len(s.splitlines())


def projected_lines(data):
    ti = data.get("tool_input") or {}
    if isinstance(ti.get("content"), str):
        return count_text(ti.get("content"))
    total = count_text(ti.get("old_string")) + count_text(ti.get("new_string"))
    edits = ti.get("edits")
    if isinstance(edits, list):
        for e in edits:
            if isinstance(e, dict):
                total += count_text(e.get("old_string")) + count_text(e.get("new_string"))
    return total

proj_lines = projected_lines(payload)
# rel_for is a HELPER call, not a git-diff/HEAD query. Budget's legitimate fail-open above
# (current_usage → exit 0) covers HEAD UNKNOWABILITY — a return-value path, the repo genuinely
# has no committed state to diff. A rel_for RAISE is a different animal: a broken safety
# component mid-decision. Per the spine invariant (CTO call: rel_for raising anywhere =
# evaluation failure = exit 2) it must OVER-block, never fall through to the final exit 0. Round
# 4 left this unwrapped, so a rel_for raise died with exit 1 — the hook contract reads any
# nonzero-but-2 as a non-blocking error and the edit PROCEEDS (ALLOW). The bash guard never
# calls rel_for, so this is the only seam that can reach it; wrapping it here makes both guards
# agree: a rel_for raise blocks wherever it is reached.
try:
    target_rel = rel_for(repo, target) if target else ""
except Exception as _rel_e:
    sys.stderr.write(
        "BLOCKED: the budget file-attribution check could not be evaluated for this target "
        "(%r). Over-blocking to stay safe; the guard helper raised mid-decision.\n" % _rel_e
    )
    sys.exit(2)
proj_files = 0 if (target_rel and target_rel in changed_files) else (1 if target else 0)
used_lines = cur_lines + proj_lines
used_files = len(changed_files) + proj_files

if used_lines > max_lines or used_files > max_files:
    write_log("budget", used_lines, used_files)
    sys.stderr.write(
        f"BLOCKED: direct-edit budget exhausted (lines {used_lines}/{max_lines}, files {used_files}/{max_files}).\n"
        "Run maestro for the REMAINDER of this task; never split a task to stay under the limit.\n"
    )
    sys.exit(2)

sys.exit(0)
PY
_budget_exit=$?
set -e
exit "$_budget_exit"
