#!/usr/bin/env bash
# PreToolUse guard — the orchestrator (main session) must DELEGATE implementation to
# the maestro crew, never edit code directly. Crew subagents (which carry an agent_id)
# are allowed to edit. Blocks even under --dangerously-skip-permissions (exit 2 ignores
# permission mode).
#
# Carve-outs that let the main session through:
#   1. Engagement OFF — `.claude/maestro-direct` exists in the repo → direct-edit mode.
#   2. Harness state — paths under `.claude/maestro*` (manifest, verify cmd, ledger) are
#      maestro's own bookkeeping, not production code, so the CTO may write them.
#   3. Scratch/tmp paths — writes under /tmp/, /private/tmp/, /var/folders/, or $TMPDIR
#      are no-impact (outside the repo) and must not be blocked; the orchestrator needs
#      these for recon/benchmark files that never touch production code.
#
# ⚠️ VERIFY before trusting in production: confirm `agent_id` is populated for subagents
# on your Claude Code version (run the agent_id probe). If it is NOT reliable, switch
# enforcement to the coded-controller (MCP) variant, where crew run as separate processes
# and this main-vs-subagent distinction is moot.
set -eu

input="$(cat)"
agent_id="$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null || true)"

# A subagent (developer/ui-developer/...) carries an agent_id → allow it to edit.
if [ -n "$agent_id" ]; then
  exit 0
fi

# Engagement OFF for this repo → allow direct edits (the founder chose direct-edit mode).
proj="${CLAUDE_PROJECT_DIR:-$PWD}"
if [ -f "$proj/.claude/maestro-direct" ] || [ -f ".claude/maestro-direct" ]; then
  exit 0
fi

# Extract file_path; canonicalization (with realpath) happens below before any carve-out check.
# SECURITY: do NOT apply the .claude/maestro carve-out on the raw path — an unanchored
# substring match on the raw value would (a) allow traversal out of .claude/maestro/ into
# production code via "..", and (b) match unrelated paths that merely contain the substring
# (e.g. skills/.claude/maestro-evil.ts, .claude/maestroX/anything).
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"

# Scratch/tmp paths are outside the repo and no-impact → allow.
# Mirrors the bash guard's benign_target() and foreman's guard.ts "no-impact paths" policy.
#
# SECURITY: canonicalize file_path via python3 realpath BEFORE the prefix check to prevent
# path-traversal attacks like /tmp/../../<repo>/file which starts with /tmp/ but resolves
# into the repository.  On macOS /tmp → /private/tmp; we also canonicalize the tmp roots.
_canon_path=""
if [ -n "$file_path" ] && command -v python3 >/dev/null 2>&1; then
  # os.path.realpath resolves symlinks in existing path components (e.g. /tmp → /private/tmp
  # on macOS) even when the final path does not yet exist.  This is exactly what we need to
  # prevent traversal attacks like /tmp/../../<repo>/file.
  _canon_path="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$file_path" 2>/dev/null || true)"
fi
# Fall back to original path if canonicalization fails (fail-open).
_check_path="${_canon_path:-$file_path}"

# Harness state writes are maestro's own bookkeeping → allow.
# SECURITY: compare against CANONICAL paths anchored to the real repo root so that
# traversal paths (.claude/maestro/../../hooks/...) and unrelated paths that contain
# the substring (skills/.claude/maestro-evil.ts, .claude/maestroX/anything) are NOT
# incorrectly classified as harness state.
_canon_proj="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$proj" 2>/dev/null || echo "$proj")"
_maestro_json="${_canon_proj}/.claude/maestro.json"
_maestro_verify="${_canon_proj}/.claude/maestro-verify"
_maestro_direct_file="${_canon_proj}/.claude/maestro-direct"
_maestro_ledger_prefix="${_canon_proj}/.claude/maestro/"
if [ "$_check_path" = "$_maestro_json" ] \
   || [ "$_check_path" = "$_maestro_verify" ] \
   || [ "$_check_path" = "$_maestro_direct_file" ]; then
  exit 0
fi
case "$_check_path" in
  # Note trailing slash: matches <repo>/.claude/maestro/<anything> but NOT maestroX or maestro-evil
  "$_maestro_ledger_prefix"*) exit 0 ;;
esac

_tmpdir="${TMPDIR:-}"
_tmpdir="${_tmpdir%/}"  # strip trailing slash for consistent prefix matching
# Canonicalize the tmp roots too (macOS: /tmp → /private/tmp).
_canon_tmp_roots=()
for _root in /tmp /private/tmp /var/folders; do
  _cr="$(python3 -c "import os; print(os.path.realpath('$_root'))" 2>/dev/null || true)"
  [ -n "$_cr" ] && _canon_tmp_roots+=("$_cr/")
done
if [ -n "$_tmpdir" ]; then
  _cr="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$_tmpdir" 2>/dev/null || true)"
  [ -n "$_cr" ] && _canon_tmp_roots+=("$_cr/")
fi

is_scratch=0
for _pfx in "${_canon_tmp_roots[@]}"; do
  case "$_check_path" in
    "$_pfx"*) is_scratch=1; break ;;
  esac
done
if [ "$is_scratch" -eq 1 ]; then
  exit 0
fi

# Prose/docs/no-impact carve-out — the CTO may edit documentation and memory files
# directly, but code remains blocked.  SECURITY: use the canonical _check_path so
# docs/../src/app.ts resolves to src/app.ts and does NOT match the docs prefix.
_base="${_check_path##*/}"
_ext=""
_stem="$_base"
case "$_base" in
  *.*)
    _ext=".${_base##*.}"
    _stem="${_base%.*}"
    ;;
esac
_lower_ext="$(printf '%s' "$_ext" | tr '[:upper:]' '[:lower:]')"
case "$_lower_ext" in
  .md|.markdown|.mdx|.txt|.rst|.adoc) exit 0 ;;
esac
_upper_stem="$(printf '%s' "$_stem" | tr '[:lower:]' '[:upper:]')"
case "$_upper_stem" in
  LICENSE|LICENCE|COPYING|NOTICE|AUTHORS) exit 0 ;;
esac
_docs_prefix="${_canon_proj}/docs/"
case "$_check_path" in
  "$_docs_prefix"*) exit 0 ;;
esac

# No agent_id, engaged, real repo file → this is the orchestrator → block direct edits.
cat >&2 <<'MSG'
BLOCKED: the orchestrator does not edit files directly.

Drive the change through the maestro MCP tool instead —
maestro({task, cwd, verifyCommand?}) → approve Gate 1 → approve Gate 2, and the developer
crew makes the change through the gated dev→test→review loop.

Scratch/recon work? Write benchmark or temp files to /tmp or $TMPDIR — those are allowed.
Production code inside the repo? Run maestro.
(Wrong repo / small tweak? Disengage with `echo 1 > .claude/maestro-direct`.)
MSG
exit 2
