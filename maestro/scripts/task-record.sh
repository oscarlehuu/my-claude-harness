#!/usr/bin/env bash
# Append an event to the active task's ledger and mirror the latest values into state.json
# so hooks can read them cheaply. JSON is always written by python — never by hand.
#
# Usage: task-record.sh [--slug <slug>] <event> [key=value ...]
#
# Events the harness understands (anything else is logged as a plain note):
#   gate1_approved                       founder approved the plan (full tier)
#                                        REFUSED while any Open-Questions blocker remains (the teeth)
#   tester_verdict   verdict=PASS|FAIL|PARTIAL|BLOCKED [summary="..."]
#   reviewer_verdict verdict=APPROVE|REQUEST_CHANGES|INCONCLUSIVE [summary="..."]
#   tier_escalated   tier=standard|full reason="..."    (one-way: refuses downgrades)
#   round_started                        bump the round counter (fix loop)
#   phase_started    phase=<id>          a phased-mode phase begins (-> in-progress in state.phases)
#   phase_done       phase=<id>          a phased-mode phase finishes (-> done in state.phases)
#                                        BOTH refuse an unknown phase id (the map is seeded by
#                                        task-plan.sh; transitions never create a ghost phase)
#   gate2_approved                       founder approved ship
#   task_done | escalated                close the task, clear the active pointer
#   consolidated                         the continual-learning consolidator finished this task
#   lesson           summary="..."       a warm learning (defect + suspected component) for retro
#   note             text="..."          freeform breadcrumb
#
# Open-Questions gate (its own sheet, .claude/maestro/<slug>/questions.json — NOT state.json):
#   question add "<text>" route=<code|history|founder|team|planner> [cost=<low|med|high>]
#   question resolve <id> cite="<file:line or note>"   (CTO/scout resolved by investigation)
#   question answer  <id> note="<founder/team answer>"  (a routed question got its answer)
#   question list                                       (human-readable dump)
# The blocking predicate (questions_gate.py, shared with task-status) is the gate's heart; a blocker
# hard-refuses gate1_approved above.
#
# `lesson` is logged like any other event (event=="lesson" in log.jsonl) — it is the SINGLE
# learning store the retro loop reads. Warm lessons emitted by the crew are recorded here, not in
# any parallel file.
set -eu

# Resolve this script's own real dir (readlink loop, the harness idiom) so the question subcommand
# and the gate1 refusal can import the sibling questions_gate.py regardless of cwd or symlinks.
_src="${BASH_SOURCE[0]}"; while [ -L "$_src" ]; do _src="$(readlink "$_src")"; done
SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"

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

# --- Open-Questions sheet: `question add|resolve|answer|list` -------------------------------------
# Handled BEFORE the generic event path because questions live in their own questions.json, never in
# state.json. All JSON is written by python (house rule); the sheet write is atomic (temp+replace).
if [ "$event" = "question" ]; then
  qsub="${1:?usage: task-record.sh question <add|resolve|answer|list> ...}"
  shift
  MAESTRO_SCRIPT_DIR="$SCRIPT_DIR" python3 - "$dir" "$qsub" "$@" <<'PY'
import datetime, json, os, sys
sys.path.insert(0, os.environ["MAESTRO_SCRIPT_DIR"])
import questions_gate as g  # noqa: E402

dir, qsub = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
# Flag-key-AWARE parse (NOT "any token containing '=' is a flag" — the generic kv idiom). The
# question TEXT is a positional that legitimately contains '=' (e.g. "is a==b allowed?"), so only a
# token whose part-before-'=' is a KNOWN flag key is a flag; everything else is positional. This
# also lets a value carry '=' (`note="x=y"`) since we still split on the FIRST '='.
FLAG_KEYS = ("route", "cost", "cite", "note")
kv = {}
positional = []
for a in args:
    if "=" in a and a.split("=", 1)[0] in FLAG_KEYS:
        k, v = a.split("=", 1)
        kv[k] = v
    else:
        positional.append(a)

ts = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
path = g.questions_path(dir)

# Load existing sheet; a corrupt sheet must not be silently overwritten (it may hold real unknowns).
try:
    questions = g.load(dir)
except g.CorruptSheet as e:
    sys.exit(f"questions.json is unreadable ({e}) — fix or remove it before recording questions")


def save():
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(questions, f, indent=2)
    os.replace(tmp, path)


def find(qid):
    for q in questions:
        if q.get("id") == qid:
            return q
    return None


if qsub == "add":
    text = positional[0] if positional else ""
    if not text.strip():
        sys.exit('question add needs non-empty text: question add "<text>" route=<...> [cost=<...>]')
    route = kv.get("route")
    if route not in g.ROUTES:
        sys.exit(f"question add needs route={'|'.join(g.ROUTES)} (got {route!r})")
    cost = kv.get("cost", g.DEFAULT_COST)   # default high = safe (torn → high → block)
    if cost not in g.COSTS:
        sys.exit(f"question add needs cost={'|'.join(g.COSTS)} (got {kv.get('cost')!r})")
    # Auto-id: max existing numeric suffix + 1 (not len+1 — stays unique even past a future deletion).
    nums = []
    for q in questions:
        qid = str(q.get("id", ""))
        if qid.startswith("q") and qid[1:].isdigit():
            nums.append(int(qid[1:]))
    qid = f"q{(max(nums) + 1) if nums else 1}"
    questions.append({"id": qid, "text": text, "route": route, "cost": cost,
                      "status": "open", "resolution": "", "ts": ts})
    save()
    print(f"added {qid} (route={route} cost={cost}, open) to questions.json")

