#!/usr/bin/env bash
# Probe script for guard-block-main-edits.sh and guard-block-main-bash.sh.
# Feeds JSON payloads to both hooks and asserts expected exit codes.
# Must print all-pass and exit 0 on a correct implementation.
set -euo pipefail

HARNESS_DIR="/Users/a1241968/Desktop/Oscar/my-claude-harness"
EDIT_GUARD="$HARNESS_DIR/hooks/guard-block-main-edits.sh"
BASH_GUARD="$HARNESS_DIR/hooks/guard-block-main-bash.sh"

PASS=0
FAIL=0

run_hook() {
  local hook="$1"
  local payload="$2"
  local expected_exit="$3"
  local label="$4"

  actual_exit=0
  printf '%s' "$payload" | "$hook" >/dev/null 2>&1 || actual_exit=$?

  if [ "$actual_exit" -eq "$expected_exit" ]; then
    echo "  PASS [$label] (exit $actual_exit)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$label] expected exit $expected_exit got $actual_exit"
    FAIL=$((FAIL + 1))
  fi
}

# Like run_hook but sets CLAUDE_PROJECT_DIR so the guard's repo-root is known.
# Used for maestro carve-out ALLOW tests where the tested path must be inside a
# specific repo root (not necessarily $PWD at test-run time).
run_hook_proj() {
  local hook="$1"
  local payload="$2"
  local expected_exit="$3"
  local label="$4"
  local proj_dir="$5"

  actual_exit=0
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$proj_dir" "$hook" >/dev/null 2>&1 || actual_exit=$?

  if [ "$actual_exit" -eq "$expected_exit" ]; then
    echo "  PASS [$label] (exit $actual_exit)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$label] expected exit $expected_exit got $actual_exit"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Helpers to build JSON payloads.
# ---------------------------------------------------------------------------
edit_payload() {
  local file_path="$1"
  local agent_id="${2:-}"
  if [ -n "$agent_id" ]; then
    printf '{"agent_id":"%s","tool_input":{"file_path":"%s"}}' "$agent_id" "$file_path"
  else
    printf '{"tool_input":{"file_path":"%s"}}' "$file_path"
  fi
}

bash_payload() {
  local command="$1"
  local agent_id="${2:-}"
  if [ -n "$agent_id" ]; then
    printf '{"agent_id":"%s","tool_input":{"command":"%s"}}' "$agent_id" "$command"
  else
    printf '{"tool_input":{"command":"%s"}}' "$command"
  fi
}

# For multi-line bash commands we use jq to safely encode the JSON.
bash_payload_multiline() {
  local command="$1"
  local agent_id="${2:-}"
  if [ -n "$agent_id" ]; then
    jq -n --arg cmd "$command" --arg aid "$agent_id" \
      '{"agent_id":$aid,"tool_input":{"command":$cmd}}'
  else
    jq -n --arg cmd "$command" \
      '{"tool_input":{"command":$cmd}}'
  fi
}

# ---------------------------------------------------------------------------
echo "=== edit-guard tests ==="

# /tmp path → ALLOW (exit 0)
run_hook "$EDIT_GUARD" \
  "$(edit_payload '/tmp/bench.mjs')" \
  0 \
  "Write /tmp/bench.mjs (no agent_id) → ALLOW"

# $TMPDIR-style path → ALLOW (exit 0)
_tmpdir="${TMPDIR:-/tmp}"
_tmpdir="${_tmpdir%/}"
run_hook "$EDIT_GUARD" \
  "$(edit_payload "${_tmpdir}/scratch/foo.ts")" \
  0 \
  "Write \$TMPDIR/scratch/foo.ts → ALLOW"

# /private/tmp path → ALLOW (exit 0)
run_hook "$EDIT_GUARD" \
  "$(edit_payload '/private/tmp/recon.json')" \
  0 \
  "Write /private/tmp/recon.json → ALLOW"

# /var/folders path → ALLOW (exit 0)
run_hook "$EDIT_GUARD" \
  "$(edit_payload '/var/folders/ab/cd1234/T/scratch.sh')" \
  0 \
  "Write /var/folders/... → ALLOW"

# Repo file → BLOCK (exit 2)
run_hook "$EDIT_GUARD" \
  "$(edit_payload "$HARNESS_DIR/src/app.ts")" \
  2 \
  "Write <repo>/src/app.ts → BLOCK"

# Subagent writing repo file → ALLOW (exit 0)
run_hook "$EDIT_GUARD" \
  "$(edit_payload "$HARNESS_DIR/src/app.ts" "developer-agent-001")" \
  0 \
  "Subagent Write repo file → ALLOW"

# .claude/maestro.json → ALLOW (exit 0).
# Use run_hook_proj so the guard's repo root matches HARNESS_DIR (otherwise proj=$PWD
# and the canonical allowed paths would be in a different repo).
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload "$HARNESS_DIR/.claude/maestro.json")" \
  0 \
  ".claude/maestro.json harness state → ALLOW" \
  "$HARNESS_DIR"

