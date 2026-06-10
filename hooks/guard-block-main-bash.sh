#!/usr/bin/env python3
"""PreToolUse(Bash) guard — close the orchestrate-only gap.

The Edit/Write guard blocks the main session from the editing TOOLS, but a shell
command (`echo >> f`, `sed -i`, `tee`, `cp`, `patch`, `git apply`, `bash -c "...>>f"`,
`python3 -c "open(...,'w')"`) can mutate the working tree and bypass it. This hook
classifies the Bash command and blocks the MAIN session (no agent_id) from any
file-mutating shell. Subagents (developer/ui-developer/... carry an agent_id) pass.
Read-only commands (ls, grep, cat, git status/log/diff, test runners, redirects to
/dev/null or $TMPDIR) pass through.

Robust tokenization via shlex (respects quotes) — mirrors pi foreman guard.ts.
Not a perfect seal (a determined model can use exotic paths); the commit-gate +
human review are the ultimate "can't ship broken" backstops.
"""
import sys, json, shlex, os, re, functools


def allow():
    sys.exit(0)


def block(reason):
    sys.stderr.write(
        "BLOCKED: the orchestrator must not modify files via shell (%s).\n"
        "Drive the change through the maestro MCP tool instead — "
        "maestro({task, cwd, verifyCommand?}) and let the gated dev->test->review loop make it.\n" % reason
    )
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
    """Return the canonical (realpath-normalized) form of path t."""
    try:
        # os.path.realpath resolves symlinks and .. segments without requiring the path to exist.
        return os.path.realpath(t)
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
    if any(ct.startswith(r) for r in _CANON_TMP_ROOTS):
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
      cat <<'EOF' > ./src/app.ts   →  cat > ./src/app.ts   (repo redirect → BLOCK)
      cat <<'EOF' | tee ./src/app.ts →  cat | tee ./src/app.ts  (repo write → BLOCK)
      cat <<'EOF' > /tmp/x         →  cat > /tmp/x          (tmp redirect → ALLOW)
    """
    # Match the heredoc introduction: optional fd, <<-?, then the delimiter
    # (which may be bare, single-quoted, or double-quoted).
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
            # Keep the part of the line BEFORE the <<DELIM marker AND everything
            # AFTER the marker (e.g. "> target" or "| tee target") for redirect analysis.
            # Only the <<DELIM token itself (and its body) is elided.
            intro_part = line[:m.start()]    # before <<DELIM
            tail_part  = line[m.end():]      # after <<DELIM (redirect/pipe target lives here)
            result.append(intro_part + tail_part)
            i += 1
            # Skip lines until we find the closing delimiter line.
            # The closing delimiter is normally the bare word on its own line.
            # When the heredoc is embedded inside a quoted shell argument
            # (e.g. bash -c "cat <<'EOF'\nbody\nEOF"), the final delimiter
            # line may have a trailing quote character (e.g. 'EOF"') because
            # the closing quote of the outer argument immediately follows.
            # Accept delim with an optional trailing ' or " as the terminator;
            # when a trailing quote is found, append it to the intro_part so
            # that the outer quoting context is preserved for shlex parsing.
            while i < len(lines):
                body_line = lines[i]
                check = body_line.lstrip("\t") if strip_tabs else body_line
                if check == delim:
                    i += 1  # consume the closing delimiter line too
                    break
                # Accept delimiter followed by any run of trailing quote/backslash chars.
                # This handles escaped-quote terminators like EOF\", EOF\"\", EOF'', EOF\'
                # that appear when a heredoc is embedded inside a quoted shell argument.
                # Capturing the trailing run and re-appending it preserves the outer
                # quoting context so shlex can still parse the surrounding command.
                trailing_pat = re.escape(delim) + r'[\\\'"]*'
                tm = re.fullmatch(trailing_pat, check)
                if tm and check != delim:  # bare delim already handled above
                    # Trailing chars close the outer quoting context — preserve them.
                    trailing_chars = check[len(delim):]
                    result[-1] = result[-1] + trailing_chars
                    i += 1
                    break
                i += 1
            # Heredoc body consumed; continue scanning the rest of the command.
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
            out.append("Q")  # whole quoted region → single inert placeholder
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
    """Regex fallback when shlex can't parse (unbalanced quotes, etc.).

    Redirect detection must mirror the REDIR set used by the parseable path:
      {">", ">>", ">|", "&>", "&>>"}
    plus fd-numbered forms N> and N>> (e.g. 1>, 2>).

    Exclusions (must NOT flag):
    - Targets matching /dev/(null|stdout|stderr|tty) — truly benign.
    - fd-duplication: N>&M, >&N, &>&N — these redirect to a descriptor, not a file.
      The telltale is the target (or the character immediately after the operator)
      starting with '&'.
    """
    _dev_re = r"/dev/(null|stdout|stderr|tty)\b"

    # Pattern A: &> and &>> (stdout+stderr redirect) — NOT fd-dup (&>&N).
    # A &> followed by & means fd-dup (e.g. &>&1) — skip.
    if re.search(r"&>>?\s*(?!&)(?!" + _dev_re + r")\S", s):
        return "shell redirection (heuristic)"

    # Pattern B: >| (clobber redirect) — always a file write (shell never uses >|& for fd-dup).
    if re.search(r">\|\s*(?!" + _dev_re + r")\S", s):
        return "shell redirection (heuristic)"

    # Pattern C: plain > or >> and fd-numbered N> or N>> (e.g. 1>, 2>, 1>>, 2>>).
    # Must exclude:
    #   - &>  (already handled above, but &>> ? would be caught above; lone > preceded by & is fd-dup '>&')
    #   - N>& (fd-dup like 2>&1) — target starts with &
    #   - >|  (clobber — handled above; plain > followed by | is not a redirect to a file)
    # The negative lookbehind (?<!&) prevents matching the > in >&N fd-dup.
    # The negative lookahead (?!&|/) with /dev check prevents flagging fd-dup targets.
    if re.search(
        r"(?<![&|])\d*>>?(?!\|)\s*(?!&)(?!" + _dev_re + r")\S",
        s,
    ):
        return "shell redirection (heuristic)"

    if re.search(r"\b(sed|gsed)\s+-i|\bperl\s+-i|\btee\b|\bdd\b|\b(cp|mv|ln)\b"
                 r"|\bpatch\b|\b(truncate|install)\b|\bgit\s+(apply|restore|stash|clean)\b", s):
        return "file-mutating command (heuristic)"
    return None


def analyze(cmd, depth=0):
    if depth > 3:
        # Deliberate ALLOW-on-overflow: deeply nested shell -c chains (>3 levels) are
        # exotic and extremely rare in legitimate orchestration. Blocking on overflow
        # would produce false-positives for benign recursive calls; the commit-gate and
        # human review remain the ultimate backstops for anything this exotic.
        return None
    # Strip heredoc bodies first so their contents (which may contain >, <, etc.)
    # are never mistaken for shell operators or redirects.
    # strip_heredocs is idempotent on heredoc-free input, so it is safe to call
    # unconditionally at every recursion level (including bash -c / sh -c inlines).
    cmd = strip_heredocs(cmd)
    try:
        tokens = tokenize(cmd)
    except ValueError:
        # Fail CLOSED: the command cannot be cleanly tokenized (dangling open quote,
        # unbalanced heredoc markers, etc.).  mask_quotes() erases content inside
        # unterminated quote regions, which means a redirect like > repo/file hidden
        # inside a dangling-quote can become invisible → coarse_reason returns None → ALLOW.
        # Instead, run coarse_reason on the RAW (unmasked) command so that any
        # redirect or file-mutating pattern is still visible.  If there is ANY
        # mutation evidence → BLOCK.  Only if the raw command is cleanly benign
        # (no mutation pattern at all) do we allow it through.
        raw_reason = coarse_reason(cmd)
        if raw_reason:
            return raw_reason
        # No mutation evidence in the raw command; fall back to the masked check as
        # a secondary signal (extra-cautious: if masking reveals a new reason, block).
        masked_reason = coarse_reason(mask_quotes(cmd))
        return masked_reason

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
                return "output redirection to %s" % tgt

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
            return "sed in-place edit"
        if name == "perl" and any(a == "-i" or a.startswith("-i") for a in args):
            return "perl in-place edit"
        if name == "tee" and any(not benign_target(a) for a in nonopt):
            return "tee writes a file"
        if name == "dd" and any(
            a.startswith("of=") and not benign_target(a[3:]) for a in args
        ):
            return "dd writes a file"
        if name in ("cp", "mv", "ln"):
            tgt = nonopt[-1] if nonopt else None
            if not benign_target(tgt):
                return "%s writes %s" % (name, tgt)
        if name in ("truncate", "install", "patch"):
            return "%s modifies files" % name
        if name in EDITORS:
            return "interactive editor %s" % name
        if name == "git":
            sub = nonopt[0] if nonopt else ""
            if sub in ("apply", "restore"):
                return "git %s mutates the tree" % sub
            if sub == "checkout" and "--" in args:
                return "git checkout -- mutates files"
            if sub == "reset" and "--hard" in args:
                return "git reset --hard discards changes"
            if sub == "stash":
                return "git stash mutates the tree"
            if sub == "clean":
                return "git clean deletes files"
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
                return "%s in-place edit" % name
            if WRITE_API.search(" ".join(args)):
                return "%s inline file write" % name
    return None


reason = analyze(command)
if reason:
    block(reason)
allow()
