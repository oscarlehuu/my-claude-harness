#!/usr/bin/env bash
# install.sh — register maestro-mcp into Claude Code.
#
# The crew runs over cliproxy (Max quota, cap-free) — cliproxy must be running on :8317. A
# Gate-1-approve resume runs a full dev→test→review cycle (minutes), so we set a long per-call
# timeout (600000ms). Re-run any time; `claude mcp add-json` overwrites the existing entry.
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER="$DIR/server.ts"
SCOPE="${1:-user}"   # user | project | local

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI not found on PATH. Add this to your .mcp.json manually:"
  cat "$DIR/.mcp.json.example" | sed "s#__SERVER__#$SERVER#"
  exit 0
fi

JSON="{\"command\":\"node\",\"args\":[\"$SERVER\"],\"env\":{},\"timeout\":600000}"

echo "Registering maestro-mcp (scope: $SCOPE) → node $SERVER"
claude mcp remove maestro --scope "$SCOPE" >/dev/null 2>&1 || true
claude mcp add-json maestro "$JSON" --scope "$SCOPE"

echo
echo "Done. Verify with:  claude mcp list"
echo "Preconditions: cliproxy running on :8317 (crew = Max quota). Node 23+ (native TS)."
echo "The CTO invokes maestro({task,...}); relay Gate 1 / Gate 2 to the founder via AskUserQuestion."
