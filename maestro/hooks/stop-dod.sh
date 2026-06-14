#!/usr/bin/env bash
# Stop hook — the light-tier Definition of Done.
#
# If code changed since the last SUCCESSFUL verify run, block the stop once and tell
# the CTO to run task-verify.sh. Covers the gap commit-gate can't see: tasks that end
# without a commit. Prose/docs/harness-state edits never trip it (same no-count rules
# as the guard), and `stop_hook_active` prevents a block loop.
set -eu
_src="${BASH_SOURCE[0]}"; while [ -L "$_src" ]; do _src="$(readlink "$_src")"; done
. "$(cd "$(dirname "$_src")" && pwd)/lib-log.sh" 2>/dev/null && mlog_init stop-dod Stop || true


input="$(cat)"

# Already blocked once this stop → let it through (no loops).
sha="$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
[ "$sha" = "true" ] && exit 0

proj="${CLAUDE_PROJECT_DIR:-$PWD}"

# Direct-edit mode is the founder's explicit escape hatch — respect it.
[ -f "$proj/.claude/maestro-direct" ] && exit 0

# Nothing to enforce without a verify command.
VERIFY="${MAESTRO_VERIFY:-}"
if [ -z "$VERIFY" ] && [ -f "$proj/.claude/maestro-verify" ]; then
  VERIFY="$(cat "$proj/.claude/maestro-verify")"
fi
[ -z "$VERIFY" ] && exit 0

set +e
python3 - "$proj" <<'PY'
import json, os, subprocess, sys

proj = os.path.realpath(sys.argv[1])

def git(*args):
    return subprocess.check_output(["git", "-C", proj, *args], stderr=subprocess.DEVNULL)

try:
    repo = os.path.realpath(git("rev-parse", "--show-toplevel").decode().strip())
except Exception:
    sys.exit(0)  # not a git repo — nothing to measure

PROSE_EXT = {".md", ".markdown", ".mdx", ".txt", ".rst", ".adoc"}
PROSE_STEM = {"LICENSE", "LICENCE", "COPYING", "NOTICE", "AUTHORS"}

def is_no_count(rel):
    rel = rel.replace("\\", "/")
    base = os.path.basename(rel)
    stem, ext = os.path.splitext(base)
    if rel.startswith(".claude/"):
        return True
    if ext.lower() in PROSE_EXT or stem.upper() in PROSE_STEM:
        return True
    if rel.startswith("docs/"):
        return True
    return False

changed = set()
try:
    out = git("diff", "--name-only", "HEAD", "--").decode("utf-8", "replace")
    changed.update(r for r in out.splitlines() if r)
    out = git("status", "--porcelain=v1", "-z", "--untracked-files=all")
    for b in out.split(b"\0"):
        if b.startswith(b"?? "):
            changed.add(b[3:].decode("utf-8", "replace"))
except Exception:
    sys.exit(0)

code_files = [r for r in changed if not is_no_count(r)]
if not code_files:
    sys.exit(0)

newest = 0
for rel in code_files:
    try:
        newest = max(newest, int(os.path.getmtime(os.path.join(repo, rel))))
    except Exception:
        pass

last = None
try:
    with open(os.path.join(repo, ".claude", "maestro", "last-verify.json"), encoding="utf-8") as f:
        last = json.load(f)
except Exception:
    pass

if last and last.get("exit") == 0 and int(last.get("epoch", 0)) >= newest:
    sys.exit(0)  # verified green after the newest code edit

why = "verify never ran" if not last else (
    "last verify FAILED" if last.get("exit") != 0 else "code changed after the last green verify")
sys.stderr.write(
    f"Code changed but is not verified ({why}; {len(code_files)} changed code file(s)).\n"
    "Before finishing: run the verify command via skills/maestro scripts/task-verify.sh "
    "(records ground truth), fix failures or report them honestly — do not end the turn "
    "claiming done with an unverified tree.\n")
sys.exit(2)
PY
_exit=$?
set -e

# Continual-learning cadence — trigger #2. Runs ONLY on the non-blocking pass path, after the
# DoD decision, fire-and-forget: it can mark a distill due + nudge but NEVER changes this hook's
# exit code (the cadence hook self-guards to exit 0, and we ignore its result regardless). The
# block path (exit 2) is left completely untouched. We replay the captured stdin so the cadence
# hook sees the same transcript_path/stop_hook_active payload this hook received.
if [ "$_exit" = 0 ]; then
  _cad="$(cd "$(dirname "$_src")" && pwd)/distill-cadence.sh"
  [ -f "$_cad" ] && printf '%s' "$input" | bash "$_cad" >/dev/null 2>&1 || true
fi

exit "$_exit"
