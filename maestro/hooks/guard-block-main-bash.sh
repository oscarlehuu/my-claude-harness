#!/usr/bin/env python3
"""PreToolUse(Bash) guard — budget-gate main-session shell mutations.

The Edit/Write guard covers editing TOOLS, but a shell command (`echo >> f`,
`sed -i`, `tee`, `cp`, `patch`, `git apply`, `bash -c "...>>f"`,
`python3 -c "open(...,'w')"`) can mutate the working tree. This hook classifies
Bash commands, preserves benign/read-only carve-outs, and lets the MAIN session
(no agent_id) mutate only within the deterministic repo budget. Subagents pass.

Robust tokenization via shlex (respects quotes) — mirrors pi foreman guard.ts.
Not a perfect seal (a determined model can use exotic paths); the commit-gate +
human review are the ultimate "can't ship broken" backstops.
"""
import sys, json, shlex, os, re, functools, subprocess, datetime, fnmatch


HOOK = "guard-block-main-bash"

# Uniform hook observability (bash hooks source lib-log.sh; this python hook wraps
# sys.exit): one JSONL line per run to .claude/maestro/hook-log.jsonl, never blocking.
import time as _mlog_time
_MLOG_T0 = _mlog_time.time()
_mlog_real_exit = sys.exit

def _mlog_exit(code=0):
    try:
        proj = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
        if os.path.isdir(os.path.join(proj, ".claude")):
            d = os.path.join(proj, ".claude", "maestro")
            os.makedirs(d, exist_ok=True)
            f = os.path.join(d, "hook-log.jsonl")
            c = int(code or 0)
            status = "block" if c == 2 else ("ok" if c == 0 else "error")
            rec = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
                   "hook": HOOK, "event": "PreToolUse", "exit": c, "status": status,
                   "durSec": int(_mlog_time.time() - _MLOG_T0)}
            with open(f, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(rec, separators=(",", ":")) + "\n")
            with open(f, encoding="utf-8") as fh:
                lines = fh.readlines()
            if len(lines) > 1000:
                tmp = f + ".tmp"
                with open(tmp, "w", encoding="utf-8") as fh:
                    fh.writelines(lines[-500:])
                os.replace(tmp, f)
    except Exception:
        pass
    _mlog_real_exit(code)

sys.exit = _mlog_exit


def allow():
    sys.exit(0)


def short_block(message):
    sys.stderr.write(message)
    if not message.endswith("\n"):
        sys.stderr.write("\n")
    sys.exit(2)


try:
    data = json.load(sys.stdin)
except Exception:
    allow()  # unparseable hook payload → fail-open (same spirit as the edit guard)

# Subagents carry an agent_id → they are the crew, allowed to mutate.
if data.get("agent_id"):
    allow()

# Direct-edit mode is a per-TARGET-repo property, resolved per target in PHASE A below — NEVER a
# session early-exit. A session-anchored marker check here would let a session in repo A (direct
# mode) write repo B's PROTECTED files before B's gate ever runs (exemptions must never union
# outward across a repo boundary). The session repo's marker still applies exactly where the
# session repo IS the governing repo: same-repo writes (PHASE A resolves the session repo as the
# target's repo and honors its marker at step (2)) and the no-target fallback (a command with no
# identifiable target, e.g. `git reset --hard`, resolves `repo` to the session repo, whose marker
# PHASE A step (2) then honors). _proj is the session root, used only as the fallback anchor.
_proj = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()

command = ((data.get("tool_input") or {}).get("command") or "")
if not command.strip():
    allow()

REDIR = {">", ">>", ">|", "&>", "&>>"}
OPS = {";", "|", "||", "&&", "&", "(", ")", "\n"}
BENIGN_DEV = {"/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"}
TMP_PREFIXES = ("/tmp/", "/private/tmp/", "/var/folders/")
_TMPDIR = os.environ.get("TMPDIR", "").rstrip("/")

