#!/usr/bin/env bash
# PreToolUse on Bash — if the command is a `git commit`, re-run the task's verify command.
# Exit code = ground truth: if verify fails, BLOCK the commit (exit 2). The orchestrator
# (or crew) cannot ship code that fails verification.
set -eu

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

# Only gate actual commits; let every other Bash command through.
case "$cmd" in
  *"git commit"*) : ;;
  *) exit 0 ;;
esac

# Resolve the verify command: env var first, then .claude/maestro-verify file.
VERIFY="${MAESTRO_VERIFY:-}"
if [ -z "$VERIFY" ] && [ -f .claude/maestro-verify ]; then
  VERIFY="$(cat .claude/maestro-verify)"
fi

# No verify configured → don't block (nothing to enforce).
[ -z "$VERIFY" ] && exit 0

log="$(mktemp)"
if ! eval "$VERIFY" >"$log" 2>&1; then
  echo "BLOCKED: verify command failed — cannot commit." >&2
  echo "  verify: $VERIFY" >&2
  tail -n 20 "$log" >&2
  rm -f "$log"
  exit 2
fi
rm -f "$log"
exit 0
