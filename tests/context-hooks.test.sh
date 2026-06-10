#!/usr/bin/env bash
# Context-injection hooks: maestro-engage (SessionStart) and crew-context (SubagentStart).
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mkrepo

# --- maestro-engage: no task ----------------------------------------------------
run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_exit 0 "$HOOK_EXIT" "engage exits 0"
assert_contains "$HOOK_OUT" "CTO mode" "engage states CTO mode"
assert_contains "$HOOK_OUT" "No open maestro task" "engage reports no open task"

# --- maestro-engage: open task + compact + direct -------------------------------
printf 'exit 1\n' > check.sh
"$SCRIPTS/task-init.sh" engage-task standard "engage test" "bash check.sh" >/dev/null
set +e; "$SCRIPTS/task-verify.sh" >/dev/null 2>&1; set -e
run_hook "$HOOKS/maestro-engage.sh" '{"source":"compact"}'
assert_contains "$HOOK_OUT" "Context was just compacted" "engage flags compact source"
assert_contains "$HOOK_OUT" "OPEN TASK: 'engage-task'" "engage reports open task from ledger"
assert_contains "$HOOK_OUT" "FAILING (exit 1)" "engage reports failing verify state"

echo 1 > .claude/maestro-direct
run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_contains "$HOOK_OUT" "DIRECT-EDIT mode" "engage reports direct mode"
rm .claude/maestro-direct

# --- crew-context: roles --------------------------------------------------------
dev_payload="{\"agent_type\":\"developer\",\"cwd\":\"$REPO\"}"
run_hook "$HOOKS/crew-context.sh" "$dev_payload"
assert_exit 0 "$HOOK_EXIT" "crew-context exits 0"
ctx="$(json_field "$HOOK_OUT" "d['hookSpecificOutput']['additionalContext']")"
assert_contains "$ctx" "developer crew member" "developer identified"
assert_contains "$ctx" "engage-task" "developer sees open task from ledger"
assert_contains "$ctx" "Edge-case discipline is MANDATORY" "developer gets edge-case contract"
assert_contains "$ctx" "NEEDS DECISION" "developer gets escalation protocol"

run_hook "$HOOKS/crew-context.sh" "{\"agent_type\":\"tester\",\"cwd\":\"$REPO\"}"
ctx="$(json_field "$HOOK_OUT" "d['hookSpecificOutput']['additionalContext']")"
assert_contains "$ctx" "VERDICT: PASS|FAIL|PARTIAL|BLOCKED" "tester gets verdict contract"
assert_contains "$ctx" "edge-case ledger" "tester told to demand the edge-case ledger"

run_hook "$HOOKS/crew-context.sh" "{\"agent_type\":\"reviewer\",\"cwd\":\"$REPO\"}"
ctx="$(json_field "$HOOK_OUT" "d['hookSpecificOutput']['additionalContext']")"
assert_contains "$ctx" "REVIEW: APPROVE|REQUEST_CHANGES" "reviewer gets review contract"

# blind-mode knowledge file pointer for scout/planner
echo "Q/A" > .claude/maestro/knowledge.md
run_hook "$HOOKS/crew-context.sh" "{\"agent_type\":\"scout\",\"cwd\":\"$REPO\"}"
ctx="$(json_field "$HOOK_OUT" "d['hookSpecificOutput']['additionalContext']")"
assert_contains "$ctx" "knowledge.md" "scout pointed at knowledge file"

# non-crew agents stay silent
run_hook "$HOOKS/crew-context.sh" "{\"agent_type\":\"Explore\",\"cwd\":\"$REPO\"}"
assert_exit 0 "$HOOK_EXIT" "non-crew agent exits 0"
[ -z "$HOOK_OUT" ] && _result ok "non-crew agent gets no injection" || _result fail "non-crew agent gets no injection" "got: $HOOK_OUT"

# malformed payload fails open
run_hook "$HOOKS/crew-context.sh" 'not-json'
assert_exit 0 "$HOOK_EXIT" "malformed payload fails open"

summary "context-hooks"
