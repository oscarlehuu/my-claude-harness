#!/usr/bin/env bash
# Continual-learning loop: learned-write.sh (the deterministic safety writer), task-distill.sh
# (the incremental index), distill-cadence.sh (the never-blocking Stop cadence), and the
# task-record task-close trigger. The safety invariants are tested here as CODE, never trusted to
# the consolidator's discretion.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRITE="$SCRIPTS/learned-write.sh"
DISTILL="$SCRIPTS/task-distill.sh"
CADENCE="$HOOKS/distill-cadence.sh"

CONV="## Learned — conventions"
GOTCHA="## Learned — gotchas"

# A fixture AGENTS.md with prose + BOTH owned Learned sections + a trailing prose section.
make_fixture() { # <path>
  cat > "$1" <<EOF
# AGENTS.md — fixture

Authored prose paragraph one. This line must survive any write byte-for-byte.

## Some Other Section

A bullet that is not a learning.
- do not touch me

$CONV

- existing convention bullet

$GOTCHA

- existing gotcha bullet

## Trailing Prose

The very last line of authored prose.
EOF
}

mkrepo

# === test_learned_write_preserves_prose ========================================
make_fixture agents-a.md
before="$(cat agents-a.md)"
"$WRITE" section agents-a.md "$CONV" "always run the verify command after edits" >/dev/null
after="$(cat agents-a.md)"
# Every line OUTSIDE the conventions section must be byte-identical. Extract the non-section
# lines from both and compare. The conventions section runs from its heading to the next "## ".
extract_outside() { # <file> <heading>  -> prints all lines NOT inside that section
  python3 - "$1" "$2" <<'PY'
import sys
path, heading = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().split("\n")
start = next((i for i, l in enumerate(lines) if l.strip() == heading), None)
if start is None:
    print("\n".join(lines)); raise SystemExit
end = len(lines)
for j in range(start + 1, len(lines)):
    if lines[j].startswith("## "):
        end = j; break
print("\n".join(lines[:start] + lines[end:]))
PY
}
# Compare via temp files (python re-opens the path, so process substitution isn't portable here).
printf '%s\n' "$before" > before.txt
printf '%s\n' "$after"  > after.txt
ob="$(extract_outside before.txt "$CONV")"
oa="$(extract_outside after.txt  "$CONV")"
[ "$ob" = "$oa" ] && _result ok "test_learned_write_preserves_prose: prose outside target byte-identical" \
  || _result fail "test_learned_write_preserves_prose: prose outside target byte-identical" "lines outside the conventions section changed"
assert_contains "$after" "always run the verify command after edits" "test_learned_write_preserves_prose: bullet was added"
assert_contains "$after" "The very last line of authored prose." "test_learned_write_preserves_prose: trailing prose intact"
assert_contains "$after" "do not touch me" "test_learned_write_preserves_prose: other-section bullet intact"

# === test_learned_write_owned_sections_only ====================================
make_fixture agents-b.md
sections_before="$(grep -c '^## ' agents-b.md)"
"$WRITE" section agents-b.md "$GOTCHA" "the install only deploys from a clean+green tree" >/dev/null
sections_after="$(grep -c '^## ' agents-b.md)"
[ "$sections_before" = "$sections_after" ] && _result ok "test_learned_write_owned_sections_only: no new section created" \
  || _result fail "test_learned_write_owned_sections_only: no new section created" "section count $sections_before -> $sections_after"
# Writing a NON-Learned heading is refused with a non-zero exit and writes nothing.
set +e
"$WRITE" section agents-b.md "## Some Other Section" "should never land here" >/dev/null 2>&1; refuse=$?
set -e
assert_exit 1 "$refuse" "test_learned_write_owned_sections_only: non-Learned heading refused"
assert_not_contains "$(cat agents-b.md)" "should never land here" "test_learned_write_owned_sections_only: refused write left no trace"

# === test_learned_write_dedup_and_cap ==========================================
make_fixture agents-c.md
"$WRITE" section agents-c.md "$CONV" "always run verify after edits" >/dev/null
n1="$(grep -c '^- ' agents-c.md)"
# Exact duplicate -> no-op.
"$WRITE" section agents-c.md "$CONV" "always run verify after edits" >/dev/null
# Whitespace/case/punctuation variant -> still a duplicate.
"$WRITE" section agents-c.md "$CONV" "  Always   run VERIFY after edits.  " >/dev/null
# Leading-marker variant -> still a duplicate.
"$WRITE" section agents-c.md "$CONV" "- always run verify after edits" >/dev/null
n2="$(grep -c '^- ' agents-c.md)"
[ "$n1" = "$n2" ] && _result ok "test_learned_write_dedup_and_cap: duplicate bullet not added twice" \
  || _result fail "test_learned_write_dedup_and_cap: duplicate bullet not added twice" "bullet count $n1 -> $n2"

# Cap: fill the conventions section to 12, then the 13th must be refused.
make_fixture agents-cap.md
# the fixture already has 1 conventions bullet; add until 12, then attempt a 13th.
i=2
while [ "$i" -le 12 ]; do
  "$WRITE" section agents-cap.md "$CONV" "convention number $i" >/dev/null
  i=$((i + 1))
done
conv_count="$(python3 - agents-cap.md "$CONV" <<'PY'
import sys
path, heading = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().split("\n")
start = next(i for i, l in enumerate(lines) if l.strip() == heading)
end = len(lines)
for j in range(start + 1, len(lines)):
    if lines[j].startswith("## "):
        end = j; break
