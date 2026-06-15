#!/usr/bin/env bash
# Open-Questions gate: questions.json sheet (task-record question add|resolve|answer|list), the
# deterministic cost-gated blocking predicate, the task-status blocker line, and the gate1_approved
# hard-refusal (the teeth). Black-box: drive the real scripts, assert on files + exit codes.
#
# House rule (learned the hard way): assertions must run in the MAIN shell, never inside a subshell
# or a pipeline's last stage — a subshell cannot mutate the parent's PASS/FAIL counters. So we
# capture command output/exit into a var with `set +e; ...; rc=$?; set -e` and assert afterwards.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QJSON() { cat ".claude/maestro/$1/questions.json" 2>/dev/null; }     # raw sheet contents for a slug
LOG()   { cat ".claude/maestro/$1/log.jsonl" 2>/dev/null; }         # event log for a slug
GATE1_COUNT() { grep -c '"event":"gate1_approved"' ".claude/maestro/$1/log.jsonl" 2>/dev/null || true; }
G1FLAG() { python3 -c "import json;print(json.load(open('.claude/maestro/$1/state.json'))['gate1Approved'])"; }
# QFIELD <slug> <q-index> <field> — load questions.json and print one field of one question. Used
# instead of raw-string matching for VALUES, because the writer uses the house ensure_ascii=True
# idiom (unicode is escaped to \uXXXX on disk), so a value must be checked via a real JSON read.
QFIELD() {
  python3 -c "import json;print(json.load(open('.claude/maestro/$1/questions.json'))[$2]['$3'])"
}

# ===========================================================================================
# test_question_add_creates_sheet — add writes questions.json with all fields + auto-id
# ===========================================================================================
mkrepo
"$SCRIPTS/task-init.sh" t1 full "q add" "true" >/dev/null
"$SCRIPTS/task-record.sh" question add "which database backs sessions?" route=code cost=high >/dev/null
assert_file_exists .claude/maestro/t1/questions.json "add creates questions.json"
q1="$(QJSON t1)"
assert_contains "$q1" '"id": "q1"' "first question gets auto-id q1"
assert_contains "$q1" '"text": "which database backs sessions?"' "text persisted"
assert_contains "$q1" '"route": "code"' "route persisted"
assert_contains "$q1" '"cost": "high"' "cost persisted"
assert_contains "$q1" '"status": "open"' "status starts open"
assert_contains "$q1" '"resolution": ""' "resolution starts empty"
assert_contains "$q1" '"ts"' "timestamp recorded"
# a second add increments the id
"$SCRIPTS/task-record.sh" question add "what is the retention window?" route=history cost=med >/dev/null
assert_contains "$(QJSON t1)" '"id": "q2"' "second question gets auto-id q2"

# ===========================================================================================
# test_default_cost_is_high — add without cost= defaults to high (safe; torn → high → block)
# ===========================================================================================
"$SCRIPTS/task-init.sh" tcost full "default cost" "true" >/dev/null
"$SCRIPTS/task-record.sh" question add "no cost given" route=founder >/dev/null
assert_contains "$(QJSON tcost)" '"cost": "high"' "missing cost= defaults to high (safe)"

# ===========================================================================================
# test_question_resolve_and_answer — status transitions resolve/answer work and persist
# ===========================================================================================
"$SCRIPTS/task-init.sh" t2 full "transitions" "true" >/dev/null
"$SCRIPTS/task-record.sh" question add "code q" route=code cost=high >/dev/null
"$SCRIPTS/task-record.sh" question add "founder q" route=founder cost=high >/dev/null
"$SCRIPTS/task-record.sh" question resolve q1 cite="auth.py:88 — JWT" >/dev/null
"$SCRIPTS/task-record.sh" question answer q2 note="use tier 2" >/dev/null
t2j="$(QJSON t2)"
assert_contains "$t2j" '"status": "resolved"' "resolve sets status=resolved"
assert_contains "$(QFIELD t2 0 resolution)" "auth.py:88 — JWT" "resolve persists the cite (round-trip)"
assert_contains "$t2j" '"status": "answered"' "answer sets status=answered"
assert_contains "$(QFIELD t2 1 resolution)" "use tier 2" "answer persists the note (round-trip)"

