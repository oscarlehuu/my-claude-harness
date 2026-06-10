#!/usr/bin/env bash
# Probe script for guard-block-main-edits.sh and guard-block-main-bash.sh.
# Feeds JSON payloads to both hooks and asserts expected exit codes.
# Must print all-pass and exit 0 on a correct implementation.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EDIT_GUARD="$HARNESS_DIR/hooks/guard-block-main-edits.sh"
BASH_GUARD="$HARNESS_DIR/hooks/guard-block-main-bash.sh"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

run_hook_proj() {
  local hook="$1"
  local payload="$2"
  local expected_exit="$3"
  local label="$4"
  local proj_dir="$5"

  local actual_exit=0
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$proj_dir" "$hook" >/dev/null 2>&1 || actual_exit=$?

  if [ "$actual_exit" -eq "$expected_exit" ]; then
    echo "  PASS [$label] (exit $actual_exit)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$label] expected exit $expected_exit got $actual_exit"
    FAIL=$((FAIL + 1))
  fi
}

run_hook_capture_proj() {
  local hook="$1"
  local payload="$2"
  local expected_exit="$3"
  local label="$4"
  local proj_dir="$5"
  local outfile="$6"

  local actual_exit=0
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$proj_dir" "$hook" >"$outfile" 2>&1 || actual_exit=$?

  if [ "$actual_exit" -eq "$expected_exit" ]; then
    echo "  PASS [$label] (exit $actual_exit)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$label] expected exit $expected_exit got $actual_exit"
    cat "$outfile" | sed 's/^/    stderr: /'
    FAIL=$((FAIL + 1))
  fi
}

assert_file_jq() {
  local file="$1"
  local jq_expr="$2"
  local label="$3"
  if [ -f "$file" ] && jq -e "$jq_expr" "$file" >/dev/null 2>&1; then
    echo "  PASS [$label]"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$label]"
    [ -f "$file" ] && cat "$file" | sed 's/^/    log: /'
    FAIL=$((FAIL + 1))
  fi
}

make_repo() {
  local name="$1"
  local budget="${2:-}"
  local repo="$TMP_ROOT/$name"
  mkdir -p "$repo/src" "$repo/hooks" "$repo/skills/.claude" "$repo/.claude/maestroX" "$repo/skills/maestro" "$repo/docs"
  printf 'const base = 1;\n' > "$repo/src/app.ts"
  printf 'const other = 2;\n' > "$repo/src/other.ts"
  printf 'echo guard\n' > "$repo/hooks/guard-block-main-bash.sh"
  printf 'evil\n' > "$repo/skills/.claude/maestro-evil.ts"
  printf 'x\n' > "$repo/.claude/maestroX/anything.ts"
  printf '# skill\n' > "$repo/skills/maestro/SKILL.md"
  printf '# docs\n' > "$repo/docs/readme.md"
  if [ -n "$budget" ]; then
    mkdir -p "$repo/.claude"
    printf '%s\n' "$budget" > "$repo/.claude/maestro-budget"
  fi
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  git -C "$repo" add .
  git -C "$repo" commit -qm init
  printf '%s' "$repo"
}

edit_payload() {
  local file_path="$1"
  local agent_id="${2:-}"
  if [ -n "$agent_id" ]; then
    jq -n --arg p "$file_path" --arg aid "$agent_id" '{agent_id:$aid,tool_input:{file_path:$p}}'
  else
    jq -n --arg p "$file_path" '{tool_input:{file_path:$p}}'
  fi
}

edit_payload_content() {
  local file_path="$1"
  local content="$2"
  jq -n --arg p "$file_path" --arg c "$content" '{tool_input:{file_path:$p,content:$c}}'
}

edit_payload_replace() {
  local file_path="$1"
  local old="$2"
  local new="$3"
  jq -n --arg p "$file_path" --arg o "$old" --arg n "$new" '{tool_input:{file_path:$p,old_string:$o,new_string:$n}}'
}

