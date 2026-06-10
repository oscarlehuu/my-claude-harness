#!/usr/bin/env bash
# PreToolUse on Bash — gate `git commit` on the tier-aware Definition of Done.
#
# Two layers, cheapest first:
#   1. Ledger DoD — if a maestro task is active, its tier decides which recorded
#      judgments must exist (standard+: tester PASS; full: + reviewer APPROVE and
#      Gate 1). Records are written by the task-*.sh scripts, so the schema is stable.
#   2. Verify re-run — the verify command is executed HERE, fresh. Exit code is
#      ground truth; no recorded claim can substitute for it.
# No active task → layer 1 is skipped (plain repos keep the old verify-only behavior).
set -eu

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

# Only gate actual commits; let every other Bash command through.
case "$cmd" in
  *"git commit"*) : ;;
  *) exit 0 ;;
esac

proj="${CLAUDE_PROJECT_DIR:-$PWD}"

# --- Layer 1: ledger DoD for the active task (if any) ---------------------------
active=""
[ -f "$proj/.claude/maestro/active" ] && active="$(cat "$proj/.claude/maestro/active")"
if [ -n "$active" ] && [ -f "$proj/.claude/maestro/$active/state.json" ]; then
  set +e
  python3 - "$proj/.claude/maestro/$active/state.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        s = json.load(f)
except Exception:
    sys.exit(0)  # unreadable ledger fails open; the verify re-run below still gates

tier = s.get("tier", "full")
missing = []
if tier in ("standard", "full") and s.get("lastTesterVerdict") != "PASS":
    missing.append(f"tester PASS (have: {s.get('lastTesterVerdict')})")
if tier == "full":
    if not s.get("gate1Approved"):
        missing.append("Gate 1 plan approval")
    if s.get("lastReviewerVerdict") != "APPROVE":
        missing.append(f"reviewer APPROVE (have: {s.get('lastReviewerVerdict')})")
if missing:
    sys.stderr.write(
        f"BLOCKED: tier '{tier}' DoD not met for task '{s.get('slug')}': "
        + "; ".join(missing) + "\n"
        "Run the missing stage and record it (task-record.sh), or escalate honestly.\n")
    sys.exit(2)
sys.exit(0)
PY
  _dod_exit=$?
  set -e
  [ "$_dod_exit" -ne 0 ] && exit "$_dod_exit"
fi

# --- Layer 2: re-run the verify command (ground truth) ---------------------------
VERIFY="${MAESTRO_VERIFY:-}"
if [ -z "$VERIFY" ] && [ -f "$proj/.claude/maestro-verify" ]; then
  VERIFY="$(cat "$proj/.claude/maestro-verify")"
fi
[ -z "$VERIFY" ] && exit 0   # nothing to enforce

log="$(mktemp)"
if ! ( cd "$proj" && eval "$VERIFY" ) >"$log" 2>&1; then
  echo "BLOCKED: verify command failed — cannot commit." >&2
  echo "  verify: $VERIFY" >&2
  tail -n 20 "$log" >&2
  rm -f "$log"
  exit 2
fi
rm -f "$log"

# Stamp the successful run so stop-dod.sh knows the tree was verified.
python3 - "$proj" "$VERIFY" <<'PY' 2>/dev/null || true
import datetime, json, os, sys
root, cmd = sys.argv[1], sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc)
os.makedirs(os.path.join(root, ".claude", "maestro"), exist_ok=True)
path = os.path.join(root, ".claude", "maestro", "last-verify.json")
tmp = f"{path}.{os.getpid()}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump({"ts": now.isoformat().replace("+00:00", "Z"),
               "epoch": int(now.timestamp()), "exit": 0, "cmd": cmd}, f, indent=2)
os.replace(tmp, path)
PY
exit 0
