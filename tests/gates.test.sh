#!/usr/bin/env bash
# Enforcement gates: commit-gate (tier DoD + verify re-run) and stop-dod.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mkrepo
printf 'exit 0\n' > check.sh
"$SCRIPTS/task-init.sh" gate-task standard "gate test" "bash check.sh" >/dev/null

commit_payload='{"tool_input":{"command":"git commit -m x"}}'

# --- commit-gate ---------------------------------------------------------------
run_hook "$HOOKS/commit-gate.sh" '{"tool_input":{"command":"ls -la"}}'
assert_exit 0 "$HOOK_EXIT" "commit-gate ignores non-commit bash"

run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 2 "$HOOK_EXIT" "commit-gate blocks standard tier without tester PASS"
assert_contains "$HOOK_ERR" "tester PASS" "block message names the missing DoD item"

# Cross-repo: while this repo has an UNMET DoD, a commit that TARGETS a different,
# clean repo (no task, no verify config) must NOT be blocked by this repo's DoD. This
# is the real-world repro: a CTO session here ran `cd <other-repo> && git commit` for an
# HQ docs change and was wrongly blocked by the session task's DoD.
OTHER_REPO="$(dirname "$REPO")/other-repo"
git -C "$(dirname "$REPO")" init -q "$OTHER_REPO"
git -C "$OTHER_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
xrepo_cd="$(printf '{"cwd":"%s","tool_input":{"command":"cd %s && git commit -m hq-docs"}}' "$REPO" "$OTHER_REPO")"
run_hook "$HOOKS/commit-gate.sh" "$xrepo_cd"
assert_exit 0 "$HOOK_EXIT" "commit-gate: 'cd otherRepo && git commit' not blocked by THIS repo's DoD"
xrepo_dashC="$(printf '{"cwd":"%s","tool_input":{"command":"git -C %s commit -m hq-docs"}}' "$REPO" "$OTHER_REPO")"
run_hook "$HOOKS/commit-gate.sh" "$xrepo_dashC"
assert_exit 0 "$HOOK_EXIT" "commit-gate: 'git -C otherRepo commit' not blocked by THIS repo's DoD"
# And a plain commit in THIS repo is still blocked (resolution didn't break same-repo gating).
run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 2 "$HOOK_EXIT" "commit-gate: same-repo commit still gated by THIS repo's unmet DoD"

# Parser robustness in effective-dir resolution (the target must resolve, not fall back to
# session gating). UNSPACED operators (`cd repoB&&git commit`) must still split into segments.
xrepo_unspaced="$(printf '{"cwd":"%s","tool_input":{"command":"cd %s&&git commit -m hq"}}' "$REPO" "$OTHER_REPO")"
run_hook "$HOOKS/commit-gate.sh" "$xrepo_unspaced"
assert_exit 0 "$HOOK_EXIT" "commit-gate: unspaced 'cd otherRepo&&git commit' resolves target, not session"
# Multiple -C: real git applies them in order, so the LAST -C wins. `git -C other -C this
# commit` runs in THIS repo → blocked by THIS repo's unmet DoD.
xrepo_lastC="$(printf '{"cwd":"%s","tool_input":{"command":"git -C %s -C %s commit -m x"}}' "$REPO" "$OTHER_REPO" "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$xrepo_lastC"
assert_exit 2 "$HOOK_EXIT" "commit-gate: last -C wins ('git -C other -C this commit' → gated by this repo)"
# And `git -C this -C other commit` runs in OTHER (clean) → not blocked by this repo's DoD.
xrepo_lastC_other="$(printf '{"cwd":"%s","tool_input":{"command":"git -C %s -C %s commit -m x"}}' "$REPO" "$REPO" "$OTHER_REPO")"
run_hook "$HOOKS/commit-gate.sh" "$xrepo_lastC_other"
assert_exit 0 "$HOOK_EXIT" "commit-gate: last -C wins ('git -C this -C other commit' → target is other, not gated)"
# A `git -C this commit` form (global option between verb and subcommand) is still detected
# as a commit — the broadened commit-detector must not miss it and skip the gate.
xrepo_dashC_this="$(printf '{"cwd":"%s","tool_input":{"command":"git -C %s commit -m x"}}' "$REPO" "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$xrepo_dashC_this"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'git -C this commit' detected as commit and gated by this repo"
# Non-commit git commands containing the word 'commit' must NOT be gated.
git_log_cmd="$(printf '{"cwd":"%s","tool_input":{"command":"git -C %s log --grep commit"}}' "$REPO" "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$git_log_cmd"
assert_exit 0 "$HOOK_EXIT" "commit-gate: 'git log --grep commit' is not a commit → not gated"

