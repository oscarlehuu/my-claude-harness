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

# Engagement OFF for this repo → allow direct edits (the founder chose direct-edit mode).
proj="${CLAUDE_PROJECT_DIR:-$PWD}"
if [ -f "$proj/.claude/maestro-direct" ] || [ -f ".claude/maestro-direct" ]; then
  exit 0
fi

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

# Harness state writes are maestro's own bookkeeping → allow.
# SECURITY: compare against CANONICAL paths anchored to the real repo root so that
# traversal paths (.claude/maestro/../../hooks/...) and unrelated paths that contain
# the substring (skills/.claude/maestro-evil.ts, .claude/maestroX/anything) are NOT
# incorrectly classified as harness state.
_canon_proj="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$proj" 2>/dev/null || echo "$proj")"
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

try:
    cur_lines, changed_files = current_usage()
except Exception:
    sys.exit(0)


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

if target and is_protected(target):
    write_log("protected", cur_lines, len(changed_files))
    sys.stderr.write("BLOCKED: protected path. Size does not matter on protected paths; run maestro for this task.\n")
    sys.exit(2)


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
