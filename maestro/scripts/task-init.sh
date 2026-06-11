#!/usr/bin/env bash
# Open a maestro task ledger: .claude/maestro/<slug>/{state.json,log.jsonl} + the active pointer.
# Usage: task-init.sh <slug> <tier: light|standard|full> "<task summary>" [verify-command]
#
# The ledger is the state machine; hooks (commit-gate, stop-dod) read it to enforce the
# tier's Definition of Done deterministically. The CTO declares the tier here, once,
# at task start — escalation later goes through task-record.sh tier_escalated (one-way).
set -eu

slug="${1:?usage: task-init.sh <slug> <tier> <task-summary> [verify-cmd]}"
tier="${2:?missing tier (light|standard|full)}"
task="${3:?missing task summary}"
verify="${4:-}"

case "$tier" in light|standard|full) : ;; *) echo "invalid tier '$tier' (light|standard|full)" >&2; exit 1 ;; esac
case "$slug" in
  *[!a-z0-9-]*|"") echo "invalid slug '$slug' (kebab-case: a-z 0-9 -)" >&2; exit 1 ;;
esac

root="${CLAUDE_PROJECT_DIR:-$PWD}"
dir="$root/.claude/maestro/$slug"

if [ -f "$dir/state.json" ]; then
  echo "task '$slug' already exists — resume it, or pick a new slug" >&2
  exit 1
fi
mkdir -p "$dir"

python3 - "$dir" "$slug" "$tier" "$task" <<'PY'
import datetime, json, os, sys
dir, slug, tier, task = sys.argv[1:5]
ts = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
state = {
    "slug": slug, "tier": tier, "task": task,
    "state": "in_progress", "round": 1,
    "gate1Approved": False, "lastTesterVerdict": None, "lastReviewerVerdict": None,
    "lastVerify": None,
    "createdAt": ts, "updatedAt": ts,
}
# atomic write: temp + rename, so a concurrent hook never reads a half-written file
path = os.path.join(dir, "state.json")
tmp = f"{path}.{os.getpid()}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
os.replace(tmp, path)
with open(os.path.join(dir, "log.jsonl"), "a", encoding="utf-8") as f:
    f.write(json.dumps({"ts": ts, "event": "task_init", "tier": tier, "task": task},
                       separators=(",", ":")) + "\n")
PY

printf '%s' "$slug" > "$root/.claude/maestro/active.$$" && mv "$root/.claude/maestro/active.$$" "$root/.claude/maestro/active"

if [ -n "$verify" ]; then
  vf="$root/.claude/maestro-verify"
  if [ -f "$vf" ] && [ "$(cat "$vf")" != "$verify" ]; then
    echo "note: replacing previous verify command: $(cat "$vf")"
  fi
  printf '%s' "$verify" > "$vf"
fi

echo "opened task '$slug' (tier: $tier) — ledger: .claude/maestro/$slug/"
[ -n "$verify" ] && echo "verify: $verify"
exit 0
