#!/usr/bin/env bash
# Shared hook observability — source this and call mlog_init; an EXIT trap logs one
# JSONL line per run to <repo>/.claude/maestro/hook-log.jsonl (hook, event, exit,
# status, duration). task-report.sh reads this to show where gates trip and how
# long they take. Never blocks, never changes the hook's exit code, and only logs
# in directories that already have a .claude/ (no littering random cwds).
#
# Usage at the top of a hook (fail-open if the lib is missing):
#   _src="${BASH_SOURCE[0]}"; while [ -L "$_src" ]; do _src="$(readlink "$_src")"; done
#   . "$(cd "$(dirname "$_src")" && pwd)/lib-log.sh" 2>/dev/null && mlog_init <name> <event> || true

mlog_init() {
  _MLOG_HOOK="$1"
  _MLOG_EVENT="$2"
  _MLOG_START="$(date +%s)"
  _MLOG_PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
  trap '_mlog_exit $?' EXIT
}

_mlog_exit() {
  local code="$1" dir file status lines
  [ -d "$_MLOG_PROJ/.claude" ] || return 0
  dir="$_MLOG_PROJ/.claude/maestro"
  mkdir -p "$dir" 2>/dev/null || return 0
  file="$dir/hook-log.jsonl"
  status=ok
  [ "$code" = 2 ] && status=block
  [ "$code" != 0 ] && [ "$code" != 2 ] && status=error
  printf '{"ts":"%s","hook":"%s","event":"%s","exit":%s,"status":"%s","durSec":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_MLOG_HOOK" "$_MLOG_EVENT" "$code" "$status" \
    "$(( $(date +%s) - _MLOG_START ))" >> "$file" 2>/dev/null || return 0
  # lazy rotation: past 1000 lines, keep the newest 500
  lines="$(wc -l < "$file" 2>/dev/null || echo 0)"
  if [ "$lines" -gt 1000 ]; then
    tail -n 500 "$file" > "$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" 2>/dev/null
  fi
  return 0
}