# --- TILDE-EXPANSION boundary in target resolution -----------------------------
# A real cross-repo HQ commit is written `cd ~/.../repo && git commit`. The resolver runs cd/-C
# path tokens through os.path.expanduser, so `~/...` routes to its real repo under $HOME instead
# of mis-joining the literal `~/...` onto the session cwd (which lands on a nonexistent path and
# misroutes to the session repo — an over-block that wrongly blocked a legitimate HQ commit).
# The fixture repo lives under $HOME (the only place a tilde path can resolve to) and is CLEAN
# (no task, no verify), so a commit targeting it via tilde passes (exit 0). $HOME/$VAR forms are
# deliberately NOT expanded → unresolvable → session fallback (over-block, the safe direction).
HOME_REPO_REL=".maestro-tilde-test-$$"
HOME_REPO="$HOME/$HOME_REPO_REL"
rm -rf "$HOME_REPO"
git -C "$HOME" init -q "$HOME_REPO" 2>/dev/null
git -C "$HOME_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
trap 'rm -rf "$HOME_REPO"' EXIT

# `cd ~/<rel> && git commit` — tilde expands → routes to the CLEAN home repo → exit 0.
tilde_cd="$(printf '{"cwd":"%s","tool_input":{"command":"cd ~/%s && git commit -m hq"}}' "$REPO" "$HOME_REPO_REL")"
run_hook "$HOOKS/commit-gate.sh" "$tilde_cd"
assert_exit 0 "$HOOK_EXIT" "commit-gate: 'cd ~/<repo> && git commit' tilde-expands and routes to that repo (clean → allow)"
# `git -C ~/<rel> commit` — tilde in -C expands → routes to the CLEAN home repo → exit 0.
tilde_dashC="$(printf '{"cwd":"%s","tool_input":{"command":"git -C ~/%s commit -m hq"}}' "$REPO" "$HOME_REPO_REL")"
run_hook "$HOOKS/commit-gate.sh" "$tilde_dashC"
assert_exit 0 "$HOOK_EXIT" "commit-gate: 'git -C ~/<repo> commit' tilde-expands and routes to that repo (clean → allow)"
# `$HOME`-var form stays UNexpanded by design → resolves to no repo → session fallback (this
# repo's DoD is unmet) → BLOCK. Proves the boundary: only ~ expands, not shell variables.
home_var_cd="$(printf '{"cwd":"%s","tool_input":{"command":"cd $HOME/%s && git commit -m hq"}}' "$REPO" "$HOME_REPO_REL")"
run_hook "$HOOKS/commit-gate.sh" "$home_var_cd"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'cd \$HOME/<repo> && git commit' (\$HOME unexpanded) falls back to session → gated"

# --- DETECTION HARDENING: prefixed / wrapped commit forms (incident class) -----
# An in-the-wild evasion slipped a stray commit on main because the tokenizer demanded the
# git verb be the segment's FIRST token, going BLIND to env-assignment and wrapper prefixes the
# old substring matcher caught. Each form below targets THIS repo (unmet DoD) and MUST block.
# The git segment has no cd/-C, so the target resolves to the SESSION repo (the incident repo).
env_prefix="$(printf '{"cwd":"%s","tool_input":{"command":"GIT_AUTHOR_NAME=x git commit -m m"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$env_prefix"
assert_exit 2 "$HOOK_EXIT" "commit-gate: env-assignment prefix 'GIT_X=y git commit' still gated (incident class)"
env_wrap="$(printf '{"cwd":"%s","tool_input":{"command":"env GIT_X=y git commit -m m"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$env_wrap"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'env GIT_X=y git commit' wrapper still gated"
cmd_wrap="$(printf '{"cwd":"%s","tool_input":{"command":"command git commit -m m"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$cmd_wrap"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'command git commit' wrapper still gated"
timeout_wrap="$(printf '{"cwd":"%s","tool_input":{"command":"timeout 30 git commit -m m"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$timeout_wrap"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'timeout 30 git commit' wrapper still gated"
nice_wrap="$(printf '{"cwd":"%s","tool_input":{"command":"nice git commit -m m"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$nice_wrap"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'nice git commit' wrapper still gated"
stacked_wrap="$(printf '{"cwd":"%s","tool_input":{"command":"env A=1 command git commit -m m"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$stacked_wrap"
assert_exit 2 "$HOOK_EXIT" "commit-gate: stacked prefixes 'env A=1 command git commit' still gated"

