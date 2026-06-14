# Deterministic off-limits guard for learned-write.sh's `section` subcommand.
#
# The continual-learning auto-writer must NEVER edit a globally-injected contract/policy file.
# Those files are injected into every maestro session, so a stray "## Learned" bullet would
# silently rewrite the team's contract. This invariant lives in code — never in the consolidator's
# prose/LLM discretion — so it cannot be reasoned around.
#
# `off_limits_reason(path)` returns a human reason string when the target is off-limits, else None.
# The caller refuses (non-zero exit, writes nothing) BEFORE reading or creating the target, so a
# denied path is left byte-identical and an absent path is never created.
#
# Path resolution mirrors registry-add.sh: realpath+expanduser collapses relative / "." / ".." /
# symlink targets so the basename and directory-segment checks cannot be dodged by an alias.
# realpath does NOT case-normalize, so on a case-insensitive filesystem (macOS/APFS, NTFS) a
# variant-case path (`Conventions.md`, `ME.md`, `RULES/x.md`) resolves to a DISTINCT string yet
# the OS opens the SAME on-disk file. A case-sensitive denylist therefore lets a variant-case path
# slip the guard and corrupt a globally-injected policy file. Every comparison below casefolds both
# sides so the denylist matches whatever case the OS would actually open.
import os
import re

# The contract's literal single-source-of-truth marker line. Both this repo's source AGENTS.md and
# the deployed ~/.claude/AGENTS.md carry it, so it deterministically identifies the contract file.
# Matched case-insensitively against a whitespace-collapsed copy of the file so a reformatted-but-real
# contract (extra spaces, different case) is still protected.
CONTRACT_MARKER = "> **Single source of truth.**"
_MARKER_NORM = re.sub(r"\s+", " ", CONTRACT_MARKER).strip().casefold()


def _has_contract_marker(text):
    # Collapse runs of whitespace and casefold before matching so an internally-reformatted marker
    # (the crown-jewel contract file is worth a tolerant check) is still recognized.
    return _MARKER_NORM in re.sub(r"\s+", " ", text).casefold()


def off_limits_reason(path):
    resolved = os.path.realpath(os.path.expanduser(path))
    base = os.path.basename(resolved)
    base_cf = base.casefold()
    # 1. conventions.md / me.md are always off-limits (company + human founder-gated policy files).
    if base_cf in ("conventions.md", "me.md"):
        return f"{base} is a founder-gated policy file — route via the inbox, never auto-write"
    # 2. the deployed global contract, identified literally by its canonical path (casefolded so a
    #    variant-case path that opens the same file on a case-insensitive FS is still caught).
    home_contract = os.path.realpath(os.path.expanduser("~/.claude/AGENTS.md"))
    if resolved.casefold() == home_contract.casefold():
        return "~/.claude/AGENTS.md is the deployed global contract — exempt from auto-write"
    # 3. any AGENTS.md carrying the contract marker is the single-source-of-truth contract. Match the
    #    basename case-insensitively so lowercase `agents.md` still triggers the marker read.
    if base_cf == "agents.md" and os.path.exists(resolved):
        try:
            with open(resolved, "r", encoding="utf-8") as f:
                if _has_contract_marker(f.read()):
                    return "this AGENTS.md is the maestro contract (single-source marker) — exempt from auto-write"
        except OSError:
            pass
    # 4. anything under a charter/ or rules/ directory segment is policy, never repo learnings.
    #    Casefold each segment so `RULES/`, `Charter/` etc. are caught while a real segment like
    #    `my-rules` / `rulesX` (which is not the policy directory) stays allowed.
    segments = [s.casefold() for s in resolved.split(os.sep)]
    for seg in ("charter", "rules"):
        if seg in segments:
            return f"{seg}/ holds policy artifacts — off-limits to the auto-writer"
    return None
