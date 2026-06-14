#!/usr/bin/env bash
# The continual-learning cadence body. Invoked by stop-dod AFTER its DoD decision, ONLY on
# the non-blocking pass path. This is trigger #2 of the learning loop: when enough work has
# accumulated, MARK a distill due and emit a non-blocking nudge so the CTO runs the consolidator.
#
# Gate (all three must hold): completed turns >= N  AND  minutes since last distill >= M  AND
# the transcript mtime advanced past the recorded watermark. It receives the SAME stop-hook
# stdin JSON as stop-dod (transcript_path, stop_hook_active). If transcript_path is absent it
# falls back to the ledger log.jsonl mtime via task-distill.sh.
#
# It NEVER returns a blocking exit code — learning must never get between the founder and a
# finished turn. Respects maestro-direct and stop_hook_active, exactly like stop-dod.
#
# Tunables (env overrides; defaults match the founder-approved cadence):
#   MAESTRO_DISTILL_TURNS    turns threshold N   (default 10)
#   MAESTRO_DISTILL_MINUTES  minutes threshold M (default 20)
set -u
_src="${BASH_SOURCE[0]}"; while [ -L "$_src" ]; do _src="$(readlink "$_src")"; done
HERE="$(cd "$(dirname "$_src")" && pwd)"
. "$HERE/lib-log.sh" 2>/dev/null && mlog_init distill-cadence Stop || true

# Every exit on this path is non-blocking. A trap guarantees that even an unexpected error
# inside the body cannot turn into a blocking (exit 2) code on the Stop hook.
trap 'exit 0' EXIT

input="$(cat 2>/dev/null || true)"
proj="${CLAUDE_PROJECT_DIR:-$PWD}"

# Same two escape hatches stop-dod honors: a block-loop guard and the founder's direct mode.
sha="$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
[ "$sha" = "true" ] && exit 0
[ -f "$proj/.claude/maestro-direct" ] && exit 0
# Continual-learning kill switch — distill-off suppresses the cadence entirely.
[ -e "$proj/.claude/maestro/distill-off" ] && exit 0

# Resolve the script dir: in the deployed tree hooks sit at .claude/hooks while scripts sit
# at .claude/skills/maestro/scripts; in the source repo both sit under maestro/. Try both.
distill=""
for c in "$HERE/../scripts/task-distill.sh" "$HERE/../skills/maestro/scripts/task-distill.sh"; do
  [ -f "$c" ] && { distill="$c"; break; }
done
[ -z "$distill" ] && exit 0  # mechanism absent — learning is best-effort, never required

TURNS_N="${MAESTRO_DISTILL_TURNS:-10}"
MIN_M="${MAESTRO_DISTILL_MINUTES:-20}"
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
# The conversation id scopes this lane watermark so parallel conversations do not clobber each
# other. The stop payload carries session_id; fall back to conversation_id, else the default key.
conv_id="$(printf '%s' "$input" | jq -r '.session_id // .conversation_id // empty' 2>/dev/null || true)"

# The gate is computed in python (clean integer math, fail-open on any surprise). It only
# DECIDES; it does not write. On a green decision the bash side marks due + nudges.
decision="$(MAESTRO_TRANSCRIPT="$transcript" MAESTRO_PROJ="$proj" MAESTRO_CONV="$conv_id" \
  MAESTRO_TURNS_N="$TURNS_N" MAESTRO_MIN_M="$MIN_M" python3 - <<'PY' 2>/dev/null || true
import json, os, time

proj = os.environ.get("MAESTRO_PROJ", "")
transcript = os.environ.get("MAESTRO_TRANSCRIPT", "")
conv = os.environ.get("MAESTRO_CONV", "") or "__default__"
try:
    N = int(os.environ.get("MAESTRO_TURNS_N", "10"))
    M = int(os.environ.get("MAESTRO_MIN_M", "20"))
except ValueError:
    raise SystemExit  # bad override -> fail-open, no fire

statefile = os.path.join(proj, ".claude", "maestro", "distill-state.json")
st = {"conversations": {}, "lastDistillEpoch": 0}
try:
    with open(statefile, encoding="utf-8") as f:
        loaded = json.load(f)
    if isinstance(loaded, dict):
        st.update(loaded)
except Exception:
    pass
convs = st.get("conversations", {}) or {}
watermark = int(convs.get(conv, 0))

# Transcript mtime, or the ledger log.jsonl as fallback when the key is absent.
src = transcript
if not (src and os.path.exists(src)):
    active = ""
    ap = os.path.join(proj, ".claude", "maestro", "active")
    try:
        with open(ap, encoding="utf-8") as f:
            active = f.read().strip()
    except Exception:
        active = ""
    cand = os.path.join(proj, ".claude", "maestro", active, "log.jsonl") if active else ""
    src = cand if (cand and os.path.exists(cand)) else ""

if not src:
    raise SystemExit  # nothing to measure -> no fire
mtime = int(os.path.getmtime(src))

# Condition A: transcript advanced past this conversation lane watermark.
advanced = mtime > watermark

# Condition B: minutes since last distill >= M. No prior distill -> treat as infinite (passes).
last = int(st.get("lastDistillEpoch", 0))
minutes = (time.time() - last) / 60.0 if last > 0 else float("inf")

# Condition C: completed turns >= N. Count assistant turns in a JSONL transcript when present;
# without a real transcript we cannot count, so the ledger-fallback path treats the gate as
# turn-met only when an explicit override makes N<=0 (tests), else relies on A+B advancing.
turns = 0
if transcript and os.path.exists(transcript):
    try:
        with open(transcript, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                t = obj.get("type") or obj.get("role")
                if t in ("assistant", "agent"):
                    turns += 1
    except Exception:
        turns = 0
turns_met = (turns >= N) if (transcript and os.path.exists(transcript)) else (N <= 0)

print("FIRE" if (advanced and (minutes >= M) and turns_met) else "SKIP")
PY
)"

[ "$decision" = "FIRE" ] || exit 0

# Fire: mark the cadence due and emit a single non-blocking nudge. We do NOT advance the
# watermark here — that happens when the consolidator actually runs (task-distill.sh advance),
# so a missed run stays due instead of being silently consumed.
"$distill" mark-due __cadence__ cadence >/dev/null 2>&1 || true
printf 'Continual-learning cadence reached: a distill pass is due. Run /maestro learn (or %s) to mine durable learnings.\n' \
  "$distill" >&2
exit 0
