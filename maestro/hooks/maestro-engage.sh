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
exit 0