# ===========================================================================================
# input validation at the boundary (bad route / bad cost / empty text / unknown id)
# ===========================================================================================
"$SCRIPTS/task-init.sh" tval full "validation" "true" >/dev/null
set +e
"$SCRIPTS/task-record.sh" question add "x" route=fnounder cost=high >/dev/null 2>&1; bad_route=$?
"$SCRIPTS/task-record.sh" question add "x" route=code cost=medium >/dev/null 2>&1; bad_cost=$?
"$SCRIPTS/task-record.sh" question add "" route=code cost=high >/dev/null 2>&1; empty_text=$?
"$SCRIPTS/task-record.sh" question add "no route" cost=high >/dev/null 2>&1; no_route=$?
"$SCRIPTS/task-record.sh" question resolve q99 cite=x >/dev/null 2>&1; bad_id=$?
"$SCRIPTS/task-record.sh" question frobnicate >/dev/null 2>&1; bad_sub=$?
set -e
assert_exit 1 "$bad_route" "invalid route= rejected"
assert_exit 1 "$bad_cost" "invalid cost= rejected"
assert_exit 1 "$empty_text" "empty question text rejected"
assert_exit 1 "$no_route" "missing route= rejected (no safe default)"
assert_exit 1 "$bad_id" "resolve of unknown id rejected"
assert_exit 1 "$bad_sub" "unknown question subcommand rejected"
assert_file_absent .claude/maestro/tval/questions.json "no sheet written by any rejected add"

# round-trip of special characters: an '=' in the text and a unicode char survive (split-on-first-=).
# Checked via a JSON read, not raw-string match, because the on-disk form escapes unicode (house idiom).
"$SCRIPTS/task-record.sh" question add "is a==b allowed for café?" route=code cost=high >/dev/null
assert_contains "$(QFIELD tval 0 text)" "is a==b allowed for café?" "text with '=' and unicode round-trips"

# ===========================================================================================
# test_gate_blocks_high_cost_founder_open — founder+high+open: task-status BLOCKS, gate1 REFUSED,
# and NO gate1_approved event is appended (atomic refusal).
# ===========================================================================================
"$SCRIPTS/task-init.sh" tblk full "founder high blocks" "true" >/dev/null
"$SCRIPTS/task-record.sh" question add "what is the launch price?" route=founder cost=high >/dev/null
set +e; status_out="$("$SCRIPTS/task-status.sh" 2>&1)"; status_rc=$?; set -e
assert_exit 1 "$status_rc" "task-status exits 1 with a high-cost founder blocker"
assert_contains "$status_out" "Open-Questions gate" "task-status renders the Open-Questions gate line"
assert_contains "$status_out" "[x] Open-Questions gate" "the gate line is marked blocking"
assert_contains "$status_out" "q1" "the blocking question id is listed in task-status"
assert_contains "$status_out" "what is the launch price?" "the blocking question text is listed"
set +e; "$SCRIPTS/task-record.sh" gate1_approved >/dev/null 2>&1; g1_rc=$?; set -e
assert_exit 1 "$g1_rc" "gate1_approved REFUSED while a high-cost founder question is open"
assert_contains "$(GATE1_COUNT tblk)" "0" "no gate1_approved event appended on refusal (atomic)"
assert_contains "$(G1FLAG tblk)" "False" "state.gate1Approved stays false on refusal"

# ===========================================================================================
# test_gate_blocks_unresolved_investigation — a code (and history) +open question blocks until
# resolved. Parametrized over both investigation routes (they share the predicate branch).
# ===========================================================================================
for route in code history; do
  slug="tinv-$route"
  "$SCRIPTS/task-init.sh" "$slug" full "$route blocks" "true" >/dev/null
  "$SCRIPTS/task-record.sh" question add "$route unknown" route="$route" cost=low >/dev/null
  set +e; "$SCRIPTS/task-status.sh" >/dev/null 2>&1; rc_open=$?; set -e
  assert_exit 1 "$rc_open" "$route+open blocks task-status (even at low cost — investigation is mandatory)"
  set +e; "$SCRIPTS/task-record.sh" gate1_approved >/dev/null 2>&1; rc_g1=$?; set -e
  assert_exit 1 "$rc_g1" "$route+open refuses gate1_approved"
  "$SCRIPTS/task-record.sh" question resolve q1 cite="found it" >/dev/null
  set +e; "$SCRIPTS/task-record.sh" gate1_approved >/dev/null 2>&1; rc_g1b=$?; set -e
  assert_exit 0 "$rc_g1b" "$route question resolved → gate1_approved succeeds"
done

