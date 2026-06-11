#!/usr/bin/env bash
# Shared test helpers — tmpdir git repos + subprocess hook runs + assertions.
# Source this from each *.test.sh. Pattern borrowed from claudekit's hook tests.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/maestro/scripts"
HOOKS="$ROOT/maestro/hooks"

PASS=0
FAIL=0

# mkrepo — fresh git repo in a tmpdir; sets $REPO and exports CLAUDE_PROJECT_DIR.
mkrepo() {
  REPO="$(mktemp -d "${TMPDIR:-/tmp}/maestro-test-XXXXXX")/repo"
  mkdir -p "$REPO"
  git -C "$(dirname "$REPO")" init -q "$REPO"
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  export CLAUDE_PROJECT_DIR="$REPO"
  cd "$REPO"
}

# run_hook <hook-file> <json-payload> — runs hook with payload on stdin.
# Captures: $HOOK_EXIT, $HOOK_OUT (stdout), $HOOK_ERR (stderr).
run_hook() {
  local out err
  out="$(mktemp)"; err="$(mktemp)"
  set +e
  printf '%s' "$2" | "$1" >"$out" 2>"$err"
  HOOK_EXIT=$?
  set -e
  HOOK_OUT="$(cat "$out")"; HOOK_ERR="$(cat "$err")"
  rm -f "$out" "$err"
}

_result() { # $1=ok/fail $2=label $3=detail
  if [ "$1" = ok ]; then PASS=$((PASS+1)); printf '  ok  %s\n' "$2"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      %s\n' "$2" "${3:-}"; fi
}

assert_exit() { # <expected> <actual> <label>
  [ "$2" -eq "$1" ] && _result ok "$3" || _result fail "$3" "expected exit $1, got $2"
}

assert_contains() { # <haystack> <needle> <label>
  case "$1" in *"$2"*) _result ok "$3" ;; *) _result fail "$3" "missing: $2" ;; esac
}

assert_not_contains() { # <haystack> <needle> <label>
  case "$1" in *"$2"*) _result fail "$3" "should not contain: $2" ;; *) _result ok "$3" ;; esac
}

assert_file_exists() { [ -e "$1" ] && _result ok "$2" || _result fail "$2" "missing file: $1"; }
assert_file_absent() { [ ! -e "$1" ] && _result ok "$2" || _result fail "$2" "file should not exist: $1"; }

# json_field <json> <python-expr-on-d> — e.g. json_field "$out" "d['hookSpecificOutput']['additionalContext']"
json_field() {
  printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)" 2>/dev/null || true
}

summary() { # <suite-name>
  echo "--- $1: $PASS passed, $FAIL failed ---"
  [ "$FAIL" -eq 0 ]
}
