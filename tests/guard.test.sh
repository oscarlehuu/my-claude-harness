#!/usr/bin/env bash
# Probe script for guard-block-main-edits.sh and guard-block-main-bash.sh.
# Feeds JSON payloads to both hooks and asserts expected exit codes.
# Must print all-pass and exit 0 on a correct implementation.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDIT_GUARD="$HARNESS_DIR/maestro/hooks/guard-block-main-edits.sh"
BASH_GUARD="$HARNESS_DIR/maestro/hooks/guard-block-main-bash.sh"

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
echo "=== parent-dir-session target-rooting tests (governs by the file's repo) ==="
# $TMP_ROOT is NOT a git repo, so it is a faithful stand-in for a CTO session sitting
# in a parent folder over sibling child repos. With CLAUDE_PROJECT_DIR pointed at the
# parent, each edit must be judged by the TARGET file's own repo — its budget, its
# protected list, its carve-outs — not the (non-repo) session dir.
PARENT="$TMP_ROOT"   # non-repo parent containing all the make_repo children

# Sibling A: src/** protected. Sibling B: open budget, nothing protected.
SIB_A="$(make_repo sib-a 'LINES=50
FILES=2
PROTECTED=src/**')"
SIB_B="$(make_repo sib-b 'LINES=50
FILES=2')"

# (a) Parent session, child A protected file → governed by A's protected list → BLOCK.
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$SIB_A/src/app.ts" 'x')" \
  2 \
  "parent session: edit child A protected src → BLOCK (A's config)" \
  "$PARENT"

# (b) Same parent session, sibling B's src is NOT protected → ALLOW (B's own config).
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$SIB_B/src/app.ts" 'x')" \
  0 \
  "parent session: edit sibling B src → ALLOW (B's config, not A's)" \
  "$PARENT"

# (c) Parent session, child A harness-state ledger → carve-out anchored to A → ALLOW.
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload "$SIB_A/.claude/maestro/some-slug/state.json")" \
  0 \
  "parent session: edit child A ledger → ALLOW (carve-out anchored to A)" \
  "$PARENT"

# (d) Parent session, child A docs/ prose → carve-out anchored to A → ALLOW.
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload "$SIB_A/docs/readme.md")" \
  0 \
  "parent session: edit child A docs/readme.md → ALLOW (docs carve-out anchored to A)" \
  "$PARENT"

# (e) bash-guard: parent session, redirect into child A protected src → BLOCK (A's config).
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $SIB_A/src/app.ts")" \
  2 \
  "parent session (bash): redirect into child A protected src → BLOCK" \
  "$PARENT"

# (f) bash-guard: parent session, redirect into sibling B src → ALLOW (B's config).
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $SIB_B/src/app.ts")" \
  0 \
  "parent session (bash): redirect into sibling B src → ALLOW (B's config)" \
  "$PARENT"

# Direct-edit mode is a per-repo carve-out: a sibling in direct mode allows direct edits
# to ITS files even from a parent session, while the protected sibling A still blocks.
DIRECT_SIB="$(make_repo sib-direct 'LINES=50
FILES=2
PROTECTED=src/**')"
printf '1\n' > "$DIRECT_SIB/.claude/maestro-direct"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$DIRECT_SIB/src/app.ts" 'x')" \
  0 \
  "parent session: edit direct-mode sibling's protected src → ALLOW (its own carve-out)" \
  "$PARENT"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $DIRECT_SIB/src/app.ts")" \
  0 \
  "parent session (bash): write direct-mode sibling's protected src → ALLOW" \
  "$PARENT"

# (g) Budget is per-target-repo: B over a tight line budget blocks while A (untouched,
#     open budget) does not — proving usage is computed against the TARGET's HEAD.
SIB_TIGHT="$(make_repo sib-tight 'LINES=0
FILES=2')"
printf 'creep\n' >> "$SIB_TIGHT/src/app.ts"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$SIB_TIGHT/src/other.ts" 'x')" \
  2 \
  "parent session: tight-budget sibling blocks on its OWN HEAD usage → BLOCK" \
  "$PARENT"
# A sibling with open budget, edited from the same parent session, is unaffected.
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$SIB_B/src/other.ts" 'x')" \
  0 \
  "parent session: open-budget sibling unaffected by the tight sibling → ALLOW" \
  "$PARENT"

# ---------------------------------------------------------------------------
echo ""
echo "=== worktree target-rooting tests (governed by the worktree's HEAD) ==="
# A file edited inside a git worktree must be judged by the worktree (rev-parse
# --show-toplevel returns the worktree path), with budget vs the worktree's HEAD.
WT_MAIN="$(make_repo wt-main 'LINES=50
FILES=2
PROTECTED=src/**')"
WT_DIR="$TMP_ROOT/wt-checkout"
git -C "$WT_MAIN" worktree add -q --detach "$WT_DIR" HEAD 2>/dev/null

# (h) Protected list travels with the worktree's HEAD → editing src in the worktree BLOCKs.
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$WT_DIR/src/app.ts" 'x')" \
  2 \
  "worktree: edit protected src inside worktree → BLOCK (worktree HEAD's config)" \
  "$PARENT"

# (i) The worktree's own ledger carve-out is anchored to the worktree, not the main checkout.
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload "$WT_DIR/.claude/maestro/wt-slug/state.json")" \
  0 \
  "worktree: edit worktree ledger → ALLOW (carve-out anchored to the worktree)" \
  "$PARENT"

git -C "$WT_MAIN" worktree remove --force "$WT_DIR" 2>/dev/null || true
git -C "$WT_MAIN" worktree prune 2>/dev/null || true

# ---------------------------------------------------------------------------
echo ""
echo "=== new-file-in-new-dir target-rooting (dirname may not exist yet) ==="
# A Write can create a brand-new file in a brand-new directory; git -C <that dir> would
# fail, so resolution walks up to the nearest existing ancestor. The protected glob must
# still match the eventual location relative to the repo root.
NEWDIR_REPO="$(make_repo newdir 'LINES=50
FILES=2
PROTECTED=src/**')"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$NEWDIR_REPO/src/brand/new/deep/file.ts" 'x')" \
  2 \
  "parent session: Write new file in new dir under protected src/** → BLOCK" \
  "$PARENT"
# Same brand-new nested path but OUTSIDE the protected glob → ALLOW under open budget.
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$NEWDIR_REPO/lib/brand/new/file.ts" 'x')" \
  0 \
  "parent session: Write new file in new dir outside protected glob → ALLOW" \
  "$PARENT"

# ---------------------------------------------------------------------------
echo ""
echo "=== nested-repo target-rooting (union of gates, never union of exemptions) ==="
# A git repo nested INSIDE a protected subtree of an outer repo (vendored dep with its own
# .git, accidental `git init`, fixture repo under src/) must NOT silently exempt the outer
# repo's PROTECTED list. The protected gate is a UNION across enclosing repos: if ANY
# enclosing repo protects the target by THAT repo's own relative path, BLOCK. Exemptions
# (carve-outs, inner maestro-direct) never flow across the boundary to defeat outer protection.
# Budget stays anchored to the innermost (target) repo.

make_nested() {
  # $1 outer-repo name, $2 inner subpath (relative to outer root), $3 outer budget config.
  local outer inner
  outer="$(make_repo "$1" "$3")"
  inner="$outer/$2"
  mkdir -p "$inner"
  printf 'const e=0;\n' > "$inner/evil.ts"
  git -C "$inner" init -q
  git -C "$inner" config user.email test@example.com
  git -C "$inner" config user.name test
  git -C "$inner" add .
  git -C "$inner" commit -qm init
  printf '%s' "$inner"
}

make_nested_headless() {
  # Like make_nested, but the INNER repo is `git init`-ed with NO COMMIT (HEAD-less).
  # `git diff HEAD` raises in such a repo; protection must still evaluate to completion.
  # $1 outer-repo name, $2 inner subpath, $3 outer budget config.
  local outer inner
  outer="$(make_repo "$1" "$3")"
  inner="$outer/$2"
  mkdir -p "$inner"
  printf 'const e=0;\n' > "$inner/evil.ts"
  git -C "$inner" init -q   # deliberately NO add/commit → HEAD-less
  printf '%s' "$inner"
}

make_solo_headless() {
  # A single (non-nested) repo, `git init`-ed with NO COMMIT (HEAD-less), with the given
  # budget config. $1 repo name, $2 budget config (may be empty for default/open budget).
  local repo="$TMP_ROOT/$1"
  mkdir -p "$repo/src" "$repo/lib"
  printf 'const base = 1;\n' > "$repo/src/app.ts"
  printf 'const u = 2;\n' > "$repo/lib/util.ts"
  if [ -n "${2:-}" ]; then
    mkdir -p "$repo/.claude"
    printf '%s\n' "$2" > "$repo/.claude/maestro-budget"
  fi
  git -C "$repo" init -q   # deliberately NO add/commit → HEAD-less
  printf '%s' "$repo"
}

# (a) Inner repo at <outer>/src/vendor; outer PROTECTED=src/**. Editing the inner file is
#     governed by the OUTER repo's protected list (src/vendor/evil.ts matches src/**) → BLOCK.
NEST_INNER="$(make_nested nest-prot 'src/vendor' 'LINES=50
FILES=2
PROTECTED=src/**')"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$NEST_INNER/evil.ts" 'x')" \
  2 \
  "nested .git under outer src/**: edit inner file → BLOCK (outer's PROTECTED, Petros fixture)" \
  "$PARENT"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $NEST_INNER/evil.ts")" \
  2 \
  "nested .git under outer src/**: bash write inner file → BLOCK (outer's PROTECTED)" \
  "$PARENT"

# (b) Inner repo under a NON-protected outer path (<outer>/lib/vendor); outer PROTECTED=src/**.
#     No outer protection reaches it → governed by inner repo's own (open) config → ALLOW.
NEST_OK="$(make_nested nest-open 'lib/vendor' 'LINES=50
FILES=2
PROTECTED=src/**')"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$NEST_OK/evil.ts" 'x')" \
  0 \
  "nested .git under outer lib/ (not protected): edit inner file → ALLOW (no over-reach)" \
  "$PARENT"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $NEST_OK/evil.ts")" \
  0 \
  "nested .git under outer lib/ (not protected): bash write inner file → ALLOW" \
  "$PARENT"

# (c) Inner repo's own maestro-direct must NOT defeat the OUTER repo's PROTECTED. The inner
#     marker would exempt direct edits to the inner repo, but the outer repo protects the path.
printf '1\n' > "$NEST_INNER/.claude/maestro-direct" 2>/dev/null || { mkdir -p "$NEST_INNER/.claude"; printf '1\n' > "$NEST_INNER/.claude/maestro-direct"; }
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$NEST_INNER/evil.ts" 'x')" \
  2 \
  "inner maestro-direct does NOT defeat outer PROTECTED: edit → BLOCK" \
  "$PARENT"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $NEST_INNER/evil.ts")" \
  2 \
  "inner maestro-direct does NOT defeat outer PROTECTED: bash write → BLOCK" \
  "$PARENT"

# (d) Inner-repo carve-outs (docs/, ledger, bare .md) must NOT defeat the outer PROTECTED —
#     they are exemptions and exemptions never flow outward across the repo boundary.
mkdir -p "$NEST_INNER/docs" "$NEST_INNER/.claude/maestro/s"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$NEST_INNER/docs/x.md" 'x')" \
  2 \
  "inner docs/ carve-out does NOT defeat outer PROTECTED: edit → BLOCK" \
  "$PARENT"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $NEST_INNER/docs/x.md")" \
  2 \
  "inner docs/ carve-out does NOT defeat outer PROTECTED: bash write → BLOCK" \
  "$PARENT"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $NEST_INNER/.claude/maestro/s/state.json")" \
  2 \
  "inner ledger carve-out does NOT defeat outer PROTECTED: bash write → BLOCK" \
  "$PARENT"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $NEST_INNER/readme.md")" \
  2 \
  "inner bare-.md carve-out does NOT defeat outer PROTECTED: bash write → BLOCK" \
  "$PARENT"

# (e) Same carve-outs in a NON-nested-under-protected inner repo still ALLOW (no over-reach):
#     the open inner repo (nest-open) under outer lib/ keeps its docs/ledger carve-outs.
mkdir -p "$NEST_OK/docs" "$NEST_OK/.claude/maestro/s"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $NEST_OK/docs/y.md")" \
  0 \
  "carve-out in inner repo NOT under outer protection still ALLOWs (docs)" \
  "$PARENT"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $NEST_OK/.claude/maestro/s/state.json")" \
  0 \
  "carve-out in inner repo NOT under outer protection still ALLOWs (ledger)" \
  "$PARENT"

# (f) Single-repo control: a repo with BOTH maestro-direct AND its own PROTECTED still lets
#     direct edits through to its OWN protected paths (no strictly-outer repo → round-1 rule).
#     This guards against the union check regressing the single-repo direct-mode carve-out.
SOLO_DIRECT="$(make_repo solo-direct 'LINES=50
FILES=2
PROTECTED=src/**')"
printf '1\n' > "$SOLO_DIRECT/.claude/maestro-direct"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$SOLO_DIRECT/src/app.ts" 'x')" \
  0 \
  "single repo with own maestro-direct + PROTECTED: edit own protected src → ALLOW" \
  "$PARENT"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $SOLO_DIRECT/src/app.ts")" \
  0 \
  "single repo with own maestro-direct + PROTECTED: bash write own protected src → ALLOW" \
  "$PARENT"

# ---------------------------------------------------------------------------
echo ""
echo "=== session-direct cross-repo: direct mode is per-TARGET, never per-session ==="
# THE FINDING: a session in repo A (direct mode) must NOT be able to edit/write repo B's
# PROTECTED files — direct-mode markers are honored per TARGET repo, never per session
# (exemptions never union outward across a repo boundary). Here the SESSION repo IS a real git
# repo carrying its own maestro-direct marker and CLAUDE_PROJECT_DIR points AT it — exactly the
# live repro. A and B are siblings under $TMP_ROOT (B is NOT nested in A) so B's OWN protected
# gate runs against B's config, not A's. Before the fix, A's session marker exited 0 first.
SESS_DIRECT="$(make_repo sess-direct 'LINES=50
FILES=2
PROTECTED=src/**')"
printf '1\n' > "$SESS_DIRECT/.claude/maestro-direct"
SESS_VICTIM="$(make_repo sess-victim 'LINES=50
FILES=2
PROTECTED=src/**')"   # sibling B: protected, NOT in direct mode

# (a) session A (direct) edits B's protected file → BLOCK (B's gate runs; A's marker is irrelevant).
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$SESS_VICTIM/src/app.ts" 'x')" \
  2 \
  "session A direct-mode: edit sibling B protected src → BLOCK (per-target, not per-session)" \
  "$SESS_DIRECT"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $SESS_VICTIM/src/app.ts")" \
  2 \
  "session A direct-mode (bash): write sibling B protected src → BLOCK (per-target)" \
  "$SESS_DIRECT"

# (b) session A (direct) edits A's OWN files — direct mode is preserved for the opted-in repo.
#     Same-repo is the common case: the target's repo IS the session repo and its marker is honored.
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$SESS_DIRECT/src/app.ts" 'x')" \
  0 \
  "session A direct-mode: edit A's OWN protected src → ALLOW (direct mode preserved)" \
  "$SESS_DIRECT"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $SESS_DIRECT/src/app.ts")" \
  0 \
  "session A direct-mode (bash): write A's OWN protected src → ALLOW (direct mode preserved)" \
  "$SESS_DIRECT"
# A's own brand-new file in a new dir (budget-permitting) — direct workflow unchanged.
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$SESS_DIRECT/lib/util.ts" 'x')" \
  0 \
  "session A direct-mode: edit A's OWN non-protected file → ALLOW" \
  "$SESS_DIRECT"

# (c) No-target bash command in a direct-mode session → ALLOW (fallback honors the SESSION marker).
#     `git reset --hard` mutates the tree but resolves to no path target, so resolution falls back
#     to the session repo, whose own marker must exempt it (replacing the removed session early-exit).
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "git reset --hard")" \
  0 \
  "session A direct-mode (bash): no-target 'git reset --hard' → ALLOW (fallback honors session marker)" \
  "$SESS_DIRECT"
# Edit-guard fallback: an empty file_path in a direct-mode session resolves to no target; the
# session repo governs (_anchor empty) and its marker must still exempt the action.
run_hook_proj "$EDIT_GUARD" \
  '{"tool_input":{}}' \
  0 \
  "session A direct-mode (edit): empty file_path → ALLOW (fallback honors session marker)" \
  "$SESS_DIRECT"

# (d) Control: with the marker REMOVED, the same targeted protected write to B is still blocked —
#     proving the ALLOW in (b) is the marker's doing, not a blanket pass. (Gating B by B's config.)
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $SESS_VICTIM/src/app.ts")" \
  2 \
  "control: non-direct session write to a protected repo → BLOCK (marker is what flips (b))" \
  "$SESS_VICTIM"

# (e) Direct-mode session + nested cases stay coherent with rounds 2-3 union-of-gates semantics:
#     an inner repo's marker (or the session's) must NOT defeat an OUTER repo's PROTECTED. The
#     session sits in a direct-mode repo; the target is an inner .git nested under an OUTER
#     protected subtree → BLOCK (exemptions never union outward, even from a direct-mode session).
NEST_FROM_DIRECT="$(make_nested nest-from-direct 'src/vendor' 'LINES=50
FILES=2
PROTECTED=src/**')"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$NEST_FROM_DIRECT/evil.ts" 'x')" \
  2 \
  "direct-mode session: edit inner .git under outer PROTECTED → BLOCK (no outward union of exemptions)" \
  "$SESS_DIRECT"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $NEST_FROM_DIRECT/evil.ts")" \
  2 \
  "direct-mode session (bash): write inner .git under outer PROTECTED → BLOCK" \
  "$SESS_DIRECT"

# ---------------------------------------------------------------------------
echo ""
echo "=== HEAD-less inner repo: protection runs INDEPENDENT of usage (no commit yet) ==="
# A repo can be `git init`-ed before its first commit (HEAD-less). `git diff HEAD` RAISES in
# such a repo, which is how usage is computed. The spine invariant — failure/ambiguity paths
# OVER-block, never UNDER-block — requires the protected check to evaluate to completion
# regardless of usage-computation success. These fixtures DELIBERATELY DO NOT COMMIT the inner
# repo; that exact gap let a HEAD-dependent usage exception skip the protected gate and exit 0.

# (g) Petros's fixture: HEAD-less inner repo under outer PROTECTED=src/** → BLOCK (both guards).
#     Before the fix the bash guard's strictly-outer union sat inside the same try as
#     current_usage(); `git diff HEAD` raised → except: allow() → exit 0 (under-block).
HL_PROT="$(make_nested_headless hl-nest-prot 'src/vendor' 'LINES=50
FILES=2
PROTECTED=src/**')"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $HL_PROT/evil.ts")" \
  2 \
  "HEAD-less inner under outer src/**: bash write → BLOCK (usage-independent protection, Petros)" \
  "$PARENT"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$HL_PROT/evil.ts" 'x')" \
  2 \
  "HEAD-less inner under outer src/**: edit → BLOCK (symmetry)" \
  "$PARENT"

# (g2) Exemptions still never cross the boundary when the inner repo is HEAD-less: an inner
#      maestro-direct marker must NOT defeat the OUTER repo's PROTECTED, even with no commit.
mkdir -p "$HL_PROT/.claude"
printf '1\n' > "$HL_PROT/.claude/maestro-direct"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $HL_PROT/evil.ts")" \
  2 \
  "HEAD-less inner maestro-direct does NOT defeat outer PROTECTED: bash write → BLOCK" \
  "$PARENT"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$HL_PROT/evil.ts" 'x')" \
  2 \
  "HEAD-less inner maestro-direct does NOT defeat outer PROTECTED: edit → BLOCK" \
  "$PARENT"

# (h) HEAD-less inner repo under a NON-protected outer path → ALLOW (no over-reach from the fix).
HL_OPEN="$(make_nested_headless hl-nest-open 'lib/vendor' 'LINES=50
FILES=2
PROTECTED=src/**')"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $HL_OPEN/evil.ts")" \
  0 \
  "HEAD-less inner under outer lib/ (not protected): bash write → ALLOW (no over-reach)" \
  "$PARENT"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$HL_OPEN/evil.ts" 'x')" \
  0 \
  "HEAD-less inner under outer lib/ (not protected): edit → ALLOW (no over-reach)" \
  "$PARENT"

# (i) HEAD-less SINGLE repo (no nesting) whose OWN PROTECTED=src/** matches → BLOCK (both guards).
#     The innermost repo's own protected gate also sat after the HEAD-dependent usage call in
#     BOTH guards; a HEAD-less repo used to skip it (bash) / fail open (edit). Now both block.
HL_SOLO_PROT="$(make_solo_headless hl-solo-prot 'LINES=50
FILES=2
PROTECTED=src/**')"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $HL_SOLO_PROT/src/app.ts")" \
  2 \
  "HEAD-less single repo, own PROTECTED=src/**: bash write protected → BLOCK" \
  "$PARENT"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$HL_SOLO_PROT/src/app.ts" 'x')" \
  2 \
  "HEAD-less single repo, own PROTECTED=src/**: edit protected → BLOCK (was under-block)" \
  "$PARENT"
# Same HEAD-less single repo, a NON-matching path → ALLOW (protection is exact, no over-reach).
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $HL_SOLO_PROT/lib/util.ts")" \
  0 \
  "HEAD-less single repo, own PROTECTED=src/**: bash write NON-protected lib/ → ALLOW" \
  "$PARENT"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$HL_SOLO_PROT/lib/util.ts" 'x')" \
  0 \
  "HEAD-less single repo, own PROTECTED=src/**: edit NON-protected lib/ → ALLOW" \
  "$PARENT"

# (j) HEAD-less SINGLE repo with NO protected config → ALLOW (baseline fail-open UNCHANGED).
#     Usage is genuinely unknowable HEAD-less; with nothing to protect, the fail-open posture
#     for budget is preserved exactly as before — the fix must not turn this into a block.
HL_SOLO_OPEN="$(make_solo_headless hl-solo-open '')"
run_hook_proj "$BASH_GUARD" \
  "$(bash_payload "echo hi > $HL_SOLO_OPEN/src/app.ts")" \
  0 \
  "HEAD-less single repo, no protected config: bash write → ALLOW (fail-open preserved)" \
  "$PARENT"
run_hook_proj "$EDIT_GUARD" \
  "$(edit_payload_content "$HL_SOLO_OPEN/src/app.ts" 'x')" \
  0 \
  "HEAD-less single repo, no protected config: edit → ALLOW (fail-open preserved)" \
  "$PARENT"

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