elif qsub in ("resolve", "answer"):
    qid = positional[0] if positional else None
    if not qid:
        sys.exit(f"question {qsub} needs an id: question {qsub} <id> "
                 + ("cite=\"...\"" if qsub == "resolve" else "note=\"...\""))
    q = find(qid)
    if q is None:
        sys.exit(f"no such question {qid!r} in questions.json")
    if qsub == "resolve":
        q["status"] = "resolved"
        q["resolution"] = kv.get("cite", "")
    else:  # answer
        q["status"] = "answered"
        q["resolution"] = kv.get("note", "")
    save()
    print(f"{qid} -> {q['status']}")

elif qsub == "list":
    if not questions:
        print("no open questions (questions.json absent or empty) — gate trivially clean")
    else:
        o, r, a = g.counts(questions)
        print(f"questions.json — open {o}, resolved {r}, answered {a}:")
        for q in questions:
            mark = "BLOCK" if g.is_blocking(q) else "  ok "
            res = f"  [{q.get('resolution')}]" if q.get("resolution") else ""
            print(f"  [{mark}] {q.get('id')}  {q.get('route')}/{q.get('cost')}/{q.get('status')}"
                  f"  {q.get('text')}{res}")

else:
    sys.exit(f"unknown question subcommand {qsub!r} (add|resolve|answer|list)")
PY
  exit $?
fi

# --- THE TEETH: gate1_approved hard-refuses while any Open-Questions blocker remains --------------
# This runs BEFORE the generic event writer below, so an unclean sheet appends NOTHING (no
# gate1_approved event in log.jsonl, gate1Approved stays false in state.json) — the refusal is
# atomic. A clean sheet (or no sheet) falls through and records normally. The predicate is the
# SHARED questions_gate.is_blocking — the same one task-status renders — so the visible blocker and
# the hard refusal can never disagree. A corrupt sheet refuses too (an unreadable ledger of unknowns
# is itself an unknown; failing open here would silently approve over hidden blockers).
if [ "$event" = "gate1_approved" ]; then
  if ! MAESTRO_SCRIPT_DIR="$SCRIPT_DIR" python3 - "$dir" <<'PY'
import os, sys
sys.path.insert(0, os.environ["MAESTRO_SCRIPT_DIR"])
import questions_gate as g  # noqa: E402

task_dir = sys.argv[1]
try:
    questions = g.load(task_dir)
except g.CorruptSheet as e:
    sys.stderr.write(f"REFUSED gate1_approved: questions.json is unreadable ({e}). "
                     "Fix or remove it, then re-approve.\n")
    sys.exit(1)

blockers = g.blocking(questions)
if blockers:
    sys.stderr.write("REFUSED gate1_approved: the Open-Questions sheet is not clean. "
                     "Resolve (code/history: investigate + cite) or get the founder to answer "
                     "(high-cost founder/team) these, then re-approve:\n")
    for q in blockers:
        sys.stderr.write(f"  - {q.get('id')} [{q.get('route')}/{q.get('cost')}/{q.get('status')}] "
                         f"{q.get('text')}\n")
    sys.stderr.write("    clear with: task-record.sh question resolve <id> cite=\"...\"  "
                     "OR  question answer <id> note=\"...\"\n")
    sys.exit(1)
sys.exit(0)
PY
  then
    exit 1
  fi
fi

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
elif event in {"phase_started", "phase_done"}:
    # Phased mode (roadmap #9): transition ONE phase's status in the state.phases map. The map is
    # seeded by task-plan.sh at scaffold; these events only move an EXISTING phase along
    # pending -> in-progress -> done. Recording for an id NOT in the map fails non-zero — never
    # auto-create a ghost phase, or a typo'd id would silently never be counted toward plan-DoD.
    phase_id = kv.get("phase", "")
    if not phase_id:
        sys.exit(f"{event} needs phase=<id> (the phase to transition)")
    phases = state.get("phases")
    if not isinstance(phases, dict) or phase_id not in phases:
        known = ", ".join(sorted(phases)) if isinstance(phases, dict) and phases else "(none)"
        sys.exit(f"{event}: unknown phase id '{phase_id}' — not in state.phases. "
                 f"Known phases: {known}. Scaffold with task-plan.sh first.")
    entry = phases[phase_id]
    if not isinstance(entry, dict):
        sys.exit(f"{event}: phase '{phase_id}' entry is malformed in state.phases")
    entry["status"] = "in-progress" if event == "phase_started" else "done"
elif event in {"task_done", "escalated"}:
    state["state"] = "done" if event == "task_done" else "escalated"
    closing = True
elif event == "consolidated":
    # The continual-learning consolidator finished this task's warm channel. The flag lives in the
    # task's own state.json (not distill-state.json) so it is task-scoped and auto-cleaned with the
    # dir. Idempotent: setting it twice is a no-op; the log.jsonl event is the audit trail.
    state["consolidated"] = True

state["updatedAt"] = ts
tmp = f"{state_path}.{os.getpid()}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
os.replace(tmp, state_path)
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

# Trigger #1 of the continual-learning loop: a closing task marks itself due for consolidation.
# We use the script's own $slug (NOT the just-cleared `active` pointer) so the closed task is the
# one marked. Strictly fail-silent: a distill-marking error must NEVER fail the task close — the
# `|| true` and the script's own atomic/fail-open writes guarantee the close already succeeded above.
# The kill switch (distill-off) is honored inside task-distill.sh mark-due, so a suppressed trigger
# is a clean no-op here too.
if [ "$event" = "task_done" ] || [ "$event" = "escalated" ]; then
  _distill="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/task-distill.sh"
  [ -f "$_distill" ] && bash "$_distill" mark-due "$slug" "$event" >/dev/null 2>&1 || true
fi