# Path-qualified / keyword-prefixed git that the literal seg[0]=="git" check went blind to (a
# proven-live miss: `/usr/bin/git commit` created a real commit while the gate returned 0). The
# git verb is matched on BASENAME, and sudo/exec join the wrapper list, time is skipped.
abspath_git="$(printf '{"cwd":"%s","tool_input":{"command":"/usr/bin/git commit -m m"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$abspath_git"
assert_exit 2 "$HOOK_EXIT" "commit-gate: path-qualified '/usr/bin/git commit' gated (basename match)"
sudo_wrap="$(printf '{"cwd":"%s","tool_input":{"command":"sudo git commit -m m"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$sudo_wrap"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'sudo git commit' wrapper gated"
exec_wrap="$(printf '{"cwd":"%s","tool_input":{"command":"exec git commit -m m"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$exec_wrap"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'exec git commit' wrapper gated"
time_wrap="$(printf '{"cwd":"%s","tool_input":{"command":"time git commit -m m"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$time_wrap"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'time git commit' keyword gated"
# sudo with option args (`sudo -u alice`) — strip its options like timeout's lead arg.
sudo_opt_wrap="$(printf '{"cwd":"%s","tool_input":{"command":"sudo -u alice git commit -m m"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$sudo_opt_wrap"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'sudo -u alice git commit' (sudo opts stripped) gated"

# --- STRUCTURAL ENGAGE/ROUTE/FALLBACK: safety must NOT depend on any wrapper enumeration --------
# Prior rounds gated by an enumerated ENGAGE condition: the gate only fired when the parser
# recognized a commit segment after stripping a fixed list of prefixes — so every prefix the list
# missed (`time -p`, `sudo time`, a post-wrapper `time`) made the gate NOT engage (under-block).
# The structural rule flips this: the raw `git commit` substring (or a basename-git + later
# `commit` token) is the dumb TRIGGER; when the parser cannot then cleanly identify a commit
# segment, the resolver over-blocks to the SESSION repo. These forms target THIS repo (unmet DoD).
#
# Thomas round-5 forms — optioned/post-wrapper `time` that the old one-shot bare-`time` skip missed.
time_p="$(printf '{"cwd":"%s","tool_input":{"command":"time -p git commit -m x"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$time_p"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'time -p git commit' (time option consumed) gated"
sudo_time="$(printf '{"cwd":"%s","tool_input":{"command":"sudo time git commit -m x"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$sudo_time"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'sudo time git commit' (wrapper then time) gated"
timeout_time="$(printf '{"cwd":"%s","tool_input":{"command":"timeout 30 time git commit -m x"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$timeout_time"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'timeout 30 time git commit' (stacked wrapper+time) gated"
env_sudo_time="$(printf '{"cwd":"%s","tool_input":{"command":"env A=1 sudo -u bob time git commit -m x"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$env_sudo_time"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'env A=1 sudo -u bob time git commit' (full stack) gated"
#
# THE TEST THAT PROVES ENUMERATION NO LONGER OWNS SAFETY: a wrapper invented for this test,
# present in NO list in the hook. The dumb trigger engages on the basename-git + `commit` token;
# the parser cannot strip `frobnicate`, finds no clean commit segment → resolver over-blocks to
# session. If this passes, tomorrow's unknown wrapper is also covered by construction.
frob="$(printf '{"cwd":"%s","tool_input":{"command":"frobnicate git commit -m x"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$frob"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'frobnicate git commit' (never-seen wrapper) gated via fallback"
#
# CASE (a) routes cleanly even when a -m message ARG contains the `git commit` substring: this is a
# real cross-repo commit (`cd otherRepo && git commit -m "...git commit..."`). The parser cleanly
# identifies the commit segment and its `cd` target → gate by OTHER (clean) repo, NOT the session
# fallback. Proves the substring in an arg does not collapse a cleanly-parsed commit into a fallback.
xrepo_msg="$(printf '{"cwd":"%s","tool_input":{"command":"cd %s && git commit -m \"fix: git commit msg\""}}' "$REPO" "$OTHER_REPO")"
run_hook "$HOOKS/commit-gate.sh" "$xrepo_msg"
assert_exit 0 "$HOOK_EXIT" "commit-gate: cross-repo commit with 'git commit' in the -m message routes to target (case a, not fallback)"