print(sum(1 for l in lines[start:end] if l.lstrip().startswith("- ")))
PY
)"
assert_contains "$conv_count" "12" "test_learned_write_dedup_and_cap: section filled to the cap of 12"
set +e
"$WRITE" section agents-cap.md "$CONV" "convention number 13 over the cap" >/dev/null 2>&1; capped=$?
set -e
assert_exit 1 "$capped" "test_learned_write_dedup_and_cap: 13th bullet refused at cap"
assert_not_contains "$(cat agents-cap.md)" "convention number 13 over the cap" "test_learned_write_dedup_and_cap: over-cap bullet not written"

# === test_company_human_route_to_inbox_only ====================================
# Stand up temp conventions.md AND me.md fixtures; routing company/human must leave both
# byte-untouched and only append to the inbox. The recurrence rule means a candidate is only
# QUEUED on its 2nd near-duplicate occurrence — so each proposal is sent twice here to cross it.
CONV_FIX="$(mktemp)"; ME_FIX="$(mktemp)"
printf 'company conventions — do not auto-edit me.\n' > "$CONV_FIX"
printf 'about the human — do not auto-edit me.\n'     > "$ME_FIX"
conv_sha_before="$(cksum < "$CONV_FIX")"
me_sha_before="$(cksum < "$ME_FIX")"
rm -f .claude/maestro/learnings-seen.json .claude/maestro/learnings-inbox.md
"$WRITE" inbox company "the parallel-lane WIP limit is a hard block" >/dev/null
"$WRITE" inbox company "the parallel-lane WIP limit is a hard block" >/dev/null  # 2nd -> queues
"$WRITE" inbox human   "the founder prefers visible folders over dotfolder magic" >/dev/null
"$WRITE" inbox human   "the founder prefers visible folders over dotfolder magic" >/dev/null  # 2nd
inbox_path=".claude/maestro/learnings-inbox.md"
assert_file_exists "$inbox_path" "test_company_human_route_to_inbox_only: inbox created"
assert_contains "$(cat "$inbox_path")" "[company]" "test_company_human_route_to_inbox_only: company proposal queued"
assert_contains "$(cat "$inbox_path")" "[human]" "test_company_human_route_to_inbox_only: human proposal queued"
assert_contains "$(cat "$inbox_path")" "WIP limit is a hard block" "test_company_human_route_to_inbox_only: company text present"
conv_sha_after="$(cksum < "$CONV_FIX")"
me_sha_after="$(cksum < "$ME_FIX")"
[ "$conv_sha_before" = "$conv_sha_after" ] && _result ok "test_company_human_route_to_inbox_only: conventions.md byte-untouched" \
  || _result fail "test_company_human_route_to_inbox_only: conventions.md byte-untouched" "conventions fixture changed"
[ "$me_sha_before" = "$me_sha_after" ] && _result ok "test_company_human_route_to_inbox_only: me.md byte-untouched" \
  || _result fail "test_company_human_route_to_inbox_only: me.md byte-untouched" "me fixture changed"
# Invalid route + empty text are refused.
set +e
"$WRITE" inbox sideways "nope" >/dev/null 2>&1; badroute=$?
"$WRITE" inbox company "" >/dev/null 2>&1; emptytext=$?
set -e
assert_exit 1 "$badroute" "test_company_human_route_to_inbox_only: invalid route refused"
assert_exit 1 "$emptytext" "test_company_human_route_to_inbox_only: empty proposal refused"
rm -f "$CONV_FIX" "$ME_FIX"

# === section path denylist: deterministic off-limits guard ======================
# The `section` subcommand must REFUSE (non-zero exit, write/modify NOTHING) for globally-injected
# contract/policy targets — the off-limits invariant lives in code, NOT in the consolidator's prose.
# Each test asserts: non-zero exit AND the target left byte-identical (cksum unchanged; if the file
# did not exist, it still does not exist). Mirrors the cksum before/after pattern above.

# refuses_off_limits <test-name> <target-path> [extra-setup-fn]
# Runs `section <target> "## Learned ..." "x"`, asserts non-zero exit and a byte-identical target.
refuses_off_limits() { # <name> <target> [home-override]
  local name="$1" target="$2" home_override="${3:-}"
  local existed=0 sha_before="" rc
  if [ -e "$target" ]; then existed=1; sha_before="$(cksum < "$target")"; fi
  set +e
  if [ -n "$home_override" ]; then
    HOME="$home_override" "$WRITE" section "$target" "## Learned User Preferences" "x" >/dev/null 2>&1; rc=$?
  else
    "$WRITE" section "$target" "## Learned User Preferences" "x" >/dev/null 2>&1; rc=$?
  fi
  set -e
  assert_exit 1 "$rc" "$name: off-limits target refused (non-zero exit)"
  if [ "$existed" -eq 1 ]; then
    [ "$sha_before" = "$(cksum < "$target")" ] \
      && _result ok "$name: target left byte-identical" \
      || _result fail "$name: target left byte-identical" "cksum of $target changed"
  else
    assert_file_absent "$target" "$name: refused target was not created"
  fi
}

# A normal project AGENTS.md WITHOUT the contract marker — the regression baseline for over-breadth.
plain_agents() { printf '# AGENTS.md — a normal project\n\njust prose, no contract marker.\n' > "$1"; }
# An AGENTS.md carrying the deterministic single-source-of-truth contract marker line.
contract_agents() { printf '# AGENTS.md\n\n> **Single source of truth.** every agent doc lives here.\n\nprose.\n' > "$1"; }

# test_section_refuses_contract_agents_md — AGENTS.md containing the contract marker is refused.
mkdir -p deny_contract && contract_agents deny_contract/AGENTS.md
refuses_off_limits "test_section_refuses_contract_agents_md" "deny_contract/AGENTS.md"