# ===========================================================================================
# test_high_cost_founder_resolve_does_not_clear — the predicate trap: a high-cost founder question
# marked merely "resolved" (CTO investigation) does NOT clear; it must be ANSWERED. Defends the
# exact wording of the locked design (status != "answered").
# ===========================================================================================
"$SCRIPTS/task-init.sh" ttrap full "resolve!=answer for founder high" "true" >/dev/null
"$SCRIPTS/task-record.sh" question add "founder call needed" route=founder cost=high >/dev/null
"$SCRIPTS/task-record.sh" question resolve q1 cite="I guessed" >/dev/null
set +e; "$SCRIPTS/task-record.sh" gate1_approved >/dev/null 2>&1; trap_rc=$?; set -e
assert_exit 1 "$trap_rc" "high-cost founder question RESOLVED (not answered) still blocks gate1"
"$SCRIPTS/task-record.sh" question answer q1 note="founder said X" >/dev/null
set +e; "$SCRIPTS/task-record.sh" gate1_approved >/dev/null 2>&1; trap_rc2=$?; set -e
assert_exit 0 "$trap_rc2" "the same question ANSWERED clears the gate"

# ===========================================================================================
# test_gate_allows_low_cost_founder_open — founder+low (and +med) open does NOT block.
# ===========================================================================================
"$SCRIPTS/task-init.sh" tlow full "low cost founder ok" "true" >/dev/null
"$SCRIPTS/task-record.sh" question add "minor preference?" route=founder cost=low >/dev/null
"$SCRIPTS/task-record.sh" question add "another preference?" route=team cost=med >/dev/null
set +e; "$SCRIPTS/task-record.sh" gate1_approved >/dev/null 2>&1; low_rc=$?; set -e
assert_exit 0 "$low_rc" "founder/team low+med cost open does NOT block (assume-unless-vetoed)"
assert_contains "$(GATE1_COUNT tlow)" "1" "gate1_approved event recorded when only low/med open remain"

# ===========================================================================================
# test_gate_allows_planner_routed — a planner-routed open question never blocks (plan's job).
# ===========================================================================================
"$SCRIPTS/task-init.sh" tpln full "planner routed ok" "true" >/dev/null
"$SCRIPTS/task-record.sh" question add "which sort algorithm?" route=planner cost=high >/dev/null
set +e; pln_status="$("$SCRIPTS/task-status.sh" 2>&1)"; set -e
assert_contains "$pln_status" "[v] Open-Questions gate" "planner-routed question leaves the gate clean"
set +e; "$SCRIPTS/task-record.sh" gate1_approved >/dev/null 2>&1; pln_rc=$?; set -e
assert_exit 0 "$pln_rc" "planner-routed (even high-cost) open does NOT block gate1_approved"

# ===========================================================================================
# test_gate_clean_after_resolve_answer — resolving the investigation Q + answering the high-cost
# founder Q clears the gate; gate1_approved then succeeds AND records the event.
# ===========================================================================================
"$SCRIPTS/task-init.sh" tclean full "drain then approve" "true" >/dev/null
"$SCRIPTS/task-record.sh" question add "where is the rate limiter?" route=code cost=high >/dev/null
"$SCRIPTS/task-record.sh" question add "what is the SLA target?" route=founder cost=high >/dev/null
set +e; "$SCRIPTS/task-record.sh" gate1_approved >/dev/null 2>&1; pre_rc=$?; set -e
assert_exit 1 "$pre_rc" "gate1 blocked before draining"
"$SCRIPTS/task-record.sh" question resolve q1 cite="middleware/ratelimit.py:12" >/dev/null
"$SCRIPTS/task-record.sh" question answer q2 note="99.9%" >/dev/null
set +e; status_clean="$("$SCRIPTS/task-status.sh" 2>&1)"; set -e
assert_contains "$status_clean" "[v] Open-Questions gate" "gate clean after resolve+answer"
set +e; "$SCRIPTS/task-record.sh" gate1_approved >/dev/null 2>&1; post_rc=$?; set -e
assert_exit 0 "$post_rc" "gate1_approved succeeds once the sheet is clean"
assert_contains "$(GATE1_COUNT tclean)" "1" "gate1_approved event IS recorded when clean"
assert_contains "$(G1FLAG tclean)" "True" "state.gate1Approved flips true when clean"

# ===========================================================================================
# no-sheet path: a task with NO questions.json is trivially clean (gate1 succeeds, status [v] none)
# ===========================================================================================
"$SCRIPTS/task-init.sh" tnone full "no sheet" "true" >/dev/null
set +e; none_status="$("$SCRIPTS/task-status.sh" 2>&1)"; set -e
assert_contains "$none_status" "[v] Open-Questions gate" "no questions.json → gate clean"
assert_contains "$none_status" "(none)" "no questions.json → 'none' detail"
set +e; "$SCRIPTS/task-record.sh" gate1_approved >/dev/null 2>&1; none_rc=$?; set -e
assert_exit 0 "$none_rc" "no questions.json → gate1_approved succeeds (trivially clean)"

