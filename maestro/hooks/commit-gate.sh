#!/usr/bin/env bash
# PreToolUse on Bash — gate `git commit` on the tier-aware Definition of Done.
#
# Two layers, cheapest first:
#   1. Ledger DoD — if a maestro task is active, its tier decides which recorded
#      judgments must exist (standard+: tester PASS; full: + reviewer APPROVE and
#      Gate 1). Records are written by the task-*.sh scripts, so the schema is stable.
#   2. Verify re-run — the verify command is executed HERE, fresh. Exit code is
#      ground truth; no recorded claim can substitute for it.
# No active task → layer 1 is skipped (plain repos keep the old verify-only behavior).
set -eu
_src="${BASH_SOURCE[0]}"; while [ -L "$_src" ]; do _src="$(readlink "$_src")"; done
. "$(cd "$(dirname "$_src")" && pwd)/lib-log.sh" 2>/dev/null && mlog_init commit-gate PreToolUse || true


input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

# Only gate actual commits; let every other Bash command through. Engagement is a THREE-STATE
# decision built so SAFETY NEVER DEPENDS ON ANY ENUMERATION — past evasions all came from the
# gate failing to ENGAGE because the parser did not recognize one more wrapper/prefix, and an
# enumeration can always be evaded by one more token:
#   1. ENGAGE (over-inclusive, dumb, unbeatable): the gate engages when the raw command string
#      contains the substring `git commit` (the original baseline matcher) OR any shlex token
#      whose basename is `git` is followed by a `commit` token in the same segment. No stripping,
#      no understanding — just a trigger.
#   2. ROUTE (precise where possible): once engaged, the clean parser (prefix/wrapper/time
#      stripping, basename match, git global options) classifies each git segment. A segment that
#      cleanly parses as `git commit` → gate (the resolver below finds WHICH repo it targets).
#   3. FALLBACK (the safety net that makes enumeration irrelevant): engaged but NO segment cleanly
#      parses as a commit → still gate, and the resolver returns the SESSION repo (over-block).
#      This catches every weird form — `time -p git commit`, `sudo time git commit`, and tomorrow's
#      wrapper nobody enumerated — because the trigger, not the parser, decided to engage.
# Three outcomes are printed: 1 = engage (a clean commit segment OR an ambiguous trigger that the
# resolver will route to the session repo); 0 = NOT a commit (every git segment cleanly classifies
# as a non-commit subcommand AND no raw `git commit` substring — e.g. `git log --grep commit`).
#
# Accepted over-block trade-offs (the baseline ALSO blocked these; restoring baseline parity closes
# the hole class that de-blocking them created): `echo git commit` and a commit-message arg whose
# raw text contains `git commit` engage and fall back to SESSION gating. `git log --grep commit`
# still passes (no `git commit` substring; its git segment cleanly classifies as `log`, a non-commit
# subcommand). The wrapper list below is ROUTING PRECISION only — it sharpens case 2 (target
# resolution); it is no longer the safety boundary. Quoted strings: shlex strips quotes; a missed
# wrapper costs an over-block, never a missed commit. Out of scope (a baseline limitation, not closed
# here): commits hidden in opaque carriers — `bash file.sh`, `python -c "..."`, `eval "$x"`.
# Falls back to the cheap substring test if python is unavailable (fail toward gating).
_is_commit=1
if command -v python3 >/dev/null 2>&1; then
  _is_commit="$(MAESTRO_CMD="$cmd" python3 - <<'PY'
import os, re, shlex
cmd = os.environ.get("MAESTRO_CMD", "")

# --- ENGAGE: the dumb, unbeatable trigger (no stripping, no parser). ----------------
# Trigger A: the raw baseline substring. Trigger B: a token whose basename is `git`
# followed by a `commit` token in the SAME segment (catches `/usr/bin/git commit`,
# `git -C dir commit`, and any wrapper prefix the parser below might not enumerate).
def segments(c):
    spaced = re.sub(r"(&&|\|\||;|\||&)", r" \1 ", c)
    toks = shlex.split(spaced)
    segs, cur = [], []
    for t in toks:
        if t in (";", "&&", "||", "|", "&"):
            segs.append(cur); cur = []
        else:
            cur.append(t)
    segs.append(cur)
    return segs

raw_substring = "git commit" in cmd
try:
    segs = segments(cmd)
except Exception:
    # Unparseable command (unbalanced quotes) → only the raw substring can be trusted; over-block.
    print(1 if raw_substring else 0); raise SystemExit

