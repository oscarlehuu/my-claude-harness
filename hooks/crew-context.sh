#!/usr/bin/env bash
# SubagentStart hook — inject maestro ledger ground truth into crew subagents.
#
# The GOAL handoff is the crew's world, but it depends on the CTO writing it well.
# This hook removes that dependency for harness facts: every crew member gets the
# open task's slug/tier/round, the verify command, and its role contract reminder —
# read from the ledger at fire time, not from anyone's memory.
# Non-crew agents get nothing (exit 0, no output). Read-only; always exit 0.

input="$(cat 2>/dev/null || true)"
_src="${BASH_SOURCE[0]}"; while [ -L "$_src" ]; do _src="$(readlink "$_src")"; done
. "$(cd "$(dirname "$_src")" && pwd)/lib-log.sh" 2>/dev/null && mlog_init crew-context SubagentStart || true

[ -z "$input" ] && exit 0

MAESTRO_HOOK_INPUT="$input" python3 - <<'PY'
import json, os, sys

CREW = {"developer", "ui-developer", "tester", "reviewer", "planner", "scout"}

try:
    payload = json.loads(os.environ.get("MAESTRO_HOOK_INPUT", "") or "{}")
except Exception:
    sys.exit(0)

role = (payload.get("agent_type") or "").strip()
if role not in CREW:
    sys.exit(0)  # not a maestro crew member — stay silent

proj = (payload.get("cwd") or "").strip() or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
mdir = os.path.join(proj, ".claude", "maestro")

def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return ""

lines = [f"[maestro] You are the {role} crew member of the maestro harness."]

# Open task ground truth from the ledger
slug = read(os.path.join(mdir, "active"))
state = None
if slug:
    try:
        with open(os.path.join(mdir, slug, "state.json"), encoding="utf-8") as f:
            state = json.load(f)
    except Exception:
        state = None
if state:
    lv = state.get("lastVerify")
    verify_state = "never ran" if not lv else ("green" if lv.get("exit") == 0 else f"FAILING (exit {lv.get('exit')})")
    lines.append(f"Open task: '{state.get('slug')}' — tier {state.get('tier')}, "
                 f"round {state.get('round')}, verify {verify_state}. "
                 f"Ledger: .claude/maestro/{state.get('slug')}/")
else:
    lines.append("No open maestro task ledger in this repo.")

verify_cmd = read(os.path.join(proj, ".claude", "maestro-verify"))
if verify_cmd:
    lines.append(f"Verify command (exit code = ground truth): {verify_cmd}")

# Role contract reminders — one or two lines each, the load-bearing rules only
if role in ("developer", "ui-developer"):
    lines.append("Edge-case discipline is MANDATORY: enumerate cases before coding, turn applicable "
                 "ones into tests, self-review the diff against your list; report the edge-case "
                 "ledger in ## Notes.")
    lines.append("You cannot ask the founder. If truly blocked on a material decision, end with: "
                 "NEEDS DECISION: <question> (recommended default: <x>).")
elif role == "tester":
    lines.append("Adversarial, default-refuted, read-only. A non-zero verify exit is FAIL regardless "
                 "of your opinion. Demand the developer's edge-case ledger — a lazy ledger is itself "
                 "a FAIL signal. End with: VERDICT: PASS|FAIL|PARTIAL|BLOCKED.")
elif role == "reviewer":
    lines.append("Read-only ship-risk review of the diff. End with: REVIEW: APPROVE|REQUEST_CHANGES. "
                 "Inconclusive output blocks strict DoD — be decisive.")

# Blind-mode knowledge file (planner/scout grounding)
if role in ("planner", "scout") and os.path.exists(os.path.join(mdir, "knowledge.md")):
    lines.append("Blind-mode knowledge file exists: .claude/maestro/knowledge.md — read it FIRST "
                 "(date-stamped hints from past tickets; re-verify before relying).")

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SubagentStart",
        "additionalContext": "\n".join(lines),
    }
}))
PY
exit 0
