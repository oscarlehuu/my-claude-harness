#!/usr/bin/env bash
# install.sh — copy deploy with provenance. Black-box, temp fixtures only:
# the source is a fresh clone of this repo in a tmpdir, the DEST is a tmpdir. We never
# touch the real ~/.claude. MAESTRO_INSTALL_VERIFY is the documented test seam for the
# green/red trust gate; the dirty-tree refusal has no override (tested as such).
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL="$ROOT/install.sh"

# A trustworthy source: a fresh git repo built from the WORKING TREE (not a clone of HEAD,
# so the install.sh / hook under test are exactly the files on disk). We copy the tracked
# tree, drop its .git, then git-init + commit everything -> a clean tree with a real HEAD,
# which is precisely what install.sh's own trust gates demand. Returns the path in $SRC.
mk_src() {
  SRC="$(mktemp -d "${TMPDIR:-/tmp}/maestro-install-src-XXXXXX")/src"
  mkdir -p "$SRC"
  # copy the tree git would see at commit time: tracked files (working-tree state) PLUS
  # untracked-but-not-ignored files. The second set is what makes this honest *before* a
  # commit — a brand-new test file (this very file, the modified install.sh) is on disk but
  # not yet tracked, and the deployed gate must run against the files actually on disk, not
  # only HEAD. We skip .git (own init below) and ignored cruft (the .claude/ ledger churn).
  ( cd "$ROOT" && { git ls-files -z; git ls-files --others --exclude-standard -z; } \
    | while IFS= read -r -d '' f; do
        mkdir -p "$SRC/$(dirname "$f")"; cp "$ROOT/$f" "$SRC/$f"
      done )
  git -C "$SRC" init -q
  git -C "$SRC" -c user.email=t@t -c user.name=t add -A >/dev/null
  git -C "$SRC" -c user.email=t@t -c user.name=t commit -q -m "fixture: working tree under test"
}
mk_dest() { DEST="$(mktemp -d "${TMPDIR:-/tmp}/maestro-install-dest-XXXXXX")/.claude"; }

# run_install <verify-override> [project-arg] — runs install.sh against $SRC into a DEST
# we control. With no project-arg, DEST is forced via HOME so we never write real ~/.claude.
# Captures $INS_EXIT, $INS_OUT, $INS_ERR.
run_install() {
  local out err
  out="$(mktemp)"; err="$(mktemp)"
  set +e
  if [ -n "${2:-}" ]; then
    MAESTRO_INSTALL_VERIFY="$1" bash "$SRC/install.sh" "$2" >"$out" 2>"$err"
  else
    MAESTRO_INSTALL_VERIFY="$1" HOME="$(dirname "$DEST")" bash "$SRC/install.sh" >"$out" 2>"$err"
  fi
  INS_EXIT=$?
  set -e
  INS_OUT="$(cat "$out")"; INS_ERR="$(cat "$err")"
  rm -f "$out" "$err"
}

# stamp_field <stamp> <python-expr-on-d> — read a field from the provenance stamp.
stamp_field() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1" 2>/dev/null || true; }

# ===========================================================================
# Happy path: clean tree + green -> files COPIED (not symlinked), hooks +x,
# stamp written with the right sha + a manifest covering every owned path.
# ===========================================================================
mk_src; mk_dest
run_install true
assert_exit 0 "$INS_EXIT" "happy: clean+green install exits 0"

# crew copied as real files, content-equal, NOT symlinks
assert_file_exists "$DEST/agents/developer.md" "happy: crew file deployed"
[ ! -L "$DEST/agents/developer.md" ] && _result ok "happy: crew is a copy not a symlink" \
  || _result fail "happy: crew is a copy not a symlink" "agents/developer.md is a symlink"
if cmp -s "$SRC/maestro/crew/developer.md" "$DEST/agents/developer.md"; then
  _result ok "happy: crew copy is content-equal to source"
else
  _result fail "happy: crew copy is content-equal to source" "content differs"
fi

# hooks copied, executable, not symlinks
assert_file_exists "$DEST/hooks/maestro-engage.sh" "happy: hook deployed"
[ ! -L "$DEST/hooks/maestro-engage.sh" ] && _result ok "happy: hook is a copy not a symlink" \
  || _result fail "happy: hook is a copy not a symlink" "hook is a symlink"
[ -x "$DEST/hooks/maestro-engage.sh" ] && _result ok "happy: hook is chmod +x" \
  || _result fail "happy: hook is chmod +x" "hook not executable"

# whole skill dir copied (SKILL.md + scripts/ + charter/), not a symlink
[ ! -L "$DEST/skills/maestro" ] && _result ok "happy: skill dir is a copy not a symlink" \
  || _result fail "happy: skill dir is a copy not a symlink" "skills/maestro is a symlink"
