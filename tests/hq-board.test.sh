#!/usr/bin/env bash
# HQ layer: queue-add + team-board (cross-repo standup aggregation).
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Build a fake HQ + one registered repo with a live ledger.
HQ="$(mktemp -d "${TMPDIR:-/tmp}/maestro-hq-XXXXXX")"
export MAESTRO_HQ="$HQ"
mkdir -p "$HQ/board/queue"

mkrepo   # sets $REPO + CLAUDE_PROJECT_DIR
printf 'exit 1\n' > check.sh
"$SCRIPTS/task-init.sh" oculus-spike standard "Oculus spike" "bash check.sh" >/dev/null
set +e; "$SCRIPTS/task-verify.sh" >/dev/null 2>&1; set -e

python3 - "$HQ" "$REPO" <<'PY'
import json, os, sys
hq, repo = sys.argv[1], sys.argv[2]
with open(os.path.join(hq, "registry.json"), "w") as f:
    json.dump({"repos": [{"name": "demo-repo", "path": repo}]}, f)
PY

# --- queue-add -------------------------------------------------------------------
"$SCRIPTS/queue-add.sh" "Build the Oculus kanban view" --repo demo-repo --tier standard >/dev/null
count="$(ls "$HQ/board/queue/"*.json | wc -l | tr -d ' ')"
[ "$count" = "1" ] && _result ok "queue-add writes one task file" || _result fail "queue-add writes one task file" "got $count"
assert_contains "$(cat "$HQ"/board/queue/*.json)" '"status": "queued"' "queued task has status field"

set +e
"$SCRIPTS/queue-add.sh" "bad" --tier mega >/dev/null 2>&1; badtier=$?
set -e
[ "$badtier" -ne 0 ] && _result ok "queue-add rejects invalid tier" || _result fail "queue-add rejects invalid tier" "accepted"

# --- team-board ------------------------------------------------------------------
out="$("$SCRIPTS/team-board.sh")"
assert_contains "$out" "QUEUE (1)" "board counts the queue"
assert_contains "$out" "Build the Oculus kanban view" "board lists queued task"
assert_contains "$out" "demo-repo/oculus-spike" "board aggregates registered repo ledger"
assert_contains "$out" "RED(1)" "board surfaces failing verify"
assert_contains "$out" "NEEDS YOU (1)" "failing task lands in NEEDS YOU"

"$SCRIPTS/team-board.sh" --write >/dev/null
assert_file_exists "$HQ/BOARD.md" "--write renders BOARD.md in HQ"

# green verify clears NEEDS YOU
printf 'exit 0\n' > check.sh
"$SCRIPTS/task-verify.sh" >/dev/null
out="$("$SCRIPTS/team-board.sh")"
assert_contains "$out" "nothing blocked on you" "green verify clears NEEDS YOU"

# no HQ configured → graceful error
set +e
MAESTRO_HQ="/nonexistent-hq-dir" "$SCRIPTS/team-board.sh" >/dev/null 2>&1; nohq=$?
set -e
[ "$nohq" -ne 0 ] && _result ok "missing HQ fails gracefully" || _result fail "missing HQ fails gracefully" "exit 0"

rm -rf "$HQ"
summary "hq-board"
