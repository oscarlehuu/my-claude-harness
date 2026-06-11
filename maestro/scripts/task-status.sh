#!/usr/bin/env bash
# Render the tier-aware Definition of Done from the ledger — by code, not by discipline.
# Paste this output at Gate 2 instead of hand-writing the checklist.
#
# Usage: task-status.sh [slug]      (defaults to the active task)
# Exit 0 = every DoD item required by the tier is satisfied; exit 1 = something blocks.
set -eu

root="${CLAUDE_PROJECT_DIR:-$PWD}"
slug="${1:-}"
if [ -z "$slug" ]; then
  [ -f "$root/.claude/maestro/active" ] && slug="$(cat "$root/.claude/maestro/active")"
fi
[ -z "$slug" ] && { echo "no active task and no slug given" >&2; exit 1; }

dir="$root/.claude/maestro/$slug"
[ -f "$dir/state.json" ] || { echo "no ledger for '$slug'" >&2; exit 1; }

python3 - "$dir" <<'PY'
import json, os, sys
dir = sys.argv[1]
with open(os.path.join(dir, "state.json"), "r", encoding="utf-8") as f:
    s = json.load(f)

tier = s.get("tier", "full")
checks = []  # (label, status: True/False/None=n/a, detail)

lv = s.get("lastVerify")
if lv is None:
    checks.append(("Verify command green", False, "never ran — run task-verify.sh"))
else:
    ok = lv.get("exit") == 0
    checks.append(("Verify command green", ok, f"exit {lv.get('exit')} @ {lv.get('ts')}"))

if tier in ("standard", "full"):
    v = s.get("lastTesterVerdict")
    checks.append(("Tester verdict PASS", v == "PASS", v or "no verdict this round"))
else:
    checks.append(("Tester verdict PASS", None, "n/a at light tier"))

if tier == "full":
    checks.append(("Plan approved (Gate 1)", bool(s.get("gate1Approved")), ""))
    rv = s.get("lastReviewerVerdict")
    checks.append(("Reviewer APPROVE", rv == "APPROVE", rv or "no review this round"))
    # Only judged full-tier tasks owe archived verdicts — if no judge ran, no row.
    if s.get("lastTesterVerdict") or s.get("lastReviewerVerdict"):
        vd = os.path.join(dir, "verdicts")
        archived = os.path.isdir(vd) and bool(os.listdir(vd))
        checks.append(("Judge verdicts archived", archived,
                       "" if archived else "save reports verbatim to verdicts/"))
else:
    checks.append(("Plan approved (Gate 1)", None, "n/a below full tier"))
    checks.append(("Reviewer APPROVE", None, "n/a below full tier"))

print(f"Task: {s.get('slug')}   Tier: {tier}   State: {s.get('state')}   Round: {s.get('round')}")
print(f"  {s.get('task','')}")
print("Definition of Done:")
blockers = []
for label, ok, detail in checks:
    mark = "-" if ok is None else ("v" if ok else "x")
    suffix = f"  ({detail})" if detail else ""
    print(f"  [{mark}] {label}{suffix}")
    if ok is False:
        blockers.append(f"{label}: {detail}" if detail else label)
print("  [x] Founder ship approval  (always pending until the founder approves)")
if blockers:
    print("Blockers: " + "; ".join(blockers))
    sys.exit(1)
print("Blockers: none — ready for founder approval")
sys.exit(0)
PY