# ===========================================================================================
# corrupt-sheet path: a malformed questions.json is a HARD blocker (never a silent pass).
# ===========================================================================================
"$SCRIPTS/task-init.sh" tcorrupt full "corrupt sheet" "true" >/dev/null
printf '{ not json' > .claude/maestro/tcorrupt/questions.json
set +e; corrupt_status="$("$SCRIPTS/task-status.sh" 2>&1)"; corrupt_status_rc=$?; set -e
assert_exit 1 "$corrupt_status_rc" "corrupt questions.json makes task-status block"
assert_contains "$corrupt_status" "unreadable" "corrupt sheet reported as unreadable in task-status"
set +e; "$SCRIPTS/task-record.sh" gate1_approved >/dev/null 2>&1; corrupt_g1=$?; set -e
assert_exit 1 "$corrupt_g1" "corrupt questions.json REFUSES gate1_approved (no silent pass)"
assert_contains "$(GATE1_COUNT tcorrupt)" "0" "no gate1_approved event appended on corrupt-sheet refusal"

# ===========================================================================================
# test_non_dict_sheet_fails_closed_cleanly — a syntactically-valid JSON array whose ELEMENTS are
# non-dict ([null], ["x"]) must fail closed via the SAME clean CorruptSheet path as broken JSON, NOT
# via an uncaught AttributeError traceback (is_blocking does q.get() and would blow up deep in the
# caller, escaping its `except CorruptSheet`). Asserts: gate1_approved exits non-zero, appends NO
# gate1 event, and neither gate1 nor task-status leaks a Python "Traceback"/"AttributeError" — they
# show the clean operator "unreadable" message. On the OLD code this fails: the output is a traceback.
# ===========================================================================================
for bad in '[null]' '["x"]'; do
  slug="tnondict-$(printf '%s' "$bad" | tr -dc 'a-z')"   # tnondictnull / tnondictx
  "$SCRIPTS/task-init.sh" "$slug" full "non-dict sheet $bad" "true" >/dev/null
  printf '%s' "$bad" > ".claude/maestro/$slug/questions.json"

  # gate1_approved: refuses cleanly, no traceback, no gate1 event appended.
  set +e; nd_g1_out="$("$SCRIPTS/task-record.sh" gate1_approved 2>&1)"; nd_g1_rc=$?; set -e
  assert_exit 1 "$nd_g1_rc" "non-dict sheet $bad REFUSES gate1_approved (fail closed)"
  assert_not_contains "$nd_g1_out" "Traceback" "non-dict sheet $bad: gate1 shows NO Python traceback"
  assert_not_contains "$nd_g1_out" "AttributeError" "non-dict sheet $bad: gate1 shows NO AttributeError"
  assert_contains "$nd_g1_out" "unreadable" "non-dict sheet $bad: gate1 shows the clean 'unreadable' message"
  assert_contains "$(GATE1_COUNT "$slug")" "0" "non-dict sheet $bad: no gate1_approved event appended"

  # task-status: blocks cleanly, no traceback, reports unreadable.
  set +e; nd_status="$("$SCRIPTS/task-status.sh" 2>&1)"; nd_status_rc=$?; set -e
  assert_exit 1 "$nd_status_rc" "non-dict sheet $bad makes task-status block"
  assert_not_contains "$nd_status" "Traceback" "non-dict sheet $bad: task-status shows NO Python traceback"
  assert_not_contains "$nd_status" "AttributeError" "non-dict sheet $bad: task-status shows NO AttributeError"
  assert_contains "$nd_status" "unreadable" "non-dict sheet $bad: task-status reports the sheet as unreadable"
done

# ===========================================================================================
# question list: human-readable dump shows blocking markers
# ===========================================================================================
"$SCRIPTS/task-init.sh" tlist full "list dump" "true" >/dev/null
"$SCRIPTS/task-record.sh" question add "blocking one" route=code cost=high >/dev/null
"$SCRIPTS/task-record.sh" question add "non-blocking one" route=planner cost=high >/dev/null
set +e; list_out="$("$SCRIPTS/task-record.sh" question list 2>&1)"; set -e
assert_contains "$list_out" "BLOCK" "question list marks the blocking question"
assert_contains "$list_out" "blocking one" "question list shows question text"
assert_contains "$list_out" "open 2" "question list shows the open count"

summary "open-questions"
