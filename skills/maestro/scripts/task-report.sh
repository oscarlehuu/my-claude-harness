#!/usr/bin/env bash
# Measure the harness on real usage: read every task ledger + the guard log in this repo
# and break down where time and friction actually went. Read-only.
#
# Usage: task-report.sh [repo-root]     (defaults to $CLAUDE_PROJECT_DIR, then $PWD)
#
# Per task: tier (+escalations), state, rounds, verify runs/fails/time, verdicts, wall-clock.
# Aggregate: counts by tier/state, verify totals, guard blocks by reason (budget vs protected).
# Use it to answer: which tier do tasks really land in? where do rounds burn? is the budget
# tripping people at the boundary (raise it) or catching real scope creep (keep it)?
set -eu

root="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
dir="$root/.claude/maestro"
[ -d "$dir" ] || { echo "no maestro ledger at $dir" >&2; exit 1; }

python3 - "$dir" <<'PY'
import datetime, json, os, sys

dir = sys.argv[1]

def parse_ts(ts):
    try:
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except Exception:
        return None

def fmt_dur(seconds):
    if seconds is None:
        return "?"
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds//60}m{seconds%60:02d}s"
    return f"{seconds//3600}h{(seconds%3600)//60:02d}m"

tasks = []
for slug in sorted(os.listdir(dir)):
    tdir = os.path.join(dir, slug)
    state_path = os.path.join(tdir, "state.json")
    if not os.path.isdir(tdir) or not os.path.exists(state_path):
        continue
    try:
        with open(state_path, encoding="utf-8") as f:
            state = json.load(f)
    except Exception:
        continue
    events = []
    try:
        with open(os.path.join(tdir, "log.jsonl"), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        events.append(json.loads(line))
                    except Exception:
                        pass
    except FileNotFoundError:
        pass

    init_tier = next((e.get("tier") for e in events if e.get("event") == "task_init"), state.get("tier"))
    escalations = [e for e in events if e.get("event") == "tier_escalated"]
    verifies = [e for e in events if e.get("event") == "verify"]
    v_fails = [e for e in verifies if e.get("exit") != 0]
    stamps = [t for t in (parse_ts(e.get("ts", "")) for e in events) if t]
    wall = (stamps[-1] - stamps[0]).total_seconds() if len(stamps) >= 2 else None
    tier_str = init_tier or "?"
    if escalations:
        tier_str += "->" + "->".join(e.get("tier", "?") for e in escalations)
    tasks.append({
        "slug": slug, "tier": tier_str, "final_tier": state.get("tier"),
        "state": state.get("state", "?"), "rounds": state.get("round", 1),
        "verify_runs": len(verifies), "verify_fails": len(v_fails),
        "verify_time": sum(e.get("durationSec", 0) for e in verifies),
        "tester": state.get("lastTesterVerdict"), "reviewer": state.get("lastReviewerVerdict"),
        "wall": wall, "escalated": len(escalations),
    })

if not tasks:
    print("no task ledgers found")
else:
    w = max(len(t["slug"]) for t in tasks)
    w = min(max(w, 4), 48)
    print(f"{'task':<{w}}  {'tier':<16} {'state':<11} {'rnd':>3} {'verify':>9} {'v-time':>7} {'wall':>7}  verdicts")
    for t in tasks:
        slug = t["slug"][:w]
        vr = f"{t['verify_runs']}({t['verify_fails']}F)" if t["verify_fails"] else str(t["verify_runs"])
        verd = " ".join(filter(None, [
            f"tester:{t['tester']}" if t["tester"] else None,
            f"review:{t['reviewer']}" if t["reviewer"] else None])) or "-"
        print(f"{slug:<{w}}  {t['tier']:<16} {t['state']:<11} {t['rounds']:>3} {vr:>9} "
              f"{fmt_dur(t['verify_time']):>7} {fmt_dur(t['wall']):>7}  {verd}")

    print()
    by_tier, by_state = {}, {}
    for t in tasks:
        by_tier[t["final_tier"] or "?"] = by_tier.get(t["final_tier"] or "?", 0) + 1
        by_state[t["state"]] = by_state.get(t["state"], 0) + 1
    total_rounds = sum(t["rounds"] for t in tasks)
    print(f"tasks: {len(tasks)}  "
          f"by tier: {', '.join(f'{k}={v}' for k, v in sorted(by_tier.items()))}  "
          f"by state: {', '.join(f'{k}={v}' for k, v in sorted(by_state.items()))}")
    print(f"rounds: {total_rounds} total, {total_rounds/len(tasks):.1f}/task   "
          f"verify: {sum(t['verify_runs'] for t in tasks)} runs, "
          f"{sum(t['verify_fails'] for t in tasks)} fails, "
          f"{fmt_dur(sum(t['verify_time'] for t in tasks))} total   "
          f"escalations: {sum(t['escalated'] for t in tasks)}")

# Guard friction: blocks by reason, and how far over budget they were.
guard_path = os.path.join(dir, "guard-log.jsonl")
blocks = []
if os.path.exists(guard_path):
    with open(guard_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    blocks.append(json.loads(line))
                except Exception:
                    pass
print()
if not blocks:
    print("guard blocks: none recorded")
else:
    budget = [b for b in blocks if b.get("reason") == "budget"]
    protected = [b for b in blocks if b.get("reason") == "protected"]
    print(f"guard blocks: {len(blocks)} (budget={len(budget)}, protected={len(protected)})")
    if budget:
        lines_used = sorted(b.get("lines_used", 0) for b in budget)
        near = sum(1 for n in lines_used if n <= 75)  # within 1.5x of the default 50
        print(f"  budget blocks at lines used: min={lines_used[0]} "
              f"median={lines_used[len(lines_used)//2]} max={lines_used[-1]}; "
              f"{near}/{len(budget)} within 1.5x of 50 (mostly-near misses -> consider raising LINES; "
              f"mostly-far -> the budget is catching real scope creep)")
PY
