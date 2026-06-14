#!/usr/bin/env bash
# Deterministic writer for continual-learning output. The safety invariants live HERE,
# in bash/python — never in the consolidator's LLM discretion. The consolidator only DECIDES
# what is durable and how to route it; this script is the ONLY thing that touches a file.
#
# Two subcommands:
#   section <agents-md-path> <heading> <bullet-text>
#       Append a bullet to a named "## Learned ..." section of an AGENTS.md file.
#       - REFUSES off-limits targets (contract AGENTS.md, conventions.md, me.md, charter/, rules/,
#         ~/.claude/AGENTS.md) deterministically via learned_write_guard.py — never LLM discretion
#       - refuses any heading that is not exactly "## Learned ..."
#       - creates the section at end-of-file if missing (touching nothing else)
#       - dedups by normalized text (idempotent); soft cap of 12 bullets per section
#       - touches ZERO lines outside the target section (byte-identical elsewhere)
#
#   inbox <company|human> <proposal-text>
#       Append a routed, founder-gated proposal to .claude/maestro/learnings-inbox.md.
#       Company/human learnings NEVER auto-write conventions.md / me.md / the contract —
#       they queue here for the machine-proposes / founder-nods flow.
#       RECURRENCE: a me.md/conventions candidate is only QUEUED once a near-duplicate has been
#       seen >= 2 times (learned_recurrence.py) — a one-off observation is recorded but not
#       proposed, so the inbox does not fill with single-shot noise. The exit code is still 0
#       (the call succeeded); it just prints "recorded (seen N) — below threshold, not queued".
#
# BOTH sinks run a deterministic secrets/PII scrub (learned_scrub.py) FIRST: a learning that
# looks like it carries a credential is DROPPED before any write (exit non-zero, nothing written).
#
# Exit non-zero on a refused/invalid request; the caller treats that as "did not write".
set -eu

# Resolve this script's own real directory (readlink loop, the harness idiom) so the section
# subcommand can import its sibling off-limits guard regardless of cwd or symlinks.
_src="${BASH_SOURCE[0]}"; while [ -L "$_src" ]; do _src="$(readlink "$_src")"; done
SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"

root="${CLAUDE_PROJECT_DIR:-$PWD}"
sub="${1:?usage: learned-write.sh <section|inbox> ...}"
shift

case "$sub" in
  section)
    file="${1:?usage: learned-write.sh section <agents-md-path> <heading> <bullet>}"
    heading="${2:?missing heading}"
    bullet="${3:?missing bullet text}"
    MAESTRO_SCRIPT_DIR="$SCRIPT_DIR" python3 - "$file" "$heading" "$bullet" <<'PY'
import os, re, sys

path, heading, bullet = sys.argv[1], sys.argv[2], sys.argv[3]
CAP = 12

# Deterministic off-limits guard (NOT prose/LLM discretion). Refuse globally-injected contract /
# policy targets BEFORE the file is read or created, so a denied path is left byte-identical (and an
# absent path is never created). The rules live in learned_write_guard.py beside this script.
sys.path.insert(0, os.environ["MAESTRO_SCRIPT_DIR"])
from learned_write_guard import off_limits_reason  # noqa: E402
from learned_scrub import is_secret_like  # noqa: E402

_reason = off_limits_reason(path)
if _reason is not None:
    sys.exit(f"refusing to write to off-limits path {path!r}: {_reason}")

# Secrets scrub: a learning that looks like it carries a credential is dropped before any write,
# BEFORE the target is read or created, so a refused secret leaves the file byte-identical.
if is_secret_like(bullet):
    sys.exit("refusing to write a learning that looks like it contains a secret/credential")

# Owned-sections-only: the writer may only ever touch a "## Learned ..." section.
# Anything else is off-limits prose and is refused — a hard, non-LLM invariant.
if not re.match(r"^## Learned(\b|$)", heading.strip()):
    sys.exit(f"refusing to write a non-Learned section: {heading!r}")
heading = heading.strip()

# A bullet is exactly one line. Collapse whitespace/newlines so distilled text can never
# forge a heading, span lines, or smuggle markup into the file structure.
def one_line(t):
    return re.sub(r"\s+", " ", t.replace("\n", " ").replace("\r", " ")).strip()

bullet = one_line(bullet)
if not bullet:
    sys.exit("refusing to write an empty bullet")
# strip any author-supplied leading marker; we own the "- " prefix
bullet = re.sub(r"^[-*]\s+", "", bullet)

def norm(t):
    # dedup key: lowercase, strip a leading bullet marker, collapse ws, drop trailing punctuation
    t = re.sub(r"^[-*]\s+", "", t.strip().lower())
    t = re.sub(r"\s+", " ", t)
    return t.rstrip(".!,;:")

lines = []
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().split("\n")

# Locate the target section: from its exact heading line to the next "## " heading (or EOF).
# Matching the FULL heading text (not a prefix) keeps two distinct "## Learned ..." sections
# from colliding.
start = None
for i, ln in enumerate(lines):
    if ln.strip() == heading:
        start = i
        break

