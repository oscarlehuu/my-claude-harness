#!/usr/bin/env bash
# SessionStart hook — inject the DYNAMIC maestro status for this repo.
#
# The static operating contract (role, tiers, gates) is NOT here — it loads via
# ~/.claude/CLAUDE.md (@AGENTS.md import), which Claude Code re-injects after compaction.
# This hook's job is what a static file can't know: live state read at fire time —
# engagement, the open task's tier/round/verify state. It fires on startup, resume,
# /clear AND compact, so a rebuilt context always gets ground truth from the ledger.
# Read-only; always exit 0.
_src="${BASH_SOURCE[0]}"; while [ -L "$_src" ]; do _src="$(readlink "$_src")"; done
. "$(cd "$(dirname "$_src")" && pwd)/lib-log.sh" 2>/dev/null && mlog_init maestro-engage SessionStart || true


input="$(cat 2>/dev/null || true)"
source_kind="$(printf '%s' "$input" | jq -r '.source // "startup"' 2>/dev/null || echo startup)"

proj="${CLAUDE_PROJECT_DIR:-$PWD}"

echo "[maestro] CTO mode — operating contract is loaded via CLAUDE.md (@AGENTS.md): triage every"
echo "code task first (\`Tier: <t> — <reason>\`), delegate beyond the guard budget, verify via"
echo "task-verify.sh (exit code = ground truth)."

if [ "$source_kind" = "compact" ]; then
  echo "[maestro] Context was just compacted — the status below is re-read from the ledger (ground truth), trust it over the summary."
fi

if [ -f "$proj/.claude/maestro-direct" ]; then
  echo "[maestro] This repo is in DIRECT-EDIT mode (guards off): .claude/maestro-direct exists."
fi

active=""
[ -f "$proj/.claude/maestro/active" ] && active="$(cat "$proj/.claude/maestro/active" 2>/dev/null)"
if [ -n "$active" ] && [ -f "$proj/.claude/maestro/$active/state.json" ]; then
  python3 - "$proj/.claude/maestro/$active/state.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    s = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
lv = s.get("lastVerify")
verify = "never ran" if not lv else ("green" if lv.get("exit") == 0 else f"FAILING (exit {lv.get('exit')})")
print(f"[maestro] OPEN TASK: '{s.get('slug')}' — tier {s.get('tier')}, state {s.get('state')}, "
      f"round {s.get('round')}, verify {verify}. Resume it (ledger: .claude/maestro/{s.get('slug')}/) "
      f"or close it with task-record.sh before starting new work.")
PY
else
  echo "[maestro] No open maestro task in this repo."
fi

# Registry nudge — "machine proposes, founder nods, CTO writes the line." If this
# repo is a git work tree that the HQ board isn't watching yet, suggest adding it.
# Strictly read-only and fail-silent: any error here must not break the hook.
{
  hq="${MAESTRO_HQ:-}"
  if [ -z "$hq" ] && [ -f "$HOME/.claude/maestro-hq" ]; then
    hq="$(cat "$HOME/.claude/maestro-hq" 2>/dev/null || true)"
  fi
  top="$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null || true)"
  # Only when: HQ exists, $proj is in a git tree, and no dismiss marker.
  if [ -n "$hq" ] && [ -d "$hq" ] && [ -n "$top" ] && [ ! -e "$proj/.claude/maestro/registry-nudge-off" ]; then
    MAESTRO_N_HQ="$hq" MAESTRO_N_TOP="$top" python3 - <<'PY' 2>/dev/null || true
import json, os, sys

hq = os.environ["MAESTRO_N_HQ"]
top = os.path.realpath(os.environ["MAESTRO_N_TOP"])

# Don't nudge the HQ about itself.
if top == os.path.realpath(hq):
    sys.exit(0)

try:
    with open(os.path.join(hq, "registry.json"), encoding="utf-8") as f:
        repos = json.load(f).get("repos", [])
except Exception:
    repos = []

for entry in repos:
    if os.path.realpath(os.path.expanduser(entry.get("path", ""))) == top:
        sys.exit(0)  # already on the board

print("[maestro] This repo is not on the company board (HQ registry). To add it: "
      "maestro/scripts/registry-add.sh — to silence this: touch .claude/maestro/registry-nudge-off")
PY
  fi
} 2>/dev/null || true

