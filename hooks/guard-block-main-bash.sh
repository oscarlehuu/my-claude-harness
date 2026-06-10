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

# Engagement OFF for this repo (.claude/maestro-direct) → direct-edit mode, allow.
_proj = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
if os.path.exists(os.path.join(_proj, ".claude", "maestro-direct")) or os.path.exists(
    os.path.join(".claude", "maestro-direct")
):
    allow()

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

    Relative mutation targets are interpreted relative to the project root, matching
    the repo used for budget/protected checks rather than the hook process cwd.
    """
    try:
        base = t if os.path.isabs(t) else os.path.join(_proj, t)
        # os.path.realpath resolves symlinks and .. segments without requiring the path to exist.
        return os.path.realpath(base)
    except Exception:
        return t


def benign_target(t):
    if not t or t == "-" or t.startswith("&"):
        return True
    if t in BENIGN_DEV:
        return True
    # SECURITY: canonicalize the target FIRST so that path-traversal attacks like
    # /tmp/../../<repo>/file or .claude/maestro/../../hooks/guard.sh are resolved
    # to their real location before any carve-out check.
    ct = _canon(t)
    # Maestro harness-state carve-out — allow ONLY the exact canonical paths that
    # are maestro's own bookkeeping, anchored to the real repo root.  An unanchored
    # substring match would allow traversal OUT of .claude/maestro/ into production
    # code, and would also match unrelated paths that merely contain the substring
    # (e.g. skills/.claude/maestro-evil.ts, .claude/maestroX/anything).
    _canon_proj = os.path.realpath(_proj)
    _maestro_exact = {
        os.path.join(_canon_proj, ".claude", "maestro.json"),
        os.path.join(_canon_proj, ".claude", "maestro-verify"),
        os.path.join(_canon_proj, ".claude", "maestro-direct"),
    }
    _maestro_ledger_prefix = os.path.join(_canon_proj, ".claude", "maestro") + os.sep
    if ct in _maestro_exact or ct.startswith(_maestro_ledger_prefix):
        return True
    _canon_proj = os.path.realpath(_proj)
    # Scratch carve-out is for no-impact files outside the repo. If the project itself
    # lives under TMPDIR during tests, keep repo paths budget/protected-gated.
    if any(ct.startswith(r) for r in _CANON_TMP_ROOTS) and not (ct == _canon_proj or ct.startswith(_canon_proj + os.sep)):
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
    _docs_prefix = os.path.join(os.path.realpath(_proj), "docs") + os.sep
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

# If git cannot be queried, fail open: tester/reviewer/commit-gate remain the
# backstops, and non-repo directories have no production-risk budget.
try:
    repo = os.path.realpath(git(os.path.realpath(_proj), "rev-parse", "--show-toplevel").decode().strip())
    max_lines, max_files, protected = load_config(repo)
    cur_lines, changed_files = current_usage(repo)
except Exception:
    allow()

if target:
    ctarget = _canon(target)
    if any(glob_match(repo, p, ctarget) for p in protected):
        write_log(repo, ctarget, "protected", cur_lines, len(changed_files))
        short_block("BLOCKED: protected path. Size does not matter on protected paths; run maestro for this task.\n")

used_lines = cur_lines
used_files = len(changed_files)
if used_lines > max_lines or used_files > max_files:
    write_log(repo, target or "", "budget", used_lines, used_files)
    short_block(
        f"BLOCKED: direct-edit budget exhausted (lines {used_lines}/{max_lines}, files {used_files}/{max_files}).\n"
        "Run maestro for the REMAINDER of this task; never split a task to stay under the limit.\n"
    )

allow()
