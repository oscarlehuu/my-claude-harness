#!/usr/bin/env bash
# registry-add.sh — the one-command line-writer that adds a repo to the HQ registry.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HQ="$(mktemp -d "${TMPDIR:-/tmp}/maestro-hq-XXXXXX")"
export MAESTRO_HQ="$HQ"

reg_paths() { # print the JSON paths array, one per line
  python3 -c "import json,sys; print('\n'.join(r['path'] for r in json.load(open(sys.argv[1]))['repos']))" "$HQ/registry.json"
}
reg_count() { python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['repos']))" "$HQ/registry.json"; }

# --- creates registry.json when missing, default name = basename ----------------
mkrepo   # $REPO + CLAUDE_PROJECT_DIR; cwd is the repo toplevel
assert_file_absent "$HQ/registry.json" "registry.json absent before first add"
out="$("$SCRIPTS/registry-add.sh")"
assert_file_exists "$HQ/registry.json" "registry-add creates registry.json when missing"
assert_contains "$out" "registered: repo" "default name is basename of the path"
[ "$(reg_count)" = "1" ] && _result ok "first add yields one entry" || _result fail "first add yields one entry" "got $(reg_count)"

# --- dedupe: same repo again -> exit 0, 'already registered', no growth ---------
set +e; out="$("$SCRIPTS/registry-add.sh")"; rc=$?; set -e
assert_exit 0 "$rc" "re-adding an existing repo exits 0"
assert_contains "$out" "already registered: repo" "re-adding reports already registered"
[ "$(reg_count)" = "1" ] && _result ok "dedupe does not append a duplicate" || _result fail "dedupe does not append a duplicate" "count grew to $(reg_count)"
# dedupe must hold even when invoked via a different spelling of the same path (trailing slash)
set +e; "$SCRIPTS/registry-add.sh" "$REPO/" >/dev/null 2>&1; dup=$?; set -e
assert_exit 0 "$dup" "dedupe via trailing-slash path exits 0"
[ "$(reg_count)" = "1" ] && _result ok "trailing-slash spelling still dedupes" || _result fail "trailing-slash spelling still dedupes" "count grew to $(reg_count)"

# --- append a second, distinct repo with explicit --name ------------------------
SECOND="$(mktemp -d "${TMPDIR:-/tmp}/maestro-repo2-XXXXXX")/proj"
mkdir -p "$SECOND"
"$SCRIPTS/registry-add.sh" "$SECOND" --name custom-name >/dev/null
[ "$(reg_count)" = "2" ] && _result ok "distinct repo appends a second entry" || _result fail "distinct repo appends a second entry" "got $(reg_count)"
assert_contains "$(cat "$HQ/registry.json")" '"name": "custom-name"' "explicit --name is stored"

# --- ~-prefix storage when the path is under \$HOME -----------------------------
UNDER_HOME="$(mktemp -d "$HOME/maestro-test-home-XXXXXX")"
trap 'rm -rf "$UNDER_HOME"' EXIT
"$SCRIPTS/registry-add.sh" "$UNDER_HOME" >/dev/null
paths="$(reg_paths)"
assert_contains "$paths" "~/maestro-test-home" "path under \$HOME is stored ~-prefixed"
assert_not_contains "$paths" "$HOME/maestro-test-home" "no absolute \$HOME path leaks into the registry"

# --- no HQ configured -> exit 1 + the standard error ----------------------------
set +e
errout="$(MAESTRO_HQ="/nonexistent-hq-$$" "$SCRIPTS/registry-add.sh" 2>&1)"; nohq=$?
set -e
assert_exit 1 "$nohq" "missing HQ exits 1"
assert_contains "$errout" "no HQ found" "missing HQ prints the standard error"

# --- malformed registry.json is never silently overwritten ----------------------
printf 'not json at all' > "$HQ/registry.json"
set +e
errout="$("$SCRIPTS/registry-add.sh" "$SECOND" 2>&1)"; bad=$?
set -e
[ "$bad" -ne 0 ] && _result ok "malformed registry refuses to overwrite" || _result fail "malformed registry refuses to overwrite" "exit 0 clobbered the file"
assert_contains "$(cat "$HQ/registry.json")" "not json at all" "malformed registry left intact"

rm -rf "$HQ"
summary "registry-add"
