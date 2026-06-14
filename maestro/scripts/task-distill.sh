#!/usr/bin/env bash
# The deterministic index behind the process-centric continual-learning loop. Shared by all three
# triggers (task-close, the stop-dod cadence, manual /maestro learn). It does NOT call an LLM: it
# maintains the watermarks + due markers, then the CTO spawns the CONSOLIDATOR step to dedup/route/
# stamp the warm lessons and the conversation delta through learned-write.sh.
#
# TWO watermarks, split by scope (a repo runs 2-3 parallel lanes, so concurrent conversations must
# not clobber each other):
#   - CONVERSATION watermark — this file, distill-state.json, a MAP keyed by conversation_id:
#       { "conversations": { "<conversation_id>": <transcript-mtime-epoch>, ... },
#         "lastDistillEpoch": <epoch>, "due": { "<slug>": "<reason>", "__cadence__": "cadence" } }
#     A missing/empty conversation_id uses the reserved "__default__" key (the ledger-fallback path).
#   - The per-TASK "consolidated" flag lives in <slug>/state.json (task-record.sh), NOT here, so it
#     is task-scoped and auto-cleaned with the task dir.
#
# KILL SWITCH: a visible marker .claude/maestro/distill-off (mirror registry-nudge-off) suppresses
# every trigger — mark-due no-ops, due-since reports nothing due — and the consolidator no-ops.
#
# Subcommands:
#   mark-due <slug> [reason]              record that <slug> needs consolidation (off-switch -> no-op)
#   status [conversation_id]             print the watermark(s) + what is due (exit 0)
#   advance [transcript-path] [conv_id]  move THAT conversation's watermark to the input mtime IF it
#                                        advanced; prints "advanced" or "noop". Falls back to the
#                                        ledger log.jsonl mtime + __default__ key when no path given.
#   due-since                            exit 0 if anything is due, 1 if not (off-switch -> 1)
#
# Every write is atomic (temp+rename) so a concurrent hook never reads a half file.
set -eu

root="${CLAUDE_PROJECT_DIR:-$PWD}"
statefile="$root/.claude/maestro/distill-state.json"
offswitch="$root/.claude/maestro/distill-off"
sub="${1:?usage: task-distill.sh <mark-due|status|advance|due-since> ...}"
shift || true

# Resolve the transcript path the triggers care about. The cadence hook passes the path it read
# from the stop-hook stdin; everything else falls back to the active task's append-only ledger log,
# which advances on every recorded event, so the watermark still moves without a transcript.
ledger_log() {
  local active
  [ -f "$root/.claude/maestro/active" ] && active="$(cat "$root/.claude/maestro/active")" || active=""
  [ -n "$active" ] && [ -f "$root/.claude/maestro/$active/log.jsonl" ] \
    && { printf '%s' "$root/.claude/maestro/$active/log.jsonl"; return 0; }
  return 1
}

case "$sub" in
  mark-due)
    slug="${1:?usage: task-distill.sh mark-due <slug> [reason]}"
    reason="${2:-task-close}"
    # Kill switch: suppress the trigger entirely (still exit 0 so a caller's `|| true` is happy).
    [ -e "$offswitch" ] && { echo "distill-off present — not marking due"; exit 0; }
    python3 - "$statefile" "$slug" "$reason" <<'PY'
import json, os, sys
statefile, slug, reason = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(os.path.dirname(statefile), exist_ok=True)
st = {"conversations": {}, "lastDistillEpoch": 0, "due": {}}
try:
    with open(statefile, encoding="utf-8") as f:
        loaded = json.load(f)
    if isinstance(loaded, dict):
        st.update(loaded)
        st.setdefault("due", {})
        st.setdefault("conversations", {})
except Exception:
    pass  # corrupt/absent state is rebuilt, never fatal
st["due"][slug] = reason
tmp = f"{statefile}.{os.getpid()}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(st, f, indent=2)
os.replace(tmp, statefile)
print(f"marked distill due: {slug} ({reason})")
PY
    ;;

  status)
    conv="${1:-}"
    python3 - "$statefile" "$conv" <<'PY'
import json, sys
statefile, conv = sys.argv[1], sys.argv[2]
try:
    with open(statefile, encoding="utf-8") as f:
        st = json.load(f)
except Exception:
    st = {"conversations": {}, "lastDistillEpoch": 0, "due": {}}
convs = st.get("conversations", {}) or {}
due = st.get("due", {}) or {}
print(f"lastDistill: {st.get('lastDistillEpoch', 0)}")
if conv:
    print(f"watermark[{conv}]: {convs.get(conv, 0)}")
else:
    if convs:
        print("conversation watermarks:")
        for cid, wm in convs.items():
            print(f"  - {cid}: {wm}")
    else:
        print("conversation watermarks: none")
if due:
    print("due:")
    for slug, reason in due.items():
        print(f"  - {slug} ({reason})")
else:
    print("due: nothing")
PY
    ;;

  due-since)
    # Kill switch: with distill-off present, nothing is ever due (the consolidator no-ops).
    [ -e "$offswitch" ] && exit 1
    python3 - "$statefile" <<'PY'
import json, sys
statefile = sys.argv[1]
try:
    with open(statefile, encoding="utf-8") as f:
        st = json.load(f)
except Exception:
    st = {}
sys.exit(0 if (st.get("due") or {}) else 1)
PY
    ;;

  advance)
    src="${1:-}"
    conv="${2:-}"
    if [ -z "$src" ]; then src="$(ledger_log || true)"; fi
    python3 - "$statefile" "$src" "$conv" <<'PY'
import json, os, sys, time
statefile, src, conv = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(os.path.dirname(statefile), exist_ok=True)
st = {"conversations": {}, "lastDistillEpoch": 0, "due": {}}
try:
    with open(statefile, encoding="utf-8") as f:
        loaded = json.load(f)
    if isinstance(loaded, dict):
        st.update(loaded)
        st.setdefault("due", {})
        st.setdefault("conversations", {})
except Exception:
    pass

# A missing/empty conversation_id maps to the reserved __default__ key so a trigger without an id
# (the ledger-fallback path) still advances WITHOUT clobbering any keyed conversation's watermark.
key = conv if conv else "__default__"
convs = st.setdefault("conversations", {})

now = int(time.time())
mtime = 0
if src and os.path.exists(src):
    try:
        mtime = int(os.path.getmtime(src))
    except Exception:
        mtime = 0

# Only NEW/changed input advances THIS conversation's watermark — unchanged input is a no-op, and
# advancing one conversation_id never touches another's entry. This is the per-lane incremental
# contract: consolidating the same delta twice extracts nothing new, and parallel lanes are isolated.
if mtime > int(convs.get(key, 0)):
    convs[key] = mtime
    st["lastDistillEpoch"] = now
    st["due"] = {}  # a completed pass clears the due markers it satisfied
    result = "advanced"
else:
    result = "noop"

tmp = f"{statefile}.{os.getpid()}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(st, f, indent=2)
os.replace(tmp, statefile)
print(result)
PY
    ;;

  *)
    echo "unknown subcommand '$sub' (mark-due|status|advance|due-since)" >&2
    exit 1
    ;;
esac