# test_section_refuses_home_global_contract — simulate $HOME/.claude/AGENTS.md via a HOME override.
# The literal-path branch must refuse it even though it carries no marker and never touches real ~.
fake_home="$(mktemp -d)"
mkdir -p "$fake_home/.claude"
printf '# global contract (no marker, matched by literal path)\n' > "$fake_home/.claude/AGENTS.md"
refuses_off_limits "test_section_refuses_home_global_contract" "$fake_home/.claude/AGENTS.md" "$fake_home"
rm -rf "$fake_home"

# test_section_refuses_conventions_md — basename conventions.md is always off-limits. Left ABSENT on
# purpose so this also proves a refused, non-existent target is never CREATED by the write attempt.
rm -f conventions.md
refuses_off_limits "test_section_refuses_conventions_md" "conventions.md"

# test_section_refuses_me_md — basename me.md is always off-limits.
printf 'about the human — founder-gated.\n' > me.md
refuses_off_limits "test_section_refuses_me_md" "me.md"

# test_section_refuses_rules_dir — any path under a rules/ segment is policy, off-limits.
mkdir -p rules && printf '# a rule\n' > rules/x.md
refuses_off_limits "test_section_refuses_rules_dir" "rules/x.md"

# test_section_refuses_charter_dir — any path under a charter/ segment is policy, off-limits.
mkdir -p charter && printf '# a charter doc\n' > charter/x.md
refuses_off_limits "test_section_refuses_charter_dir" "charter/x.md"

# === case-variant bypass: the denylist must casefold every comparison ===========
# On a case-insensitive filesystem (macOS/APFS) realpath does NOT case-normalize, so a variant-case
# path resolves to a distinct string yet the OS opens the SAME on-disk file. A case-sensitive
# denylist therefore lets `Conventions.md` / `ME.md` / `RULES/x.md` etc. slip the guard and corrupt
# the underlying lowercase policy file. Each test below asserts the variant-case write is REFUSED
# (non-zero exit) AND the underlying lowercase on-disk file is left byte-identical (or, when absent,
# is never created). refuses_off_limits handles the cksum/absence assertions for the variant target;
# on a case-insensitive FS that target IS the lowercase file, so its byte-identity is asserted there.

# test_section_refuses_conventions_md_case_variant — `Conventions.md` must be refused like conventions.md.
rm -f conventions.md Conventions.md
refuses_off_limits "test_section_refuses_conventions_md_case_variant" "Conventions.md"

# test_section_refuses_me_md_case_variant — `ME.md` must be refused like me.md.
rm -f me.md ME.md
printf 'about the human — founder-gated.\n' > me.md
refuses_off_limits "test_section_refuses_me_md_case_variant" "ME.md"

# test_section_refuses_rules_dir_case_variant — a `Rules/` segment must be refused like rules/.
mkdir -p rules && printf '# a rule\n' > rules/x.md
refuses_off_limits "test_section_refuses_rules_dir_case_variant" "Rules/x.md"

# test_section_refuses_charter_dir_case_variant — a `CHARTER/` segment must be refused like charter/.
mkdir -p charter && printf '# a charter doc\n' > charter/x.md
refuses_off_limits "test_section_refuses_charter_dir_case_variant" "CHARTER/x.md"

# test_section_refuses_contract_agents_md_lowercase — lowercase `agents.md` carrying the contract
# marker must still trigger the marker-read branch (basename compared casefolded).
mkdir -p deny_lc && contract_agents deny_lc/agents.md
refuses_off_limits "test_section_refuses_contract_agents_md_lowercase" "deny_lc/agents.md"

# test_section_refuses_home_global_contract_lowercase — $HOME/.claude/agents.md (lowercase) must be
# refused by the casefolded literal-path branch, via the same HOME override the home-contract test uses.
fake_home_lc="$(mktemp -d)"
mkdir -p "$fake_home_lc/.claude"
printf '# global contract lowercase path (no marker, matched by casefolded literal path)\n' > "$fake_home_lc/.claude/agents.md"
refuses_off_limits "test_section_refuses_home_global_contract_lowercase" "$fake_home_lc/.claude/agents.md" "$fake_home_lc"
rm -rf "$fake_home_lc"

# test_section_refuses_reformatted_contract_marker — the contract-marker match tolerates collapsed/
# extra internal whitespace and case, so a reformatted-but-real contract is still refused.
mkdir -p deny_ws
printf '# AGENTS.md\n\n>   **single   source   of   truth.** every agent doc lives here.\n\nprose.\n' > deny_ws/AGENTS.md
refuses_off_limits "test_section_refuses_reformatted_contract_marker" "deny_ws/AGENTS.md"

# test_section_allows_plain_project_agents_md — regression guard: a normal AGENTS.md WITHOUT the
# contract marker must STILL accept the bullet, so the denylist is not over-broad.
plain_agents plain-agents.md
set +e
"$WRITE" section plain-agents.md "## Learned — gotchas" "a genuine repo gotcha worth keeping" >/dev/null 2>&1; allow_rc=$?
set -e
assert_exit 0 "$allow_rc" "test_section_allows_plain_project_agents_md: plain AGENTS.md accepts the bullet"
assert_contains "$(cat plain-agents.md)" "a genuine repo gotcha worth keeping" \
  "test_section_allows_plain_project_agents_md: bullet landed in a non-contract AGENTS.md"

# === task-distill index: helpers ===============================================
# A clean state for the cadence/index tests.
state=".claude/maestro/distill-state.json"
mkdir -p .claude/maestro