# Staleness nudge — "production runtime is behind the harness repo". We read the stamp from
# the runtime that is ACTUALLY executing this hook: the .claude dir two levels up from the
# hook's own resolved path (when copy-deployed it lives at <.claude>/hooks/maestro-engage.sh),
# falling back to ~/.claude when that can't be derived. If the stamp exists, its recorded
# source repo still exists, and the source HEAD differs from the stamped sha -> one line.
# Strictly read-only, fail-silent, one git rev-parse and only when the stamp is present.
# MAESTRO_DEPLOYED_STAMP overrides the stamp path (test seam, mirrors MAESTRO_HQ above).
{
  stamp="${MAESTRO_DEPLOYED_STAMP:-}"
  if [ -z "$stamp" ]; then
    rt="$(cd "$(dirname "$_src")/.." 2>/dev/null && pwd || true)"
    case "$rt" in */.claude) stamp="$rt/maestro-deployed.json" ;; *) stamp="$HOME/.claude/maestro-deployed.json" ;; esac
  fi
  if [ -f "$stamp" ]; then
    MAESTRO_STALE_STAMP="$stamp" python3 - <<'PY' 2>/dev/null || true
import json, os, subprocess, sys
try:
    s = json.load(open(os.environ["MAESTRO_STALE_STAMP"], encoding="utf-8"))
    src, sha = s["source"], s["sha"]
except Exception:
    sys.exit(0)
if not src or not sha or not os.path.isdir(src):
    sys.exit(0)
try:
    head = subprocess.run(["git", "-C", src, "rev-parse", "HEAD"],
                          capture_output=True, text=True, timeout=5).stdout.strip()
except Exception:
    sys.exit(0)
if head and head != sha:
    print(f"[maestro] Production runtime is behind the harness repo "
          f"(deployed {sha[:7]}, repo at {head[:7]}) — review + re-run install.sh when ready.")
PY
  fi
} 2>/dev/null || true

# Context slots — the two identity layers a static file can't carry. AGENTS.md (the
# framework's law) already loads via CLAUDE.md; these add, in reading order:
#   1. company slot — how THIS company works: $HQ/knowledge/conventions.md (HQ resolved
#      like team-board.sh: $MAESTRO_HQ, else the ~/.claude/maestro-hq pointer file).
#   2. personal slot — who the human at this machine is: ~/.claude/me.md ($MAESTRO_ME seam).
# Each: exists + readable + non-blank → header + the first 60 lines (a runaway file must
# not tax every session); whether the source files exist is the user's business. Strictly
# read-only and fail-silent like the nudges above — any error prints nothing for that slot.
{
  hq="${MAESTRO_HQ:-}"
  if [ -z "$hq" ] && [ -f "$HOME/.claude/maestro-hq" ]; then
    hq="$(cat "$HOME/.claude/maestro-hq" 2>/dev/null || true)"
  fi
  MAESTRO_SLOT_HQ="$hq" MAESTRO_SLOT_ME="${MAESTRO_ME:-$HOME/.claude/me.md}" python3 - <<'PY' 2>/dev/null || true
import os

CAP = 60

def emit(path, header):
    if not path:
        return
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except Exception:
        return  # missing, unreadable, or non-UTF-8 → silent for this slot
    if not text.strip():
        return  # blank/whitespace-only → nothing to say
    lines = text.splitlines()
    print(header)
    for line in lines[:CAP]:
        print(line)
    if len(lines) > CAP:
        print("[maestro] (...truncated — keep this file under 60 lines)")

hq = (os.environ.get("MAESTRO_SLOT_HQ") or "").strip()
conventions = os.path.join(hq, "knowledge", "conventions.md") if hq else ""
emit(conventions, "[maestro] Company conventions:")
emit((os.environ.get("MAESTRO_SLOT_ME") or "").strip(), "[maestro] About the human:")
PY
} 2>/dev/null || true

exit 0