assert_file_exists "$DEST/skills/maestro/SKILL.md" "happy: skill SKILL.md deployed"
assert_file_exists "$DEST/skills/maestro/scripts/task-verify.sh" "happy: skill scripts/ deployed"
assert_file_exists "$DEST/skills/maestro/charter/gate-pipeline.md" "happy: skill charter/ deployed"

# contract docs + rules copied
assert_file_exists "$DEST/AGENTS.md" "happy: AGENTS.md deployed"
assert_file_exists "$DEST/CLAUDE.md" "happy: CLAUDE.md deployed"
[ ! -L "$DEST/AGENTS.md" ] && _result ok "happy: AGENTS.md is a copy not a symlink" \
  || _result fail "happy: AGENTS.md is a copy not a symlink" "AGENTS.md is a symlink"
assert_file_exists "$DEST/rules/engineering-principles.md" "happy: a rules file deployed"

# stamp: present, with the source sha + a manifest naming owned paths
assert_file_exists "$DEST/maestro-deployed.json" "happy: provenance stamp written"
SRC_SHA="$(git -C "$SRC" rev-parse HEAD)"
[ "$(stamp_field "$DEST/maestro-deployed.json" "d['sha']")" = "$SRC_SHA" ] \
  && _result ok "happy: stamp sha matches source HEAD" \
  || _result fail "happy: stamp sha matches source HEAD" "got $(stamp_field "$DEST/maestro-deployed.json" "d['sha']") want $SRC_SHA"
# compare realpaths — install.sh resolves $ROOT via `cd && pwd`, which may canonicalize
# symlinked tmp paths (/var -> /private/var on macOS); the deployed repo is still $SRC.
STAMP_SRC="$(stamp_field "$DEST/maestro-deployed.json" "d['source']")"
[ "$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$STAMP_SRC")" \
  = "$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$SRC")" ] \
  && _result ok "happy: stamp records the source repo path" \
  || _result fail "happy: stamp records the source repo path" "got $STAMP_SRC want $SRC"
man_has="$(stamp_field "$DEST/maestro-deployed.json" "'yes' if '$DEST/agents/developer.md' in d['manifest'] and '$DEST/skills/maestro' in d['manifest'] else 'no'")"
[ "$man_has" = "yes" ] && _result ok "happy: manifest lists deployed target paths" \
  || _result fail "happy: manifest lists deployed target paths" "manifest missing owned paths"

# ===========================================================================
# Dirty tree -> refuse, non-zero exit, DEST untouched. No override exists.
# ===========================================================================
mk_src; mk_dest
echo "scratch" > "$SRC/DIRTY_FILE"   # untracked change => dirty working tree
run_install true
assert_exit 1 "$INS_EXIT" "dirty: dirty tree refuses with non-zero exit"
assert_contains "$INS_ERR" "dirty" "dirty: refusal message names a dirty tree"
assert_file_absent "$DEST/maestro-deployed.json" "dirty: DEST left untouched (no stamp)"
assert_file_absent "$DEST/agents/developer.md" "dirty: DEST left untouched (no crew copied)"

# ===========================================================================
# Red suite (MAESTRO_INSTALL_VERIFY=false) -> refuse, non-zero, DEST untouched.
# ===========================================================================
mk_src; mk_dest
run_install false
assert_exit 1 "$INS_EXIT" "red: red verify refuses with non-zero exit"
assert_contains "$INS_ERR" "verify failed" "red: refusal message names the failed verify"
assert_file_absent "$DEST/maestro-deployed.json" "red: DEST left untouched (no stamp)"

# ===========================================================================
# Re-deploy over a previous copy-deploy -> owned files replaced, stamp updated.
# Hand-edit an owned file (skills/maestro/SKILL.md) -> it must be replaced (owned
# namespace, never preserved). Advance the source HEAD -> stamp sha must update.
# ===========================================================================
mk_src; mk_dest
run_install true
FIRST_SHA="$(stamp_field "$DEST/maestro-deployed.json" "d['sha']")"
echo "HAND EDIT THAT MUST NOT SURVIVE" >> "$DEST/skills/maestro/SKILL.md"
echo "HAND EDIT OWNED HOOK" >> "$DEST/hooks/maestro-engage.sh"
# advance source HEAD with a real commit so the redeploy sha differs
echo "note" > "$SRC/REDEPLOY_NOTE.txt"
git -C "$SRC" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$SRC" -c user.email=t@t -c user.name=t commit -q -m "redeploy bump"
SECOND_SHA="$(git -C "$SRC" rev-parse HEAD)"
run_install true
assert_exit 0 "$INS_EXIT" "redeploy: second clean+green install exits 0"
if cmp -s "$SRC/maestro/SKILL.md" "$DEST/skills/maestro/SKILL.md"; then
  _result ok "redeploy: owned skill file replaced (hand-edit gone)"