# === test_distill_index_incremental ============================================
# A transcript file: first advance moves the watermark; an unchanged file is a no-op; a
# touched (newer mtime) file advances again.
ts_file="$(mktemp)"
printf '{"type":"assistant"}\n' > "$ts_file"
# normalize the mtime to a known past value so "advance" can move forward deterministically
touch -t 202601010000 "$ts_file"
rm -f "$state"
r1="$("$DISTILL" advance "$ts_file")"
assert_contains "$r1" "advanced" "test_distill_index_incremental: first run advances the watermark"
r2="$("$DISTILL" advance "$ts_file")"
assert_contains "$r2" "noop" "test_distill_index_incremental: unchanged transcript is a no-op"
touch -t 202601020000 "$ts_file"   # bump mtime forward
r3="$("$DISTILL" advance "$ts_file")"
assert_contains "$r3" "advanced" "test_distill_index_incremental: changed transcript advances again"
rm -f "$ts_file"

# === test_task_close_marks_distill_failsafe ====================================
printf 'exit 0\n' > check.sh
"$SCRIPTS/task-init.sh" closer light "close trigger test" "bash check.sh" >/dev/null
rm -f "$state"   # start clean so we can observe the mark
"$SCRIPTS/task-record.sh" task_done >/dev/null
assert_file_exists "$state" "test_task_close_marks_distill_failsafe: close created distill-state"
due_has_slug="$(python3 - "$state" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
print("yes" if "closer" in (st.get("due") or {}) else "no")
PY
)"
assert_contains "$due_has_slug" "yes" "test_task_close_marks_distill_failsafe: closed slug marked due"

# Induced failure: make ONLY the distill mark fail (not the close's own writes) by replacing
# distill-state.json with a DIRECTORY — mark-due's atomic rename onto it raises, the trigger's
# `|| true` swallows it, and the close must STILL exit 0 (and still clear the active pointer).
"$SCRIPTS/task-init.sh" closer2 light "close failsafe" "bash check.sh" >/dev/null
rm -rf "$state"; mkdir "$state"   # a dir where a file is expected -> mark-due cannot write
set +e
"$SCRIPTS/task-record.sh" task_done >/dev/null 2>&1; close_code=$?
set -e
assert_exit 0 "$close_code" "test_task_close_marks_distill_failsafe: close exits 0 even when distill-marking fails"
assert_file_absent .claude/maestro/active "test_task_close_marks_distill_failsafe: failed distill-mark did not block clearing active"
rm -rf "$state"

# === cadence: shared payload builders ==========================================
# The cadence reads transcript_path + stop_hook_active from the stop-hook stdin JSON.
cad_transcript="$(mktemp)"
# 12 assistant turns so the turn gate (default N=10) is satisfiable.
python3 -c "print('\n'.join('{\"type\":\"assistant\"}' for _ in range(12)))" > "$cad_transcript"
touch -t 202601030000 "$cad_transcript"

# === test_cadence_fires_when_all_conditions ====================================
# Fresh state: no prior distill -> minutes treated as infinite (passes M); watermark 0 so the
# transcript advances; 12 turns >= N=10. All three conditions hold -> FIRE (marks __cadence__ due).
rm -f "$state"
run_hook "$CADENCE" "{\"transcript_path\":\"$cad_transcript\",\"stop_hook_active\":false}"
assert_exit 0 "$HOOK_EXIT" "test_cadence_fires_when_all_conditions: cadence exits 0 on fire"
fired_due="$(python3 - "$state" <<'PY'
import json, os, sys
p = sys.argv[1]
print("yes" if (os.path.exists(p) and "__cadence__" in (json.load(open(p)).get("due") or {})) else "no")
PY
)"
assert_contains "$fired_due" "yes" "test_cadence_fires_when_all_conditions: fire marks a cadence distill due"

# Negative arm A: turns below N -> no fire.
rm -f "$state"
short_transcript="$(mktemp)"
python3 -c "print('\n'.join('{\"type\":\"assistant\"}' for _ in range(3)))" > "$short_transcript"
touch -t 202601030000 "$short_transcript"
run_hook "$CADENCE" "{\"transcript_path\":\"$short_transcript\",\"stop_hook_active\":false}"
no_fire_turns="$(python3 - "$state" <<'PY'
import json, os, sys
p = sys.argv[1]
print("yes" if (os.path.exists(p) and (json.load(open(p)).get("due") or {})) else "no")
PY
)"
assert_contains "$no_fire_turns" "no" "test_cadence_fires_when_all_conditions: below N turns does not fire"
rm -f "$short_transcript"

# Negative arm B: minutes below M -> no fire. Seed lastDistillEpoch to NOW so M is not met,
# and set the watermark below the transcript mtime so only the minute gate blocks it.
python3 - "$state" "$cad_transcript" <<'PY'
import json, os, sys, time
state, ts = sys.argv[1], sys.argv[2]
json.dump({"watermark": 0, "lastDistillEpoch": int(time.time()), "due": {}}, open(state, "w"))
PY
run_hook "$CADENCE" "{\"transcript_path\":\"$cad_transcript\",\"stop_hook_active\":false}"
no_fire_min="$(python3 - "$state" <<'PY'
import json, sys
print("yes" if (json.load(open(sys.argv[1])).get("due") or {}) else "no")
PY
)"
assert_contains "$no_fire_min" "no" "test_cadence_fires_when_all_conditions: below M minutes does not fire"