# .claude/maestro/slug/state.json (genuine ledger entry) → ALLOW (exit 0)
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload "$HARNESS_DIR/.claude/maestro/some-plan-slug/state.json")" \
  0 \
  ".claude/maestro/<slug>/state.json genuine ledger → ALLOW" \
  "$HARNESS_DIR"

# ---------------------------------------------------------------------------
echo ""
echo "=== maestro carve-out anchoring tests (edit-guard) ==="

# Traversal through .claude/maestro/ to a production file → BLOCK (exit 2)
run_hook "$EDIT_GUARD" \
  "$(edit_payload "$HARNESS_DIR/.claude/maestro/../../hooks/guard-block-main-bash.sh")" \
  2 \
  ".claude/maestro/../../hooks/guard-block-main-bash.sh traversal → BLOCK"

# Path containing maestro substring in unrelated location → BLOCK (exit 2)
run_hook "$EDIT_GUARD" \
  "$(edit_payload "$HARNESS_DIR/skills/.claude/maestro-evil.ts")" \
  2 \
  "skills/.claude/maestro-evil.ts unanchored substring → BLOCK"

# maestroX directory (not the maestro ledger dir) → BLOCK (exit 2)
run_hook "$EDIT_GUARD" \
  "$(edit_payload "$HARNESS_DIR/.claude/maestroX/anything.ts")" \
  2 \
  ".claude/maestroX/anything.ts (unanchored suffix) → BLOCK"

# ---------------------------------------------------------------------------
echo ""
echo "=== bash-guard tests ==="

# cat > /tmp/b.mjs <<'EOF'\nconst x = a > Number(b);\nEOF → ALLOW
# The heredoc body contains > which must NOT be scanned as a redirect.
HEREDOC_CMD="$(printf "cat > /tmp/b.mjs <<'EOF'\nconst x = a > Number(b);\nfs.writeFileSync('/tmp/out.txt', x);\nEOF")"
printf '%s' "$(bash_payload_multiline "$HEREDOC_CMD")" | \
  "$BASH_GUARD" >/dev/null 2>&1 && HC_EXIT=0 || HC_EXIT=$?
if [ "$HC_EXIT" -eq 0 ]; then
  echo "  PASS [heredoc with > in body → ALLOW] (exit $HC_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL [heredoc with > in body → ALLOW] expected exit 0 got $HC_EXIT"
  FAIL=$((FAIL + 1))
fi

# plain redirect to /tmp → ALLOW (exit 0)
run_hook "$BASH_GUARD" \
  "$(bash_payload 'echo hi > /tmp/x')" \
  0 \
  "echo hi > /tmp/x → ALLOW"

