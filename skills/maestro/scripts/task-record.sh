#!/usr/bin/env bash
# Append an event to the active task's ledger and mirror the latest values into state.json
# so hooks can read them cheaply. JSON is always written by python — never by hand.
#
# Usage: task-record.sh [--slug <slug>] <event> [key=value ...]
#
# Events the harness understands (anything else is logged as a plain note):
#   gate1_approved                       founder approved the plan (full tier)
#   tester_verdict   verdict=PASS|FAIL|PARTIAL|BLOCKED [summary="..."]
#   reviewer_verdict verdict=APPROVE|REQUEST_CHANGES|INCONCLUSIVE [summary="..."]
#   tier_escalated   tier=standard|full reason="..."    (one-way: refuses downgrades)
#   round_started                        bump the round counter (fix loop)
#   gate2_approved                       founder approved ship
#   task_done | escalated                close the task, clear the active pointer
#   note             text="..."          freeform breadcrumb
set -eu

root="${CLAUDE_PROJECT_DIR:-$PWD}"
slug=""
if [ "${1:-}" = "--slug" ]; then slug="${2:?--slug needs a value}"; shift 2; fi
event="${1:?usage: task-record.sh [--slug <slug>] <event> [key=value ...]}"
shift

if [ -z "$slug" ]; then
  [ -f "$root/.claude/maestro/active" ] && slug="$(cat "$root/.claude/maestro/active")"
fi
[ -z "$slug" ] && { echo "no active task — run task-init.sh first or pass --slug" >&2; exit 1; }

dir="$root/.claude/maestro/$slug"
[ -f "$dir/state.json" ] && [ -d "$dir" ] || { echo "no ledger for '$slug' at $dir" >&2; exit 1; }

python3 - "$dir" "$root" "$slug" "$event" "$@" <<'PY'
import datetime, json, os, sys

dir, root, slug, event = sys.argv[1:5]
kv = {}
for arg in sys.argv[5:]:
    if "=" in arg:
        k, v = arg.split("=", 1)
        kv[k] = v

TIERS = ["light", "standard", "full"]
ts = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
state_path = os.path.join(dir, "state.json")
with open(state_path, "r", encoding="utf-8") as f:
    state = json.load(f)

closing = False
if event == "tester_verdict":
    v = kv.get("verdict", "").upper()
    if v not in {"PASS", "FAIL", "PARTIAL", "BLOCKED"}:
        sys.exit(f"tester_verdict needs verdict=PASS|FAIL|PARTIAL|BLOCKED (got '{v}')")
    kv["verdict"] = v
    state["lastTesterVerdict"] = v
elif event == "reviewer_verdict":
    v = kv.get("verdict", "").upper()
    if v not in {"APPROVE", "REQUEST_CHANGES", "INCONCLUSIVE"}:
        sys.exit(f"reviewer_verdict needs verdict=APPROVE|REQUEST_CHANGES|INCONCLUSIVE (got '{v}')")
    kv["verdict"] = v
    state["lastReviewerVerdict"] = v
elif event == "tier_escalated":
    new = kv.get("tier", "")
    if new not in TIERS:
        sys.exit(f"tier_escalated needs tier=standard|full (got '{new}')")
    if TIERS.index(new) <= TIERS.index(state["tier"]):
        sys.exit(f"refusing tier downgrade {state['tier']} -> {new}: the ratchet is one-way. "
                 "If the tier is genuinely too heavy, ask the founder.")
    state["tier"] = new
elif event == "gate1_approved":
    state["gate1Approved"] = True
elif event == "round_started":
    state["round"] = int(state.get("round", 1)) + 1
    # a new dev round invalidates previous judgments — they judged the old diff
    state["lastTesterVerdict"] = None
    state["lastReviewerVerdict"] = None
elif event in {"task_done", "escalated"}:
    state["state"] = "done" if event == "task_done" else "escalated"
    closing = True

state["updatedAt"] = ts
with open(state_path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
with open(os.path.join(dir, "log.jsonl"), "a", encoding="utf-8") as f:
    f.write(json.dumps({"ts": ts, "event": event, **kv}, separators=(",", ":")) + "\n")

if closing:
    active = os.path.join(root, ".claude", "maestro", "active")
    try:
        with open(active, "r", encoding="utf-8") as f:
            if f.read().strip() == slug:
                os.remove(active)
    except FileNotFoundError:
        pass

print(f"recorded {event} on '{slug}'" + (f" (tier now {state['tier']})" if event == "tier_escalated" else ""))
PY