# Negative arm C: transcript did NOT advance (this conversation's watermark already at/above its
# mtime) -> no fire. The payload carries no session_id, so the cadence reads the __default__ key.
python3 - "$state" "$cad_transcript" <<'PY'
import json, os, sys
state, ts = sys.argv[1], sys.argv[2]
mt = int(os.path.getmtime(ts))
json.dump({"conversations": {"__default__": mt + 100}, "lastDistillEpoch": 0, "due": {}}, open(state, "w"))
PY
run_hook "$CADENCE" "{\"transcript_path\":\"$cad_transcript\",\"stop_hook_active\":false}"
no_fire_wm="$(python3 - "$state" <<'PY'
import json, sys
print("yes" if (json.load(open(sys.argv[1])).get("due") or {}) else "no")
PY
)"
assert_contains "$no_fire_wm" "no" "test_cadence_fires_when_all_conditions: non-advanced transcript does not fire"

# === test_cadence_skips_direct_and_block_loop ==================================
# Direct mode -> no fire even with all conditions otherwise met.
rm -f "$state"
echo 1 > .claude/maestro-direct
run_hook "$CADENCE" "{\"transcript_path\":\"$cad_transcript\",\"stop_hook_active\":false}"
direct_no_fire="$(python3 - "$state" <<'PY'
import json, os, sys
p = sys.argv[1]
print("yes" if (os.path.exists(p) and (json.load(open(p)).get("due") or {})) else "no")
PY
)"
assert_contains "$direct_no_fire" "no" "test_cadence_skips_direct_and_block_loop: maestro-direct suppresses fire"
assert_exit 0 "$HOOK_EXIT" "test_cadence_skips_direct_and_block_loop: direct mode exits 0"
rm -f .claude/maestro-direct

# stop_hook_active -> no fire (block-loop guard).
rm -f "$state"
run_hook "$CADENCE" "{\"transcript_path\":\"$cad_transcript\",\"stop_hook_active\":true}"
loop_no_fire="$(python3 - "$state" <<'PY'
import json, os, sys
p = sys.argv[1]
print("yes" if (os.path.exists(p) and (json.load(open(p)).get("due") or {})) else "no")
PY
)"
assert_contains "$loop_no_fire" "no" "test_cadence_skips_direct_and_block_loop: stop_hook_active suppresses fire"
assert_exit 0 "$HOOK_EXIT" "test_cadence_skips_direct_and_block_loop: block-loop guard exits 0"

# === test_cadence_never_blocks =================================================
# Across fire, skip, malformed JSON, and empty stdin — the cadence NEVER returns a blocking code.
rm -f "$state"
run_hook "$CADENCE" "{\"transcript_path\":\"$cad_transcript\",\"stop_hook_active\":false}"
assert_exit 0 "$HOOK_EXIT" "test_cadence_never_blocks: fire path is non-blocking"
run_hook "$CADENCE" 'not-json-at-all'
assert_exit 0 "$HOOK_EXIT" "test_cadence_never_blocks: malformed JSON fails open"
run_hook "$CADENCE" ''
assert_exit 0 "$HOOK_EXIT" "test_cadence_never_blocks: empty stdin fails open"
# A bad N override must not crash or block.
MAESTRO_DISTILL_TURNS="notanumber" run_hook "$CADENCE" "{\"transcript_path\":\"$cad_transcript\",\"stop_hook_active\":false}"
assert_exit 0 "$HOOK_EXIT" "test_cadence_never_blocks: bad env override fails open"

# === cadence fallback: no transcript_path -> ledger log.jsonl mtime =============
# When transcript_path is absent, the cadence falls back to the active task's ledger log.
rm -f "$state"
"$SCRIPTS/task-init.sh" fallbacktask light "fallback ledger test" "bash check.sh" >/dev/null
# default N=10 cannot be turn-counted without a transcript; force the turn gate open via N<=0,
# and ensure the ledger log mtime is fresh (task-init just wrote it) so it advances past 0.
MAESTRO_DISTILL_TURNS=0 run_hook "$CADENCE" '{"stop_hook_active":false}'
assert_exit 0 "$HOOK_EXIT" "cadence fallback: exits 0 with no transcript_path"
fallback_due="$(python3 - "$state" <<'PY'
import json, os, sys
p = sys.argv[1]
print("yes" if (os.path.exists(p) and "__cadence__" in (json.load(open(p)).get("due") or {})) else "no")
PY
)"
assert_contains "$fallback_due" "yes" "cadence fallback: ledger log mtime drives a fire when transcript_path absent"

# === stop-dod integration: pass path fires cadence, block path stays untouched ====
# The cadence must only run on stop-dod's NON-blocking pass path and must never alter the
# exit-2 block path. We drive the real stop-dod hook with a real verify command.
STOPDOD="$HOOKS/stop-dod.sh"

# Block path: unverified code change -> stop-dod blocks (exit 2). distill-state must NOT appear,
# proving the cadence did not run on the block path.
mkrepo
mkdir -p .claude/maestro
printf 'exit 0\n' > check.sh
printf 'bash check.sh\n' > .claude/maestro-verify
printf 'real code\n' > app.py            # an unverified code file -> stop-dod blocks
git -C "$REPO" add -A >/dev/null 2>&1 || true
sd_transcript="$(mktemp)"
python3 -c "print('\n'.join('{\"type\":\"assistant\"}' for _ in range(12)))" > "$sd_transcript"
touch -t 202601030000 "$sd_transcript"
rm -f .claude/maestro/distill-state.json
run_hook "$STOPDOD" "{\"transcript_path\":\"$sd_transcript\",\"stop_hook_active\":false}"
assert_exit 2 "$HOOK_EXIT" "stop-dod integration: unverified code still blocks (exit 2)"
assert_file_absent .claude/maestro/distill-state.json "stop-dod integration: cadence did NOT run on the block path"

