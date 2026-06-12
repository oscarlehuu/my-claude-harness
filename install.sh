#!/usr/bin/env bash
set -euo pipefail
# Install the maestro harness into Claude Code — a COPY deploy with provenance.
#   ./install.sh            -> ~/.claude          (global: applies everywhere)
#   ./install.sh <project>  -> <project>/.claude  (project-local)
#
# The harness repo is the PROJECT; the installed .claude is the PRODUCTION runtime.
# Files are COPIED (not symlinked) so a mid-edit working tree is never live machine-wide
# before a verdict. The loop: run stable production -> edit the project -> reinstall
# (only when the tree is clean AND the suite is green) -> repeat.
#
# Refusal is the safety: a dirty tree or a red suite aborts the deploy (non-zero exit).
# A provenance stamp ($DEST/maestro-deployed.json) records the source path, deployed sha,
# timestamp, and the manifest of deployed paths — it is how later installs tell our copies
# from user files, and how the staleness nudge in maestro-engage.sh knows it is behind.
#
# Rollback is "re-run install.sh from a good commit" — not `git checkout`, because the
# runtime no longer points back at the working tree.
#
# Test seam: MAESTRO_INSTALL_VERIFY overrides the verify COMMAND (default `bash tests/run-all.sh`)
# so the suite can drive happy/red paths without running the real thing. The dirty-tree
# refusal has NO override — a dirty source is never trustworthy.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEST="${1:+$1/.claude}"; DEST="${DEST:-$HOME/.claude}"

die() { echo "install: $*" >&2; exit 1; }

# --- Trust gate 1: the source tree must be clean ------------------------------------
# A non-git source, a tree with uncommitted changes, or a repo with no HEAD are all
# untrustworthy — we refuse to copy anything we can't stamp with a committed sha.
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "source is not a git repo ($ROOT) — refusing to deploy."
SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" \
  || die "source has no commits — refusing to deploy."
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  die "source tree is dirty — commit or stash before deploying. (no override; a dirty source is never trustworthy)"
fi

# --- Trust gate 2: the suite must be green ------------------------------------------
VERIFY_CMD="${MAESTRO_INSTALL_VERIFY:-bash tests/run-all.sh}"
echo "install: verifying source ($VERIFY_CMD) ..."
if ! ( cd "$ROOT" && eval "$VERIFY_CMD" >/dev/null 2>&1 ); then
  die "verify failed ($VERIFY_CMD) — refusing to deploy a red tree."
fi

