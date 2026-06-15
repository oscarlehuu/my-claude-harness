# Phase-decomposition graph helper (roadmap #9) — the canonical dependency-graph logic shared by
# task-plan.sh (scaffold-time validation + dispatch order) and task-status.sh (k/N strip + resume
# point). One implementation, imported by both via MAESTRO_SCRIPT_DIR + sys.path, mirrors the
# questions_gate.py / learned_*.py helper pattern. Two copies of a topo-sort WOULD drift — and a
# drifted graph means status names a different "next phase" than the scaffolder ordered.
#
# A phase is canonically: {id, status, deps, risk} in the state.json `phases` map, where
#   id     : kebab-case (a-z 0-9 -), unique — also the phase dir slug suffix
#   status : pending | in-progress | done
#   deps   : list of phase ids that must be `done` before this phase is dispatchable
#   risk   : low | high   (tester runs on high-risk phases + one final whole-plan pass)
import re

STATUSES = ("pending", "in-progress", "done")
RISKS = ("low", "high")
ID_RE = re.compile(r"^[a-z0-9-]+$")


class GraphError(Exception):
    """A phase dependency graph that cannot be ordered: a cycle, a dangling dep, a duplicate id, or
    a malformed phase. Callers turn this into a non-zero exit with the message — never a silent pass
    (an un-orderable graph can never be dispatched correctly)."""


def validate_id(pid):
    """A phase id must be non-empty kebab-case so it is safe as a directory slug (no path
    separators, no '.', no unicode surprises) and unambiguous as a map key. Mirrors task-init's
    slug rule — the same boundary that stops a `../escape` traversal in the scaffolded dir name."""
    if not isinstance(pid, str) or not pid or not ID_RE.match(pid):
        raise GraphError(f"invalid phase id {pid!r} — must be kebab-case (a-z 0-9 -), non-empty")


def normalize_phases(raw):
    """Coerce a list of phase specs (dicts) into {id: {status, deps, risk, ...}}, validating ids,
    statuses, risks, and rejecting duplicate ids. Unknown keys on a spec are preserved (so a spec
    can carry GOAL-body fields the scaffolder uses). Raises GraphError on any malformation.

    Accepts a list (scaffold-time spec) OR an already-built map (state.json round-trip); a map is
    validated the same way so a hand-edited state.json cannot smuggle a bad graph past status."""
    phases = {}
    if isinstance(raw, dict):
        items = list(raw.items())
    elif isinstance(raw, list):
        items = []
        for p in raw:
            if not isinstance(p, dict):
                raise GraphError(f"each phase must be an object, got {type(p).__name__}")
            pid = p.get("id")
            items.append((pid, p))
    else:
        raise GraphError("phases must be a list of phase objects or an id->phase map")

    for pid, p in items:
        validate_id(pid)
        if pid in phases:
            raise GraphError(f"duplicate phase id {pid!r}")
        if not isinstance(p, dict):
            raise GraphError(f"phase {pid!r} must be an object")
        status = p.get("status", "pending")
        if status not in STATUSES:
            raise GraphError(f"phase {pid!r}: status must be one of {STATUSES} (got {status!r})")
        risk = p.get("risk", "low")
        if risk not in RISKS:
            raise GraphError(f"phase {pid!r}: risk must be one of {RISKS} (got {risk!r})")
        deps = p.get("deps", p.get("dependencies", []))
        if not isinstance(deps, list) or not all(isinstance(d, str) for d in deps):
            raise GraphError(f"phase {pid!r}: deps must be a list of phase ids")
        entry = {k: v for k, v in p.items() if k not in ("id", "dependencies")}
        entry["status"] = status
        entry["risk"] = risk
        entry["deps"] = deps
        phases[pid] = entry
    return phases


def _check_deps_exist(phases):
    """Every dep must name a phase that exists — a dangling dep can never become `done`, so the
    dependent phase would never be dispatchable (a silent deadlock). Reject at scaffold."""
    for pid, entry in phases.items():
        for d in entry["deps"]:
            if d not in phases:
                raise GraphError(f"phase {pid!r} depends on unknown phase {d!r}")
            if d == pid:
                raise GraphError(f"phase {pid!r} depends on itself (a 1-node cycle)")


def topo_order(phases):
    """Return phase ids in a valid dependency order (a dep always precedes its dependent). Raises
    GraphError on a cycle (including a self-loop) or a dangling dep. Kahn's algorithm; ties broken
    by id for a STABLE, reproducible order (so the same spec always scaffolds the same NN numbering).

    Operates on an already-normalized {id: entry} map."""
    _check_deps_exist(phases)
    indeg = {pid: 0 for pid in phases}
    adj = {pid: [] for pid in phases}
    for pid, entry in phases.items():
        for d in entry["deps"]:
            adj[d].append(pid)
            indeg[pid] += 1
    ready = sorted(pid for pid, n in indeg.items() if n == 0)
    order = []
    while ready:
        cur = ready.pop(0)
        order.append(cur)
        newly = []
        for nxt in adj[cur]:
            indeg[nxt] -= 1
            if indeg[nxt] == 0:
                newly.append(nxt)
        # re-sort the frontier so ordering stays deterministic regardless of insertion sequence
        ready = sorted(ready + newly)
    if len(order) != len(phases):
        stuck = sorted(set(phases) - set(order))
        raise GraphError(f"dependency cycle among phases: {', '.join(stuck)}")
    return order


def next_dispatchable(phases):
    """The resume point: the first phase (in topo order) that is not `done` and whose deps are ALL
    `done`. Returns the phase id, or None if every phase is done. Raises GraphError on a bad graph
    (so resume never silently picks a phase from an un-orderable graph)."""
    order = topo_order(phases)
    for pid in order:
        entry = phases[pid]
        if entry["status"] == "done":
            continue
        if all(phases[d]["status"] == "done" for d in entry["deps"]):
            return pid
    return None


def progress(phases):
    """(done_count, total) for the `Phases: k/N done` strip."""
    total = len(phases)
    done = sum(1 for e in phases.values() if e.get("status") == "done")
    return done, total


def any_pending(phases):
    """True iff at least one phase is not `done`. Drives the commit-gate phase-vs-ship decision and
    the plan-DoD block: any non-done phase ⇒ phase mode (PHASE commit); zero ⇒ ship mode."""
    return any(e.get("status") != "done" for e in phases.values())
