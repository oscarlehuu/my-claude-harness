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
echo "=== anti-divergence: shared guard helpers have exactly ONE definition ==="
# The whole point of guard_lib.py: the segment/glob matchers and the protected-config
# loader must exist in ONE place. A re-added second copy (the exact divergence that bit us)
# must make this suite FAIL. We grep the two hooks for any `def <helper>(` — they must define
# NONE of the shared helpers locally (they import them from guard_lib). guard_lib.py itself is
# the single home and is NOT scanned. Proven to bite: temporarily re-adding a copy turns these
# PASS lines into FAILs (see the regression-bite check below).
SHARED_HELPERS="match_segments glob_match load_config load_protected git_toplevel outer_repos"
GUARD_FILES="$EDIT_GUARD $BASH_GUARD"
for helper in $SHARED_HELPERS; do
  # grep -c exits 1 when a file has zero matches; under `set -o pipefail` that would abort the
  # suite, so count occurrences with a non-failing grep -o | wc -l instead.
  count="$({ grep -hoE "^[[:space:]]*def ${helper}\(" $GUARD_FILES 2>/dev/null || true; } | wc -l | tr -d ' ')"
  if [ "$count" -eq 0 ]; then
    echo "  PASS [no local 'def ${helper}(' in either guard — single source in guard_lib.py]"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [shared helper '${helper}' is redefined in a guard ($count copies) — divergence risk; move it to guard_lib.py]"
    FAIL=$((FAIL + 1))
  fi
done

# Regression-bite proof: synthesize a guard file that re-adds a local `def match_segments(`
# and confirm the SAME grep that the assertions use would flag it (count >= 1). This guarantees
# the anti-divergence check actually fires on a real regression rather than passing vacuously.
BITE_FILE="$TMP_ROOT/bite-guard.sh"
{ cat "$BASH_GUARD"; printf '\ndef match_segments(psegs, ssegs):\n    return True\n'; } > "$BITE_FILE"
bite_count="$({ grep -hoE "^[[:space:]]*def match_segments\(" "$BITE_FILE" 2>/dev/null || true; } | wc -l | tr -d ' ')"
if [ "$bite_count" -ge 1 ]; then
  echo "  PASS [anti-divergence grep BITES on a re-added 'def match_segments(' (count=$bite_count)]"
  PASS=$((PASS + 1))
else
  echo "  FAIL [anti-divergence grep did NOT bite on a re-added copy — the check is vacuous]"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== both-layouts: guards run green from the repo tree AND a deployed dir ==="
# Tests call the hooks in-tree (guard_lib.py beside them in maestro/hooks/). Production runs
# the COPIED hooks from ~/.claude/hooks/ with guard_lib.py copied alongside. Simulate the
# deployed layout: copy BOTH guards + the lib into a flat temp dir (no maestro/hooks/ tree,
# no repo around them) and fire one real protected-block decision through each. If the lib
# resolution were wrong, the import would fail and the guard would mis-decide (fail-open → 0).
DEPLOY_DIR="$TMP_ROOT/deployed-hooks"
mkdir -p "$DEPLOY_DIR"
# Mirror install.sh's deployed hooks/ set: both guards, the shared lib, AND lib-log.sh (the
# guards source it for observability). install.sh's *.sh + *.py copy lines deploy all of these
# into the same flat dir; the test must reproduce that layout faithfully.
cp "$EDIT_GUARD" "$BASH_GUARD" \
   "$HARNESS_DIR/maestro/hooks/guard_lib.py" \
   "$HARNESS_DIR/maestro/hooks/lib-log.sh" \
   "$DEPLOY_DIR/"
chmod +x "$DEPLOY_DIR/guard-block-main-edits.sh" "$DEPLOY_DIR/guard-block-main-bash.sh"
DEPLOY_EDIT="$DEPLOY_DIR/guard-block-main-edits.sh"
DEPLOY_BASH="$DEPLOY_DIR/guard-block-main-bash.sh"

# A target repo with a protected path; the guards must still BLOCK it when run from the
# deployed dir (proving the shared lib was found via the hook's own dir, not the cwd/tree).
DEPLOY_REPO="$(make_repo deployed-target 'LINES=50
FILES=2
PROTECTED=src/**')"
run_hook_proj "$DEPLOY_EDIT" \
  "$(edit_payload_content "$DEPLOY_REPO/src/app.ts" 'x')" \
  2 \
  "deployed layout (edit-guard): protected repo file → BLOCK (lib found beside the hook)" \
  "$DEPLOY_REPO"
run_hook_proj "$DEPLOY_BASH" \
  "$(bash_payload "echo hi > $DEPLOY_REPO/src/app.ts")" \
  2 \
  "deployed layout (bash-guard): protected redirect → BLOCK (lib found beside the hook)" \
  "$DEPLOY_REPO"
# And a non-protected path from the deployed dir still ALLOWs (the lib is genuinely doing the
# matching, not blanket-blocking because of a broken import). (Dropped a redundant re-fire of
# the protected→BLOCK assertion above that was mislabeled "control"; the ALLOW cases below are
# the real control proving the lib matches rather than blanket-blocks.)
DEPLOY_OPEN="$(make_repo deployed-open 'LINES=50
FILES=2')"
run_hook_proj "$DEPLOY_EDIT" \
  "$(edit_payload_content "$DEPLOY_OPEN/src/app.ts" 'x')" \
  0 \
  "deployed layout (edit-guard): non-protected under-budget file → ALLOW (lib matches, not blanket-blocks)" \
  "$DEPLOY_OPEN"
run_hook_proj "$DEPLOY_BASH" \
  "$(bash_payload "echo hi > $DEPLOY_OPEN/src/app.ts")" \
  0 \
  "deployed layout (bash-guard): non-protected redirect → ALLOW" \
  "$DEPLOY_OPEN"

# ---------------------------------------------------------------------------
echo ""
echo "=== missing-lib: guard_lib.py absent from the hook dir → OVER-BLOCK on both guards ==="
# The mirror of the both-layouts happy path. A partial install (install.sh copies .sh on one
# line, .py on the next, stamp last) can leave the guards present without guard_lib.py and no
# staleness flag. The hook contract reads exit 2 as BLOCK and ANY OTHER nonzero as a
# non-blocking error (ALLOW) — so a bare ImportError (exit 1) would let a protected mutation
# through. Both guards must catch the import failure and exit 2, naming the lib for debug.
NOLIB_DIR="$TMP_ROOT/nolib-hooks"
mkdir -p "$NOLIB_DIR"
# Deliberately copy the guards + lib-log.sh but NOT guard_lib.py (the partial-deploy window).
cp "$EDIT_GUARD" "$BASH_GUARD" \
   "$HARNESS_DIR/maestro/hooks/lib-log.sh" \
   "$NOLIB_DIR/"
chmod +x "$NOLIB_DIR/guard-block-main-edits.sh" "$NOLIB_DIR/guard-block-main-bash.sh"
NOLIB_EDIT="$NOLIB_DIR/guard-block-main-edits.sh"
NOLIB_BASH="$NOLIB_DIR/guard-block-main-bash.sh"
# A real protected target (proves it is the lib import, not an empty-target shortcut, that
# triggers the block). The repo is irrelevant to the import seam, but use a protected path so
# the "should have blocked anyway" intent is unambiguous.
NOLIB_REPO="$(make_repo nolib-target 'LINES=50
FILES=2
PROTECTED=src/**')"

NOLIB_EDIT_OUT="$TMP_ROOT/nolib-edit.out"
run_hook_capture_proj "$NOLIB_EDIT" \
  "$(edit_payload_content "$NOLIB_REPO/src/app.ts" 'x')" \
  2 \
  "missing-lib (edit-guard): protected edit → exit 2 (over-block, not fall-through)" \
  "$NOLIB_REPO" \
  "$NOLIB_EDIT_OUT"
if grep -q "guard_lib" "$NOLIB_EDIT_OUT"; then
  echo "  PASS [missing-lib (edit-guard): failure message names guard_lib]"
  PASS=$((PASS + 1))
else
  echo "  FAIL [missing-lib (edit-guard): failure message must name guard_lib]"
  cat "$NOLIB_EDIT_OUT" | sed 's/^/    out: /'
  FAIL=$((FAIL + 1))
fi

NOLIB_BASH_OUT="$TMP_ROOT/nolib-bash.out"
run_hook_capture_proj "$NOLIB_BASH" \
  "$(bash_payload "echo hi > $NOLIB_REPO/src/app.ts")" \
  2 \
  "missing-lib (bash-guard): protected redirect → exit 2 (over-block, not fall-through)" \
  "$NOLIB_REPO" \
  "$NOLIB_BASH_OUT"
if grep -q "guard_lib" "$NOLIB_BASH_OUT"; then
  echo "  PASS [missing-lib (bash-guard): failure message names guard_lib]"
  PASS=$((PASS + 1))
else
  echo "  FAIL [missing-lib (bash-guard): failure message must name guard_lib]"
  cat "$NOLIB_BASH_OUT" | sed 's/^/    out: /'
  FAIL=$((FAIL + 1))
fi
# A non-protected path with the lib MISSING must ALSO block (the import seam fires before any
# target classification — a broken safety component over-blocks everything, not just protected
# paths). Proves the exit-2 is the import guard, not the protected match.
NOLIB_OPEN="$(make_repo nolib-open 'LINES=50
FILES=2')"
run_hook_proj "$NOLIB_EDIT" \
  "$(edit_payload_content "$NOLIB_OPEN/src/app.ts" 'x')" \
  2 \
  "missing-lib (edit-guard): even a non-protected edit → exit 2 (broken lib over-blocks all)" \
  "$NOLIB_OPEN"
run_hook_proj "$NOLIB_BASH" \
  "$(bash_payload "echo hi > $NOLIB_OPEN/src/app.ts")" \
  2 \
  "missing-lib (bash-guard): even a non-protected redirect → exit 2 (broken lib over-blocks all)" \
  "$NOLIB_OPEN"

# ---------------------------------------------------------------------------
echo ""
echo "=== corrupt-lib: PRESENT-but-broken guard_lib.py → OVER-BLOCK on both guards, both seams ==="
# The OTHER half of the same non-atomic partial-deploy window the missing-lib block covers.
# install.sh copy_owned() is `rm -rf; cp -R`: the missing half (rm done, cp not started) is the
# missing-lib case; the corrupt half (cp truncated mid-stream) leaves guard_lib.py PRESENT but
# syntactically invalid. A truncated module raises SyntaxError on import — which is NOT an
# ImportError subclass, so a narrow `except ImportError` would let it PROPAGATE to exit 1, which
# the hook contract reads as ALLOW. Both guards must catch the BROAD exception class and exit 2.
# Bite-proof: on the round-2 narrow-except code these assertions FAIL in the ALLOW direction
# (edits exit 0, bash exit 1) — they only pass once the except is widened to `except Exception`.
CORRUPT_DIR="$TMP_ROOT/corrupt-hooks"
mkdir -p "$CORRUPT_DIR"
cp "$EDIT_GUARD" "$BASH_GUARD" \
   "$HARNESS_DIR/maestro/hooks/lib-log.sh" \
   "$CORRUPT_DIR/"
chmod +x "$CORRUPT_DIR/guard-block-main-edits.sh" "$CORRUPT_DIR/guard-block-main-bash.sh"
# A truncated copy: cut mid-statement so the module ends on an unterminated construct (open
# paren never closed) — exactly what a streaming `cp` interrupted partway leaves on disk. This
# raises SyntaxError at import, the corruption class a narrow ImportError-only catch misses.
printf 'import os\n\ndef git_toplevel(d):\n    return os.path.realpath(\n' > "$CORRUPT_DIR/guard_lib.py"
# Sanity: the fixture really is a SyntaxError (not an ImportError) — guards the bite-proof claim.
if GUARD_LIB_DIR="$CORRUPT_DIR" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["GUARD_LIB_DIR"])
try:
    import guard_lib  # noqa: F401
except SyntaxError:
    sys.exit(0)   # expected: corrupt fixture raises SyntaxError
except Exception:
    sys.exit(1)   # any OTHER exception means the fixture is not exercising the SyntaxError path
sys.exit(2)       # imported cleanly → fixture is not actually corrupt
PY
then
  echo "  PASS [corrupt-lib fixture raises SyntaxError (the non-ImportError corruption class)]"
  PASS=$((PASS + 1))
else
  echo "  FAIL [corrupt-lib fixture did NOT raise SyntaxError — the bite-proof premise is broken]"
  FAIL=$((FAIL + 1))
fi
CORRUPT_EDIT="$CORRUPT_DIR/guard-block-main-edits.sh"
CORRUPT_BASH="$CORRUPT_DIR/guard-block-main-bash.sh"

# (a) SINGLE-REPO protected path → the edits-guard MAIN seam and the bash-guard import seam.
CORRUPT_REPO="$(make_repo corrupt-target 'LINES=50
FILES=2
PROTECTED=src/**')"
CORRUPT_EDIT_OUT="$TMP_ROOT/corrupt-edit.out"
run_hook_capture_proj "$CORRUPT_EDIT" \
  "$(edit_payload_content "$CORRUPT_REPO/src/app.ts" 'x')" \
  2 \
  "corrupt-lib (edit-guard, main seam): protected edit → exit 2 (over-block, not fall-through)" \
  "$CORRUPT_REPO" \
  "$CORRUPT_EDIT_OUT"
if grep -q "guard_lib" "$CORRUPT_EDIT_OUT"; then
  echo "  PASS [corrupt-lib (edit-guard): failure message names guard_lib]"
  PASS=$((PASS + 1))
else
  echo "  FAIL [corrupt-lib (edit-guard): failure message must name guard_lib]"
  cat "$CORRUPT_EDIT_OUT" | sed 's/^/    out: /'
  FAIL=$((FAIL + 1))
fi
CORRUPT_BASH_OUT="$TMP_ROOT/corrupt-bash.out"
run_hook_capture_proj "$CORRUPT_BASH" \
  "$(bash_payload "echo hi > $CORRUPT_REPO/src/app.ts")" \
  2 \
  "corrupt-lib (bash-guard): protected redirect → exit 2 (over-block, not fall-through)" \
  "$CORRUPT_REPO" \
  "$CORRUPT_BASH_OUT"
if grep -q "guard_lib" "$CORRUPT_BASH_OUT"; then
  echo "  PASS [corrupt-lib (bash-guard): failure message names guard_lib]"
  PASS=$((PASS + 1))
else
  echo "  FAIL [corrupt-lib (bash-guard): failure message must name guard_lib]"
  cat "$CORRUPT_BASH_OUT" | sed 's/^/    out: /'
  FAIL=$((FAIL + 1))
fi

# (b) NESTED fixture → exercises the edits-guard OUTER-UNION seam (the seam B2 proved was the
# silent fall-through: SyntaxError exits 1, `_outer_exit -eq 2` never fires, the single-repo
# gate hits the same corrupt lib). With _anchor set to an inner repo that has a strictly-outer
# enclosing repo, the outer-union heredoc runs FIRST; a corrupt lib there must exit 2 and the
# bash side must propagate it. The inner target itself is in the inner repo, NOT in the outer
# PROTECTED glob — so a working lib would ALLOW; only the broken-lib over-block makes it BLOCK,
# proving the block comes from the outer-union import seam, not a protected match.
CORRUPT_INNER="$(make_nested corrupt-nest 'lib/vendor' 'LINES=50
FILES=2
PROTECTED=src/**')"
CORRUPT_NEST_OUT="$TMP_ROOT/corrupt-nest.out"
run_hook_capture_proj "$CORRUPT_EDIT" \
  "$(edit_payload_content "$CORRUPT_INNER/evil.ts" 'x')" \
  2 \
  "corrupt-lib (edit-guard, OUTER-UNION seam): nested target → exit 2 (no silent fall-through)" \
  "$CORRUPT_INNER" \
  "$CORRUPT_NEST_OUT"
if grep -q "guard_lib" "$CORRUPT_NEST_OUT"; then
  echo "  PASS [corrupt-lib (edit-guard, outer-union seam): failure message names guard_lib]"
  PASS=$((PASS + 1))
else
  echo "  FAIL [corrupt-lib (edit-guard, outer-union seam): failure message must name guard_lib]"
  cat "$CORRUPT_NEST_OUT" | sed 's/^/    out: /'
  FAIL=$((FAIL + 1))
fi
# The bash guard on the same nested target must also over-block (its single import seam covers
# all paths — there is no separate outer-union subprocess to fall through).
run_hook_proj "$CORRUPT_BASH" \
  "$(bash_payload "echo hi > $CORRUPT_INNER/evil.ts")" \
  2 \
  "corrupt-lib (bash-guard): nested redirect → exit 2 (broken lib over-blocks)" \
  "$CORRUPT_INNER"

# ---------------------------------------------------------------------------
echo ""
echo "=== raising-lib: guard_lib imports CLEANLY but a helper RAISES at call time → OVER-BLOCK ==="
# The THIRD door of the spine invariant (Petros B3), distinct from missing-lib (will not load)
# and corrupt-lib (SyntaxError on import). Here guard_lib.py imports fine — every `from
# guard_lib import X` succeeds — but a helper RAISES when CALLED on a protected path. The
# matcher/config calls sit in the EVALUATION region of each guard; on a RESOLVED target the
# protected decision could not be computed, which the spine invariant says is NEVER an ALLOW.
# Bite-proof: on the pre-round-4 code these exit-code assertions FAIL in the ALLOW direction
# (bash exit 0 via the broad `except: allow()`, edits exit 1 via the unwrapped _budget_exit /
# the outer-union fall-through). They only pass once the protected default is INVERTED to BLOCK.

# Deploy both guards + lib-log.sh + a guard_lib.py that re-exports the REAL lib and overrides one
# helper to raise at call time. $1 = dir to build, $2 = helper name to break. The break set is the
# FULL evaluation-helper surface, not just the matcher/config pair: glob_match, load_config,
# outer_repos, git_toplevel, rel_for, match_segments. Round 4 only ever broke glob_match/load_config,
# so the differential matrix never exercised the two helpers (outer_repos, git_toplevel) whose
# bash-guard cells were the surviving 0/1 coin-flip — the uniformity assertion was vacuous over them.
make_raising_hooks() {
  local dir="$1" broken="$2"
  mkdir -p "$dir"
  cp "$EDIT_GUARD" "$BASH_GUARD" "$HARNESS_DIR/maestro/hooks/lib-log.sh" "$dir/"
  chmod +x "$dir/guard-block-main-edits.sh" "$dir/guard-block-main-bash.sh"
  # Start from a byte-for-byte copy of the real lib (so EVERY imported name exists and the
  # happy-path helpers still work), then redefine ONE helper to raise when called. The import
  # itself succeeds — only the call raises, which is exactly the B3 surface.
  cp "$HARNESS_DIR/maestro/hooks/guard_lib.py" "$dir/guard_lib.py"
  cat >> "$dir/guard_lib.py" <<RAISEPY

# --- test override: $broken raises at CALL time (clean import, broken body) ---
def $broken(*_a, **_k):
    raise RuntimeError("$broken deliberately raised at call time (B3 test override)")
RAISEPY
}

# Sanity: the raising fixture must IMPORT cleanly (the whole point — not a missing/corrupt lib).
RAISE_SANITY_DIR="$TMP_ROOT/raise-sanity"
make_raising_hooks "$RAISE_SANITY_DIR" glob_match
if GUARD_LIB_DIR="$RAISE_SANITY_DIR" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["GUARD_LIB_DIR"])
try:
    from guard_lib import glob_match, load_config, outer_repos, rel_for  # noqa: F401
except Exception:
    sys.exit(1)   # must NOT fail to import — that would be the missing/corrupt case, not B3
try:
    glob_match("/x", "src/**", "/x/src/a.ts")
except RuntimeError:
    sys.exit(0)   # expected: import OK, call raises → the B3 surface
sys.exit(2)       # call did not raise → fixture is not exercising B3
PY
then
  echo "  PASS [raising-lib fixture imports cleanly but the helper raises at CALL time (the B3 surface)]"
  PASS=$((PASS + 1))
else
  echo "  FAIL [raising-lib fixture is not exercising the clean-import-raising-call surface]"
  FAIL=$((FAIL + 1))
fi

# Helper: collect every raising-lib exit code into a list so E6 can assert UNIFORMITY (all 2).
RAISE_EXITS=""

run_raise_case() {
  # $1 hook, $2 payload, $3 label, $4 proj_dir, $5 outfile (for message-naming assert)
  local hook="$1" payload="$2" label="$3" proj_dir="$4" outfile="$5"
  local actual=0
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$proj_dir" "$hook" >"$outfile" 2>&1 || actual=$?
  RAISE_EXITS="$RAISE_EXITS $actual"
  if [ "$actual" -eq 2 ]; then
    echo "  PASS [$label] (exit $actual)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$label] expected exit 2 (over-block) got $actual"
    cat "$outfile" | sed 's/^/    stderr: /'
    FAIL=$((FAIL + 1))
  fi
}

# (a) glob_match raises — SINGLE protected repo → edits MAIN seam + bash inner-protected match.
RAISE_GLOB_DIR="$TMP_ROOT/raise-glob"
make_raising_hooks "$RAISE_GLOB_DIR" glob_match
RAISE_EDIT="$RAISE_GLOB_DIR/guard-block-main-edits.sh"
RAISE_BASH="$RAISE_GLOB_DIR/guard-block-main-bash.sh"
RAISE_REPO="$(make_repo raise-target 'LINES=50
FILES=2
PROTECTED=src/**')"
RG_EDIT_OUT="$TMP_ROOT/raise-glob-edit.out"
run_raise_case "$RAISE_EDIT" \
  "$(edit_payload_content "$RAISE_REPO/src/app.ts" 'x')" \
  "raising glob_match (edit-guard, main seam): protected edit → exit 2 (inverted default)" \
  "$RAISE_REPO" "$RG_EDIT_OUT"
RG_BASH_OUT="$TMP_ROOT/raise-glob-bash.out"
run_raise_case "$RAISE_BASH" \
  "$(bash_payload "echo hi > $RAISE_REPO/src/app.ts")" \
  "raising glob_match (bash-guard): protected redirect → exit 2 (inverted default, not broad allow)" \
  "$RAISE_REPO" "$RG_BASH_OUT"
# E11: an evaluation-throw block must NAME its cause (the helper that raised) so it is debuggable.
if grep -qi "glob_match\|could not be evaluated\|raised mid-decision" "$RG_BASH_OUT"; then
  echo "  PASS [raising glob_match (bash-guard): over-block message names the failed evaluation]"
  PASS=$((PASS + 1))
else
  echo "  FAIL [raising glob_match (bash-guard): over-block message must name the failed evaluation]"
  cat "$RG_BASH_OUT" | sed 's/^/    out: /'
  FAIL=$((FAIL + 1))
fi
if grep -qi "glob_match\|could not be evaluated\|raised mid-decision" "$RG_EDIT_OUT"; then
  echo "  PASS [raising glob_match (edit-guard): over-block message names the failed evaluation]"
  PASS=$((PASS + 1))
else
  echo "  FAIL [raising glob_match (edit-guard): over-block message must name the failed evaluation]"
  cat "$RG_EDIT_OUT" | sed 's/^/    out: /'
  FAIL=$((FAIL + 1))
fi

# (b) load_config raises — SINGLE protected repo (E3): bash load_config call + edits load_config call.
RAISE_LC_DIR="$TMP_ROOT/raise-loadcfg"
make_raising_hooks "$RAISE_LC_DIR" load_config
RAISE_LC_EDIT="$RAISE_LC_DIR/guard-block-main-edits.sh"
RAISE_LC_BASH="$RAISE_LC_DIR/guard-block-main-bash.sh"
RLC_EDIT_OUT="$TMP_ROOT/raise-lc-edit.out"
run_raise_case "$RAISE_LC_EDIT" \
  "$(edit_payload_content "$RAISE_REPO/src/app.ts" 'x')" \
  "raising load_config (edit-guard): protected edit → exit 2 (config-load throw over-blocks)" \
  "$RAISE_REPO" "$RLC_EDIT_OUT"
RLC_BASH_OUT="$TMP_ROOT/raise-lc-bash.out"
run_raise_case "$RAISE_LC_BASH" \
  "$(bash_payload "echo hi > $RAISE_REPO/src/app.ts")" \
  "raising load_config (bash-guard): protected redirect → exit 2 (config-load throw over-blocks)" \
  "$RAISE_REPO" "$RLC_BASH_OUT"

# (c) glob_match raises — NESTED fixture (E2/E5): exercises the edits OUTER-UNION seam (B2 proved
# the silent fall-through) AND the bash strictly-outer match. The inner target is NOT itself in the
# outer PROTECTED glob, so a HEALTHY lib would ALLOW; only the inverted-default over-block makes it
# BLOCK — proving the block comes from the raising-helper evaluation, not a real protected match.
RAISE_INNER="$(make_nested raise-nest 'lib/vendor' 'LINES=50
FILES=2
PROTECTED=src/**')"
RN_EDIT_OUT="$TMP_ROOT/raise-nest-edit.out"
run_raise_case "$RAISE_EDIT" \
  "$(edit_payload_content "$RAISE_INNER/evil.ts" 'x')" \
  "raising glob_match (edit-guard, OUTER-UNION seam): nested target → exit 2 (no silent fall-through)" \
  "$RAISE_INNER" "$RN_EDIT_OUT"
RN_BASH_OUT="$TMP_ROOT/raise-nest-bash.out"
run_raise_case "$RAISE_BASH" \
  "$(bash_payload "echo hi > $RAISE_INNER/evil.ts")" \
  "raising glob_match (bash-guard, strictly-outer match): nested redirect → exit 2 (uniform block)" \
  "$RAISE_INNER" "$RN_BASH_OUT"

# (d) E7/E8: NON-protected target with the raising lib. The evaluation itself threw, so the
# decision is uncomputable → over-block (exit 2) regardless of whether the path would have
# matched. Two sub-cases: a repo WITH a PROTECTED list (target not matching it), and a repo with
# NO protected config at all — both still BLOCK because the throw is in the evaluation region.
RAISE_OK_REPO="$(make_repo raise-nonmatch 'LINES=50
FILES=2
PROTECTED=src/**')"
RNM_OUT="$TMP_ROOT/raise-nonmatch-bash.out"
run_raise_case "$RAISE_BASH" \
  "$(bash_payload "echo hi > $RAISE_OK_REPO/lib/util.ts")" \
  "raising glob_match + NON-protected target (E7): evaluation threw → exit 2 (uncomputable ≠ allow)" \
  "$RAISE_OK_REPO" "$RNM_OUT"
# E8 (documented choice): a repo with NO protected config (empty list). With an EMPTY protected
# list the match loop never CALLS glob_match — so the broken helper never raises, the protected
# decision completes honestly as "nothing protected", and the path falls to the BUDGET gate.
# This is NOT a fail-open: the evaluation did not throw, so there is no exception to over-block.
# The invariant keys on "evaluation threw", and here it did not. A tiny edit stays under budget
# → ALLOW; the assertion documents that the broken helper does not change an empty-config repo.
RAISE_NOPROT_REPO="$(make_repo raise-noprot)"   # no maestro-budget at all → empty protected list
run_hook_proj "$RAISE_BASH" \
  "$(bash_payload "echo hi > $RAISE_NOPROT_REPO/src/app.ts")" \
  0 \
  "raising glob_match + NO protected config (E8): empty list never calls the helper → no throw → ALLOW" \
  "$RAISE_NOPROT_REPO"

# (e) E9: repo UNIDENTIFIABLE (target outside ANY git repo) + raising lib → still ALLOW. This is
# the ONE legitimate fail-open: resolution finds no governing repo, so the evaluation region with
# the raising helper never runs against a governed list. A /tmp target is outside every repo.
RAISE_TMP_OUT="$TMP_ROOT/raise-outside.out"
_otdir="${TMPDIR:-/tmp}"; _otdir="${_otdir%/}"
run_hook_proj "$RAISE_BASH" \
  "$(bash_payload "echo hi > ${_otdir}/raise-scratch.ts")" \
  0 \
  "raising glob_match + target OUTSIDE any repo (E9): the ONE fail-open stays ALLOW" \
  "$RAISE_REPO"

# (g) DIFFERENTIAL MATRIX over the FULL evaluation-helper set (round-5: closes the vacuous E6).
# Round 4's matrix only broke glob_match/load_config, so it never exercised outer_repos or
# git_toplevel — the two helpers whose BASH cells were the surviving coin-flip (outer_repos→0,
# git_toplevel→1) the differential matrix below would have caught. For EACH helper we break it,
# resolve a PROTECTED target on BOTH guards, and assert: (i) both land on exit 2 (over-block),
# (ii) the two guards AGREE (explicit bash-vs-edits agreement assertion), and (iii) every
# protected/nested cell feeds RAISE_EXITS so the E6 uniformity collector below sees them.
#
# Reachability note (honest, per helper): bash imports git_toplevel/outer_repos/load_config/
# glob_match; edits imports outer_repos/load_config/glob_match (outer-union) + load_config/
# glob_match/rel_for (main). The edits guard resolves its own repo via raw `git` (NOT the lib's
# git_toplevel) and never imports rel_for in a path reached on a protected target — so for
# git_toplevel/rel_for the EDITS cell still reaches exit 2 via the HONEST protected match
# (glob_match works), while the BASH cell exercises the inverted default directly. Either way the
# two guards AGREE on exit 2 for a protected target, which is what the invariant demands.
RAISE_MATRIX_PROT_REPO="$(make_repo raise-matrix 'LINES=50
FILES=2
PROTECTED=src/**')"
# Nested fixture: inner target NOT in the outer PROTECTED glob, so a HEALTHY lib would ALLOW;
# only the inverted over-block (or an honest outer match) blocks — isolates the raising helper.
RAISE_MATRIX_INNER="$(make_nested raise-matrix-nest 'lib/vendor' 'LINES=50
FILES=2
PROTECTED=src/**')"
# No-config repo: empty protected list, so the protected gate short-circuits without calling the
# matcher and the BUDGET region actually runs — this is the ONLY cell that reaches the edits
# rel_for call (line ~474). On the pre-round-5 code a raising rel_for here gave edits exit 1.
RAISE_MATRIX_NOPROT="$(make_repo raise-matrix-noprot)"
_mtdir="${TMPDIR:-/tmp}"; _mtdir="${_mtdir%/}"

for _helper in glob_match load_config outer_repos git_toplevel rel_for match_segments; do
  _hd="$TMP_ROOT/raise-matrix-$_helper"
  make_raising_hooks "$_hd" "$_helper"
  _hbash="$_hd/guard-block-main-bash.sh"
  _hedit="$_hd/guard-block-main-edits.sh"

  # --- PROTECTED target on BOTH guards: both must over-block (exit 2). Feeds RAISE_EXITS. ---
  _po="$TMP_ROOT/rm-$_helper-prot.out"
  run_raise_case "$_hedit" \
    "$(edit_payload_content "$RAISE_MATRIX_PROT_REPO/src/app.ts" 'x')" \
    "raising $_helper (edit-guard): protected src → exit 2" \
    "$RAISE_MATRIX_PROT_REPO" "$_po"
  _eedit=2   # run_raise_case PASSes only on exit 2; capture the real exit for the agreement check
  _eedit=0; printf '%s' "$(edit_payload_content "$RAISE_MATRIX_PROT_REPO/src/app.ts" 'x')" \
    | CLAUDE_PROJECT_DIR="$RAISE_MATRIX_PROT_REPO" "$_hedit" >/dev/null 2>&1 || _eedit=$?
  _pbo="$TMP_ROOT/rm-$_helper-prot-bash.out"
  run_raise_case "$_hbash" \
    "$(bash_payload "echo hi >> $RAISE_MATRIX_PROT_REPO/src/app.ts")" \
    "raising $_helper (bash-guard): protected redirect → exit 2" \
    "$RAISE_MATRIX_PROT_REPO" "$_pbo"
  _ebash=0; printf '%s' "$(bash_payload "echo hi >> $RAISE_MATRIX_PROT_REPO/src/app.ts")" \
    | CLAUDE_PROJECT_DIR="$RAISE_MATRIX_PROT_REPO" "$_hbash" >/dev/null 2>&1 || _ebash=$?

  # --- AGREEMENT: the two guards must land on the SAME exit for a protected target (no coin-flip
  #     between bash and edits). This is the explicit bash-vs-edits agreement assertion per helper. ---
  if [ "$_ebash" -eq "$_eedit" ]; then
    echo "  PASS [raising $_helper: bash and edits AGREE on exit $_ebash for a protected target]"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [raising $_helper: guards DISAGREE — bash=$_ebash edits=$_eedit (the round-4 coin-flip)]"
    FAIL=$((FAIL + 1))
  fi

  # --- NESTED target on BOTH guards: both over-block (exit 2). Feeds RAISE_EXITS. ---
  run_raise_case "$_hedit" \
    "$(edit_payload_content "$RAISE_MATRIX_INNER/evil.ts" 'x')" \
    "raising $_helper (edit-guard, outer-union seam): nested → exit 2" \
    "$RAISE_MATRIX_INNER" "$TMP_ROOT/rm-$_helper-nest-edit.out"
  run_raise_case "$_hbash" \
    "$(bash_payload "echo hi >> $RAISE_MATRIX_INNER/evil.ts")" \
    "raising $_helper (bash-guard, enclosing chain): nested → exit 2" \
    "$RAISE_MATRIX_INNER" "$TMP_ROOT/rm-$_helper-nest-bash.out"

  # --- OUTSIDE any repo: the invariant draws the line by RETURN-vs-RAISE, not by target class.
  #     For a MATCHER/CONFIG helper (glob_match, load_config, rel_for, match_segments) and for
  #     outer_repos, a HEALTHY resolution returns EMPTY for an out-of-repo target, so the broken
  #     helper is NEVER called against a governed list → the ONE legitimate fail-open holds (exit
  #     0) on both guards. But git_toplevel IS the resolution helper: a /tmp target makes the bash
  #     guard call it (benign_target → target_repo → git_toplevel), and a RAISE there is NOT the
  #     "no repo" signal (that is an EMPTY RETURN) — it is a broken component, so the bash guard
  #     OVER-blocks (exit 2), uniformly with every other broken-resolution seam. The edits guard
  #     resolves its repo via raw `git` (not the lib's git_toplevel), so its out-of-repo cell stays
  #     a clean fail-open (exit 0) — an honest difference (no lib helper to raise), not a coin-flip.
  #     These cells are the fail-open boundary and are NOT added to RAISE_EXITS. ---
  if [ "$_helper" = "git_toplevel" ]; then
    _oo_bash_expect=2   # resolution helper raised → block, uniformly (raise is never the fail-open)
  else
    _oo_bash_expect=0   # healthy resolution returns empty → broken helper never reached → ALLOW
  fi
  run_hook_proj "$_hedit" \
    "$(edit_payload_content "${_mtdir}/raise-mx-$_helper.ts" 'x')" \
    0 \
    "raising $_helper (edit-guard): target OUTSIDE any repo → ALLOW (edits uses raw git, no lib raise)" \
    "$RAISE_MATRIX_PROT_REPO"
  run_hook_proj "$_hbash" \
    "$(bash_payload "echo hi > ${_mtdir}/raise-mx-$_helper-b.ts")" \
    "$_oo_bash_expect" \
    "raising $_helper (bash-guard): target OUTSIDE any repo → exit $_oo_bash_expect (return=fail-open, raise=block)" \
    "$RAISE_MATRIX_PROT_REPO"
done

# --- rel_for budget-region cell: a NO-CONFIG repo is the only target that reaches the edits
#     rel_for call (the protected gate short-circuits on an empty list, so the budget region runs
#     and calls rel_for at line ~474). On the pre-round-5 code this gave edits exit 1 (ALLOW via
#     the unwrapped budget heredoc); the wrap makes it exit 2. The bash guard never calls rel_for,
#     so its honest answer on a no-config tiny edit is exit 0 (allow) — we assert that explicitly,
#     and that edits now BLOCKS, removing the round-4 disagreement on the rel_for seam. ---
_rfd="$TMP_ROOT/raise-relfor-budget"
make_raising_hooks "$_rfd" rel_for
_rf_edit_out="$TMP_ROOT/raise-relfor-budget-edit.out"
_rf_eedit=0; printf '%s' "$(edit_payload_content "$RAISE_MATRIX_NOPROT/src/app.ts" 'x')" \
  | CLAUDE_PROJECT_DIR="$RAISE_MATRIX_NOPROT" "$_rfd/guard-block-main-edits.sh" >"$_rf_edit_out" 2>&1 || _rf_eedit=$?
if [ "$_rf_eedit" -eq 2 ]; then
  echo "  PASS [raising rel_for (edit-guard, budget region): no-config repo → exit 2 (wrapped, was exit 1=ALLOW)]"
  PASS=$((PASS + 1))
else
  echo "  FAIL [raising rel_for (edit-guard, budget region): no-config repo expected exit 2 got $_rf_eedit]"
  cat "$_rf_edit_out" | sed 's/^/    out: /'
  FAIL=$((FAIL + 1))
fi
RAISE_EXITS="$RAISE_EXITS $_rf_eedit"   # feed the rel_for budget cell into the uniformity collector
_rf_ebash=0; printf '%s' "$(bash_payload "echo hi >> $RAISE_MATRIX_NOPROT/src/app.ts")" \
  | CLAUDE_PROJECT_DIR="$RAISE_MATRIX_NOPROT" "$_rfd/guard-block-main-bash.sh" >/dev/null 2>&1 || _rf_ebash=$?
if [ "$_rf_ebash" -eq 0 ]; then
  echo "  PASS [raising rel_for (bash-guard): no-config tiny edit → exit 0 (bash never calls rel_for; honest allow)]"
  PASS=$((PASS + 1))
else
  echo "  FAIL [raising rel_for (bash-guard): no-config tiny edit expected exit 0 got $_rf_ebash]"
  FAIL=$((FAIL + 1))
fi

# --- BITE-PROOF (round-5), the two round-4 survivors: the working-tree round-4 bash guard
#     ALLOWED a raising outer_repos (→ exit 0, via the resolution try's broad `except: allow()`
#     that the chain walk sat inside) and a raising git_toplevel (→ exit 1, via an uncaught
#     traceback out of analyze() → benign_target → target_repo). Both were ALLOW directions.
#     Reverting the guard mid-suite would mutate source files, so this in-suite bite asserts the
#     FIXED behavior with a TWO-PART signal that each round-4 failure mode distinctly fails:
#       (i)  exit 2  — bites outer_repos→0 (broad allow) and git_toplevel→1 (uncaught traceback);
#       (ii) a CONTROLLED over-block message — outer_repos's round-4 allow() was silent (no
#            message) and git_toplevel's round-4 traceback is Python's, not ours, so requiring OUR
#            message bites a half-fix that blocks without routing through the inverted-default path.
#     The differential-against-round-4 revert (cells flip to 0/1) is run manually and recorded in
#     the edge-case ledger (section E, round 5), mirroring how rounds 1–4 bite-proofed each fix. ---
for _bite in outer_repos git_toplevel; do
  _bd="$TMP_ROOT/raise-bite-$_bite"
  make_raising_hooks "$_bd" "$_bite"
  _bo="$TMP_ROOT/raise-bite-$_bite.out"
  _bx=0; printf '%s' "$(bash_payload "echo hi >> $RAISE_MATRIX_PROT_REPO/src/app.ts")" \
    | CLAUDE_PROJECT_DIR="$RAISE_MATRIX_PROT_REPO" "$_bd/guard-block-main-bash.sh" >"$_bo" 2>&1 || _bx=$?
  # The fix is proven by BOTH halves: exit 2 (not the round-4 0/1) AND a controlled over-block
  # message (the pre-fix code produced none on these seams — allow() is silent, the traceback is
  # not our message). A revert to round-4 fails exit!=2 here; a half-revert that blocks without
  # the controlled path fails the naming half.
  if [ "$_bx" -eq 2 ] && grep -qi "could not be evaluated\|raised mid-decision\|chain walk\|classification" "$_bo"; then
    echo "  PASS [bite-proof: bash $_bite raise → exit 2 + controlled over-block message (was round-4 $( [ "$_bite" = outer_repos ] && echo 0 || echo 1 )=ALLOW)]"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [bite-proof: bash $_bite raise → exit $_bx (want 2) with controlled message]"
    cat "$_bo" | sed 's/^/    out: /'
    FAIL=$((FAIL + 1))
  fi
done

# (f) E6 / Petros N4: UNIFORMITY. Every raising-helper protected case above must land on the
# SAME exit (2) — no 0/1/2 coin-flip across seams. RAISE_EXITS collected each over-block case.
RAISE_NONUNIFORM=0
for _e in $RAISE_EXITS; do
  [ "$_e" -eq 2 ] || RAISE_NONUNIFORM=1
done
if [ "$RAISE_NONUNIFORM" -eq 0 ] && [ -n "$RAISE_EXITS" ]; then
  echo "  PASS [raising-lib UNIFORMITY (N4): every raising-helper protected case exits 2 — no coin-flip]"
  PASS=$((PASS + 1))
else
  echo "  FAIL [raising-lib UNIFORMITY (N4): non-uniform exits across seams ->$RAISE_EXITS]"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== unreadable budget: chmod-000 maestro-budget → FAIL CLOSED (BLOCK) on both guards ==="
# An UNREADABLE budget (file is there but chmod 000 -> PermissionError) used to fail OPEN:
# load_config returned (50,2,[]) with an EMPTY protected list, so a protected path slipped
# through. The spine invariant says ambiguity over-blocks — we cannot read the declared
# policy, so we protect everything. Distinct from an ABSENT budget (no file), which keeps
# today's legitimate defaults. Skipped under root, which ignores 000 perms (mirrors
# tests/context-hooks.test.sh:146).
if [ "$(id -u)" != "0" ]; then
  UNREAD_REPO="$(make_repo unreadable-budget 'LINES=50
FILES=2
PROTECTED=src/**')"
  chmod 000 "$UNREAD_REPO/.claude/maestro-budget"
  # src/app.ts is in the (now unreadable) PROTECTED list AND would be blocked by the
  # fail-closed "**" anyway — either way the answer must be BLOCK, never ALLOW. Capture stderr
  # too: the over-block message must NAME its cause (the budget is unreadable), so a fail-closed
  # block self-explains instead of looking like a mysterious protected-path block on a path the
  # operator never listed. The cause string flows from load_config's fail_closed_reason marker.
  UNREAD_EDIT_OUT="$TMP_ROOT/unread-edit.out"
  run_hook_capture_proj "$EDIT_GUARD" \
    "$(edit_payload_content "$UNREAD_REPO/src/app.ts" 'x')" \
    2 \
    "unreadable budget (edit-guard): protected path → BLOCK (fail closed, not fail open)" \
    "$UNREAD_REPO" \
    "$UNREAD_EDIT_OUT"
  if grep -qi "unreadable" "$UNREAD_EDIT_OUT"; then
    echo "  PASS [unreadable budget (edit-guard): over-block message names the cause (unreadable budget)]"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [unreadable budget (edit-guard): over-block message must name the cause]"
    cat "$UNREAD_EDIT_OUT" | sed 's/^/    out: /'
    FAIL=$((FAIL + 1))
  fi
  UNREAD_BASH_OUT="$TMP_ROOT/unread-bash.out"
  run_hook_capture_proj "$BASH_GUARD" \
    "$(bash_payload "echo hi > $UNREAD_REPO/src/app.ts")" \
    2 \
    "unreadable budget (bash-guard): protected redirect → BLOCK (fail closed, not fail open)" \
    "$UNREAD_REPO" \
    "$UNREAD_BASH_OUT"
  if grep -qi "unreadable" "$UNREAD_BASH_OUT"; then
    echo "  PASS [unreadable budget (bash-guard): over-block message names the cause (unreadable budget)]"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [unreadable budget (bash-guard): over-block message must name the cause]"
    cat "$UNREAD_BASH_OUT" | sed 's/^/    out: /'
    FAIL=$((FAIL + 1))
  fi
  # A path the budget does NOT name must also block under fail-closed (protect everything via
  # "**"): the operator declared a policy we cannot read, so nothing is exempt. Use a .ts file
  # under a non-protected dir; .md/docs/tmp carve-outs run BEFORE the budget gate and are out
  # of scope here, so pick a plain code path.
  printf 'const x = 1;\n' > "$UNREAD_REPO/extra.ts"
  run_hook_proj "$EDIT_GUARD" \
    "$(edit_payload_content "$UNREAD_REPO/extra.ts" 'x')" \
    2 \
    "unreadable budget (edit-guard): non-listed code path → BLOCK (fail closed protects all)" \
    "$UNREAD_REPO"
  chmod 644 "$UNREAD_REPO/.claude/maestro-budget"  # restore so the trap-rm and any reuse are clean
else
  echo "  SKIP [unreadable-budget tests skipped under root (000 perms ignored)]"
fi

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