# redirect to repo file → BLOCK (exit 2)
run_hook "$BASH_GUARD" \
  "$(bash_payload "echo hi > $HARNESS_DIR/src/app.ts")" \
  2 \
  "echo hi > <repo>/src/app.ts → BLOCK"

# grep with > in pattern (quoted) → ALLOW (exit 0)
run_hook "$BASH_GUARD" \
  "$(bash_payload 'grep \">\" file.txt')" \
  0 \
  'grep ">" file.txt → ALLOW'

# subagent redirect to repo file → ALLOW (exit 0)
run_hook "$BASH_GUARD" \
  "$(bash_payload "echo hi > $HARNESS_DIR/src/app.ts" "developer-agent-001")" \
  0 \
  "Subagent redirect to repo → ALLOW"

# /dev/null redirect → ALLOW (exit 0)
run_hook "$BASH_GUARD" \
  "$(bash_payload 'some-command > /dev/null 2>&1')" \
  0 \
  "redirect to /dev/null → ALLOW"

# ---------------------------------------------------------------------------
echo ""
echo "=== maestro carve-out anchoring tests (bash-guard) ==="

# Traversal through .claude/maestro/ to a production hook file → BLOCK (exit 2)
run_hook "$BASH_GUARD" \
  "$(bash_payload "echo evil > $HARNESS_DIR/.claude/maestro/../../hooks/guard-block-main-bash.sh")" \
  2 \
  "echo > .claude/maestro/../../hooks/guard-block-main-bash.sh traversal → BLOCK"

# Path containing maestro substring in unrelated location → BLOCK (exit 2)
run_hook "$BASH_GUARD" \
  "$(bash_payload "echo evil > $HARNESS_DIR/skills/.claude/maestro-evil.ts")" \
  2 \
  "echo > skills/.claude/maestro-evil.ts unanchored substring → BLOCK"

# maestroX directory (not the maestro ledger dir) → BLOCK (exit 2)
run_hook "$BASH_GUARD" \
  "$(bash_payload "echo evil > $HARNESS_DIR/.claude/maestroX/anything.ts")" \
  2 \
  "echo > .claude/maestroX/anything.ts (unanchored suffix) → BLOCK"

# Genuine maestro ledger write via redirect → ALLOW (exit 0).
# Set CLAUDE_PROJECT_DIR so the bash guard's _proj resolves to HARNESS_DIR, making the
# canonical allowed set match the path in the payload.
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo '{}' > $HARNESS_DIR/.claude/maestro/some-plan/state.json")" \
  0 \
  "echo > .claude/maestro/<slug>/state.json genuine ledger → ALLOW" \
  "$HARNESS_DIR"

# ---------------------------------------------------------------------------
echo ""
echo "=== path-traversal tests (edit-guard) ==="

# /tmp/../../<repo>/file → must BLOCK (exit 2) — path escapes tmp via ..
run_hook "$EDIT_GUARD" \
  "$(edit_payload "/tmp/../../Users/a1241968/Desktop/Oscar/my-claude-harness/skills/maestro/SKILL.md")" \
  2 \
  "/tmp/../../<repo>/file path traversal → BLOCK"

# $TMPDIR/<enough ..>/<repo>/file → must BLOCK (exit 2).
# We compute exactly how many ".." are needed to escape TMPDIR to the filesystem root,
# then append the repo-relative path so the canonical result IS the repo file.
_tmpdir_clean="${TMPDIR:-/tmp}"
_tmpdir_clean="${_tmpdir_clean%/}"
# Depth = number of path components in _tmpdir_clean (leading / gives one empty component).
_depth=$(python3 -c "import sys; p=sys.argv[1].lstrip('/'); print(len([c for c in p.split('/') if c]))" "$_tmpdir_clean")
_dots=$(python3 -c "print('/'.join(['..'] * int('$_depth')))")
_traversal_path="${_tmpdir_clean}/${_dots}/Users/a1241968/Desktop/Oscar/my-claude-harness/skills/maestro/SKILL.md"
run_hook "$EDIT_GUARD" \
  "$(edit_payload "$_traversal_path")" \
  2 \
  "\$TMPDIR/<N-dots>/<repo>/file path traversal → BLOCK"

