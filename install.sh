#!/usr/bin/env bash
set -euo pipefail
# Install the maestro harness into Claude Code.
#   ./install.sh            -> ~/.claude          (global: applies everywhere)
#   ./install.sh <project>  -> <project>/.claude  (project-local)
# Symlinks the live source so edits here apply immediately. Hooks are chmod +x.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEST="${1:+$1/.claude}"; DEST="${DEST:-$HOME/.claude}"
mkdir -p "$DEST/agents" "$DEST/hooks" "$DEST/skills"
chmod +x "$ROOT"/hooks/*.sh "$ROOT"/skills/maestro/scripts/*.sh

for f in "$ROOT"/crew/*.md;  do ln -sfn "$f" "$DEST/agents/$(basename "$f")"; done
for f in "$ROOT"/hooks/*.sh; do ln -sfn "$f" "$DEST/hooks/$(basename "$f")"; done
ln -sfn "$ROOT/skills/maestro" "$DEST/skills/maestro"

# AGENTS.md / CLAUDE.md are the assistant's docs. Project-local: link to the project root.
# Global: do NOT clobber an existing ~/.claude/CLAUDE.md — the charter also lives in the skill.
if [ -n "${1:-}" ]; then
  ln -sfn "$ROOT/AGENTS.md" "$1/AGENTS.md"
  ln -sfn "$ROOT/CLAUDE.md" "$1/CLAUDE.md"
else
  echo "NOTE: global install does not overwrite ~/.claude/CLAUDE.md."
  echo "      The CTO charter lives in this repo's AGENTS.md/CLAUDE.md and in skills/maestro/SKILL.md."
fi

echo "Installed maestro crew+hooks+skill into: $DEST"
echo "  crew: $(ls "$ROOT/crew" | tr '\n' ' ')"
echo "  hooks: guard-block-main-edits, guard-block-main-bash, commit-gate, stop-dod, maestro-engage   skill: maestro (+scripts)"
echo "NEXT: merge settings.hooks.json into $DEST/settings.json"
echo "      (PreToolUse guards + commit-gate + SessionStart auto-engage)."
echo "      For a GLOBAL install, rewrite the hook command paths from \$CLAUDE_PROJECT_DIR to absolute $DEST/hooks/..."