else
  _result fail "redeploy: owned skill file replaced (hand-edit gone)" "hand-edit survived in owned namespace"
fi
if cmp -s "$SRC/maestro/hooks/maestro-engage.sh" "$DEST/hooks/maestro-engage.sh"; then
  _result ok "redeploy: owned hook replaced (hand-edit gone)"
else
  _result fail "redeploy: owned hook replaced (hand-edit gone)" "hand-edit survived in owned hook"
fi
[ "$(stamp_field "$DEST/maestro-deployed.json" "d['sha']")" = "$SECOND_SHA" ] \
  && _result ok "redeploy: stamp sha updated to the new HEAD" \
  || _result fail "redeploy: stamp sha updated to the new HEAD" "stamp still at old sha"
[ "$FIRST_SHA" != "$SECOND_SHA" ] && _result ok "redeploy: the two deploys had different shas (sanity)" \
  || _result fail "redeploy: the two deploys had different shas (sanity)" "shas equal — bump did not take"

# ===========================================================================
# Migration: DEST pre-populated with the OLD symlink layout -> symlinks replaced
# by real copies. This is the upgrade path for every existing symlink install.
# ===========================================================================
mk_src; mk_dest
mkdir -p "$DEST/agents" "$DEST/hooks" "$DEST/skills" "$DEST/rules"
ln -s "$SRC/maestro/crew/developer.md" "$DEST/agents/developer.md"
ln -s "$SRC/maestro/hooks/maestro-engage.sh" "$DEST/hooks/maestro-engage.sh"
ln -s "$SRC/maestro" "$DEST/skills/maestro"
ln -s "$SRC/AGENTS.md" "$DEST/AGENTS.md"
[ -L "$DEST/agents/developer.md" ] && _result ok "migration: precondition — old layout is symlinks" \
  || _result fail "migration: precondition — old layout is symlinks" "fixture not a symlink"
run_install true
assert_exit 0 "$INS_EXIT" "migration: install over old symlinks exits 0"
[ -e "$DEST/agents/developer.md" ] && [ ! -L "$DEST/agents/developer.md" ] \
  && _result ok "migration: crew symlink replaced by a copy" \
  || _result fail "migration: crew symlink replaced by a copy" "still a symlink (or gone)"
[ -e "$DEST/skills/maestro" ] && [ ! -L "$DEST/skills/maestro" ] \
  && _result ok "migration: skill symlink replaced by a real dir" \
  || _result fail "migration: skill symlink replaced by a real dir" "skills/maestro still a symlink"
[ -e "$DEST/AGENTS.md" ] && [ ! -L "$DEST/AGENTS.md" ] \
  && _result ok "migration: AGENTS.md symlink replaced by a copy" \
  || _result fail "migration: AGENTS.md symlink replaced by a copy" "AGENTS.md still a symlink"

# ===========================================================================
# Never-clobber: a user's OWN AGENTS.md (a real file we never deployed, absent from
# any stamp manifest) -> left untouched + a NOTE. The user-owned contract stays theirs.
# ===========================================================================
mk_src; mk_dest
mkdir -p "$DEST"
printf 'MY OWN CONTRACT — do not touch\n' > "$DEST/AGENTS.md"
run_install true
assert_exit 0 "$INS_EXIT" "never-clobber: install still succeeds"
if grep -q "MY OWN CONTRACT" "$DEST/AGENTS.md"; then
  _result ok "never-clobber: user's own AGENTS.md left untouched"
else
  _result fail "never-clobber: user's own AGENTS.md left untouched" "user file was overwritten"
fi
assert_contains "$INS_OUT" "left untouched" "never-clobber: install NOTEs the skipped file"
# and that user file is NOT recorded in the manifest (it isn't ours)
nc="$(stamp_field "$DEST/maestro-deployed.json" "'in' if '$DEST/AGENTS.md' in d['manifest'] else 'out'")"
[ "$nc" = "out" ] && _result ok "never-clobber: user AGENTS.md not added to the manifest" \
  || _result fail "never-clobber: user AGENTS.md not added to the manifest" "user file leaked into manifest"