# ---------------------------------------------------------------------------
echo ""
echo "=== path-traversal tests (bash-guard) ==="

# echo x > /tmp/../../<repo>/file → must BLOCK (exit 2)
run_hook "$BASH_GUARD" \
  "$(bash_payload "echo x > /tmp/../../Users/a1241968/Desktop/Oscar/my-claude-harness/skills/maestro/SKILL.md")" \
  2 \
  "echo x > /tmp/../../<repo>/file path traversal → BLOCK"

# ---------------------------------------------------------------------------
echo ""
echo "=== heredoc-with-redirect tests (bash-guard) ==="

# cat <<'EOF' > <repo>/src/app.ts — redirect AFTER marker must be preserved → BLOCK (exit 2)
HEREDOC_REPO_CMD="$(printf "cat <<'EOF' > %s/src/app.ts\nhello\nEOF" "$HARNESS_DIR")"
printf '%s' "$(bash_payload_multiline "$HEREDOC_REPO_CMD")" | \
  "$BASH_GUARD" >/dev/null 2>&1 && HR_EXIT=0 || HR_EXIT=$?
if [ "$HR_EXIT" -eq 2 ]; then
  echo "  PASS [cat <<'EOF' > <repo>/src/app.ts → BLOCK] (exit $HR_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL [cat <<'EOF' > <repo>/src/app.ts → BLOCK] expected exit 2 got $HR_EXIT"
  FAIL=$((FAIL + 1))
fi

# cat <<'EOF' | tee <repo>/src/app.ts — pipe+tee AFTER marker must be preserved → BLOCK (exit 2)
HEREDOC_TEE_CMD="$(printf "cat <<'EOF' | tee %s/src/app.ts\nhello\nEOF" "$HARNESS_DIR")"
printf '%s' "$(bash_payload_multiline "$HEREDOC_TEE_CMD")" | \
  "$BASH_GUARD" >/dev/null 2>&1 && HT_EXIT=0 || HT_EXIT=$?
if [ "$HT_EXIT" -eq 2 ]; then
  echo "  PASS [cat <<'EOF' | tee <repo>/src/app.ts → BLOCK] (exit $HT_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL [cat <<'EOF' | tee <repo>/src/app.ts → BLOCK] expected exit 2 got $HT_EXIT"
  FAIL=$((FAIL + 1))
fi

# cat <<'EOF' > /tmp/safe.txt — redirect to tmp must still ALLOW (exit 0)
HEREDOC_TMP_CMD="$(printf "cat <<'EOF' > /tmp/safe.txt\nhello\nEOF")"
printf '%s' "$(bash_payload_multiline "$HEREDOC_TMP_CMD")" | \
  "$BASH_GUARD" >/dev/null 2>&1 && HTMP_EXIT=0 || HTMP_EXIT=$?
if [ "$HTMP_EXIT" -eq 0 ]; then
  echo "  PASS [cat <<'EOF' > /tmp/safe.txt → ALLOW] (exit $HTMP_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL [cat <<'EOF' > /tmp/safe.txt → ALLOW] expected exit 0 got $HTMP_EXIT"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== nested bash -c heredoc tests (bash-guard) ==="

# bash -c "cat <<'EOF' > <repo>/src/app.ts\n...\nEOF" → heredoc inside bash -c must BLOCK (exit 2)
NESTED_BASH_CMD="$(printf "bash -c \"cat <<'EOF' > %s/src/app.ts\nmalicious\nEOF\"" "$HARNESS_DIR")"
printf '%s' "$(bash_payload_multiline "$NESTED_BASH_CMD")" | \
  "$BASH_GUARD" >/dev/null 2>&1 && NB_EXIT=0 || NB_EXIT=$?