# Pass path: verify green after the edit -> stop-dod passes (exit 0) and the cadence runs,
# marking a distill due.
"$SCRIPTS/task-verify.sh" >/dev/null 2>&1 || true   # records a green verify AFTER app.py's mtime
# ensure the verify epoch is >= the code file mtime (verify just ran, so it is)
rm -f .claude/maestro/distill-state.json
run_hook "$STOPDOD" "{\"transcript_path\":\"$sd_transcript\",\"stop_hook_active\":false}"
assert_exit 0 "$HOOK_EXIT" "stop-dod integration: verified tree passes (exit 0)"
sd_fired="$(python3 - .claude/maestro/distill-state.json <<'PY'
import json, os, sys
p = sys.argv[1]
print("yes" if (os.path.exists(p) and "__cadence__" in (json.load(open(p)).get("due") or {})) else "no")
PY
)"
assert_contains "$sd_fired" "yes" "stop-dod integration: cadence fired on the pass path"
rm -f "$sd_transcript"

rm -f "$cad_transcript"

# === ROUND 4: process-centric reshape ==========================================
# A fresh repo so the new watermark map + per-task flag + kill switch start clean.
mkrepo
mkdir -p .claude/maestro
state=".claude/maestro/distill-state.json"

# === test_conversation_watermark_keyed_by_id ===================================
# Two conversation_ids must advance INDEPENDENTLY: advancing one never clobbers the other's
# watermark (parallel lanes share one repo). This is the core regression risk of the reshape.
rm -f "$state"
ts_a="$(mktemp)"; ts_b="$(mktemp)"
printf '{}\n' > "$ts_a"; printf '{}\n' > "$ts_b"
touch -t 202602010000 "$ts_a"   # conv-A's transcript mtime
touch -t 202602020000 "$ts_b"   # conv-B's transcript mtime (later)
ra="$("$DISTILL" advance "$ts_a" conv-A)"
assert_contains "$ra" "advanced" "test_conversation_watermark_keyed_by_id: conv-A advances on first run"
# Advancing conv-B must NOT reset conv-A's watermark.
rb="$("$DISTILL" advance "$ts_b" conv-B)"
assert_contains "$rb" "advanced" "test_conversation_watermark_keyed_by_id: conv-B advances independently"
wm_a="$(python3 - "$state" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
print(st.get("conversations", {}).get("conv-A", "MISSING"))
PY
)"
wm_b="$(python3 - "$state" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
print(st.get("conversations", {}).get("conv-B", "MISSING"))
PY
)"
mt_a="$(python3 -c "import os,sys;print(int(os.path.getmtime(sys.argv[1])))" "$ts_a")"
mt_b="$(python3 -c "import os,sys;print(int(os.path.getmtime(sys.argv[1])))" "$ts_b")"
[ "$wm_a" = "$mt_a" ] && _result ok "test_conversation_watermark_keyed_by_id: conv-A watermark preserved after conv-B advance" \
  || _result fail "test_conversation_watermark_keyed_by_id: conv-A watermark preserved after conv-B advance" "conv-A=$wm_a expected $mt_a (clobbered by conv-B)"
[ "$wm_b" = "$mt_b" ] && _result ok "test_conversation_watermark_keyed_by_id: conv-B watermark set correctly" \
  || _result fail "test_conversation_watermark_keyed_by_id: conv-B watermark set correctly" "conv-B=$wm_b expected $mt_b"
# Re-advancing conv-A with its unchanged transcript is a per-key no-op (does not re-fire).
ra2="$("$DISTILL" advance "$ts_a" conv-A)"
assert_contains "$ra2" "noop" "test_conversation_watermark_keyed_by_id: unchanged conv-A transcript is a per-key no-op"
rm -f "$ts_a" "$ts_b"

# === test_per_task_consolidated_flag_in_state ==================================
# The per-task "consolidated" flag must live in <slug>/state.json (task-scoped, auto-cleaned with
# the dir), NOT in distill-state.json. Recording it sets the flag and logs a `consolidated` event.
printf 'exit 0\n' > check.sh
"$SCRIPTS/task-init.sh" consoltask light "consolidated flag test" "bash check.sh" >/dev/null
rm -f "$state"
"$SCRIPTS/task-record.sh" consolidated >/dev/null
flag_in_state="$(python3 - .claude/maestro/consoltask/state.json <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
print("yes" if st.get("consolidated") is True else "no")
PY
)"
assert_contains "$flag_in_state" "yes" "test_per_task_consolidated_flag_in_state: flag set true in <slug>/state.json"
# The flag must NOT live in distill-state.json.
not_in_distill="$(python3 - "$state" <<'PY'
import json, os, sys
p = sys.argv[1]
if not os.path.exists(p):
    print("yes"); raise SystemExit
st = json.load(open(p))
print("yes" if "consolidated" not in st else "no")
PY
)"
assert_contains "$not_in_distill" "yes" "test_per_task_consolidated_flag_in_state: flag absent from distill-state.json"
# A `consolidated` event is logged (audit trail), and re-recording is idempotent.
assert_contains "$(cat .claude/maestro/consoltask/log.jsonl)" '"event":"consolidated"' "test_per_task_consolidated_flag_in_state: consolidated event logged"
"$SCRIPTS/task-record.sh" --slug consoltask consolidated >/dev/null
flag_still="$(python3 - .claude/maestro/consoltask/state.json <<'PY'
import json, sys
print("yes" if json.load(open(sys.argv[1])).get("consolidated") is True else "no")
PY
)"
assert_contains "$flag_still" "yes" "test_per_task_consolidated_flag_in_state: re-recording is idempotent"

