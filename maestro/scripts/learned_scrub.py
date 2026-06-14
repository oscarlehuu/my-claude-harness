# Deterministic secrets/PII scrub for the continual-learning consolidator.
#
# A distilled learning must NEVER carry a live secret into a durable sink (an AGENTS.md
# `## Learned` section or the founder inbox) — those files are read, committed, and injected.
# The scrub lives in code, not in the consolidator's prose discretion, so a secret cannot be
# reasoned past. `is_secret_like(text)` returns True when the text looks like it contains a
# credential; the caller then DROPS the learning before any write.
#
# This errs toward dropping: a learning that merely *mentions* a token is rarely durable, so a
# false positive costs one dropped bullet, while a false negative leaks a secret into git. The
# patterns target the shapes secrets actually take, not every word — ordinary prose passes.
import re

# Assignment-style leaks: KEY=..., api_token: ..., DB_PASSWORD=..., STRIPE_SECRET_KEY=....
# Real env-var secrets are overwhelmingly PREFIX_KEYWORD=value (DB_PASSWORD, API_TOKEN,
# AWS_SECRET_ACCESS_KEY): the keyword sits inside a longer underscore/dash name. A leading `\b`
# would NOT anchor there — `_` is a word char, so `\bpassword` never matched inside `DB_PASSWORD`,
# and short values slipped the entropy net too. So we allow an optional `[\w-]` name PREFIX that
# ends in a `_`/`-` separator and an optional `[\w-]` name SUFFIX, both glued to the keyword, then
# the `[:=]` value. The (?<![\w-]) lookbehind keeps the prefix from starting mid-word, and the
# keyword set stays exactly the one that reliably precedes a credential — bare `password=...` /
# `token: ...` still match, while ordinary `port=8080` / `key=value` (no secret keyword) do not.
_ASSIGN = re.compile(
    r"(?i)(?<![\w-])(?:[\w-]*[_-])?(?:api[_-]?key|secret|token|password|passwd|pwd|credential|"
    r"client[_-]?secret|access[_-]?key|private[_-]?key|auth[_-]?token|bearer)(?:[_-][\w-]*)?"
    r"\s*[:=]\s*\S+"
)
# Common provider key prefixes followed by a real key body (length-bounded so a bare prefix word
# in prose does not trip it).
_PREFIXED = re.compile(
    r"(?i)\b(?:sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|"
    r"github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{12,}|"
    r"AIza[0-9A-Za-z_-]{20,})\b"
)
# A "Bearer <token>" header value.
_BEARER = re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._\-]{16,}\b")
# A long unbroken high-entropy run (hex or base64-ish), the shape of a raw key/hash. A 32+
# run with no spaces is overwhelmingly a secret, not a word.
_LONG_RUN = re.compile(r"\b[A-Za-z0-9+/_-]{32,}={0,2}\b")
# A PEM / private-key block header.
_PEM = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")


def is_secret_like(text):
    if not text:
        return False
    for rx in (_ASSIGN, _PREFIXED, _BEARER, _PEM):
        if rx.search(text):
            return True
    # The long-run check is last and slightly narrower: require it to look key-ish (contains a
    # digit AND a letter) so a long all-letter word or a hyphenated slug does not trip it.
    for m in _LONG_RUN.finditer(text):
        tok = m.group(0)
        if any(c.isdigit() for c in tok) and any(c.isalpha() for c in tok):
            return True
    return False
