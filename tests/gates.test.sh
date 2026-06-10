#!/usr/bin/env bash
# Enforcement gates: commit-gate (tier DoD + verify re-run) and stop-dod.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mkrepo
printf 'exit 0\n' > check.sh
"$SCRIPTS/task-init.sh" gate-task standard "gate test" "bash check.sh" >/dev/null

commit_payload='{"tool_input":{"command":"git commit -m x"}}'

# --- commit-gate ---------------------------------------------------------------
run_hook "$HOOKS/commit-gate.sh" '{"tool_input":{"command":"ls -la"}}'
assert_exit 0 "$HOOK_EXIT" "commit-gate ignores non-commit bash"

run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 2 "$HOOK_EXIT" "commit-gate blocks standard tier without tester PASS"
assert_contains "$HOOK_ERR" "tester PASS" "block message names the missing DoD item"

"$SCRIPTS/task-record.sh" tester_verdict verdict=PASS >/dev/null
run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 0 "$HOOK_EXIT" "commit-gate allows when tier DoD met and verify green"

printf 'exit 1\n' > check.sh
run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 2 "$HOOK_EXIT" "commit-gate re-runs verify: red verify blocks even with PASS recorded"
printf 'exit 0\n' > check.sh

"$SCRIPTS/task-record.sh" round_started >/dev/null
run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 2 "$HOOK_EXIT" "stale verdict from previous round does not satisfy commit-gate"

# full tier: needs gate1 + reviewer too
"$SCRIPTS/task-record.sh" tier_escalated tier=full reason=x >/dev/null
"$SCRIPTS/task-record.sh" tester_verdict verdict=PASS >/dev/null
run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 2 "$HOOK_EXIT" "full tier blocks without Gate 1 + reviewer"
"$SCRIPTS/task-record.sh" gate1_approved >/dev/null
"$SCRIPTS/task-record.sh" reviewer_verdict verdict=APPROVE >/dev/null
run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 0 "$HOOK_EXIT" "full tier allows with tester PASS + Gate 1 + reviewer APPROVE"
"$SCRIPTS/task-record.sh" task_done >/dev/null

# --- stop-dod -------------------------------------------------------------------
sleep 1 && echo "code" > app.py
run_hook "$HOOKS/stop-dod.sh" '{"stop_hook_active":false}'
assert_exit 2 "$HOOK_EXIT" "stop-dod blocks unverified code change"

run_hook "$HOOKS/stop-dod.sh" '{"stop_hook_active":true}'
assert_exit 0 "$HOOK_EXIT" "stop-dod loop guard: second stop passes"

"$SCRIPTS/task-verify.sh" >/dev/null
run_hook "$HOOKS/stop-dod.sh" '{"stop_hook_active":false}'
assert_exit 0 "$HOOK_EXIT" "stop-dod passes after green verify"

sleep 1 && echo "notes" > README.md
run_hook "$HOOKS/stop-dod.sh" '{"stop_hook_active":false}'
assert_exit 0 "$HOOK_EXIT" "prose-only change never trips stop-dod"

sleep 1 && echo "more code" >> app.py
echo 1 > .claude/maestro-direct
run_hook "$HOOKS/stop-dod.sh" '{"stop_hook_active":false}'
assert_exit 0 "$HOOK_EXIT" "direct-edit mode disables stop-dod"
rm .claude/maestro-direct

summary "gates"
