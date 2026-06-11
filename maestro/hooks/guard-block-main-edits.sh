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
  _outer_repo="$(python3 - "$_check_path" "$_anchor" <<'PY'
import fnmatch, os, subprocess, sys

target = os.path.realpath(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] else ""
inner = os.path.realpath(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else ""
if not target or not inner:
    sys.exit(0)


def git_toplevel(d):
    try:
        return os.path.realpath(subprocess.check_output(
            ["git", "-C", d, "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL).decode().strip())
    except Exception:
        return ""


def outer_repos(start):
    """Enclosing repo roots STRICTLY outside `start`, innermost → outermost (start excluded)."""
    chain, seen, cur = [], {start}, start
    while True:
        parent = os.path.dirname(cur)
        if not parent or parent == cur:
            break
        outer = git_toplevel(parent)
        if not outer or outer in seen:
            break
        seen.add(outer); chain.append(outer); cur = outer
    return chain


def load_protected(repo):
    out = []
    try:
        with open(os.path.join(repo, ".claude", "maestro-budget"), encoding="utf-8") as f:
            for raw in f:
                raw = raw.strip()
                if not raw or raw.startswith("#") or "=" not in raw:
                    continue
                k, v = raw.split("=", 1)
                if k.strip().upper() == "PROTECTED":
                    out = [p for p in v.strip().split(":") if p]
    except FileNotFoundError:
        pass
    except Exception:
        return []
    return out


def rel_for(repo, path):
    try:
        return os.path.relpath(os.path.realpath(path), repo).replace(os.sep, "/")
    except Exception:
        return path.replace(os.sep, "/")


def match_segments(psegs, ssegs):
    if not psegs:
        return not ssegs
    head = psegs[0]
    if head == "**":
        return match_segments(psegs[1:], ssegs) or (bool(ssegs) and match_segments(psegs, ssegs[1:]))
    return bool(ssegs) and fnmatch.fnmatchcase(ssegs[0], head) and match_segments(psegs[1:], ssegs[1:])


def glob_match(repo, pattern, abs_path):
    pat = pattern.strip().replace("\\", "/")
    if not pat:
        return False
    if os.path.isabs(pat):
        subject = os.path.realpath(abs_path).lstrip(os.sep).replace(os.sep, "/")
        pat = os.path.realpath(pat).lstrip(os.sep).replace(os.sep, "/")
    else:
        subject = rel_for(repo, abs_path)
    return match_segments([p for p in pat.split("/") if p], [p for p in subject.split("/") if p])


for repo in outer_repos(inner):
    if any(glob_match(repo, p, target) for p in load_protected(repo)):
        print(repo)
        sys.exit(0)
sys.exit(0)
PY
)"
  set -e
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
python3 - "$_check_path" "$_canon_proj" 3<<<"$input" <<'PY'
import datetime, fnmatch, json, os, subprocess, sys

HOOK = "guard-block-main-edits"
target = os.path.realpath(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] else ""
proj = os.path.realpath(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else os.getcwd()
try:
    payload = json.load(os.fdopen(3))
except Exception:
    sys.exit(0)  # unparseable hook payload stays fail-open


def git(*args):
    return subprocess.check_output(["git", "-C", proj, *args], stderr=subprocess.DEVNULL)

try:
    repo = os.path.realpath(git("rev-parse", "--show-toplevel").decode().strip())
except Exception:
    sys.exit(0)


def load_config():
    lines, files, protected = 50, 2, []
    path = os.path.join(repo, ".claude", "maestro-budget")
    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                raw = raw.strip()
                if not raw or raw.startswith("#") or "=" not in raw:
                    continue
                k, v = raw.split("=", 1)
                k, v = k.strip().upper(), v.strip()
                if k == "LINES":
                    try:
                        n = int(v)
                        if n >= 0:
                            lines = n
                    except Exception:
                        lines = 50
                elif k == "FILES":
                    try:
                        n = int(v)
                        if n >= 0:
                            files = n
                    except Exception:
                        files = 2
                elif k == "PROTECTED":
                    protected = [p for p in v.split(":") if p]
    except FileNotFoundError:
        pass
    except Exception:
        return 50, 2, []
    return lines, files, protected

max_lines, max_files, protected = load_config()


def rel_for(path):
    try:
        return os.path.relpath(os.path.realpath(path), repo).replace(os.sep, "/")
    except Exception:
        return path.replace(os.sep, "/")


def match_segments(psegs, ssegs):
    if not psegs:
        return not ssegs
    head = psegs[0]
    if head == "**":
        return match_segments(psegs[1:], ssegs) or (bool(ssegs) and match_segments(psegs, ssegs[1:]))
    return bool(ssegs) and fnmatch.fnmatchcase(ssegs[0], head) and match_segments(psegs[1:], ssegs[1:])


def glob_match(pattern, abs_path):
    pat = pattern.strip().replace("\\", "/")
    if not pat:
        return False
    if os.path.isabs(pat):
        subject = os.path.realpath(abs_path).lstrip(os.sep).replace(os.sep, "/")
        pat = os.path.realpath(pat).lstrip(os.sep).replace(os.sep, "/")
    else:
        subject = rel_for(abs_path)
    return match_segments([p for p in pat.split("/") if p != ""], [p for p in subject.split("/") if p != ""])


def is_protected(path):
    return any(glob_match(p, path) for p in protected)


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
if target and is_protected(target):
    write_log("protected", 0, 0)
    sys.stderr.write("BLOCKED: protected path. Size does not matter on protected paths; run maestro for this task.\n")
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
target_rel = rel_for(target) if target else ""
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
