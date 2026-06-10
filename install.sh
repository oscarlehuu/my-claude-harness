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

# AGENTS.md is the single source of truth; CLAUDE.md is a pointer that imports @AGENTS.md.
# Project-local: link both to the project root. Global: link both into ~/.claude so the
# contract loads in every session — but never clobber a CLAUDE.md/AGENTS.md the user wrote
# themselves (only replace missing files or our own symlinks).
link_doc() { # $1 = source file, $2 = dest path
  if [ ! -e "$2" ] || [ -L "$2" ]; then
    ln -sfn "$1" "$2"
  else
    echo "NOTE: $2 exists and is not a symlink — left untouched. Merge $1 manually."
  fi
}
if [ -n "${1:-}" ]; then
  link_doc "$ROOT/AGENTS.md" "$1/AGENTS.md"
  link_doc "$ROOT/CLAUDE.md" "$1/CLAUDE.md"
else
  link_doc "$ROOT/AGENTS.md" "$DEST/AGENTS.md"
  link_doc "$ROOT/CLAUDE.md" "$DEST/CLAUDE.md"
fi

echo "Installed maestro crew+hooks+skill into: $DEST"
echo "  crew: $(ls "$ROOT/crew" | tr '\n' ' ')"
echo "  hooks: guard-block-main-edits, guard-block-main-bash, commit-gate, stop-dod, maestro-engage   skill: maestro (+scripts)"
echo "NEXT: merge settings.hooks.json into $DEST/settings.json"
echo "      (PreToolUse guards + commit-gate + SessionStart auto-engage)."
echo "      For a GLOBAL install, rewrite the hook command paths from \$CLAUDE_PROJECT_DIR to absolute $DEST/hooks/..."
