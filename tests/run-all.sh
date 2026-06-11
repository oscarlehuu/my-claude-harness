#!/usr/bin/env bash
# Run the full maestro test suite. Exit non-zero if any suite fails.
# This is also the repo's own verify command — the harness gates itself with it.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

suites=(
  "$ROOT/tests/ledger-scripts.test.sh"
  "$ROOT/tests/gates.test.sh"
  "$ROOT/tests/context-hooks.test.sh"
  "$ROOT/tests/doc-drift.test.sh"
  "$ROOT/tests/hq-board.test.sh"
  "$ROOT/tests/registry-add.test.sh"
  "$ROOT/tests/guard.test.sh"
)

failed=0
for s in "${suites[@]}"; do
  echo "== $(basename "$s") =="
  if ! bash "$s"; then
    failed=1
  fi
  echo
done

if [ "$failed" -ne 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: ALL SUITES PASS"
exit 0