# === test_me_md_conventions_require_recurrence =================================
# A me.md/conventions candidate seen ONCE is NOT queued (anti-spam); the 2nd near-duplicate IS.
rm -f .claude/maestro/learnings-inbox.md .claude/maestro/learnings-seen.json
out1="$("$WRITE" inbox human "the founder converses in vietnamese, artifacts in english")"
assert_contains "$out1" "below recurrence threshold" "test_me_md_conventions_require_recurrence: 1st occurrence recorded, not queued"
assert_file_absent .claude/maestro/learnings-inbox.md "test_me_md_conventions_require_recurrence: inbox not created on a single occurrence"
# 2nd near-duplicate (whitespace/case variant) crosses the threshold -> queued.
out2="$("$WRITE" inbox human "  The founder CONVERSES in Vietnamese, artifacts in English.  ")"
assert_contains "$out2" "queued" "test_me_md_conventions_require_recurrence: 2nd near-duplicate occurrence is queued"
assert_file_exists .claude/maestro/learnings-inbox.md "test_me_md_conventions_require_recurrence: inbox created on the 2nd occurrence"
assert_contains "$(cat .claude/maestro/learnings-inbox.md)" "[human]" "test_me_md_conventions_require_recurrence: queued as a human proposal"
# A DIFFERENT learning seen once stays unqueued (the counter is per-learning, not global).
out3="$("$WRITE" inbox company "an unrelated company observation seen only once")"
assert_contains "$out3" "below recurrence threshold" "test_me_md_conventions_require_recurrence: a distinct one-off stays unqueued"
assert_not_contains "$(cat .claude/maestro/learnings-inbox.md)" "unrelated company observation" "test_me_md_conventions_require_recurrence: one-off distinct learning not in inbox"
# A 3rd occurrence (case/whitespace variant) must NOT append a duplicate inbox line — the inbox
# dedup strips the "[route] (date)" prefix before comparing, so recurrence past the threshold is
# still idempotent (no inbox spam from a learning that keeps recurring).
hcount_before="$(grep -c '^- \[human\]' .claude/maestro/learnings-inbox.md)"
"$WRITE" inbox human "  THE founder converses in VIETNAMESE, artifacts in english.  " >/dev/null
hcount_after="$(grep -c '^- \[human\]' .claude/maestro/learnings-inbox.md)"
[ "$hcount_before" = "$hcount_after" ] && _result ok "test_me_md_conventions_require_recurrence: 3rd occurrence does not duplicate the inbox line" \
  || _result fail "test_me_md_conventions_require_recurrence: 3rd occurrence does not duplicate the inbox line" "human lines $hcount_before -> $hcount_after"

# === test_repo_fact_single_shot ================================================
# A repo fact is written to a project AGENTS.md `## Learned` section on its FIRST occurrence —
# no recurrence gate (single-shot, easily reverted). Uses a plain markerless AGENTS.md.
printf '# AGENTS.md — a normal project\n\nprose, no contract marker.\n' > repo-agents.md
"$WRITE" section repo-agents.md "## Learned — gotchas" "the test harness blocks git keywords in bash" >/dev/null
assert_contains "$(cat repo-agents.md)" "the test harness blocks git keywords in bash" \
  "test_repo_fact_single_shot: repo fact written on first occurrence"
assert_contains "$(cat repo-agents.md)" "## Learned — gotchas" "test_repo_fact_single_shot: owned section created"

# === test_distill_off_suppresses_all ===========================================
# With .claude/maestro/distill-off present: the cadence does not mark due, task-close does not mark
# due, and due-since reports nothing due (the consolidator path no-ops).
touch .claude/maestro/distill-off
# (a) cadence does not fire
rm -f "$state"
off_cad_ts="$(mktemp)"
python3 -c "print('\n'.join('{\"type\":\"assistant\"}' for _ in range(12)))" > "$off_cad_ts"
touch -t 202602030000 "$off_cad_ts"
run_hook "$CADENCE" "{\"transcript_path\":\"$off_cad_ts\",\"session_id\":\"conv-off\",\"stop_hook_active\":false}"
assert_exit 0 "$HOOK_EXIT" "test_distill_off_suppresses_all: cadence still exits 0 with kill switch"
off_cad_due="$(python3 - "$state" <<'PY'
import json, os, sys
p = sys.argv[1]
print("yes" if (os.path.exists(p) and (json.load(open(p)).get("due") or {})) else "no")
PY
)"
assert_contains "$off_cad_due" "no" "test_distill_off_suppresses_all: cadence does NOT mark due under distill-off"
# (b) task-close does not mark due
"$SCRIPTS/task-init.sh" offclose light "kill-switch close" "bash check.sh" >/dev/null
rm -f "$state"
"$SCRIPTS/task-record.sh" task_done >/dev/null
off_close_due="$(python3 - "$state" <<'PY'
import json, os, sys
p = sys.argv[1]
print("yes" if (os.path.exists(p) and (json.load(open(p)).get("due") or {})) else "no")
PY
)"
assert_contains "$off_close_due" "no" "test_distill_off_suppresses_all: task-close does NOT mark due under distill-off"
# (c) even a directly-marked due reports nothing due (consolidator no-ops): due-since exits 1.
rm -f .claude/maestro/distill-off
"$DISTILL" mark-due seeded manual >/dev/null   # seed a due entry while OFF-switch removed
touch .claude/maestro/distill-off              # now turn the kill switch back on
set +e
"$DISTILL" due-since; off_due_since=$?
set -e
assert_exit 1 "$off_due_since" "test_distill_off_suppresses_all: due-since reports nothing due under distill-off"
# (d) a direct mark-due is a clean no-op under the switch (still exits 0).
set +e
"$DISTILL" mark-due another manual >/dev/null 2>&1; off_mark=$?
set -e
assert_exit 0 "$off_mark" "test_distill_off_suppresses_all: mark-due is a clean no-op under distill-off"
rm -f .claude/maestro/distill-off "$off_cad_ts"
# With the switch removed, due-since works again (regression baseline).
set +e
"$DISTILL" due-since; on_due_since=$?
set -e
assert_exit 0 "$on_due_since" "test_distill_off_suppresses_all: due-since works again once the switch is removed"

