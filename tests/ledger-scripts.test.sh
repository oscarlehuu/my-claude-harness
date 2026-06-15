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

# --- PHASED MODE (roadmap #9): phase events transition the state.phases map -------------------
# task-plan.sh seeds the map; phase_started -> in-progress, phase_done -> done; an unknown phase id
# is rejected (never auto-create a ghost phase). All run in this same mkrepo ledger.
"$SCRIPTS/task-init.sh" phased full "phased task" "bash check.sh" >/dev/null
cat > phase-spec.json <<'JSON'
{ "phases": [
  { "id": "p-one", "risk": "high", "goal": "first" },
  { "id": "p-two", "deps": ["p-one"], "risk": "low", "goal": "second" }
] }
JSON
"$SCRIPTS/task-plan.sh" phase-spec.json >/dev/null
assert_file_exists .claude/maestro/phased/phases/phase-01-p-one/phase.md "task-plan scaffolds the topo-first phase dir"
assert_contains "$(cat .claude/maestro/phased/state.json)" '"p-one"' "task-plan seeds the phases map in state.json"

"$SCRIPTS/task-record.sh" phase_started phase=p-one >/dev/null
assert_contains "$(cat .claude/maestro/phased/state.json)" '"status": "in-progress"' "phase_started -> in-progress"
"$SCRIPTS/task-record.sh" phase_done phase=p-one >/dev/null
# p-one is now done; p-two still pending. Confirm the done transition landed.
phased_state="$(python3 -c "import json;print(json.load(open('.claude/maestro/phased/state.json'))['phases']['p-one']['status'])")"
assert_contains "$phased_state" "done" "phase_done -> done"

set +e
"$SCRIPTS/task-record.sh" phase_done phase=ghost-id >/dev/null 2>&1; unknown_phase=$?
set -e
[ "$unknown_phase" -ne 0 ] && _result ok "phase_done for an unknown phase id is rejected (non-zero)" \
  || _result fail "phase_done for an unknown phase id is rejected (non-zero)" "ghost id was accepted"

set +e
"$SCRIPTS/task-record.sh" phase_started >/dev/null 2>&1; missing_phase_arg=$?
set -e
[ "$missing_phase_arg" -ne 0 ] && _result ok "phase_started without phase= is rejected" \
  || _result fail "phase_started without phase= is rejected" "missing phase= was accepted"

# --- PHASED task-status: k/N strip + plan-DoD blocked until all phases done -------------------
# Make every plan-level gate GREEN (gate1 + verify + tester + reviewer + verdicts archived) so the
# ONLY remaining blocker is the unfinished phases — proving plan-DoD blocks on phases alone.
"$SCRIPTS/task-record.sh" gate1_approved >/dev/null
"$SCRIPTS/task-verify.sh" >/dev/null           # check.sh exits 0 here
"$SCRIPTS/task-record.sh" tester_verdict verdict=PASS >/dev/null
"$SCRIPTS/task-record.sh" reviewer_verdict verdict=APPROVE >/dev/null
mkdir -p .claude/maestro/phased/verdicts
printf 'PASS\n' > .claude/maestro/phased/verdicts/round-1-tester.md

set +e; out_phased="$("$SCRIPTS/task-status.sh" phased 2>&1)"; phased_block=$?; set -e
assert_contains "$out_phased" "Phases: 1/2 done" "phased task renders the k/N strip"
assert_contains "$out_phased" "All phases done (plan-DoD)" "phased task carries the plan-DoD row"
assert_exit 1 "$phased_block" "plan-DoD BLOCKED while a phase is pending even with verify+gates green"

# Finish the last phase → plan-DoD clears (every gate now green).
"$SCRIPTS/task-record.sh" phase_done phase=p-two >/dev/null
"$SCRIPTS/task-verify.sh" >/dev/null
set +e; out_done="$("$SCRIPTS/task-status.sh" phased 2>&1)"; phased_ok=$?; set -e
assert_contains "$out_done" "Phases: 2/2 done" "phased task strip shows all done"
assert_exit 0 "$phased_ok" "plan-DoD clears once all phases done + gates green"

# --- task-plan refusals: cycle, dangling dep, duplicate, re-scaffold, malformed spec ---------
"$SCRIPTS/task-init.sh" cyc full "cycle task" "bash check.sh" >/dev/null
cat > cyc-spec.json <<'JSON'
{ "phases": [ { "id": "a", "deps": ["b"] }, { "id": "b", "deps": ["a"] } ] }
JSON
set +e; "$SCRIPTS/task-plan.sh" --slug cyc cyc-spec.json >/dev/null 2>&1; cyc_ec=$?; set -e
[ "$cyc_ec" -ne 0 ] && _result ok "task-plan: 2-node dependency cycle exits non-zero" \
  || _result fail "task-plan: 2-node dependency cycle exits non-zero" "cycle was accepted"