# PRECISION boundary, case (b) — a CLEAN non-commit classification with NO raw substring passes.
# `git -C <repo> commit-tree` puts `-C <repo>` between `git` and `commit-tree`, so the raw string
# does NOT contain the `git commit` substring; the parser cleanly classifies the git segment as a
# non-commit verb (`commit-tree`) → exit 0. (The bare `git commit-tree` form WOULD contain the
# substring and over-block; the `-C` form is the clean-classification case the parser earns.)
commit_tree="$(printf '{"cwd":"%s","tool_input":{"command":"git -C %s commit-tree HEAD^{tree}"}}' "$REPO" "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$commit_tree"
assert_exit 0 "$HOOK_EXIT" "commit-gate: 'git -C repo commit-tree' (clean non-commit verb, no substring) → not gated"

# --- TARGET RESOLUTION: failure-tolerant chains fall back to the session repo ---
# `cd <nonexistent>; git commit` — at runtime the cd fails but `;` tolerates it, so the commit
# runs in the ORIGINAL (session) cwd. The parser must NOT trust the absent dir as the target;
# it falls back to the session repo, whose DoD is unmet → BLOCK.
NOPE="$(dirname "$REPO")/does-not-exist-xyz"
semic_chain="$(printf '{"cwd":"%s","tool_input":{"command":"cd %s; git commit -m x"}}' "$REPO" "$NOPE")"
run_hook "$HOOKS/commit-gate.sh" "$semic_chain"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'cd <nonexistent>; git commit' falls back to session → gated"
# Same for `||`: `cd <nonexistent> || git commit` runs the commit in the original cwd.
or_chain="$(printf '{"cwd":"%s","tool_input":{"command":"cd %s || git commit -m x"}}' "$REPO" "$NOPE")"
run_hook "$HOOKS/commit-gate.sh" "$or_chain"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'cd <nonexistent> || git commit' falls back to session → gated"

# BASELINE-PARITY OVER-BLOCK (deliberately flipped from the old FP-passing behavior): the raw
# string `echo git commit` contains the `git commit` substring, so the dumb ENGAGE trigger fires.
# The clean parser finds NO commit segment (the leading verb is `echo`), so detection falls to the
# trigger-but-ambiguous branch → engage; the resolver then over-blocks to the SESSION repo (unmet
# DoD) → BLOCK. The OLD baseline substring matcher also blocked this; de-blocking it was the
# nicety that opened the enumeration hole class (every missed wrapper became an under-block), so
# we restore baseline parity here on purpose.
echo_cmd="$(printf '{"cwd":"%s","tool_input":{"command":"echo git commit"}}' "$REPO")"
run_hook "$HOOKS/commit-gate.sh" "$echo_cmd"
assert_exit 2 "$HOOK_EXIT" "commit-gate: 'echo git commit' contains the substring → engages, falls back to session gate (baseline parity)"

"$SCRIPTS/task-record.sh" tester_verdict verdict=PASS >/dev/null
run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 0 "$HOOK_EXIT" "commit-gate allows when tier DoD met and verify green"

# Layer 2 (verify re-run) uses the TARGET repo's verify, not the session's. The session
# is fully green here, but the OTHER repo gets its OWN failing verify config — a commit
# targeting it must block on THAT verify, proving layer 2 moved to the target too.
mkdir -p "$OTHER_REPO/.claude"
printf 'bash other-check.sh\n' > "$OTHER_REPO/.claude/maestro-verify"
printf 'exit 1\n' > "$OTHER_REPO/other-check.sh"
run_hook "$HOOKS/commit-gate.sh" "$xrepo_cd"
assert_exit 2 "$HOOK_EXIT" "commit-gate layer 2: target repo's FAILING verify blocks the cross-repo commit"
printf 'exit 0\n' > "$OTHER_REPO/other-check.sh"
run_hook "$HOOKS/commit-gate.sh" "$xrepo_cd"
assert_exit 0 "$HOOK_EXIT" "commit-gate layer 2: target repo's GREEN verify lets the cross-repo commit through"

printf 'exit 1\n' > check.sh
run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 2 "$HOOK_EXIT" "commit-gate re-runs verify: red verify blocks even with PASS recorded"
printf 'exit 0\n' > check.sh

"$SCRIPTS/task-record.sh" round_started >/dev/null
run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 2 "$HOOK_EXIT" "stale verdict from previous round does not satisfy commit-gate"

