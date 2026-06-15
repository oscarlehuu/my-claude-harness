# Open-Questions gate — the canonical, deterministic blocking predicate and questions.json I/O.
#
# Why a shared helper (not two copies in two heredocs): the blocking rule is the heart of the gate
# and lives in TWO places — task-status.sh (renders the blocker) and task-record.sh (refuses
# gate1_approved). Two copies WOULD drift (that is exactly the doc-drift bug class the suite already
# guards against), and a drifted predicate means status says "clean" while the gate refuses, or
# worse. One function, imported by both, is the single source of truth. Mirrors the learned_*.py
# helper pattern beside learned-write.sh (imported via MAESTRO_SCRIPT_DIR + sys.path).
#
# A question is canonically: {id, text, route, cost, status, resolution, ts}.
#   route  : code | history | founder | team | planner   (reuses blind-mode routing + planner)
#   cost   : low | med | high                            (cost-if-wrong; default high = safe)
#   status : open | resolved | answered                  (resolved = CTO/scout investigation;
#                                                          answered = founder/team replied)
import json
import os

ROUTES = ("code", "history", "founder", "team", "planner")
COSTS = ("low", "med", "high")
STATUSES = ("open", "resolved", "answered")
DEFAULT_COST = "high"  # torn high-vs-low → high → block (mirrors the tier ratchet's tie-breaker)


def questions_path(task_dir):
    return os.path.join(task_dir, "questions.json")


class CorruptSheet(Exception):
    """questions.json exists but is not readable as a list of question objects.

    A corrupt sheet must NEVER fail open into "clean" — an unreadable ledger of unknowns is itself
    an unknown. Callers turn this into a hard blocker (the safe direction), not a silent pass.
    """


def load(task_dir):
    """Return the list of questions, or [] if the sheet is absent (absent == trivially clean).

    Raises CorruptSheet if the file exists but is malformed, so the caller blocks rather than
    silently treating a broken sheet as empty.
    """
    path = questions_path(task_dir)
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (ValueError, OSError) as e:
        raise CorruptSheet(str(e))
    if not isinstance(data, list):
        raise CorruptSheet("questions.json is not a JSON array")
    # Every element must be a question object (dict). A hand-corrupted sheet — e.g. [null], ["x"],
    # [5] — is valid JSON and a valid list, so it slips past the check above, but is_blocking() would
    # then call q.get(...) on a non-dict and raise AttributeError deep in the caller, ESCAPING the
    # caller's `except CorruptSheet` and printing a Python traceback. A corrupt sheet must fail closed
    # with the SAME clean operator message a syntactically-broken file gets, never a stack trace, so
    # we degrade it to the existing CorruptSheet fail-closed path here.
    if not all(isinstance(q, dict) for q in data):
        raise CorruptSheet("questions.json contains a non-object entry (each question must be a JSON object)")
    return data


def is_blocking(q):
    """The deterministic blocking predicate — the heart of the gate.

    BLOCKS iff:
      (route in {code, history}  AND status == "open")                          # must investigate
      OR (route in {founder, team} AND cost == "high" AND status != "answered") # founder must answer

    Non-blocking, by construction:
      - any planner-routed question (resolving it is the planner's job, not a pre-plan blocker)
      - founder/team low- or med-cost still open (assume-unless-vetoed, blind-mode style)
      - anything resolved or answered

    Note the founder/high branch keys on status != "answered": a high-cost founder question must be
    *answered* to clear it. Marking it merely "resolved" (CTO investigation) does NOT clear a
    high-cost founder question — the founder decision was the whole point, so the gate holds until a
    real answer lands. This exact wording is from the locked design (evolution-roadmap §2).
    """
    route = q.get("route")
    status = q.get("status")
    cost = q.get("cost")
    if route in ("code", "history") and status == "open":
        return True
    if route in ("founder", "team") and cost == "high" and status != "answered":
        return True
    return False


def blocking(questions):
    """All blocking questions, in sheet order."""
    return [q for q in questions if is_blocking(q)]


def counts(questions):
    """(open, resolved, answered) tallies for the status summary line."""
    o = sum(1 for q in questions if q.get("status") == "open")
    r = sum(1 for q in questions if q.get("status") == "resolved")
    a = sum(1 for q in questions if q.get("status") == "answered")
    return o, r, a