assert_file_absent .claude/maestro/cyc/phases "task-plan: cycle writes NO phases/ dir (no half-scaffold)"

cat > dangle-spec.json <<'JSON'
{ "phases": [ { "id": "a", "deps": ["ghost"] } ] }
JSON
set +e; "$SCRIPTS/task-plan.sh" --slug cyc dangle-spec.json >/dev/null 2>&1; dangle_ec=$?; set -e
[ "$dangle_ec" -ne 0 ] && _result ok "task-plan: dangling dependency exits non-zero" \
  || _result fail "task-plan: dangling dependency exits non-zero" "dangling dep was accepted"

cat > dup-spec.json <<'JSON'
{ "phases": [ { "id": "a" }, { "id": "a" } ] }
JSON
set +e; "$SCRIPTS/task-plan.sh" --slug cyc dup-spec.json >/dev/null 2>&1; dup_ec=$?; set -e
[ "$dup_ec" -ne 0 ] && _result ok "task-plan: duplicate phase id exits non-zero" \
  || _result fail "task-plan: duplicate phase id exits non-zero" "duplicate id was accepted"

printf 'not valid json' > bad-spec.json
set +e; "$SCRIPTS/task-plan.sh" --slug cyc bad-spec.json >/dev/null 2>&1; bad_ec=$?; set -e
[ "$bad_ec" -ne 0 ] && _result ok "task-plan: malformed spec exits non-zero" \
  || _result fail "task-plan: malformed spec exits non-zero" "malformed spec was accepted"

# re-scaffold over an existing phases/ tree is refused (would wipe in-flight status). The `phased`
# task already has phases/ from above; target it explicitly (active now points at `cyc`).
set +e; "$SCRIPTS/task-plan.sh" --slug phased phase-spec.json >/dev/null 2>&1; rescaffold_ec=$?; set -e
[ "$rescaffold_ec" -ne 0 ] && _result ok "task-plan: re-scaffold over existing phases/ is refused" \
  || _result fail "task-plan: re-scaffold over existing phases/ is refused" "re-scaffold clobbered"

# --- task-plan: corrupt/non-object state.json aborts BEFORE any dir (all-or-nothing scaffold) -----
# The state.json read+validate moved to the TOP (before os.makedirs) so a corrupt ledger leaves NO
# orphan phases/ tree that the re-plan guard would then refuse to recover. The spec here is VALID
# (phase-spec.json from above) — the ONLY fault is the corrupt ledger, isolating the read-order fix.
"$SCRIPTS/task-init.sh" corrupt full "corrupt-state task" "bash check.sh" >/dev/null
printf 'not a valid json object {{{' > .claude/maestro/corrupt/state.json
set +e; corrupt_out="$("$SCRIPTS/task-plan.sh" --slug corrupt phase-spec.json 2>&1)"; corrupt_ec=$?; set -e
[ "$corrupt_ec" -ne 0 ] && _result ok "task-plan: corrupt state.json exits non-zero" \
  || _result fail "task-plan: corrupt state.json exits non-zero" "corrupt state.json was accepted"
assert_file_absent .claude/maestro/corrupt/phases "task-plan: corrupt state.json writes NO phases/ dir (no orphan tree)"
assert_not_contains "$corrupt_out" "Traceback" "task-plan: corrupt state.json fails clean (no python traceback)"

# A valid-JSON-but-non-object state.json (a list / scalar) is also rejected before any dir is made.
"$SCRIPTS/task-init.sh" nonobj full "non-object-state task" "bash check.sh" >/dev/null
printf '[1, 2, 3]' > .claude/maestro/nonobj/state.json
set +e; "$SCRIPTS/task-plan.sh" --slug nonobj phase-spec.json >/dev/null 2>&1; nonobj_ec=$?; set -e
[ "$nonobj_ec" -ne 0 ] && _result ok "task-plan: non-object state.json exits non-zero" \
  || _result fail "task-plan: non-object state.json exits non-zero" "non-object state.json was accepted"
assert_file_absent .claude/maestro/nonobj/phases "task-plan: non-object state.json writes NO phases/ dir"

summary "ledger-scripts"