def token_pair_trigger(seg):
    for i, t in enumerate(seg):
        if os.path.basename(t) == "git":
            if "commit" in seg[i + 1:]:
                return True
    return False

triggered = raw_substring or any(token_pair_trigger(s) for s in segs)
if not triggered:
    print(0); raise SystemExit

# --- ROUTE: the clean parser classifies each git segment (precision, not safety). ----
# Wrappers that precede the real command without changing what it is. `timeout`/`xargs`/`sudo`
# take a numeric/option lead arg (e.g. `sudo -u alice`); we skip VAR=val assignments and any
# leading option/number so the git verb surfaces. `time` joins the wrapper loop and consumes its
# `-p`/`--portability` option (`time -p git commit`); after the loop bare `time` is also skipped.
WRAPPERS = ("env", "command", "nice", "nohup", "timeout", "xargs", "stdbuf", "ionice",
            "sudo", "exec", "time")
# sudo value-taking short options consume the FOLLOWING token (`sudo -u alice git commit`):
# strip that value too so the git verb surfaces, mirroring the `-C <dir>` handling in git itself.
SUDO_VALUE_OPTS = ("-u", "-g", "-h", "-p", "-C", "-r", "-t", "-U", "-R", "-T")


def strip_wrappers(seg, i):
    while i < len(seg) and seg[i] in WRAPPERS:
        is_sudo = seg[i] == "sudo"
        is_time = seg[i] == "time"
        i += 1
        while i < len(seg) and (seg[i].startswith("-") or re.match(r"^\d+(\.\d+)?[smhd]?$", seg[i])
                                or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", seg[i])):
            if is_sudo and seg[i] in SUDO_VALUE_OPTS and i + 1 < len(seg):
                i += 1                  # also consume the value token after `-u`, `-g`, etc.
            i += 1
            if is_time:
                break                   # `time` takes at most its own option (`-p`), then the verb
    return i

def git_segment_class(seg):
    """Classify a segment: 'commit' (a clean git commit), 'other' (a clean non-commit git verb),
    or None (not cleanly a git invocation at all — caller treats as ambiguous → fall back)."""
    i = 0
    # Strip leading VAR=val assignments (the env-prefix evasion: `GIT_AUTHOR_NAME=x git ...`).
    while i < len(seg) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", seg[i]):
        i += 1
    # Strip leading wrappers and their option/numeric lead args (`env A=1`, `timeout 30`,
    # `sudo -u alice`, `time -p`).
    i = strip_wrappers(seg, i)
    # Match the git verb on BASENAME, not the literal "git": path-qualified or `./`-relative
    # invocations (`/usr/bin/git`, `/opt/homebrew/bin/git`, `./git`) all run git and the
    # substring baseline caught them, so detection must too.
    if i >= len(seg) or os.path.basename(seg[i]) != "git":
        return None
    i += 1
    while i < len(seg):                 # skip git global options before the subcommand
        if seg[i] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace"):
            i += 2; continue
        if seg[i].startswith("-"):
            i += 1; continue
        break
    if i >= len(seg):
        return None                     # `git` with no subcommand → ambiguous, not a clean verb
    return "commit" if seg[i] == "commit" else "other"

classes = [git_segment_class(s) for s in segs]
if "commit" in classes:
    print(1); raise SystemExit        # case (a): a cleanly-parsed commit segment → gate by target
# Case (b): every git segment cleanly classifies as a NON-commit verb AND the raw string has no
# `git commit` substring → genuinely not a commit (e.g. `git log --grep commit`) → exit 0.
git_segs = [c for c in classes if c is not None]
if git_segs and all(c == "other" for c in git_segs) and not raw_substring:
    print(0); raise SystemExit
# Case (c): triggered but NOT cleanly a commit (ambiguous wrapper, opaque form, or raw substring
# present without a classified source) → ENGAGE; the resolver falls back to SESSION gating.
print(1)
PY
)"
  [ -z "$_is_commit" ] && _is_commit=0
else
  case "$cmd" in *"git commit"*) _is_commit=1 ;; *) _is_commit=0 ;; esac
fi
[ "$_is_commit" = "1" ] || exit 0

