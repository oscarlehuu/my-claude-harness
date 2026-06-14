# Recurrence rule for founder-gated (company/human) learnings.
#
# Repo facts are single-shot — written on first occurrence, easily reverted. But a candidate for
# `me.md` / `conventions.md` is injected into every session, so we only PROPOSE it once it has
# recurred: a near-duplicate learning must be seen >= THRESHOLD times before it reaches the inbox.
# This avoids inbox spam from one-off observations while still catching genuine, repeating patterns.
#
# Counting is deterministic and uses no new parallel store: a per-project tally
# (.claude/maestro/learnings-seen.json) records how many times each normalized learning has been
# observed. record_and_count(text) bumps the tally and returns the new count; the caller proposes
# only when that count >= THRESHOLD.
import json
import os
import re

THRESHOLD = 2  # propose to the inbox only on the 2nd (or later) near-duplicate occurrence


def norm(text):
    # The near-duplicate key: strip a leading bullet marker, lowercase, collapse whitespace, drop
    # trailing punctuation. Mirrors learned-write's dedup norm so "seen" and "queued" agree.
    t = re.sub(r"^[-*]\s+", "", (text or "").strip().lower())
    t = re.sub(r"\s+", " ", t)
    return t.rstrip(".!,;:")


def _load(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return data
    except Exception:
        pass  # absent/corrupt tally is rebuilt, never fatal
    return {}


def record_and_count(seen_path, route, text):
    """Bump the occurrence tally for (route, text) and return the new count.

    Keyed by route+normalized-text so an identical observation about the company and about the
    human are tracked separately. The write is atomic (temp + rename) so a concurrent trigger
    never reads a half file.
    """
    key = f"{route}\x1f{norm(text)}"
    tally = _load(seen_path)
    count = int(tally.get(key, 0)) + 1
    tally[key] = count
    os.makedirs(os.path.dirname(seen_path), exist_ok=True)
    tmp = f"{seen_path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(tally, f, indent=2)
    os.replace(tmp, seen_path)
    return count