# ===========================================================================
# Project-local install (./install.sh <project>) -> same semantics, stamp at
# <project>/.claude/maestro-deployed.json, contract docs at the project root.
# ===========================================================================
mk_src
PROJ="$(mktemp -d "${TMPDIR:-/tmp}/maestro-install-proj-XXXXXX")/proj"
mkdir -p "$PROJ"
run_install true "$PROJ"
assert_exit 0 "$INS_EXIT" "project-local: install exits 0"
assert_file_exists "$PROJ/.claude/maestro-deployed.json" "project-local: stamp at <project>/.claude"
assert_file_exists "$PROJ/.claude/agents/developer.md" "project-local: crew deployed under <project>/.claude"
assert_file_exists "$PROJ/AGENTS.md" "project-local: contract doc at the project root"
[ ! -L "$PROJ/AGENTS.md" ] && _result ok "project-local: contract doc is a copy" \
  || _result fail "project-local: contract doc is a copy" "AGENTS.md is a symlink"

# ===========================================================================
# Source not a git repo -> refuse, non-zero, DEST untouched.
# ===========================================================================
NOGIT="$(mktemp -d "${TMPDIR:-/tmp}/maestro-install-nogit-XXXXXX")/src"
cp -R "$ROOT" "$NOGIT"
rm -rf "$NOGIT/.git"
mk_dest
set +e
out="$(MAESTRO_INSTALL_VERIFY=true HOME="$(dirname "$DEST")" bash "$NOGIT/install.sh" 2>&1)"; ng=$?
set -e
assert_exit 1 "$ng" "no-git: a non-git source refuses with non-zero exit"
assert_contains "$out" "not a git repo" "no-git: refusal names the non-git source"
assert_file_absent "$DEST/maestro-deployed.json" "no-git: DEST untouched"

# ===========================================================================
# Staleness nudge in maestro-engage.sh, driven via the MAESTRO_DEPLOYED_STAMP seam.
#   stamp sha BEHIND source HEAD -> the one line prints
#   stamp sha EQUAL to source HEAD -> silent
#   stamp missing -> silent
# ===========================================================================
NUDGE_LINE="Production runtime is behind the harness repo"
mkrepo   # fresh git repo as the "harness source"; its HEAD is the current sha
SRC_HEAD="$(git -C "$REPO" rev-parse HEAD)"
STAMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/maestro-stamp-XXXXXX")"

# behind: stamp records an old (fake) sha -> nudge fires
python3 - "$STAMP_DIR/stamp.json" "$REPO" "0000000000000000000000000000000000000000" <<'PY'
import json, sys
json.dump({"source": sys.argv[2], "sha": sys.argv[3], "manifest": []}, open(sys.argv[1], "w"))
PY
MAESTRO_DEPLOYED_STAMP="$STAMP_DIR/stamp.json" run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_exit 0 "$HOOK_EXIT" "stale: hook still exits 0"
assert_contains "$HOOK_OUT" "$NUDGE_LINE" "stale: stamp behind HEAD prints the nudge"
assert_contains "$HOOK_OUT" "${SRC_HEAD:0:7}" "stale: nudge names the current repo short-sha"

# equal: stamp records the real current sha -> silent
python3 - "$STAMP_DIR/stamp.json" "$REPO" "$SRC_HEAD" <<'PY'
import json, sys
json.dump({"source": sys.argv[2], "sha": sys.argv[3], "manifest": []}, open(sys.argv[1], "w"))
PY
MAESTRO_DEPLOYED_STAMP="$STAMP_DIR/stamp.json" run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_not_contains "$HOOK_OUT" "$NUDGE_LINE" "stale: stamp equal to HEAD is silent"

# missing stamp -> silent (point the seam at a path that does not exist)
MAESTRO_DEPLOYED_STAMP="$STAMP_DIR/does-not-exist.json" run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_not_contains "$HOOK_OUT" "$NUDGE_LINE" "stale: missing stamp is silent"

# corrupt/hand-edited stamp -> fail-silent (no crash, no nudge)
printf 'not json at all {{{' > "$STAMP_DIR/stamp.json"
MAESTRO_DEPLOYED_STAMP="$STAMP_DIR/stamp.json" run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_exit 0 "$HOOK_EXIT" "stale: corrupt stamp still exits 0"
assert_not_contains "$HOOK_OUT" "$NUDGE_LINE" "stale: corrupt stamp is silent"

# stamped source repo gone -> fail-silent
python3 - "$STAMP_DIR/stamp.json" "/nonexistent-source-$$" "$SRC_HEAD" <<'PY'
import json, sys
json.dump({"source": sys.argv[2], "sha": sys.argv[3], "manifest": []}, open(sys.argv[1], "w"))
PY
MAESTRO_DEPLOYED_STAMP="$STAMP_DIR/stamp.json" run_hook "$HOOKS/maestro-engage.sh" '{"source":"startup"}'
assert_not_contains "$HOOK_OUT" "$NUDGE_LINE" "stale: missing source repo is silent"

rm -rf "$STAMP_DIR"

summary "install"