EDITORS = {"vi", "vim", "nvim", "nano", "emacs", "ed", "ex", "pico", "micro"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
LANGS = {"python", "python3", "python2", "node", "nodejs", "ruby", "perl", "php"}
# Language file-write / delete APIs (NOT a bare ">", which is a comparison in code).
WRITE_API = re.compile(
    r"open\s*\([^)]*['\"][wax]"
    r"|\.write\s*\(|writeFileSync|appendFileSync|createWriteStream"
    r"|fs\.(write|append|create|rm|unlink|mkdir)"
    r"|File\.(write|open|delete)|Path\([^)]*\)\.(write|unlink)"
    r"|shutil\.(move|copy|rmtree)|os\.(remove|rename|replace|rmdir|unlink)|\bunlink\s*\(",
    re.I,
)

# Build canonical tmp root prefixes once at module load.
# On macOS /tmp → /private/tmp; resolve all roots so traversal attacks can't escape.
def _build_tmp_roots():
    roots = []
    for p in list(TMP_PREFIXES) + ([_TMPDIR] if _TMPDIR else []):
        try:
            canon = os.path.realpath(p.rstrip("/"))
        except Exception:
            canon = p.rstrip("/")
        roots.append(canon.rstrip("/") + "/")
    return roots

_CANON_TMP_ROOTS = _build_tmp_roots()


@functools.lru_cache(maxsize=256)
def _canon(t):
    """Return the canonical (realpath-normalized) form of path t.

    Relative mutation targets are interpreted relative to the session project root —
    that is the command's effective cwd, the natural base for a relative shell path.
    """
    try:
        base = t if os.path.isabs(t) else os.path.join(_proj, t)
        # os.path.realpath resolves symlinks and .. segments without requiring the path to exist.
        return os.path.realpath(base)
    except Exception:
        return t


def _git_toplevel(d):
    """git work-tree root containing dir d, or '' if d is in no repo / git unavailable."""
    try:
        return os.path.realpath(
            subprocess.check_output(
                ["git", "-C", d, "rev-parse", "--show-toplevel"],
                stderr=subprocess.DEVNULL,
            ).decode().strip()
        )
    except Exception:
        return ""


def _nearest_existing_dir(ct):
    """Walk ct's dirname up to the nearest EXISTING ancestor (a write may create new dirs)."""
    d = os.path.dirname(ct) or "/"
    while d and d != "/" and not os.path.isdir(d):
        d = os.path.dirname(d)
    return d


@functools.lru_cache(maxsize=256)
def target_repo(ct):
    """Innermost repo root governing canonical path ct, resolved from the TARGET.

    A command can touch a file in a sibling/child repo while the session sits elsewhere;
    that file must be judged by ITS OWN repo's carve-outs, budget and protected list.
    git -C <nonexistent-dir> fails and a write can create a brand-new dir, so we walk up
    to the nearest existing ancestor before querying git. Falls back to the session repo
    when the target is outside any repo / unresolvable (preserves today's fail-open).
    This anchors BUDGET and CARVE-OUTS to the innermost repo (round-1 behaviour); the
    PROTECTED check additionally consults the enclosing chain (see enclosing_repos).
    """
    d = _nearest_existing_dir(ct)
    if d and os.path.isdir(d):
        top = _git_toplevel(d)
        if top:
            return top
    top = _git_toplevel(os.path.realpath(_proj))
    return top or os.path.realpath(_proj)


@functools.lru_cache(maxsize=256)
def enclosing_repos(ct):
    """All git repo roots enclosing canonical path ct, ordered innermost → outermost.

    A repo nested inside a protected subtree of an OUTER repo (vendored dep with its own
    .git, accidental `git init`, fixture repo under src/) would otherwise resolve only to
    the inner root — which carries none of the outer repo's PROTECTED config, silently
    exempting protected code. The PROTECTED gate is a UNION over this chain: if ANY
    enclosing repo's protected list matches the target by THAT repo's own relative path,
    block. Carve-outs/budget never union outward — only protection does.

    Bounded walk: from the innermost repo root, step to its parent dir and ask git for the
    next enclosing work tree, repeating until git finds none (filesystem root). realpath is
    resolved once per step; git is queried once per enclosing level (a handful at most).
    """
    chain = []
    inner = target_repo(ct)
    # target_repo falls back to _proj even when ct is in no repo; only treat it as a real
    # enclosing root if it is genuinely a git work tree.
    d = _nearest_existing_dir(ct)
    if not (d and os.path.isdir(d) and _git_toplevel(d)):
        return tuple()
    cur = inner
    seen = set()
    while cur and cur not in seen:
        seen.add(cur)
        chain.append(cur)
        parent = os.path.dirname(cur)
        if not parent or parent == cur:
            break
        outer = _git_toplevel(parent)
        if not outer or outer in seen:
            break
        cur = outer
    return tuple(chain)


@functools.lru_cache(maxsize=256)
def outer_protects(ct):
    """True if any STRICTLY-OUTER enclosing repo protects ct by its own relative path.

    Exemptions must never flow across repo boundaries: a carve-out anchored to the INNER
    (target) repo — docs/, .claude/maestro ledger, harness-state, scratch, even a .md prose
    file — must not whitelist a path that an OUTER repo protects (the inner repo lives inside
    the outer repo's protected subtree). benign_target() consults this so outer protection
    always wins over inner carve-outs; the innermost repo's own protected list is enforced
    later by the budget/protected gate (with accurate usage in its log).
    """
    chain = enclosing_repos(ct)
    if len(chain) < 2:
        return False  # no strictly-outer repo → nothing can leak outward
    for repo in chain[1:]:
        _, _, prot = load_config(repo)
        if any(glob_match(repo, p, ct) for p in prot):
            return True
    return False


def benign_target(t):
    if not t or t == "-" or t.startswith("&"):
        return True
    if t in BENIGN_DEV:
        return True
    # SECURITY: canonicalize the target FIRST so that path-traversal attacks like
    # /tmp/../../<repo>/file or .claude/maestro/../../hooks/guard.sh are resolved
    # to their real location before any carve-out check.
    ct = _canon(t)
    # Exemptions never cross repo boundaries: if a STRICTLY-OUTER enclosing repo protects ct
    # (the target's inner repo sits inside that outer repo's protected subtree), NO carve-out
    # below applies — the path is a real mutation target and the protected union will block it.
    if outer_protects(ct):
        return False
    # Repo-relative carve-outs are anchored to the TARGET's repo, not the session — the
    # anchor moves as one piece so a parent-anchored carve-out can't whitelist a child file.
    _repo = target_repo(ct)
    # Maestro harness-state carve-out — allow ONLY the exact canonical paths that
    # are maestro's own bookkeeping, anchored to the target's repo root.  An unanchored
    # substring match would allow traversal OUT of .claude/maestro/ into production
    # code, and would also match unrelated paths that merely contain the substring
    # (e.g. skills/.claude/maestro-evil.ts, .claude/maestroX/anything).
    _maestro_exact = {
        os.path.join(_repo, ".claude", "maestro.json"),
        os.path.join(_repo, ".claude", "maestro-verify"),
        os.path.join(_repo, ".claude", "maestro-direct"),
    }
    _maestro_ledger_prefix = os.path.join(_repo, ".claude", "maestro") + os.sep
    if ct in _maestro_exact or ct.startswith(_maestro_ledger_prefix):
        return True
    # Scratch carve-out is for no-impact files outside the repo. If the target itself
    # lives under TMPDIR but inside a repo (e.g. tmpdir test repos), keep it gated.
    if any(ct.startswith(r) for r in _CANON_TMP_ROOTS) and not (ct == _repo or ct.startswith(_repo + os.sep)):
        return True

    # Prose/docs/no-impact carve-out — allow direct writes to documentation/memory files.
    # SECURITY: apply this to canonical ct so docs/../src/app.ts resolves outside docs
    # and remains blocked.
    _base = os.path.basename(ct)
    _stem, _ext = os.path.splitext(_base)
    if _ext.lower() in {".md", ".markdown", ".mdx", ".txt", ".rst", ".adoc"}:
        return True
    if _stem.upper() in {"LICENSE", "LICENCE", "COPYING", "NOTICE", "AUTHORS"}:
        return True
    _docs_prefix = os.path.join(_repo, "docs") + os.sep
    if ct.startswith(_docs_prefix):
        return True

    return False


def basename(p):
    return p.rsplit("/", 1)[-1].rsplit("\\", 1)[-1]


def strip_heredocs(s):
    """Remove heredoc bodies so their content is never scanned as shell syntax.

    Handles:  <<DELIM  <<-DELIM  <<'DELIM'  <<"DELIM"
    Everything from the <<DELIM marker token through the line that is exactly
    the bare delimiter (with optional leading tabs for <<-) is removed.
    CRITICALLY: content on the intro line BEFORE and AFTER the <<DELIM token
    is preserved so that:
      cat <<'EOF' > ./src/app.ts   →  cat > ./src/app.ts   (repo redirect → budget gate)
      cat <<'EOF' | tee ./src/app.ts →  cat | tee ./src/app.ts  (repo write → budget gate)
      cat <<'EOF' > /tmp/x         →  cat > /tmp/x          (tmp redirect → ALLOW)
    """
    heredoc_intro = re.compile(
        r'(?P<redir>(?:\d+)?<<(?P<strip>-?))'
        r"(?P<q>['\"]?)(?P<delim>[A-Za-z0-9_]+)(?P=q)"
    )
    lines = s.split("\n")
    result = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = heredoc_intro.search(line)
        if m:
            delim = m.group("delim")
            strip_tabs = m.group("strip") == "-"
            intro_part = line[:m.start()]
            tail_part  = line[m.end():]
            result.append(intro_part + tail_part)
            i += 1
            while i < len(lines):
                body_line = lines[i]
                check = body_line.lstrip("\t") if strip_tabs else body_line
                if check == delim:
                    i += 1
                    break
                trailing_pat = re.escape(delim) + r'[\\\'\"]*'
                tm = re.fullmatch(trailing_pat, check)
                if tm and check != delim:
                    trailing_chars = check[len(delim):]
                    result[-1] = result[-1] + trailing_chars
                    i += 1
                    break
                i += 1
        else:
            result.append(line)
            i += 1
    return "\n".join(result)


def tokenize(s):
    lex = shlex.shlex(s, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    return list(lex)


def mask_quotes(s):
    """Replace each quoted region with a placeholder so a quoted '>' (e.g.
    grep ">") is not mistaken for a redirect operator. shlex posix mode strips
    quotes, losing that distinction — so redirect detection runs on this mask."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c in ("'", '"'):
            q, i = c, i + 1
            while i < n and s[i] != q:
                if q == '"' and s[i] == "\\":
                    i += 2
                    continue
                i += 1
            out.append("Q")
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def lead_command(seg):
    """Return (command, args) skipping leading VAR=val and redirections."""
    i = 0
    while i < len(seg):
        t = seg[i]
        if t in REDIR:
            i += 2
            continue
        if re.match(r"^\d+$", t) and i + 1 < len(seg) and seg[i + 1] in REDIR:
            i += 2
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            i += 1
            continue
        return t, seg[i + 1:]
    return None, []


def coarse_reason(s):
    """Regex fallback when shlex can't parse (unbalanced quotes, etc.)."""
    _dev_re = r"/dev/(null|stdout|stderr|tty)\b"
    m = re.search(r"&>>?\s*(?!&)(?!" + _dev_re + r")(?P<t>\S+)", s)
    if m:
        return ("shell redirection (heuristic)", m.group("t").rstrip("\\'\""))
    m = re.search(r">\|\s*(?!" + _dev_re + r")(?P<t>\S+)", s)
    if m:
        return ("shell redirection (heuristic)", m.group("t").rstrip("\\'\""))
    m = re.search(
        r"(?<![&|])\d*>>?(?!\|)\s*(?!&)(?!" + _dev_re + r")(?P<t>\S+)",
        s,
    )
    if m:
        return ("shell redirection (heuristic)", m.group("t").rstrip("\\'\""))

    if re.search(r"\b(sed|gsed)\s+-i|\bperl\s+-i|\btee\b|\bdd\b|\b(cp|mv|ln)\b"
                 r"|\bpatch\b|\b(truncate|install)\b|\bgit\s+(apply|restore|stash|clean)\b", s):
        return ("file-mutating command (heuristic)", None)
    return None


def analyze(cmd, depth=0):
    if depth > 3:
        # Deliberate ALLOW-on-overflow: deeply nested shell -c chains (>3 levels) are
        # exotic and extremely rare in legitimate orchestration. Blocking on overflow
        # would produce false-positives for benign recursive calls; the commit-gate and
        # human review remain the ultimate backstops for anything this exotic.
        return None
    cmd = strip_heredocs(cmd)
    try:
        tokens = tokenize(cmd)
    except ValueError:
        raw_reason = coarse_reason(cmd)
        if raw_reason:
            return raw_reason
        return coarse_reason(mask_quotes(cmd))

    # 1) Output redirection to a real file. Detect on the quote-masked command so
    #    a quoted '>' inside an argument is not read as a redirect operator.
    try:
        masked_tokens = tokenize(mask_quotes(cmd))
    except ValueError:
        masked_tokens = mask_quotes(cmd).split()
    for i, t in enumerate(masked_tokens):
        if t in REDIR:
            tgt = masked_tokens[i + 1] if i + 1 < len(masked_tokens) else None
            if not benign_target(tgt):
                return ("output redirection to %s" % tgt, tgt)

    # 2) Per-segment leading-command classification.
    segments, seg = [], []
    for t in tokens:
        if t in OPS:
            if seg:
                segments.append(seg)
                seg = []
        else:
            seg.append(t)
    if seg:
        segments.append(seg)

    for seg in segments:
        cmd0, args = lead_command(seg)
        if not cmd0:
            continue
        name = basename(cmd0)
        nonopt = [a for a in args if not a.startswith("-")]

        if name in ("sed", "gsed") and any(
            a == "-i" or a.startswith("-i") or a == "--in-place" for a in args
        ):
            tgt = nonopt[-1] if nonopt else None
            return ("sed in-place edit", tgt)
        if name == "perl" and any(a == "-i" or a.startswith("-i") for a in args):
            tgt = nonopt[-1] if nonopt else None
            return ("perl in-place edit", tgt)
        if name == "tee" and any(not benign_target(a) for a in nonopt):
            tgt = next((a for a in nonopt if not benign_target(a)), None)
            return ("tee writes a file", tgt)
        if name == "dd" and any(
            a.startswith("of=") and not benign_target(a[3:]) for a in args
        ):
            tgt = next((a[3:] for a in args if a.startswith("of=") and not benign_target(a[3:])), None)
            return ("dd writes a file", tgt)
        if name in ("cp", "mv", "ln"):
            tgt = nonopt[-1] if nonopt else None
            if not benign_target(tgt):
                return ("%s writes %s" % (name, tgt), tgt)
        if name in ("truncate", "install", "patch"):
            tgt = nonopt[-1] if nonopt else None
            return ("%s modifies files" % name, tgt)
        if name in EDITORS:
            tgt = nonopt[-1] if nonopt else None
            return ("interactive editor %s" % name, tgt)
        if name == "git":
            sub = nonopt[0] if nonopt else ""
            if sub in ("apply", "restore"):
                tgt = nonopt[-1] if len(nonopt) > 1 else None
                return ("git %s mutates the tree" % sub, tgt)
            if sub == "checkout" and "--" in args:
                tgt = args[-1] if args else None
                return ("git checkout -- mutates files", tgt)
            if sub == "reset" and "--hard" in args:
                return ("git reset --hard discards changes", None)
            if sub == "stash":
                return ("git stash mutates the tree", None)
            if sub == "clean":
                return ("git clean deletes files", None)
        # Shell -c: recurse into the inline script.
        if name in SHELLS:
            for j, a in enumerate(args):
                if a == "-c" and j + 1 < len(args):
                    r = analyze(args[j + 1], depth + 1)
                    if r:
                        return r
        # Interpreter -c/-e/-i with a language file-write API.
        if name in LANGS:
            if any(a == "-i" or a.startswith("-i") for a in args):
                return ("%s in-place edit" % name, nonopt[-1] if nonopt else None)
            if WRITE_API.search(" ".join(args)):
                return ("%s inline file write" % name, None)
    return None


def git(repo, *args):
    return subprocess.check_output(["git", "-C", repo, *args], stderr=subprocess.DEVNULL)


def load_config(repo):
    lines, files, protected = 50, 2, []
    path = os.path.join(repo, ".claude", "maestro-budget")
    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                raw = raw.strip()
                if not raw or raw.startswith("#") or "=" not in raw:
                    continue
                k, v = raw.split("=", 1)
                k, v = k.strip().upper(), v.strip()
                if k == "LINES":
                    try:
                        n = int(v)
                        if n >= 0:
                            lines = n
                    except Exception:
                        lines = 50
                elif k == "FILES":
                    try:
                        n = int(v)
                        if n >= 0:
                            files = n
                    except Exception:
                        files = 2
                elif k == "PROTECTED":
                    protected = [p for p in v.split(":") if p]
    except FileNotFoundError:
        pass
    except Exception:
        return 50, 2, []
    return lines, files, protected


def rel_for(repo, path):
    try:
        return os.path.relpath(os.path.realpath(path), repo).replace(os.sep, "/")
    except Exception:
        return (path or "").replace(os.sep, "/")


def match_segments(psegs, ssegs):
    if not psegs:
        return not ssegs
    head = psegs[0]
    if head == "**":
        return match_segments(psegs[1:], ssegs) or (bool(ssegs) and match_segments(psegs, ssegs[1:]))
    return bool(ssegs) and fnmatch.fnmatchcase(ssegs[0], head) and match_segments(psegs[1:], ssegs[1:])


def glob_match(repo, pattern, abs_path):
    pat = pattern.strip().replace("\\", "/")
    if not pat:
        return False
    if os.path.isabs(pat):
        subject = os.path.realpath(abs_path).lstrip(os.sep).replace(os.sep, "/")
        pat = os.path.realpath(pat).lstrip(os.sep).replace(os.sep, "/")
    else:
        subject = rel_for(repo, abs_path)
    return match_segments([p for p in pat.split("/") if p != ""], [p for p in subject.split("/") if p != ""])


def is_no_count_rel(rel):
    rel = rel.replace("\\", "/")
    base = os.path.basename(rel)
    stem, ext = os.path.splitext(base)
    if rel in {".claude/maestro.json", ".claude/maestro-verify", ".claude/maestro-direct"}:
        return True
    if rel.startswith(".claude/maestro/"):
        return True
    if ext.lower() in {".md", ".markdown", ".mdx", ".txt", ".rst", ".adoc"}:
        return True
    if stem.upper() in {"LICENSE", "LICENCE", "COPYING", "NOTICE", "AUTHORS"}:
        return True
    if rel.startswith("docs/"):
        return True
    return False


def line_count_file(path):
    try:
        with open(path, "rb") as f:
            data = f.read()
        if not data:
            return 0
        return len(data.splitlines())
    except Exception:
        return 0


def current_usage(repo):
    changed = set()
    lines = 0
    out = git(repo, "diff", "--numstat", "HEAD", "--").decode("utf-8", "replace")
    for row in out.splitlines():
        parts = row.split("\t")
        if len(parts) < 3:
            continue
        rel = parts[-1]
        if is_no_count_rel(rel):
            continue
        changed.add(rel)
        try:
            add = 0 if parts[0] == "-" else int(parts[0])
            dele = 0 if parts[1] == "-" else int(parts[1])
        except Exception:
            add = dele = 0
        lines += add + dele
    out = git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    for b in out.split(b"\0"):
        if not b or not b.startswith(b"?? "):
            continue
        rel = b[3:].decode("utf-8", "replace")
        if is_no_count_rel(rel):
            continue
        changed.add(rel)
        lines += line_count_file(os.path.join(repo, rel))
    return lines, changed


def write_log(repo, target, reason, lines_used, files_used):
    try:
        log_dir = os.path.join(repo, ".claude", "maestro")
        os.makedirs(log_dir, exist_ok=True)
        rec = {
            "ts": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
            "hook": HOOK,
            "target": os.path.realpath(target) if target else "",
            "lines_used": lines_used,
            "files_used": files_used,
            "reason": reason,
        }
        with open(os.path.join(log_dir, "guard-log.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
    except Exception:
        pass


result = analyze(command)
if not result:
    allow()
reason, target = result

# Root the governing repo on the TARGET the command touches, not the session dir, so a
# command mutating a sibling/child repo is judged by THAT repo's budget and protected
# list. Commands with no identifiable target (e.g. `git reset --hard`) keep the session
# repo. If git cannot be queried, fail open: tester/reviewer/commit-gate remain the
# backstops, and non-repo directories have no production-risk budget.
ctarget = _canon(target) if target else ""

# ── PHASE A: PROTECTION — must evaluate to completion INDEPENDENT of usage computation.
# Enclosing-repo discovery, config load and glob matching need a git work tree but NOT HEAD;
# a freshly `git init`-ed repo with no commit yet is a valid work tree. Keeping protection in
# its own try-block (separate from PHASE B's `current_usage`, which runs `git diff HEAD` and
# RAISES on a HEAD-less repo) is the spine invariant: a repo-state exception in usage must not
# skip the protected union. Mirrors the edit guard's ordering, where the strictly-outer union
# runs and can exit 2 before any HEAD-dependent work. If THIS block itself throws for
# git-unavailable reasons, the fail-open posture is preserved (tester/commit-gate backstop).
max_lines, max_files, protected = 50, 2, []
repo = ""
try:
    if ctarget:
        repo = target_repo(ctarget)
        # Enclosing-repo chain for the PROTECTED union (innermost → outermost). When the
        # target is in no repo, the chain is empty and only the session fallback below runs.
        repo_chain = enclosing_repos(ctarget)
    else:
        repo = os.path.realpath(git(os.path.realpath(_proj), "rev-parse", "--show-toplevel").decode().strip())
        repo_chain = (repo,)
    # Confirm the resolved root really is a git work tree before gating on it (HEAD-agnostic).
    git(repo, "rev-parse", "--show-toplevel")
    if not repo_chain:
        repo_chain = (repo,)
    # Budget/protected config stays anchored to the innermost (target) repo — round-1 behaviour.
    max_lines, max_files, protected = load_config(repo)

    # PROTECTED is a UNION OF GATES across the enclosing chain, but exemptions never flow
    # ACROSS repo boundaries. Ordering encodes that:
    #   (1) STRICTLY-OUTER repos' protected lists are checked FIRST — an inner repo's
    #       maestro-direct or permissive config can never bypass an outer repo's PROTECTED.
    #   (2) THEN the GOVERNING repo's own direct-mode carve-out applies — a founder who put THIS
    #       repo in direct mode wants direct mutations to it, even on its own protected paths
    #       (round-1 per-repo carve-out, single-repo case). `repo` is the TARGET repo for a real
    #       target, or the SESSION repo on the no-target fallback (e.g. `git reset --hard`) — so
    #       this one check honors the marker per target AND on the session fallback, replacing the
    #       removed session early-exit without ever exempting another repo's files cross-session.
    #   (3) THEN the innermost repo's own protected list. Each repo's globs are evaluated
    #       against the target's path RELATIVE TO THAT repo's own root.
    # Size is irrelevant on protected paths, so logs record 0/0 usage here (usage may not yet
    # be known, and is genuinely unknowable for a HEAD-less repo) — matches the edit guard.
    if target:
        for _r in repo_chain[1:]:                      # (1) strictly-outer repos
            if any(glob_match(_r, p, ctarget) for p in load_config(_r)[2]):
                write_log(_r, ctarget, "protected", 0, 0)
                short_block("BLOCKED: protected path. Size does not matter on protected paths; run maestro for this task.\n")
    if os.path.exists(os.path.join(repo, ".claude", "maestro-direct")):  # (2) inner direct-mode
        allow()
    if target:                                         # (3) innermost repo's own protected
        if any(glob_match(repo, p, ctarget) for p in protected):
            write_log(repo, ctarget, "protected", 0, 0)
            short_block("BLOCKED: protected path. Size does not matter on protected paths; run maestro for this task.\n")
except Exception:
    # Protection could not be evaluated for git-unavailable reasons → fail open (unchanged
    # posture). A HEAD-less repo does NOT land here: nothing above queries HEAD.
    allow()

# ── PHASE B: BUDGET — usage requires HEAD (`git diff HEAD`). If it cannot be computed (e.g.
# a HEAD-less repo with no commit yet), budget is genuinely unknowable → fail open. Protection
# (PHASE A) has already run to completion by this point, so this fail-open NEVER under-blocks a
# protected path. Anchored to the innermost (target) repo — round-1 behaviour.
try:
    cur_lines, changed_files = current_usage(repo)
except Exception:
    allow()

used_lines = cur_lines
used_files = len(changed_files)
if used_lines > max_lines or used_files > max_files:
    write_log(repo, target or "", "budget", used_lines, used_files)
    short_block(
        f"BLOCKED: direct-edit budget exhausted (lines {used_lines}/{max_lines}, files {used_files}/{max_files}).\n"
        "Run maestro for the REMAINDER of this task; never split a task to stay under the limit.\n"
    )

allow()