if start is None:
    # Create the section at end-of-file. Touch nothing above: append a blank separator
    # only if the file is non-empty and does not already end blank.
    block = []
    if lines and not (len(lines) == 1 and lines[0] == ""):
        if lines[-1].strip() != "":
            block.append("")
    block.append(heading)
    block.append("")
    block.append(f"- {bullet}")
    new_lines = lines + block if lines != [""] else [heading, "", f"- {bullet}"]
    out = "\n".join(new_lines)
    if not out.endswith("\n"):
        out += "\n"
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(out)
    os.replace(tmp, path)
    print(f"created section {heading!r} and added 1 bullet")
    sys.exit(0)

# Find the end of the section (next "## " heading at col 0, or EOF).
end = len(lines)
for j in range(start + 1, len(lines)):
    if lines[j].startswith("## "):
        end = j
        break

section = lines[start:end]
existing = [norm(ln) for ln in section if ln.lstrip().startswith("- ")]
if norm(bullet) in existing:
    print(f"duplicate — {heading!r} unchanged ({len(existing)} bullets)")
    sys.exit(0)
if len(existing) >= CAP:
    sys.exit(f"section {heading!r} at cap ({CAP}) — refusing to add; distill or prune first")

# Insert the new bullet AFTER the last existing bullet (or right after the heading's blank
# line if there are none yet). Everything outside [start:end] is left byte-identical.
insert_at = None
for k in range(len(section) - 1, -1, -1):
    if section[k].lstrip().startswith("- "):
        insert_at = k + 1
        break
if insert_at is None:
    # no bullets yet — insert after the heading and a single blank line
    insert_at = 1
    if len(section) > 1 and section[1].strip() == "":
        insert_at = 2
    else:
        section.insert(1, "")
        insert_at = 2

section.insert(insert_at, f"- {bullet}")
new_lines = lines[:start] + section + lines[end:]
out = "\n".join(new_lines)
# Preserve the file's trailing-newline state: AGENTS.md files end with a newline.
tmp = f"{path}.{os.getpid()}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(out)
os.replace(tmp, path)
print(f"added 1 bullet to {heading!r} ({len(existing) + 1} bullets)")
PY
    ;;

  inbox)
    route="${1:?usage: learned-write.sh inbox <company|human> <proposal>}"
    text="${2:?missing proposal text}"
    inbox="$root/.claude/maestro/learnings-inbox.md"
    seen="$root/.claude/maestro/learnings-seen.json"
    case "$route" in
      company|human) : ;;
      *) echo "invalid route '$route' (company|human)" >&2; exit 1 ;;
    esac
    MAESTRO_SCRIPT_DIR="$SCRIPT_DIR" python3 - "$inbox" "$route" "$text" "$seen" <<'PY'
import datetime, os, re, sys

inbox, route, text, seen = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = re.sub(r"\s+", " ", text.replace("\n", " ")).strip()
if not text:
    sys.exit("refusing to queue an empty proposal")

# Secrets scrub before anything else — a credential-shaped proposal never even gets counted.
sys.path.insert(0, os.environ["MAESTRO_SCRIPT_DIR"])
from learned_scrub import is_secret_like  # noqa: E402
from learned_recurrence import record_and_count, THRESHOLD  # noqa: E402

if is_secret_like(text):
    sys.exit("refusing to queue a proposal that looks like it contains a secret/credential")

# Recurrence gate: me.md/conventions candidates are only proposed once a near-duplicate has
# recurred. Record this occurrence; below the threshold we record but do NOT queue (anti-spam).
count = record_and_count(seen, route, text)
if count < THRESHOLD:
    print(f"recorded {route} learning (seen {count}) — below recurrence threshold, not queued")
    sys.exit(0)

ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
os.makedirs(os.path.dirname(inbox), exist_ok=True)

header = "# Learnings inbox — founder-gated proposals\n\n" \
         "> Machine proposes, founder nods, the CTO writes the line. Company learnings route to\n" \
         "> HQ conventions.md; human learnings route to me.md — neither is auto-written. Clear an\n" \
         "> entry once the founder has decided.\n\n"

created = not os.path.exists(inbox)
# Dedup: do not queue a proposal whose normalized text already sits in the inbox. Existing lines
# carry a "[route] (YYYY-MM-DD) " prefix we own — strip it before comparing so the dedup matches on
# the LEARNING text, not the prefix. Without this strip a recurring learning (3rd+ occurrence) would
# pass the recurrence gate and append a duplicate inbox line.
_PREFIX = re.compile(r"^\[[a-z]+\]\s*\([0-9]{4}-[0-9]{2}-[0-9]{2}\)\s*")
def norm(t):
    return re.sub(r"\s+", " ", _PREFIX.sub("", t.strip()).lower()).rstrip(".!,;:")

if not created:
    with open(inbox, "r", encoding="utf-8") as f:
        body = f.read()
    if norm(text) in {norm(l[2:]) for l in body.split("\n") if l.startswith("- ")}:
        print("duplicate proposal — inbox unchanged")
        sys.exit(0)

with open(inbox, "a", encoding="utf-8") as f:
    if created:
        f.write(header)
    f.write(f"- [{route}] ({ts}) {text}\n")
print(f"queued {route} proposal in {inbox}")
PY
    ;;

  *)
    echo "unknown subcommand '$sub' (section|inbox)" >&2
    exit 1
    ;;
esac