# Gate the commit by the repo it actually TARGETS, not the session dir. A `cd repoB &&
# git commit` (or `git -C repoB commit`) must be judged by repoB's ledger DoD and repoB's
# verify command — a commit in a repo with no active task and no verify config passes
# untouched, even while another repo has an unmet full-tier DoD. Resolution order:
#   1. the commit segment's effective dir (its `cd`/`-C` context),
#   2. the session cwd the hook receives in its payload,
#   3. CLAUDE_PROJECT_DIR, then PWD (last resort).
# Then anchor to that dir's git work tree. Fail-open to the session dir on any miss.
#
# TILDE-EXPANSION BOUNDARY: `cd ~/repo` and `git -C ~/repo` tokens are run through
# os.path.expanduser at parse time (`~`/`~user` → home dir) so a cross-repo HQ commit under
# the home dir routes to its real repo instead of mis-joining `~/...` to the session cwd
# (which lands on a nonexistent path → wrong session-repo gate). `$HOME`/`$VAR` forms are
# deliberately left UNexpanded — the shell expands them at runtime but the parser sees an opaque
# literal, which resolves to no repo → session fallback (over-block, the safe direction).
_session_cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
_session_proj="${_session_cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}"
set +e
proj="$(MAESTRO_CMD="$cmd" MAESTRO_SESSION="$_session_proj" python3 - 2>/dev/null <<'PY'
import os, re, shlex, subprocess

cmd = os.environ.get("MAESTRO_CMD", "")
session = os.environ.get("MAESTRO_SESSION") or os.getcwd()


