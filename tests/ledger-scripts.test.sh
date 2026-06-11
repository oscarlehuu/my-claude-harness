#!/usr/bin/env bash
# Ledger scripts: task-init, task-record (ratchet, verdicts, lifecycle), task-verify, task-status.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mkrepo

# --- task-init ---------------------------------------------------------------
set +e
"$SCRIPTS/task-init.sh" Bad_Slug light "x" >/dev/null 2>&1; bad_slug=$?
"$SCRIPTS/task-init.sh" ok-slug mega "x" >/dev/null 2>&1; bad_tier=$?
set -e
assert_exit 1 "$bad_slug" "task-init rejects non-kebab slug"
assert_exit 1 "$bad_tier" "task-init rejects unknown tier"

"$SCRIPTS/task-init.sh" demo light "demo task" "bash check.sh" >/dev/null
assert_file_exists .claude/maestro/demo/state.json "task-init writes state.json"
assert_contains "$(cat .claude/maestro/active)" "demo" "task-init sets active pointer"
assert_contains "$(cat .claude/maestro-verify)" "bash check.sh" "task-init writes verify command"

set +e
"$SCRIPTS/task-init.sh" demo light "again" >/dev/null 2>&1; dup=$?
set -e
assert_exit 1 "$dup" "task-init refuses duplicate slug"

# --- task-verify: ground truth recording --------------------------------------
printf 'exit 1\n' > check.sh
set +e; "$SCRIPTS/task-verify.sh" >/dev/null 2>&1; vfail=$?; set -e
assert_exit 1 "$vfail" "task-verify propagates failing exit code"
assert_contains "$(cat .claude/maestro/last-verify.json)" '"exit": 1' "failing verify recorded as ground truth"

printf 'exit 0\n' > check.sh
"$SCRIPTS/task-verify.sh" >/dev/null
assert_contains "$(cat .claude/maestro/demo/state.json)" '"exit": 0' "green verify mirrored into state.json"

# --- task-status: tier-aware DoD ----------------------------------------------
set +e; "$SCRIPTS/task-status.sh" >/dev/null 2>&1; light_ok=$?; set -e
assert_exit 0 "$light_ok" "light tier DoD met with green verify only"

# --- task-record: ratchet is one-way -------------------------------------------
"$SCRIPTS/task-record.sh" tier_escalated tier=standard reason="grew" >/dev/null
assert_contains "$(cat .claude/maestro/demo/state.json)" '"tier": "standard"' "escalation recorded"
set +e
"$SCRIPTS/task-record.sh" tier_escalated tier=light reason="nah" >/dev/null 2>&1; down=$?
set -e
[ "$down" -ne 0 ] && _result ok "ratchet refuses downgrade" || _result fail "ratchet refuses downgrade" "downgrade was accepted"

set +e; "$SCRIPTS/task-status.sh" >/dev/null 2>&1; std_block=$?; set -e
assert_exit 1 "$std_block" "standard tier blocks without tester PASS"

# --- task-record: verdict validation + round reset ------------------------------
set +e
"$SCRIPTS/task-record.sh" tester_verdict verdict=MAYBE >/dev/null 2>&1; badv=$?
set -e
[ "$badv" -ne 0 ] && _result ok "invalid tester verdict rejected" || _result fail "invalid tester verdict rejected" "MAYBE accepted"

"$SCRIPTS/task-record.sh" tester_verdict verdict=PASS summary="ok" >/dev/null
set +e; "$SCRIPTS/task-status.sh" >/dev/null 2>&1; std_ok=$?; set -e
assert_exit 0 "$std_ok" "standard tier DoD met with tester PASS"

"$SCRIPTS/task-record.sh" round_started >/dev/null
assert_contains "$(cat .claude/maestro/demo/state.json)" '"lastTesterVerdict": null' "new round invalidates stale verdicts"
assert_contains "$(cat .claude/maestro/demo/state.json)" '"round": 2' "round counter bumped"

# --- lifecycle: close clears the active pointer ---------------------------------
"$SCRIPTS/task-record.sh" tester_verdict verdict=PASS >/dev/null
"$SCRIPTS/task-record.sh" task_done >/dev/null
assert_file_absent .claude/maestro/active "task_done clears active pointer"
assert_contains "$(cat .claude/maestro/demo/state.json)" '"state": "done"' "task closed in state.json"

# --- task-status: "Judge verdicts archived" DoD row (full tier, judged tasks) ----
# Full tier + a tester verdict but no verdicts/ dir → row present, [x].
"$SCRIPTS/task-init.sh" judged full "judged task" "bash check.sh" >/dev/null
"$SCRIPTS/task-record.sh" gate1_approved >/dev/null
"$SCRIPTS/task-verify.sh" >/dev/null   # check.sh currently exits 0
"$SCRIPTS/task-record.sh" tester_verdict verdict=PASS >/dev/null
"$SCRIPTS/task-record.sh" reviewer_verdict verdict=APPROVE >/dev/null
set +e; out_missing="$("$SCRIPTS/task-status.sh" 2>&1)"; set -e
assert_contains "$out_missing" "[x] Judge verdicts archived" "missing verdicts/ → row present and unmet"
assert_contains "$out_missing" "save reports verbatim to verdicts/" "row carries the archive hint"

# Empty verdicts/ dir is the same as missing → still [x].
mkdir -p .claude/maestro/judged/verdicts
set +e; out_empty="$("$SCRIPTS/task-status.sh" 2>&1)"; set -e
assert_contains "$out_empty" "[x] Judge verdicts archived" "empty verdicts/ → row present and unmet"

# A saved verdict file flips the row to [v].
printf 'VERDICT: PASS\n' > .claude/maestro/judged/verdicts/round-1-tester.md
set +e; out_full="$("$SCRIPTS/task-status.sh" 2>&1)"; set -e
assert_contains "$out_full" "[v] Judge verdicts archived" "non-empty verdicts/ → row met"

# Lower tiers never carry the row — light-tier task, even with a verdict path, has none.
"$SCRIPTS/task-init.sh" lightjob light "light task" "bash check.sh" >/dev/null
"$SCRIPTS/task-verify.sh" >/dev/null
set +e; out_light="$("$SCRIPTS/task-status.sh" 2>&1)"; set -e
assert_not_contains "$out_light" "Judge verdicts archived" "light tier → row absent"

summary "ledger-scripts"