# full tier: needs gate1 + reviewer too
"$SCRIPTS/task-record.sh" tier_escalated tier=full reason=x >/dev/null
"$SCRIPTS/task-record.sh" tester_verdict verdict=PASS >/dev/null
run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 2 "$HOOK_EXIT" "full tier blocks without Gate 1 + reviewer"
"$SCRIPTS/task-record.sh" gate1_approved >/dev/null
"$SCRIPTS/task-record.sh" reviewer_verdict verdict=APPROVE >/dev/null
run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 0 "$HOOK_EXIT" "full tier allows with tester PASS + Gate 1 + reviewer APPROVE"
"$SCRIPTS/task-record.sh" task_done >/dev/null

# --- PHASED MODE commit-gate (roadmap #9): PHASE commit vs SHIP commit ----------
# REGRESSION GUARD (case c): every commit-gate assertion ABOVE ran on a NON-phased task — they ARE
# the proof that an absent `phases` map behaves byte-for-byte as today. If the phased branch leaked
# into the legacy path, those assertions would have broken. The two cases below add phased behavior.
"$SCRIPTS/task-init.sh" phased-gate full "phased commit gate" "bash check.sh" >/dev/null
cat > phase-spec.json <<'JSON'
{ "phases": [ { "id": "ph-a", "risk": "high" }, { "id": "ph-b", "deps": ["ph-a"], "risk": "low" } ] }
JSON
"$SCRIPTS/task-plan.sh" phase-spec.json >/dev/null
printf 'exit 0\n' > check.sh   # the ONE repo verify (founder decision: all phases share it)

# Case (a): a phase is still pending and the verify is GREEN → PHASE commit → ALLOWED. No tester
# PASS, no reviewer, no Gate-1 recorded — phase commits skip the plan-level gates by design.
run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 0 "$HOOK_EXIT" "commit-gate PHASE commit: pending phase + green verify → allowed (skips plan-DoD)"

# A phase commit STILL re-runs verify (Layer 2 = the phase-DoD). A red verify blocks even mid-phase.
printf 'exit 1\n' > check.sh
run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 2 "$HOOK_EXIT" "commit-gate PHASE commit: pending phase + RED verify → blocked (verify is the phase-DoD)"
printf 'exit 0\n' > check.sh

# Case (b): mark EVERY phase done → zero pending → the next commit is the SHIP commit → full
# plan-DoD applies. With no tester PASS recorded, the ship commit is BLOCKED (back to ship-DoD).
"$SCRIPTS/task-record.sh" phase_done phase=ph-a >/dev/null
"$SCRIPTS/task-record.sh" phase_done phase=ph-b >/dev/null
run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 2 "$HOOK_EXIT" "commit-gate SHIP commit: all phases done + no tester PASS → blocked (full plan-DoD)"
assert_contains "$HOOK_ERR" "tester PASS" "ship commit block names the missing plan-level DoD item"

# Satisfy the full plan-DoD → the ship commit goes through.
"$SCRIPTS/task-record.sh" gate1_approved >/dev/null
"$SCRIPTS/task-record.sh" tester_verdict verdict=PASS >/dev/null
"$SCRIPTS/task-record.sh" reviewer_verdict verdict=APPROVE >/dev/null
run_hook "$HOOKS/commit-gate.sh" "$commit_payload"
assert_exit 0 "$HOOK_EXIT" "commit-gate SHIP commit: all phases done + full plan-DoD met → allowed"
"$SCRIPTS/task-record.sh" task_done >/dev/null

# --- stop-dod -------------------------------------------------------------------
sleep 1 && echo "code" > app.py
run_hook "$HOOKS/stop-dod.sh" '{"stop_hook_active":false}'
assert_exit 2 "$HOOK_EXIT" "stop-dod blocks unverified code change"

run_hook "$HOOKS/stop-dod.sh" '{"stop_hook_active":true}'
assert_exit 0 "$HOOK_EXIT" "stop-dod loop guard: second stop passes"

"$SCRIPTS/task-verify.sh" >/dev/null
run_hook "$HOOKS/stop-dod.sh" '{"stop_hook_active":false}'
assert_exit 0 "$HOOK_EXIT" "stop-dod passes after green verify"

sleep 1 && echo "notes" > README.md
run_hook "$HOOKS/stop-dod.sh" '{"stop_hook_active":false}'
assert_exit 0 "$HOOK_EXIT" "prose-only change never trips stop-dod"

sleep 1 && echo "more code" >> app.py
echo 1 > .claude/maestro-direct
run_hook "$HOOKS/stop-dod.sh" '{"stop_hook_active":false}'
assert_exit 0 "$HOOK_EXIT" "direct-edit mode disables stop-dod"
rm .claude/maestro-direct

summary "gates"
