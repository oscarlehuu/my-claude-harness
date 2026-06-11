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

# --- maestro-engage: registry nudge ---------------------------------------------
# No HQ -> a teammate without a company sees zero noise. Point at a path that does
# not exist so a real HQ in the runner's env can't make this flake.
MAESTRO_HQ="/nonexistent-hq-$$" run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_not_contains "$HOOK_OUT" "not on the company board" "no HQ -> no nudge"

# Stand up a fake HQ with an empty registry.
NUDGE_HQ="$(mktemp -d "${TMPDIR:-/tmp}/maestro-nudge-hq-XXXXXX")"
echo '{"repos": []}' > "$NUDGE_HQ/registry.json"
export MAESTRO_HQ="$NUDGE_HQ"

# Unregistered git repo -> the nudge appears.
run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_contains "$HOOK_OUT" "not on the company board" "unregistered repo gets the nudge"
assert_contains "$HOOK_OUT" "registry-add.sh" "nudge names the add script"

# Dismiss marker present -> silent.
mkdir -p "$REPO/.claude/maestro"
touch "$REPO/.claude/maestro/registry-nudge-off"
run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_not_contains "$HOOK_OUT" "not on the company board" "dismiss marker silences the nudge"
rm "$REPO/.claude/maestro/registry-nudge-off"

# Repo now in the registry (realpath, so resolve symlinks like /private on macOS) -> silent.
python3 - "$NUDGE_HQ" "$REPO" <<'PY'
import json, os, sys
hq, repo = sys.argv[1], os.path.realpath(sys.argv[2])
with open(os.path.join(hq, "registry.json"), "w") as f:
    json.dump({"repos": [{"name": "demo", "path": repo}]}, f)
PY
run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_not_contains "$HOOK_OUT" "not on the company board" "registered repo gets no nudge"

# The HQ must not nudge itself even when it is its own git repo.
git -C "$NUDGE_HQ" init -q
git -C "$NUDGE_HQ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
CLAUDE_PROJECT_DIR="$NUDGE_HQ" run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_not_contains "$HOOK_OUT" "not on the company board" "HQ does not nudge about itself"
export CLAUDE_PROJECT_DIR="$REPO"

unset MAESTRO_HQ
rm -rf "$NUDGE_HQ"
cd "$REPO"

# --- maestro-engage: context slots (company + personal) -------------------------
# Two optional identity layers loaded at fire time: company conventions
# ($HQ/knowledge/conventions.md) and the human (~/.claude/me.md, $MAESTRO_ME seam).
SLOT_HQ="$(mktemp -d "${TMPDIR:-/tmp}/maestro-slot-hq-XXXXXX")"
mkdir -p "$SLOT_HQ/knowledge"
printf 'Ship behind a flag.\nNever push to main.\n' > "$SLOT_HQ/knowledge/conventions.md"
SLOT_ME="$(mktemp "${TMPDIR:-/tmp}/maestro-slot-me-XXXXXX")"
printf 'Oscar — founder. Terse reports.\n' > "$SLOT_ME"

# Company conventions present -> header + content. Point ME at a nonexistent path so a
# real ~/.claude/me.md on the runner can't make the "company only" assertions flake.
MAESTRO_HQ="$SLOT_HQ" MAESTRO_ME="/nonexistent-me-$$" \
  run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_contains "$HOOK_OUT" "Company conventions:" "engage prints company header when conventions present"
assert_contains "$HOOK_OUT" "Never push to main." "engage prints company content"
assert_not_contains "$HOOK_OUT" "About the human:" "no me.md -> no personal header"

# Conventions file missing (HQ dir exists, file absent) -> no company header.
rm "$SLOT_HQ/knowledge/conventions.md"
MAESTRO_HQ="$SLOT_HQ" MAESTRO_ME="/nonexistent-me-$$" \
  run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_not_contains "$HOOK_OUT" "Company conventions:" "missing conventions file -> no company header"