def repo_root(d):
    d = os.path.realpath(d)
    while d and d != "/" and not os.path.isdir(d):
        d = os.path.dirname(d)
    try:
        return os.path.realpath(subprocess.check_output(
            ["git", "-C", d, "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL).decode().strip())
    except Exception:
        return ""


WRAPPERS = ("env", "command", "nice", "nohup", "timeout", "xargs", "stdbuf", "ionice",
            "sudo", "exec", "time")
SUDO_VALUE_OPTS = ("-u", "-g", "-h", "-p", "-C", "-r", "-t", "-U", "-R", "-T")


def strip_prefixes(seg):
    """Drop leading VAR=val assignments and wrappers so the real verb (git/cd) surfaces.

    Mirrors the detection layer: `GIT_X=y git -C r commit`, `env A=1 git commit`,
    `timeout 30 git commit`, `sudo -u alice git commit`, `exec git commit`, `time -p git commit`
    must resolve the same target as the bare form. This is ROUTING PRECISION — when it fails,
    the caller over-blocks to the session repo, so an unhandled prefix is a safe over-block.
    """
    i = 0
    while i < len(seg) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", seg[i]):
        i += 1
    while i < len(seg) and seg[i] in WRAPPERS:
        is_sudo = seg[i] == "sudo"
        is_time = seg[i] == "time"
        i += 1
        while i < len(seg) and (seg[i].startswith("-") or re.match(r"^\d+(\.\d+)?[smhd]?$", seg[i])
                                or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", seg[i])):
            if is_sudo and seg[i] in SUDO_VALUE_OPTS and i + 1 < len(seg):
                i += 1                  # also consume the value token after `-u`, `-g`, etc.
            i += 1
            if is_time:
                break                   # `time` takes at most its own option (`-p`), then the verb
    return seg[i:]


def effective_dir():
    """Effective dir of the FIRST `git commit` segment: its `cd` + `git -C` context.

    Only the cleanly-parsed target is trusted; otherwise we return the session dir (over-block).
    A `cd X` that FAILS at runtime must NOT be trusted to target X's repo. For `;`/`||`
    failure-tolerant chains the runtime cwd can diverge from the parse-time cwd, so if a `cd`
    reached via `;`/`||` names a path that does not exist at parse time, the commit will run in
    the ORIGINAL cwd at runtime → we fall back to the session repo. `&&` chains keep prior
    behavior (a failed `cd` stops the chain, so the commit never runs).
    """
    # Pre-split UNSPACED shell operators (`cd repoB&&git commit`, `cd repoB;git commit`) so
    # the segment boundary survives tokenization — otherwise shlex yields a single mangled
    # token (`repoB&&git`) and the target dir is lost, falling back to session gating.
    spaced = re.sub(r"(&&|\|\||;|\||&)", r" \1 ", cmd)
    try:
        segs, ops, cur = [], [], []
        prev_op = ";"          # the operator that PRECEDES the next segment (first is unguarded)
        for tok in shlex.split(spaced):
            if tok in (";", "&&", "||", "|", "&"):
                segs.append(cur); ops.append(prev_op); cur = []; prev_op = tok
            else:
                cur.append(tok)
        segs.append(cur); ops.append(prev_op)
    except Exception:
        return session
    cwd = session
    for seg, op in zip(segs, ops):
        seg = strip_prefixes(seg)
        if not seg:
            continue
        if seg[0] == "cd" and len(seg) > 1:                    # `cd <dir>` sets cwd
            d = os.path.expanduser(seg[1])     # `cd ~/repo` → $HOME/repo; `$HOME/x` stays literal
            target = d if os.path.isabs(d) else os.path.join(cwd, d)
            # `;`/`||`-reached cd whose path is absent at parse time runs in the ORIGINAL cwd at
            # runtime (the failed cd is tolerated). Do not trust it; over-block to the session.
            if op in (";", "||") and not os.path.isdir(target):
                return session
            cwd = target
            continue
        if os.path.basename(seg[0]) == "git" and "commit" in seg:
            # Honor the LAST `-C <dir>` — real git applies each in order, so the final one
            # wins (`git -C a -C b commit` runs in b). Relative -C dirs stack on cwd.
            i, dch = 0, cwd
            while i < len(seg):
                if seg[i] == "-C" and i + 1 < len(seg):
                    d = os.path.expanduser(seg[i + 1])   # `git -C ~/repo commit` → $HOME/repo
                    dch = d if os.path.isabs(d) else os.path.join(dch, d)
                    i += 2
                    continue
                i += 1
            return dch
    return cwd


root = repo_root(effective_dir()) or repo_root(session) or os.path.realpath(session)
print(root)
PY
)"
set -e
[ -z "$proj" ] && proj="$_session_proj"

# --- Layer 1: ledger DoD for the active task (if any) ---------------------------
active=""
[ -f "$proj/.claude/maestro/active" ] && active="$(cat "$proj/.claude/maestro/active")"
if [ -n "$active" ] && [ -f "$proj/.claude/maestro/$active/state.json" ]; then
  set +e
  python3 - "$proj/.claude/maestro/$active/state.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        s = json.load(f)
except Exception:
    sys.exit(0)  # unreadable ledger fails open; the verify re-run below still gates

tier = s.get("tier", "full")
missing = []
if tier in ("standard", "full") and s.get("lastTesterVerdict") != "PASS":
    missing.append(f"tester PASS (have: {s.get('lastTesterVerdict')})")
if tier == "full":
    if not s.get("gate1Approved"):
        missing.append("Gate 1 plan approval")
    if s.get("lastReviewerVerdict") != "APPROVE":
        missing.append(f"reviewer APPROVE (have: {s.get('lastReviewerVerdict')})")
if missing:
    sys.stderr.write(
        f"BLOCKED: tier '{tier}' DoD not met for task '{s.get('slug')}': "
        + "; ".join(missing) + "\n"
        "Run the missing stage and record it (task-record.sh), or escalate honestly.\n")
    sys.exit(2)
sys.exit(0)
PY
  _dod_exit=$?
  set -e
  [ "$_dod_exit" -ne 0 ] && exit "$_dod_exit"
fi

# --- Layer 2: re-run the verify command (ground truth) ---------------------------
VERIFY="${MAESTRO_VERIFY:-}"
if [ -z "$VERIFY" ] && [ -f "$proj/.claude/maestro-verify" ]; then
  VERIFY="$(cat "$proj/.claude/maestro-verify")"
fi
[ -z "$VERIFY" ] && exit 0   # nothing to enforce

log="$(mktemp)"
if ! ( cd "$proj" && eval "$VERIFY" ) >"$log" 2>&1; then
  echo "BLOCKED: verify command failed — cannot commit." >&2
  echo "  verify: $VERIFY" >&2
  tail -n 20 "$log" >&2
  rm -f "$log"
  exit 2
fi
rm -f "$log"

# Stamp the successful run so stop-dod.sh knows the tree was verified.
python3 - "$proj" "$VERIFY" <<'PY' 2>/dev/null || true
import datetime, json, os, sys
root, cmd = sys.argv[1], sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc)
os.makedirs(os.path.join(root, ".claude", "maestro"), exist_ok=True)
path = os.path.join(root, ".claude", "maestro", "last-verify.json")
tmp = f"{path}.{os.getpid()}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump({"ts": now.isoformat().replace("+00:00", "Z"),
               "epoch": int(now.timestamp()), "exit": 0, "cmd": cmd}, f, indent=2)
os.replace(tmp, path)
PY
exit 0
