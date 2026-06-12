"""Shared pure helpers for the two main-session guards.

guard-block-main-edits.sh and guard-block-main-bash.sh both decide whether a
main-session mutation is allowed: same protected-config load, same glob/segment
matching, same repo-root and enclosing-repo walks. Those decisions MUST stay
identical between the two hooks — a divergence (an ordering or matching fix
applied to one copy and not the other) is exactly the class of bug this module
exists to make impossible. Keep ONLY pure helpers here; each hook keeps its own
orchestration (payload parse, phase ordering, exits, logging) in its heredoc.

FILE NAME: `guard_lib.py` uses an underscore (not the repo's kebab-case rule) so
it is importable as a python module — a deliberate, documented exception. The
hooks resolve their own real directory (the `_src` readlink pattern) and pass it
in via the GUARD_LIB_DIR env var, then `sys.path.insert(0, that_dir)` and
`from guard_lib import ...`. The lib sits beside the hooks in BOTH layouts: the
repo tree (maestro/hooks/) and the deployed copy (~/.claude/hooks/).
"""
import fnmatch
import os
import subprocess


def git_toplevel(d):
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


def outer_repos(start):
    """Enclosing repo roots STRICTLY outside `start`, innermost -> outermost (start excluded).

    Bounded walk: from `start`, step to each parent dir and ask git for the next
    enclosing work tree, until git finds none (filesystem root) or a cycle is hit.
    """
    chain, seen, cur = [], {start}, start
    while True:
        parent = os.path.dirname(cur)
        if not parent or parent == cur:
            break
        outer = git_toplevel(parent)
        if not outer or outer in seen:
            break
        seen.add(outer)
        chain.append(outer)
        cur = outer
    return chain


class _ProtectedList(list):
    """A protected-glob list that can carry a fail_closed_reason marker.

    load_config returns a plain list on the happy path and this subclass (behaving
    exactly like a list everywhere it is iterated/indexed) only when it had to fail
    CLOSED on an unreadable budget. Callers compose their over-block message with
    getattr(protected, "fail_closed_reason", "") so the block self-explains its cause
    instead of showing the generic protected-path text. Subclassing list keeps the 3-tuple
    arity unchanged — no call site needs to learn a 4th return value.
    """
    fail_closed_reason = ""


def load_config(repo):
    """Parse <repo>/.claude/maestro-budget -> (max_lines, max_files, protected_list).

    ABSENT file (FileNotFoundError) -> legitimate defaults (50, 2, []): "no budget
    configured" is the normal case, not a failure. A malformed value for LINES/FILES
    resets THAT field to its default (the file is still readable).

    UNREADABLE file (exists but cannot be opened/read -> PermissionError on a chmod-000
    budget, IsADirectoryError, or any other OSError) FAILS CLOSED: we cannot know what the
    repo declared protected, and the spine invariant says ambiguity over-blocks. We return
    (0, 0, _ProtectedList(["**"])) -- budget 0 makes any nonzero change exceed it, and "**"
    protects every path under the repo; the returned list carries a fail_closed_reason so the
    caller's block message can NAME the cause (an unexplained over-block is its own incident).
    This is NOT "git unavailable"; the file is THERE and the operator intended a policy we
    can't read, so we apply the most conservative one. (Was previously a fail-OPEN that
    returned (50, 2, []) with an EMPTY protected list -> protected paths were allowed through
    an unreadable budget; this closes that gap.)
    """
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
        pass  # absent -> legitimate defaults
    except Exception:
        # File exists but could not be read to completion: chmod-000 -> PermissionError,
        # a dir where a file is expected -> IsADirectoryError, I/O error -> OSError, or
        # non-UTF-8 garbled bytes -> UnicodeDecodeError. We cannot know the declared policy,
        # so fail CLOSED: protect everything ("**"), block any size (budget 0). Catching
        # broadly (not just OSError) is deliberate: a decode error left to propagate would
        # crash the caller and land in its fail-OPEN exception handler -> under-block, the
        # exact direction the spine invariant forbids.
        prot = _ProtectedList(["**"])
        prot.fail_closed_reason = "maestro-budget unreadable — check permissions"
        return 0, 0, prot
    return lines, files, protected


def rel_for(repo, path):
    """Path relative to repo root, '/'-normalized. Falls back to the raw path on error."""
    try:
        return os.path.relpath(os.path.realpath(path), repo).replace(os.sep, "/")
    except Exception:
        return (path or "").replace(os.sep, "/")


def match_segments(psegs, ssegs):
    """Glob-segment match with '**' spanning zero-or-more path segments.

    psegs/ssegs are '/'-split path-segment lists. A literal '**' segment matches
    any number of subject segments (including zero); every other segment is matched
    case-sensitively with fnmatch (so '*' and '?' are single-segment wildcards).
    """
    if not psegs:
        return not ssegs
    head = psegs[0]
    if head == "**":
        return match_segments(psegs[1:], ssegs) or (bool(ssegs) and match_segments(psegs, ssegs[1:]))
    return bool(ssegs) and fnmatch.fnmatchcase(ssegs[0], head) and match_segments(psegs[1:], ssegs[1:])


def glob_match(repo, pattern, abs_path):
    """True if `pattern` (a maestro-budget PROTECTED glob) matches abs_path.

    Relative patterns match abs_path's path RELATIVE TO `repo`; absolute patterns
    match the realpath'd absolute path. '**' spans directory levels (see
    match_segments). Empty pattern never matches.
    """
    pat = pattern.strip().replace("\\", "/")
    if not pat:
        return False
    if os.path.isabs(pat):
        subject = os.path.realpath(abs_path).lstrip(os.sep).replace(os.sep, "/")
        pat = os.path.realpath(pat).lstrip(os.sep).replace(os.sep, "/")
    else:
        subject = rel_for(repo, abs_path)
    return match_segments([p for p in pat.split("/") if p], [p for p in subject.split("/") if p])