printf 'Ship behind a flag.\nNever push to main.\n' > "$SLOT_HQ/knowledge/conventions.md"

# HQ pointer missing entirely (no env, no ~/.claude/maestro-hq it can reach) -> no
# company header. A teammate without an office sees zero company noise. We point MAESTRO_HQ
# at a nonexistent path: empty resolution falls through, dead path reads nothing.
MAESTRO_HQ="/nonexistent-hq-$$" MAESTRO_ME="/nonexistent-me-$$" \
  run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_not_contains "$HOOK_OUT" "Company conventions:" "dead HQ path -> no company header"

# Personal slot present (via MAESTRO_ME seam) -> header + content; no HQ -> no company.
MAESTRO_HQ="/nonexistent-hq-$$" MAESTRO_ME="$SLOT_ME" \
  run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_contains "$HOOK_OUT" "About the human:" "engage prints personal header when me.md present"
assert_contains "$HOOK_OUT" "Oscar — founder." "engage prints personal content"
assert_not_contains "$HOOK_OUT" "Company conventions:" "personal present, no HQ -> no company header"

# me.md absent -> no personal header.
MAESTRO_HQ="/nonexistent-hq-$$" MAESTRO_ME="/nonexistent-me-$$" \
  run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_not_contains "$HOOK_OUT" "About the human:" "absent me.md -> no personal header"

# Both present -> both blocks, company FIRST (framework -> company -> person order).
MAESTRO_HQ="$SLOT_HQ" MAESTRO_ME="$SLOT_ME" \
  run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_contains "$HOOK_OUT" "Company conventions:" "both present -> company header"
assert_contains "$HOOK_OUT" "About the human:" "both present -> personal header"
cpos="$(printf '%s\n' "$HOOK_OUT" | grep -n 'Company conventions:' | head -1 | cut -d: -f1)"
hpos="$(printf '%s\n' "$HOOK_OUT" | grep -n 'About the human:' | head -1 | cut -d: -f1)"
if [ -n "$cpos" ] && [ -n "$hpos" ] && [ "$cpos" -lt "$hpos" ]; then
  _result ok "company slot prints before personal slot"
else
  _result fail "company slot prints before personal slot" "company line $cpos, human line $hpos"
fi

# Runaway file (>60 lines) -> first 60 lines + one truncation notice.
python3 -c "print('\n'.join('cv-line-%d' % i for i in range(1, 71)))" > "$SLOT_HQ/knowledge/conventions.md"
MAESTRO_HQ="$SLOT_HQ" MAESTRO_ME="/nonexistent-me-$$" \
  run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_contains "$HOOK_OUT" "cv-line-60" "engage prints the 60th line of a long file"
assert_not_contains "$HOOK_OUT" "cv-line-61" "engage stops at 60 lines"
assert_contains "$HOOK_OUT" "truncated — keep this file under 60 lines" "engage adds the truncation notice"
printf 'Ship behind a flag.\nNever push to main.\n' > "$SLOT_HQ/knowledge/conventions.md"

# Blank-only conventions -> no header (non-blank rule).
printf '   \n\t\n' > "$SLOT_HQ/knowledge/conventions.md"
MAESTRO_HQ="$SLOT_HQ" MAESTRO_ME="/nonexistent-me-$$" \
  run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_not_contains "$HOOK_OUT" "Company conventions:" "blank conventions -> no company header"
printf 'Ship behind a flag.\nNever push to main.\n' > "$SLOT_HQ/knowledge/conventions.md"

# Unreadable conventions (chmod 000) -> silent for the slot, hook still exits 0 and
# still prints its normal status lines. (Skipped when running as root, which ignores perms.)
if [ "$(id -u)" != "0" ]; then
  chmod 000 "$SLOT_HQ/knowledge/conventions.md"
  MAESTRO_HQ="$SLOT_HQ" MAESTRO_ME="/nonexistent-me-$$" \
    run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
  assert_exit 0 "$HOOK_EXIT" "engage exits 0 with an unreadable slot file"
  assert_not_contains "$HOOK_OUT" "Company conventions:" "unreadable conventions -> silent slot"
  assert_contains "$HOOK_OUT" "CTO mode" "engage still prints its normal status with an unreadable slot"
  chmod 644 "$SLOT_HQ/knowledge/conventions.md"