# === test_secrets_scrubbed =====================================================
# A learning carrying a token/key/credential is DROPPED before any sink (section AND inbox).
#
# These cases exercise the _ASSIGN net on its own. Real env-var secrets are PREFIX_KEYWORD=value
# (DB_PASSWORD, API_TOKEN, STRIPE_SECRET_KEY) — the keyword sits inside a longer underscore name,
# which a `\b`-anchored pattern silently missed. The VALUES here are deliberately short and free of
# any provider prefix (no sk-/ghp_/AKIA…) and under the 32-char high-entropy run, so the only net
# that can fire is _ASSIGN. On the old `\b`-anchored regex these would have leaked into BOTH sinks;
# this test therefore FAILS on the old code and is not a tautology that trips a different net.
secret_cases=(
  "DB_PASSWORD=p4ssw0rd"
  "API_TOKEN=mytok12345"
  "STRIPE_SECRET_KEY=sk_live_short"
)
for sc in "${secret_cases[@]}"; do
  # --- section sink: refuse (non-zero) AND leave the target byte-identical ---
  printf '# AGENTS.md — plain project\n\nprose.\n' > secret-agents.md
  sec_before="$(cksum < secret-agents.md)"
  set +e
  "$WRITE" section secret-agents.md "## Learned — gotchas" "$sc" >/dev/null 2>&1; sec_sec_rc=$?
  set -e
  assert_exit 1 "$sec_sec_rc" "test_secrets_scrubbed: section refuses env-var secret '$sc'"
  [ "$sec_before" = "$(cksum < secret-agents.md)" ] && _result ok "test_secrets_scrubbed: section byte-identical after refusing '$sc'" \
    || _result fail "test_secrets_scrubbed: section byte-identical after refusing '$sc'" "secret-agents.md changed"
  # --- inbox sink: refuse (non-zero) AND never queue the proposal ---
  rm -f .claude/maestro/learnings-inbox.md .claude/maestro/learnings-seen.json
  set +e
  "$WRITE" inbox company "$sc" >/dev/null 2>&1; sec_inbox_rc=$?
  set -e
  assert_exit 1 "$sec_inbox_rc" "test_secrets_scrubbed: inbox refuses env-var secret '$sc'"
  assert_file_absent .claude/maestro/learnings-inbox.md "test_secrets_scrubbed: env-var secret '$sc' never queued"
done
# A non-secret learning with similar words still passes (no over-broad false positive).
printf '# AGENTS.md — plain project\n\nprose.\n' > ok-agents.md
set +e
"$WRITE" section ok-agents.md "## Learned — conventions" "store API tokens in the secret manager, never in code" >/dev/null 2>&1; ok_rc=$?
set -e
assert_exit 0 "$ok_rc" "test_secrets_scrubbed: an ordinary learning that merely mentions secrets still writes"
assert_contains "$(cat ok-agents.md)" "store API tokens in the secret manager" "test_secrets_scrubbed: non-secret learning landed"

# === test_secret_advice_false_positive =========================================
# Advice ABOUT secrets that carries no actual key=value credential value MUST still write — the
# scrub keys on credential SHAPE (a keyword glued to a `[:=] value`), not on the word "password"
# or "token" appearing in prose. Guards the widened _ASSIGN prefix from eating ordinary advice.
printf '# AGENTS.md — plain project\n\nprose.\n' > advice-agents.md
set +e
"$WRITE" section advice-agents.md "## Learned — conventions" "never hardcode a password; store tokens in the secret manager" >/dev/null 2>&1; advice_rc=$?
set -e
assert_exit 0 "$advice_rc" "test_secret_advice_false_positive: secret advice with no key=value still writes"
assert_contains "$(cat advice-agents.md)" "never hardcode a password" "test_secret_advice_false_positive: advice bullet landed"

# === test_lessons_unified_with_retro ===========================================
# Warm-emitted lessons are recorded as ledger `lesson` events — ONE store the retro loop reads,
# NOT a parallel learning file. The flag/event must land in the active task's log.jsonl.
"$SCRIPTS/task-init.sh" lessontask light "warm lesson test" "bash check.sh" >/dev/null
"$SCRIPTS/task-record.sh" lesson summary="the writer denylist must casefold + a parallel store breaks retro attribution" >/dev/null
assert_contains "$(cat .claude/maestro/lessontask/log.jsonl)" '"event":"lesson"' "test_lessons_unified_with_retro: warm lesson recorded as a ledger lesson event"
assert_contains "$(cat .claude/maestro/lessontask/log.jsonl)" "casefold" "test_lessons_unified_with_retro: lesson summary captured in the ledger"
# No parallel learning store is created by recording a lesson — the inbox/section sinks are only
# touched by the consolidator/writer, never by `lesson` recording.
assert_file_absent .claude/maestro/lessons.jsonl "test_lessons_unified_with_retro: no parallel lessons store created"
assert_file_absent .claude/maestro/lessons.md "test_lessons_unified_with_retro: no parallel lessons markdown created"

summary "distill"