# --- Deploy ------------------------------------------------------------------------
mkdir -p "$DEST/agents" "$DEST/hooks" "$DEST/skills" "$DEST/rules"
chmod +x "$ROOT"/maestro/hooks/*.sh "$ROOT"/maestro/scripts/*.sh "$ROOT"/hq/bootstrap.sh 2>/dev/null || true

MANIFEST=()   # every target path we own — recorded in the stamp

# copy_owned: installer-owned namespaces (agents/hooks/skills/maestro). Always replace,
# whatever is there now — a prior symlink (old layout), a stale copy, or a hand-edit.
#
# ATOMIC per target: copy to a temp name in the SAME directory, then `mv -f` into place.
# `mv` between two paths on one filesystem is a rename(2) — a concurrent reader (a live guard
# firing mid-deploy) sees either the whole OLD file or the whole NEW one, never a half-written
# `cp` in progress. The temp is a sibling of the dest so the rename never crosses a filesystem
# boundary (which would degrade `mv` back into a non-atomic copy). For a directory target
# (skills/maestro), `mv` onto an EXISTING dir would move the source INTO it rather than replace
# it, so we `rm -rf` the dest first — directory targets are not read mid-flight by the guards
# (only the two hooks + guard_lib.py beside them are), so the brief gap there is immaterial.
copy_owned() { # $1 = source path, $2 = dest path
  local tmp; tmp="$2.maestro-tmp.$$"
  rm -rf "$tmp"
  cp -R "$1" "$tmp"
  if [ -d "$tmp" ]; then
    rm -rf "$2"          # mv-onto-existing-dir has move-INTO semantics; clear it first
    mv -f "$tmp" "$2"
  else
    mv -f "$tmp" "$2"    # atomic rename: a reader never observes a partial file
  fi
  MANIFEST+=("$2")
}

# copy_doc: user-ownable files (AGENTS.md/CLAUDE.md/rules). Replace our own deploys
# (a symlink from the old layout, or a path already in this run's manifest) but never
# clobber a real file the user wrote themselves — leave it + NOTE, same contract as the
# old link_doc. We treat any plain (non-symlink) file NOT placed by us as the user's.
copy_doc() { # $1 = source file, $2 = dest path
  if [ -e "$2" ] && [ ! -L "$2" ] && ! stamp_has "$2"; then
    echo "NOTE: $2 exists and is not a deployed copy — left untouched. Merge $1 manually."
    return
  fi
  rm -rf "$2"
  cp "$1" "$2"
  MANIFEST+=("$2")
}

# stamp_has: was this target path recorded in a *previous* deploy's manifest? That is how
# we tell "our copy that the user happened to hand-edit" (replace) from "the user's own
# file we never touched" (leave). Reads the existing stamp; absent/corrupt => not ours.
stamp_has() { # $1 = dest path
  [ -f "$DEST/maestro-deployed.json" ] || return 1
  MAESTRO_STAMP="$DEST/maestro-deployed.json" MAESTRO_Q="$1" python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    m = json.load(open(os.environ["MAESTRO_STAMP"], encoding="utf-8")).get("manifest", [])
except Exception:
    sys.exit(1)
sys.exit(0 if os.environ["MAESTRO_Q"] in m else 1)
PY
}

# crew .md -> agents/ ; hook .sh -> hooks/ ; the whole skill dir -> skills/maestro
for f in "$ROOT"/maestro/crew/*.md;  do copy_owned "$f" "$DEST/agents/$(basename "$f")"; done
# DEPLOY ORDER IS LOAD-BEARING: the shared python helper (guard_lib.py) must land BEFORE the
# *.sh guard hooks that import it. A guard hook is a self-contained safety component the moment
# its file appears; if a NEW guard were deployed while an OLD/absent guard_lib.py still sat
# beside it, a live session firing that guard would import a stale-or-missing lib and fail
# closed (exit 2) — a false block. Copying the lib first means at the instant any new guard
# becomes live, the new (or at worst the equal prior) lib is already in place. Combined with
# copy_owned's atomic rename, at NO point during a deploy does a guard fire against a missing or
# older guard_lib.py. The guards import it from their own dir in BOTH the repo tree and the
# deployed copy (it is a .py module, not a *.sh hook, so it needs its own copy line).
for f in "$ROOT"/maestro/hooks/*.py; do [ -e "$f" ] || continue; copy_owned "$f" "$DEST/hooks/$(basename "$f")"; done
for f in "$ROOT"/maestro/hooks/*.sh; do copy_owned "$f" "$DEST/hooks/$(basename "$f")"; done
chmod +x "$DEST"/hooks/*.sh 2>/dev/null || true
copy_owned "$ROOT/maestro" "$DEST/skills/maestro"

# Contract docs. Project-local: into the project root. Global: into ~/.claude so the
# contract loads in every session. AGENTS.md is the source of truth; CLAUDE.md imports it.
if [ -n "${1:-}" ]; then
  copy_doc "$ROOT/AGENTS.md" "$1/AGENTS.md"
  copy_doc "$ROOT/CLAUDE.md" "$1/CLAUDE.md"
else
  copy_doc "$ROOT/AGENTS.md" "$DEST/AGENTS.md"
  copy_doc "$ROOT/CLAUDE.md" "$DEST/CLAUDE.md"
fi

# Global engineering rules ride along like the contract docs. Older sources may have no
# rules/ dir — guard the glob so it never expands to a literal "*.md".
if [ -d "$ROOT/rules" ]; then
  for f in "$ROOT"/rules/*.md; do
    [ -e "$f" ] || continue
    copy_doc "$f" "$DEST/rules/$(basename "$f")"
  done
fi

# --- Provenance stamp --------------------------------------------------------------
# Written LAST, after the manifest is complete. This file is the boundary between
# "deployed copy" and "user file" for every future install, and the anchor for the
# staleness nudge. Last writer wins under concurrent installs (no lock — documented).
MAESTRO_STAMP_OUT="$DEST/maestro-deployed.json" \
MAESTRO_SRC="$ROOT" MAESTRO_SHA="$SHA" \
python3 - "${MANIFEST[@]}" <<'PY'
import json, os, sys
from datetime import datetime, timezone
stamp = {
    "source": os.environ["MAESTRO_SRC"],
    "sha": os.environ["MAESTRO_SHA"],
    "deployedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "manifest": sys.argv[1:],
}
with open(os.environ["MAESTRO_STAMP_OUT"], "w", encoding="utf-8") as f:
    json.dump(stamp, f, indent=2)
    f.write("\n")
PY

echo "Installed maestro crew+hooks+skill into: $DEST (copy deploy @ ${SHA:0:7})"
echo "  crew: $(ls "$ROOT/maestro/crew" | tr '\n' ' ')"
echo "  hooks: guard-block-main-edits, guard-block-main-bash, commit-gate, stop-dod, crew-context, maestro-engage   skill: maestro (+scripts)"
echo "  stamp: $DEST/maestro-deployed.json"
echo "NEXT: merge settings.hooks.json into $DEST/settings.json"
echo "      (PreToolUse guards + commit-gate + SessionStart auto-engage)."
echo "      For a GLOBAL install, rewrite the hook command paths from \$CLAUDE_PROJECT_DIR to absolute $DEST/hooks/..."