fi

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

# --- crew-context: context slots ------------------------------------------------
# Same two identity layers as engage, injected into the crew's additionalContext.
# Both present -> both blocks, company first.
MAESTRO_HQ="$SLOT_HQ" MAESTRO_ME="$SLOT_ME" \
  run_hook "$HOOKS/crew-context.sh" "$dev_payload"
ctx="$(json_field "$HOOK_OUT" "d['hookSpecificOutput']['additionalContext']")"
assert_contains "$ctx" "Company conventions:" "crew gets company header when conventions present"
assert_contains "$ctx" "Never push to main." "crew gets company content"
assert_contains "$ctx" "About the human:" "crew gets personal header when me.md present"
assert_contains "$ctx" "Oscar — founder." "crew gets personal content"
cpos="$(printf '%s' "$ctx" | grep -n 'Company conventions:' | head -1 | cut -d: -f1)"
hpos="$(printf '%s' "$ctx" | grep -n 'About the human:' | head -1 | cut -d: -f1)"
if [ -n "$cpos" ] && [ -n "$hpos" ] && [ "$cpos" -lt "$hpos" ]; then
  _result ok "crew company slot prints before personal slot"
else
  _result fail "crew company slot prints before personal slot" "company line $cpos, human line $hpos"
fi

# Absent -> neither block.
MAESTRO_HQ="/nonexistent-hq-$$" MAESTRO_ME="/nonexistent-me-$$" \
  run_hook "$HOOKS/crew-context.sh" "$dev_payload"
ctx="$(json_field "$HOOK_OUT" "d['hookSpecificOutput']['additionalContext']")"
assert_not_contains "$ctx" "Company conventions:" "crew: no HQ -> no company header"
assert_not_contains "$ctx" "About the human:" "crew: absent me.md -> no personal header"

# Runaway file -> truncated at 60 + notice.
python3 -c "print('\n'.join('cv-line-%d' % i for i in range(1, 71)))" > "$SLOT_HQ/knowledge/conventions.md"
MAESTRO_HQ="$SLOT_HQ" MAESTRO_ME="/nonexistent-me-$$" \
  run_hook "$HOOKS/crew-context.sh" "$dev_payload"
ctx="$(json_field "$HOOK_OUT" "d['hookSpecificOutput']['additionalContext']")"
assert_contains "$ctx" "cv-line-60" "crew gets the 60th line of a long file"
assert_not_contains "$ctx" "cv-line-61" "crew slot stops at 60 lines"
assert_contains "$ctx" "truncated — keep this file under 60 lines" "crew slot adds the truncation notice"
printf 'Ship behind a flag.\nNever push to main.\n' > "$SLOT_HQ/knowledge/conventions.md"

# Fail-silent: unreadable file -> silent slot, hook still exits 0. (Skip as root.)
if [ "$(id -u)" != "0" ]; then
  chmod 000 "$SLOT_HQ/knowledge/conventions.md"
  MAESTRO_HQ="$SLOT_HQ" MAESTRO_ME="/nonexistent-me-$$" \
    run_hook "$HOOKS/crew-context.sh" "$dev_payload"
  assert_exit 0 "$HOOK_EXIT" "crew-context exits 0 with an unreadable slot file"
  ctx="$(json_field "$HOOK_OUT" "d['hookSpecificOutput']['additionalContext']")"
  assert_not_contains "$ctx" "Company conventions:" "crew: unreadable conventions -> silent slot"
  assert_contains "$ctx" "developer crew member" "crew still gets its normal context with an unreadable slot"
  chmod 644 "$SLOT_HQ/knowledge/conventions.md"
fi

rm -rf "$SLOT_HQ" "$SLOT_ME"

summary "context-hooks"
