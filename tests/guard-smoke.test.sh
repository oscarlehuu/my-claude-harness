#!/usr/bin/env bash
# Smoke canary for the two main-session guards. This runs FIRST in run-all.sh.
#
# One known-protected fixture per guard MUST BLOCK (exit 2) before any other suite runs.
# It is a fail-fast tripwire for the "one character kills the guard" class: a typo in a
# heredoc, a broken import, a desynced quote — anything that silently turns a guard into a
# pass-through — trips here and halts the whole suite before the 144-cell matrices waste
# minutes proving a guard that no longer blocks anything. Standalone: its own tmpdir git
# repo, no dependence on any other suite's state.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDIT_GUARD="$HARNESS_DIR/maestro/hooks/guard-block-main-edits.sh"
BASH_GUARD="$HARNESS_DIR/maestro/hooks/guard-block-main-bash.sh"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# A protected fixture repo: src/** is declared protected, so a main-session (no agent_id)
# mutation of src/app.ts must BLOCK regardless of size.
mk_protected_repo() {
  local repo="$TMP_ROOT/protected"
  mkdir -p "$repo/src" "$repo/.claude"
  printf 'const base = 1;\n' > "$repo/src/app.ts"
  printf 'LINES=50\nFILES=2\nPROTECTED=src/**\n' > "$repo/.claude/maestro-budget"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  git -C "$repo" add .
  git -C "$repo" commit -qm init
  printf '%s' "$repo"
}

# assert_block <hook> <payload> <label> <proj_dir>: the guard MUST exit 2 (BLOCK).
# Any other exit (0 ALLOW, 1 non-blocking error) is a canary failure — the guard is no
# longer protecting a known-protected path.
assert_block() {
  local hook="$1" payload="$2" label="$3" proj_dir="$4"
  local actual=0
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$proj_dir" "$hook" >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq 2 ]; then
    echo "  PASS [$label] (exit 2 BLOCK)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$label] expected exit 2 (BLOCK) got $actual — guard no longer protects a known-protected path"
    FAIL=$((FAIL + 1))
  fi
}

REPO="$(mk_protected_repo)"

echo "=== guard smoke canary: each guard must BLOCK a known-protected fixture ==="

# Edit-guard: a Write to the protected src/app.ts must BLOCK.
EDIT_PAYLOAD="$(jq -n --arg p "$REPO/src/app.ts" --arg c 'x' '{tool_input:{file_path:$p,content:$c}}')"
assert_block "$EDIT_GUARD" "$EDIT_PAYLOAD" "edit-guard: Write protected src/app.ts" "$REPO"

# Bash-guard: a redirect into the protected src/app.ts must BLOCK.
BASH_PAYLOAD="$(jq -n --arg cmd "echo hi > $REPO/src/app.ts" '{tool_input:{command:$cmd}}')"
assert_block "$BASH_GUARD" "$BASH_PAYLOAD" "bash-guard: redirect into protected src/app.ts" "$REPO"

echo ""
echo "=== Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
  echo "CANARY PASS"
  exit 0
else
  echo "CANARY FAILED — a guard stopped blocking a known-protected path; halting the suite"
  exit 1
fi
