#!/usr/bin/env bash
# Run the verify command and record the GROUND-TRUTH result in the ledger.
# This is the only writer of `verify` events and `.claude/maestro/last-verify.json`,
# so a recorded pass always means "the command really exited 0" — not an LLM's claim.
#
# Usage: task-verify.sh                  run .claude/maestro-verify (or $MAESTRO_VERIFY)
#        task-verify.sh -- <command...>  run an explicit command instead
# Exits with the verify command's own exit code.
set -u

root="${CLAUDE_PROJECT_DIR:-$PWD}"

cmd=""
if [ "${1:-}" = "--" ]; then
  shift
  cmd="$*"
else
  cmd="${MAESTRO_VERIFY:-}"
  [ -z "$cmd" ] && [ -f "$root/.claude/maestro-verify" ] && cmd="$(cat "$root/.claude/maestro-verify")"
fi
if [ -z "$cmd" ]; then
  echo "no verify command (.claude/maestro-verify, \$MAESTRO_VERIFY, or 'task-verify.sh -- <cmd>')" >&2
  exit 1
fi

log="$(mktemp)"
start_epoch="$(date +%s)"
set +e
( cd "$root" && eval "$cmd" ) >"$log" 2>&1
code=$?
set -e
dur=$(( $(date +%s) - start_epoch ))

slug=""
[ -f "$root/.claude/maestro/active" ] && slug="$(cat "$root/.claude/maestro/active")"

python3 - "$root" "$slug" "$code" "$dur" "$cmd" <<'PY'
import datetime, json, os, sys
root, slug, code, dur, cmd = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.isoformat().replace("+00:00", "Z")
rec = {"ts": ts, "epoch": int(now.timestamp()), "exit": code, "cmd": cmd, "durationSec": dur}

def write_json_atomic(path, obj):
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)
    os.replace(tmp, path)

os.makedirs(os.path.join(root, ".claude", "maestro"), exist_ok=True)
write_json_atomic(os.path.join(root, ".claude", "maestro", "last-verify.json"), rec)

if slug:
    dir = os.path.join(root, ".claude", "maestro", slug)
    if os.path.isdir(dir):
        with open(os.path.join(dir, "log.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": ts, "event": "verify", "exit": code,
                                "durationSec": dur}, separators=(",", ":")) + "\n")
        sp = os.path.join(dir, "state.json")
        try:
            with open(sp, "r", encoding="utf-8") as f:
                state = json.load(f)
            state["lastVerify"] = {"ts": ts, "exit": code}
            state["updatedAt"] = ts
            write_json_atomic(sp, state)
        except Exception:
            pass
PY

if [ "$code" -eq 0 ]; then
  echo "VERIFY PASS (${dur}s): $cmd"
else
  echo "VERIFY FAIL exit=$code (${dur}s): $cmd"
  echo "--- last 40 lines ---"
  tail -n 40 "$log"
fi
rm -f "$log"
exit "$code"
