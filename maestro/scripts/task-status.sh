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

# Resolve this script's own real dir (readlink loop, the harness idiom) so we can import the sibling
# questions_gate.py (the shared blocking predicate) regardless of cwd or symlinks.
_src="${BASH_SOURCE[0]}"; while [ -L "$_src" ]; do _src="$(readlink "$_src")"; done
SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"

MAESTRO_SCRIPT_DIR="$SCRIPT_DIR" python3 - "$dir" <<'PY'
import json, os, sys
dir = sys.argv[1]
sys.path.insert(0, os.environ["MAESTRO_SCRIPT_DIR"])
import questions_gate as g  # shared blocking predicate — never re-implemented here
with open(os.path.join(dir, "state.json"), "r", encoding="utf-8") as f:
    s = json.load(f)

tier = s.get("tier", "full")
checks = []  # (label, status: True/False/None=n/a, detail)

# Open-Questions gate — applies at EVERY tier (a load-bearing unknown is dangerous at any size).
# A corrupt sheet is a hard blocker, not a silent pass (an unreadable ledger of unknowns is itself
# an unknown). The predicate is questions_gate.is_blocking — the SAME one task-record uses to refuse
# gate1_approved — so the rendered blocker and the hard refusal can never disagree.
oq_corrupt = None
try:
    oq = g.load(dir)
    oq_blockers = g.blocking(oq)
    oq_open, oq_resolved, oq_answered = g.counts(oq)
except g.CorruptSheet as e:
    oq, oq_blockers, oq_corrupt = [], [], str(e)
    oq_open = oq_resolved = oq_answered = 0
if oq_corrupt is not None:
    checks.append(("Open-Questions gate", False, f"questions.json unreadable ({oq_corrupt}) — fix or rm"))
elif oq_blockers:
    ids = ", ".join(f"{q.get('id')} [{q.get('route')}/{q.get('cost')}/{q.get('status')}]"
                    for q in oq_blockers)
    checks.append(("Open-Questions gate", False, f"{len(oq_blockers)} blocking: {ids}"))
elif oq:
    checks.append(("Open-Questions gate", True,
                   f"open {oq_open}, resolved {oq_resolved}, answered {oq_answered} — none blocking"))
else:
    checks.append(("Open-Questions gate", True, "none"))

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

# Full Open-Questions listing (the DoD line carries only ids for brevity; here the CTO sees the
# actual question text so it knows WHAT to clear). Only printed when a sheet exists.
if oq or oq_corrupt is not None:
    print(f"Open questions: open {oq_open}, resolved {oq_resolved}, answered {oq_answered}"
          + (f"  [{len(oq_blockers)} BLOCKING]" if oq_blockers else ""))
    for q in oq:
        mark = "BLOCK" if g.is_blocking(q) else " ok  "
        res = f"  -> {q.get('resolution')}" if q.get("resolution") else ""
        print(f"  [{mark}] {q.get('id')}  {q.get('route')}/{q.get('cost')}/{q.get('status')}"
              f"  {q.get('text')}{res}")

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