bash_payload() {
  local command="$1"
  local agent_id="${2:-}"
  if [ -n "$agent_id" ]; then
    jq -n --arg cmd "$command" --arg aid "$agent_id" '{agent_id:$aid,tool_input:{command:$cmd}}'
  else
    jq -n --arg cmd "$command" '{tool_input:{command:$cmd}}'
  fi
}

BASE_REPO="$(make_repo base)"
STRICT_REPO="$(make_repo strict 'LINES=50
FILES=2
PROTECTED=src/**:hooks/**:skills/.claude/**:.claude/maestroX/**')"

# ---------------------------------------------------------------------------
echo "=== edit-guard carve-out and protected-path tests ==="

run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload '/tmp/bench.mjs')" \
  0 \
  "Write /tmp/bench.mjs (no agent_id) → ALLOW" \
  "$BASE_REPO"

_tmpdir="${TMPDIR:-/tmp}"
_tmpdir="${_tmpdir%/}"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload "${_tmpdir}/scratch/foo.ts")" \
  0 \
  "Write \$TMPDIR/scratch/foo.ts → ALLOW" \
  "$BASE_REPO"

run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload '/private/tmp/recon.json')" \
  0 \
  "Write /private/tmp/recon.json → ALLOW" \
  "$BASE_REPO"

run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload '/var/folders/ab/cd1234/T/scratch.sh')" \
  0 \
  "Write /var/folders/... → ALLOW" \
  "$BASE_REPO"

run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$BASE_REPO/src/app.ts" 'small')" \
  0 \
  "Under-budget edit to repo file → ALLOW" \
  "$BASE_REPO"

run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content 'src/app.ts' 'small')" \
  0 \
  "Under-budget relative-path edit to repo file → ALLOW" \
  "$BASE_REPO"

run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$STRICT_REPO/src/app.ts" 'small')" \
  2 \
  "Protected repo file → BLOCK" \
  "$STRICT_REPO"

run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload "$STRICT_REPO/src/app.ts" "developer-agent-001")" \
  0 \
  "Subagent Write repo file → ALLOW" \
  "$STRICT_REPO"

run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload "$STRICT_REPO/.claude/maestro.json")" \
  0 \
  ".claude/maestro.json harness state → ALLOW" \
  "$STRICT_REPO"

run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload "$STRICT_REPO/.claude/maestro/some-plan-slug/state.json")" \
  0 \
  ".claude/maestro/<slug>/state.json genuine ledger → ALLOW" \
  "$STRICT_REPO"

run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload "$BASE_REPO/docs/readme.md")" \
  0 \
  "Prose/docs direct edit → ALLOW" \
  "$BASE_REPO"

# ---------------------------------------------------------------------------
echo ""
echo "=== maestro carve-out anchoring tests (edit-guard) ==="

run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload "$STRICT_REPO/.claude/maestro/../../hooks/guard-block-main-bash.sh")" \
  2 \
  ".claude/maestro/../../hooks/guard-block-main-bash.sh traversal → BLOCK" \
  "$STRICT_REPO"

run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload "$STRICT_REPO/skills/.claude/maestro-evil.ts")" \
  2 \
  "skills/.claude/maestro-evil.ts unanchored substring → BLOCK" \
  "$STRICT_REPO"

run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload "$STRICT_REPO/.claude/maestroX/anything.ts")" \
  2 \
  ".claude/maestroX/anything.ts (unanchored suffix) → BLOCK" \
  "$STRICT_REPO"

# ---------------------------------------------------------------------------
echo ""
echo "=== bash-guard carve-out, read-only, and protected-path tests ==="

HEREDOC_CMD="$(printf "cat > /tmp/b.mjs <<'EOF'\nconst x = a > Number(b);\nfs.writeFileSync('/tmp/out.txt', x);\nEOF")"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "$HEREDOC_CMD")" \
  0 \
  "heredoc with > in body → ALLOW" \
  "$BASE_REPO"

run_hook_proj "$BASH_GUARD" \
  "$(bash_payload 'echo hi > /tmp/x')" \
  0 \
  "echo hi > /tmp/x → ALLOW" \
  "$BASE_REPO"

run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $BASE_REPO/src/app.ts")" \
  0 \
  "Under-budget echo hi > repo file → ALLOW" \
  "$BASE_REPO"

run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $STRICT_REPO/src/app.ts")" \
  2 \
  "Protected echo hi > repo file → BLOCK" \
  "$STRICT_REPO"

run_hook_proj "$BASH_GUARD" \
  "$(bash_payload 'echo hi > src/app.ts')" \
  2 \
  "Protected relative-path echo hi > repo file → BLOCK" \
  "$STRICT_REPO"

run_hook_proj "$BASH_GUARD" \
  "$(bash_payload 'grep ">" file.txt')" \
  0 \
  'grep ">" file.txt → ALLOW' \
  "$BASE_REPO"

run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $STRICT_REPO/src/app.ts" "developer-agent-001")" \
  0 \
  "Subagent redirect to repo → ALLOW" \
  "$STRICT_REPO"

run_hook_proj "$BASH_GUARD" \
  "$(bash_payload 'some-command > /dev/null 2>&1')" \
  0 \
  "redirect to /dev/null → ALLOW" \
  "$BASE_REPO"

# ---------------------------------------------------------------------------
echo ""
echo "=== maestro carve-out anchoring tests (bash-guard) ==="

run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo evil > $STRICT_REPO/.claude/maestro/../../hooks/guard-block-main-bash.sh")" \
  2 \
  "echo > .claude/maestro/../../hooks/guard-block-main-bash.sh traversal → BLOCK" \
  "$STRICT_REPO"

run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo evil > $STRICT_REPO/skills/.claude/maestro-evil.ts")" \
  2 \
  "echo > skills/.claude/maestro-evil.ts unanchored substring → BLOCK" \
  "$STRICT_REPO"

run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo evil > $STRICT_REPO/.claude/maestroX/anything.ts")" \
  2 \
  "echo > .claude/maestroX/anything.ts (unanchored suffix) → BLOCK" \
  "$STRICT_REPO"

run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo '{}' > $STRICT_REPO/.claude/maestro/some-plan/state.json")" \
  0 \
  "echo > .claude/maestro/<slug>/state.json genuine ledger → ALLOW" \
  "$STRICT_REPO"

# ---------------------------------------------------------------------------
echo ""
echo "=== path-traversal tests (canonicalize before prefix checks) ==="

run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload "/tmp/../../$STRICT_REPO/src/app.ts")" \
  2 \
  "/tmp/../../<repo>/src/app.ts path traversal → BLOCK" \
  "$STRICT_REPO"

_tmpdir_clean="${TMPDIR:-/tmp}"
_tmpdir_clean="${_tmpdir_clean%/}"
_depth=$(python3 -c "import sys; p=sys.argv[1].lstrip('/'); print(len([c for c in p.split('/') if c]))" "$_tmpdir_clean")
_dots=$(python3 -c "print('/'.join(['..'] * int('$_depth')))")
_traversal_path="${_tmpdir_clean}/${_dots}${STRICT_REPO}/src/app.ts"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload "$_traversal_path")" \
  2 \
  "\$TMPDIR/<N-dots>/<repo>/src/app.ts path traversal → BLOCK" \
  "$STRICT_REPO"

run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo x > /tmp/../../$STRICT_REPO/src/app.ts")" \
  2 \
  "echo x > /tmp/../../<repo>/src/app.ts path traversal → BLOCK" \
  "$STRICT_REPO"

# ---------------------------------------------------------------------------
echo ""
echo "=== heredoc-with-redirect tests (bash-guard) ==="

HEREDOC_REPO_CMD="$(printf "cat <<'EOF' > %s/src/app.ts\nhello\nEOF" "$STRICT_REPO")"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "$HEREDOC_REPO_CMD")" \
  2 \
  "cat <<'EOF' > <repo>/src/app.ts → BLOCK" \
  "$STRICT_REPO"

HEREDOC_TEE_CMD="$(printf "cat <<'EOF' | tee %s/src/app.ts\nhello\nEOF" "$STRICT_REPO")"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "$HEREDOC_TEE_CMD")" \
  2 \
  "cat <<'EOF' | tee <repo>/src/app.ts → BLOCK" \
  "$STRICT_REPO"

HEREDOC_TMP_CMD="$(printf "cat <<'EOF' > /tmp/safe.txt\nhello\nEOF")"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "$HEREDOC_TMP_CMD")" \
  0 \
  "cat <<'EOF' > /tmp/safe.txt → ALLOW" \
  "$BASE_REPO"

# ---------------------------------------------------------------------------
echo ""
echo "=== nested bash -c heredoc tests (bash-guard) ==="

NESTED_BASH_CMD="$(printf "bash -c \"cat <<'EOF' > %s/src/app.ts\nmalicious\nEOF\"" "$STRICT_REPO")"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "$NESTED_BASH_CMD")" \
  2 \
  "bash -c heredoc > repo → BLOCK" \
  "$STRICT_REPO"

NESTED_SH_CMD="$(printf "sh -c \"cat <<'EOF' > %s/src/app.ts\nmalicious\nEOF\"" "$STRICT_REPO")"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "$NESTED_SH_CMD")" \
  2 \
  "sh -c heredoc > repo → BLOCK" \
  "$STRICT_REPO"

NESTED_TMP_CMD="$(printf "bash -c \"cat <<'EOF' > /tmp/safe.txt\nhello\nEOF\"")"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "$NESTED_TMP_CMD")" \
  0 \
  "bash -c heredoc > /tmp/safe.txt → ALLOW" \
  "$BASE_REPO"

# ---------------------------------------------------------------------------
echo ""
echo "=== escaped-quote and unparseable coverage tests (bash-guard) ==="

EQ_CMD="$(printf 'bash -c "cat <<'"'"'EOF'"'"' > %s/src/app.ts\nmal\nEOF\\\""' "$STRICT_REPO")"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "$EQ_CMD")" \
  2 \
  "bash -c with escaped-quote heredoc terminator EOF\\\" > repo → BLOCK" \
  "$STRICT_REPO"

DN_CMD="$(printf 'bash -c "bash -c \\"cat <<'"'"'EOF'"'"' > %s/src/app.ts\nmal\nEOF\\""' "$STRICT_REPO")"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "$DN_CMD")" \
  2 \
  "double-nested bash -c heredoc > repo → BLOCK" \
  "$STRICT_REPO"

OVER_REPO="$(make_repo unparse-over 'LINES=0
FILES=2')"
printf 'changed\n' >> "$OVER_REPO/src/app.ts"
UNPARSE_CMD="echo 'unclosed redirect > ${OVER_REPO}/src/app.ts"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "$UNPARSE_CMD")" \
  2 \
  "unparseable command with mutation evidence over budget → BLOCK" \
  "$OVER_REPO"

UNPARSE_CLOBBER="echo 'unclosed >| ${OVER_REPO}/src/app.ts"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "$UNPARSE_CLOBBER")" \
  2 \
  "unparseable >| over budget → BLOCK" \
  "$OVER_REPO"

UNPARSE_AMPGT="echo 'unclosed &> ${OVER_REPO}/src/app.ts"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "$UNPARSE_AMPGT")" \
  2 \
  "unparseable &> over budget → BLOCK" \
  "$OVER_REPO"

UNPARSE_FD="echo 'unclosed 1> ${OVER_REPO}/src/app.ts"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "$UNPARSE_FD")" \
  2 \
  "unparseable 1> over budget → BLOCK" \
  "$OVER_REPO"

UNPARSE_FDUP="some-read-only-cmd 'unclosed 2>&1"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "$UNPARSE_FDUP")" \
  0 \
  "unparseable fd-dup 2>&1 only → ALLOW" \
  "$BASE_REPO"

# ---------------------------------------------------------------------------
echo ""
echo "=== budget/config/log tests ==="

CREEP_REPO="$(make_repo creep 'LINES=3
FILES=2')"
printf 'one\ntwo\n' >> "$CREEP_REPO/src/app.ts"
run_hook_capture_proj "$EDIT_GUARD" \
  "$(edit_payload_replace "$CREEP_REPO/src/other.ts" 'old' 'new1
new2')" \
  2 \
  "Cumulative creep crosses line budget → BLOCK" \
  "$CREEP_REPO" "$TMP_ROOT/creep.out"
grep -q 'REMAINDER of this task' "$TMP_ROOT/creep.out" && echo "  PASS [budget block message is model re-prompt]" && PASS=$((PASS + 1)) || { echo "  FAIL [budget block message is model re-prompt]"; FAIL=$((FAIL + 1)); }

OVERSIZE_REPO="$(make_repo oversize 'LINES=2
FILES=2')"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$OVERSIZE_REPO/src/app.ts" 'a
b
c')" \
  2 \
  "Single oversized edit blocked via projection → BLOCK" \
  "$OVERSIZE_REPO"

UNTRACKED_REPO="$(make_repo untracked 'LINES=2
FILES=3')"
printf 'a\nb\nc\n' > "$UNTRACKED_REPO/src/new-file.ts"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_replace "$UNTRACKED_REPO/src/app.ts" '' '')" \
  2 \
  "Untracked new file counted toward budget → BLOCK" \
  "$UNTRACKED_REPO"

CUSTOM_ALLOW_REPO="$(make_repo custom-allow 'LINES=4
FILES=1')"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$CUSTOM_ALLOW_REPO/src/app.ts" 'a
b
c
d')" \
  0 \
  "Custom .claude/maestro-budget respected at equality → ALLOW" \
  "$CUSTOM_ALLOW_REPO"

CUSTOM_BLOCK_REPO="$(make_repo custom-block 'LINES=1
FILES=1')"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$CUSTOM_BLOCK_REPO/src/app.ts" 'a
b')" \
  2 \
  "Custom .claude/maestro-budget lower line cap → BLOCK" \
  "$CUSTOM_BLOCK_REPO"

PROT_REPO="$(make_repo protected-zero 'LINES=50
FILES=2
PROTECTED=src/**')"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$PROT_REPO/src/app.ts" 'x')" \
  2 \
  "Protected path blocked even at zero usage → BLOCK" \
  "$PROT_REPO"
assert_file_jq "$PROT_REPO/.claude/maestro/guard-log.jsonl" \
  'select(.hook=="guard-block-main-edits" and .reason=="protected" and .lines_used==0 and .files_used==0)' \
  "edit guard-log.jsonl line written on protected block"

BASH_BUDGET_REPO="$(make_repo bash-budget 'LINES=0
FILES=2')"
printf 'changed\n' >> "$BASH_BUDGET_REPO/src/app.ts"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $BASH_BUDGET_REPO/src/other.ts")" \
  2 \
  "Bash mutating command over current budget → BLOCK" \
  "$BASH_BUDGET_REPO"
assert_file_jq "$BASH_BUDGET_REPO/.claude/maestro/guard-log.jsonl" \
  'select(.hook=="guard-block-main-bash" and .reason=="budget" and .lines_used>0)' \
  "bash guard-log.jsonl line written on budget block"

BASH_PROT_REPO="$(make_repo bash-protected 'LINES=50
FILES=2
PROTECTED=src/**')"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $BASH_PROT_REPO/src/app.ts")" \
  2 \
  "Bash protected path blocked at zero usage → BLOCK" \
  "$BASH_PROT_REPO"
assert_file_jq "$BASH_PROT_REPO/.claude/maestro/guard-log.jsonl" \
  'select(.hook=="guard-block-main-bash" and .reason=="protected" and .lines_used==0 and .files_used==0)' \
  "bash guard-log.jsonl line written on protected block"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