if [ "$NB_EXIT" -eq 2 ]; then
  echo "  PASS [bash -c \"cat <<'EOF' > <repo>/src/app.ts → BLOCK\"] (exit $NB_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL [bash -c \"cat <<'EOF' > <repo>/src/app.ts → BLOCK\"] expected exit 2 got $NB_EXIT"
  FAIL=$((FAIL + 1))
fi

# sh -c "cat <<'EOF' > <repo>/skills/maestro/SKILL.md\n...\nEOF" → BLOCK (exit 2)
NESTED_SH_CMD="$(printf "sh -c \"cat <<'EOF' > %s/skills/maestro/SKILL.md\nmalicious\nEOF\"" "$HARNESS_DIR")"
printf '%s' "$(bash_payload_multiline "$NESTED_SH_CMD")" | \
  "$BASH_GUARD" >/dev/null 2>&1 && NS_EXIT=0 || NS_EXIT=$?
if [ "$NS_EXIT" -eq 2 ]; then
  echo "  PASS [sh -c \"cat <<'EOF' > <repo>/SKILL.md → BLOCK\"] (exit $NS_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL [sh -c \"cat <<'EOF' > <repo>/SKILL.md → BLOCK\"] expected exit 2 got $NS_EXIT"
  FAIL=$((FAIL + 1))
fi

# bash -c "cat <<'EOF' > /tmp/safe.txt\n...\nEOF" → redirect inside bash -c to tmp must ALLOW (exit 0)
NESTED_TMP_CMD="$(printf "bash -c \"cat <<'EOF' > /tmp/safe.txt\nhello\nEOF\"")"
printf '%s' "$(bash_payload_multiline "$NESTED_TMP_CMD")" | \
  "$BASH_GUARD" >/dev/null 2>&1 && NT_EXIT=0 || NT_EXIT=$?
if [ "$NT_EXIT" -eq 0 ]; then
  echo "  PASS [bash -c \"cat <<'EOF' > /tmp/safe.txt → ALLOW\"] (exit $NT_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL [bash -c \"cat <<'EOF' > /tmp/safe.txt → ALLOW\"] expected exit 0 got $NT_EXIT"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== escaped-quote heredoc terminator tests (bash-guard) ==="

# bash -c "cat <<'EOF' > <repo>/src/app.ts\nmal\nEOF\"" → escaped-quote terminator must BLOCK (exit 2)
# The closing line is EOF\" — a backslash-escaped quote follows the delimiter.
EQ_CMD="$(printf 'bash -c "cat <<'"'"'EOF'"'"' > %s/src/app.ts\nmal\nEOF\""' "$HARNESS_DIR")"
printf '%s' "$(bash_payload_multiline "$EQ_CMD")" | \
  "$BASH_GUARD" >/dev/null 2>&1 && EQ_EXIT=0 || EQ_EXIT=$?
if [ "$EQ_EXIT" -eq 2 ]; then
  echo "  PASS [bash -c with escaped-quote heredoc terminator EOF\\\" > repo → BLOCK] (exit $EQ_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL [bash -c with escaped-quote heredoc terminator EOF\\\" > repo → BLOCK] expected exit 2 got $EQ_EXIT"
  FAIL=$((FAIL + 1))
fi

# Double-nested bash -c with escaped heredoc terminator → BLOCK (exit 2)
# bash -c "bash -c \"cat <<'EOF' > <repo>/src/app.ts\nmal\nEOF\"\""
DN_CMD="$(printf 'bash -c "bash -c \\"cat <<'"'"'EOF'"'"' > %s/src/app.ts\nmal\nEOF\\""' "$HARNESS_DIR")"
printf '%s' "$(bash_payload_multiline "$DN_CMD")" | \
  "$BASH_GUARD" >/dev/null 2>&1 && DN_EXIT=0 || DN_EXIT=$?
if [ "$DN_EXIT" -eq 2 ]; then
  echo "  PASS [double-nested bash -c heredoc > repo → BLOCK] (exit $DN_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL [double-nested bash -c heredoc > repo → BLOCK] expected exit 2 got $DN_EXIT"
  FAIL=$((FAIL + 1))
fi

# Genuinely-unparseable mutating command → BLOCK (exit 2)
# Dangling open-quote hides a redirect: tokenize raises ValueError; raw coarse_reason detects it.
UNPARSE_CMD="echo 'unclosed redirect > ${HARNESS_DIR}/src/app.ts"
printf '%s' "$(bash_payload_multiline "$UNPARSE_CMD")" | \
  "$BASH_GUARD" >/dev/null 2>&1 && UP_EXIT=0 || UP_EXIT=$?
if [ "$UP_EXIT" -eq 2 ]; then
  echo "  PASS [unparseable command with mutation evidence → BLOCK] (exit $UP_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL [unparseable command with mutation evidence → BLOCK] expected exit 2 got $UP_EXIT"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== unparseable redirect-operator coverage tests (bash-guard) ==="
# These commands have a dangling open-quote so shlex raises ValueError;
# the fail-closed path (coarse_reason on raw command) must catch them.

# >| to repo path → BLOCK (exit 2)
UNPARSE_CLOBBER="echo 'unclosed >| ${HARNESS_DIR}/skills/maestro/SKILL.md"
printf '%s' "$(bash_payload_multiline "$UNPARSE_CLOBBER")" | \
  "$BASH_GUARD" >/dev/null 2>&1 && UC_EXIT=0 || UC_EXIT=$?
if [ "$UC_EXIT" -eq 2 ]; then
  echo "  PASS [unparseable >| to repo path → BLOCK] (exit $UC_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL [unparseable >| to repo path → BLOCK] expected exit 2 got $UC_EXIT"
  FAIL=$((FAIL + 1))
fi

# &> to repo path → BLOCK (exit 2)
UNPARSE_AMPGT="echo 'unclosed &> ${HARNESS_DIR}/skills/maestro/SKILL.md"
printf '%s' "$(bash_payload_multiline "$UNPARSE_AMPGT")" | \
  "$BASH_GUARD" >/dev/null 2>&1 && AG_EXIT=0 || AG_EXIT=$?
if [ "$AG_EXIT" -eq 2 ]; then
  echo "  PASS [unparseable &> to repo path → BLOCK] (exit $AG_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL [unparseable &> to repo path → BLOCK] expected exit 2 got $AG_EXIT"
  FAIL=$((FAIL + 1))
fi

# 1> (fd-numbered) to repo path → BLOCK (exit 2)
UNPARSE_FD="echo 'unclosed 1> ${HARNESS_DIR}/skills/maestro/SKILL.md"
printf '%s' "$(bash_payload_multiline "$UNPARSE_FD")" | \
  "$BASH_GUARD" >/dev/null 2>&1 && FD_EXIT=0 || FD_EXIT=$?
if [ "$FD_EXIT" -eq 2 ]; then
  echo "  PASS [unparseable 1> to repo path → BLOCK] (exit $FD_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL [unparseable 1> to repo path → BLOCK] expected exit 2 got $FD_EXIT"
  FAIL=$((FAIL + 1))
fi

# 2>&1 (fd-dup) in an otherwise read-only unparseable command → ALLOW (exit 0).
# coarse_reason's fd-dup exclusion (target starts with '&') prevents this from being
# classified as a file-writing redirect, so the hook must exit 0.
UNPARSE_FDUP="some-read-only-cmd 'unclosed 2>&1"
run_hook "$BASH_GUARD" \
  "$(bash_payload_multiline "$UNPARSE_FDUP")" \
  0 \
  "unparseable fd-dup 2>&1 only → ALLOW"

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
