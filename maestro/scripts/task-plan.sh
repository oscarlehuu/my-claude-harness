#!/usr/bin/env bash
# Scaffold a phased-mode plan (roadmap #9): decompose a large/project GOAL handoff into N
# self-contained, independently-verifiable phase files under .claude/maestro/<slug>/phases/.
#
# Usage: task-plan.sh [--slug <slug>] <spec.json>
#
# The spec is a JSON file describing the phases (a small, declarative, testable input — args alone
# cannot carry multi-section GOAL bodies). Shape:
#   { "phases": [
#       { "id": "phase-id", "short": "dir-suffix"?, "deps": ["other-id", ...]?, "risk": "low|high"?,
#         "goal": "...", "context": "...", "deliverables": "...",
#         "constraints": "...", "acceptance": "...", "verify": "..." },
#       ...
#   ] }
# Only `id` is required per phase; everything else has a safe default. `short` defaults to the id;
# `deps` to []; `risk` to low. The GOAL-body fields serialize into each phase.md (the Maestro GOAL
# shape — GOAL / CONTEXT / DELIVERABLES / CONSTRAINTS / ACCEPTANCE — NOT claudekit's 7 sections).
#
# For each phase, in dependency (topo) order, it creates:
#   phases/phase-NN-<short>/phase.md        the serialized GOAL handoff + frontmatter
#                                           (id · status · dependencies[] · verify · risk)
#   phases/phase-NN-<short>/edge-cases.md   empty (per-phase artifact scoping — the Wave-1 race fix:
#                                           no shared edge-cases.md across phases)
#   phases/phase-NN-<short>/verdicts/       empty dir for this phase's judge reports
# …and seeds the `phases` map into state.json so commit-gate + task-status read phase status.
#
# REFUSALS (all exit non-zero, write NOTHING — validated up front so a bad spec never half-scaffolds):
#   - a dependency cycle (incl. self-loop), a dangling dep, a duplicate phase id, a malformed phase
#   - a phases/ tree already present (re-scaffold would wipe in-flight status + edge-cases)
#   - an unreadable/malformed spec file
#   - an unreadable / corrupt / non-object state.json (read+validated BEFORE any dir is created, so a
#     corrupt ledger can never leave an orphan phases/ tree the re-plan guard then refuses to recover)
# JSON is always written by python; the state.json write is atomic (temp + rename), matching the
# house rule and the rest of the ledger scripts.
set -eu

# Resolve this script's own real dir (readlink loop, the harness idiom) so we can import the sibling
# phases_lib.py (the shared graph/topo helper) regardless of cwd or symlinks.
_src="${BASH_SOURCE[0]}"; while [ -L "$_src" ]; do _src="$(readlink "$_src")"; done
SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"

root="${CLAUDE_PROJECT_DIR:-$PWD}"
slug=""
if [ "${1:-}" = "--slug" ]; then slug="${2:?--slug needs a value}"; shift 2; fi
spec="${1:?usage: task-plan.sh [--slug <slug>] <spec.json>}"

if [ -z "$slug" ]; then
  [ -f "$root/.claude/maestro/active" ] && slug="$(cat "$root/.claude/maestro/active")"
fi
[ -z "$slug" ] && { echo "no active task — run task-init.sh first or pass --slug" >&2; exit 1; }

dir="$root/.claude/maestro/$slug"
[ -f "$dir/state.json" ] && [ -d "$dir" ] || { echo "no ledger for '$slug' at $dir" >&2; exit 1; }
[ -f "$spec" ] || { echo "spec file not found: $spec" >&2; exit 1; }

# Refuse to clobber an existing phases/ tree (mirrors task-init refusing a duplicate slug). A
# re-scaffold would wipe in-flight phase status and per-phase edge-cases — destructive, never silent.
if [ -d "$dir/phases" ]; then
  echo "phases/ already scaffolded for '$slug' — resume it, or remove $dir/phases to re-plan" >&2
  exit 1
fi

MAESTRO_SCRIPT_DIR="$SCRIPT_DIR" python3 - "$dir" "$spec" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["MAESTRO_SCRIPT_DIR"])
import phases_lib as ph  # shared graph/topo helper — never re-implemented here

task_dir, spec_path = sys.argv[1], sys.argv[2]

# --- load + validate the spec WHOLE before writing anything (no half-scaffold) -------------------
try:
    with open(spec_path, "r", encoding="utf-8") as f:
        spec = json.load(f)
except (ValueError, OSError) as e:
    sys.exit(f"spec is unreadable ({e}) — fix the JSON in {spec_path}")

if not isinstance(spec, dict) or "phases" not in spec:
    sys.exit('spec must be a JSON object with a "phases" array')
raw = spec["phases"]
if not isinstance(raw, list) or not raw:
    sys.exit('spec "phases" must be a non-empty array')

# normalize_phases + topo_order raise GraphError on a cycle, dangling dep, duplicate id, bad id, or
# any malformed phase — every refusal happens HERE, before a single dir is created.
try:
    phases = ph.normalize_phases(raw)
    order = ph.topo_order(phases)
except ph.GraphError as e:
    sys.exit(f"invalid phase graph: {e}")

# --- load + validate state.json WHOLE before writing anything (all-or-nothing scaffold) ----------
# Read it HERE, before any os.makedirs below: a corrupt / unreadable / non-object ledger must abort
# with a clean message and leave NOTHING on disk. (Reading it only at seed time — after the dirs
# exist — left an orphan phases/ tree the re-plan guard then refused to recover without a manual rm.)
# The parsed object is reused for the atomic seed write at the end — one read, no second open.
state_path = os.path.join(task_dir, "state.json")
try:
    with open(state_path, "r", encoding="utf-8") as f:
        state = json.load(f)
except (ValueError, OSError) as e:
    sys.exit(f"state.json is unreadable/corrupt ({e}) — fix it before planning ({state_path})")
if not isinstance(state, dict):
    sys.exit(f"state.json must be a JSON object — refusing to scaffold ({state_path})")

# carry the GOAL-body fields keyed by id (normalize_phases preserved unknown spec keys on each entry)
def body_field(pid, key, default=""):
    v = phases[pid].get(key, default)
    return v if isinstance(v, str) else default

# --- build the phases map (state.json) + the per-phase dir plan -----------------------------------
# NN numbering follows topo order so the lowest-numbered phase is always dispatchable first.
plan = []   # (nn, dirname, pid)
phases_map = {}
seen_dirs = set()
for i, pid in enumerate(order, start=1):
    entry = phases[pid]
    short = entry.get("short", pid)
    if not isinstance(short, str) or not ph.ID_RE.match(short):
        sys.exit(f"phase {pid!r}: 'short' must be kebab-case (a-z 0-9 -) — it is a directory name")
    nn = f"{i:02d}"
    dirname = f"phase-{nn}-{short}"
    if dirname in seen_dirs:
        sys.exit(f"phase {pid!r}: directory name {dirname!r} collides with another phase's")
    seen_dirs.add(dirname)
    plan.append((nn, dirname, pid))
    phases_map[pid] = {"status": "pending", "deps": entry["deps"], "risk": entry["risk"]}

# --- write: per-phase dirs + files, then seed state.phases (atomic) -------------------------------
phases_root = os.path.join(task_dir, "phases")
os.makedirs(phases_root, exist_ok=False)   # exist_ok=False: the bash guard already proved it absent

GOAL_SECTIONS = [
    ("GOAL", "goal"),
    ("CONTEXT TO READ FIRST", "context"),
    ("DELIVERABLES", "deliverables"),
    ("CONSTRAINTS / NON-GOALS", "constraints"),
    ("ACCEPTANCE / VERIFY", "acceptance"),
]

for nn, dirname, pid in plan:
    pdir = os.path.join(phases_root, dirname)
    os.makedirs(os.path.join(pdir, "verdicts"), exist_ok=False)
    entry = phases[pid]
    verify = body_field(pid, "verify")
    deps = entry["deps"]
    # frontmatter: id · status · dependencies[] · verify · risk (status starts pending; the hook
    # reads state.json as the authority — frontmatter is the human/dispatch-time copy).
    fm = ["---",
          f"id: {pid}",
          "status: pending",
          "dependencies: [" + ", ".join(deps) + "]",
          f"verify: {verify}",
          f"risk: {entry['risk']}",
          "---", ""]
    lines = fm + [f"# Phase {nn}: {pid}", ""]
    for title, key in GOAL_SECTIONS:
        lines.append(f"## {title}")
        lines.append(body_field(pid, key) or "_(to be filled in by the CTO at dispatch)_")
        lines.append("")
    with open(os.path.join(pdir, "phase.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines).rstrip() + "\n")
    # per-phase edge-cases.md is intentionally EMPTY — the developer dispatched on THIS phase writes
    # its own ledger here (per-phase artifact scoping; the Wave-1 shared-edge-cases race must not return).
    with open(os.path.join(pdir, "edge-cases.md"), "w", encoding="utf-8") as f:
        f.write(f"# Edge-case ledger — {pid}\n\n_(the developer dispatched on this phase fills this in)_\n")

# seed state.phases atomically (the hook authority); preserve every other key byte-for-byte. `state`
# was read + validated at the TOP (before any dir existed) — reuse it; do NOT reopen state.json here.
state["phases"] = phases_map
import datetime
state["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
tmp = f"{state_path}.{os.getpid()}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
os.replace(tmp, state_path)

# breadcrumb in the log (same jsonl the other scripts append to)
with open(os.path.join(task_dir, "log.jsonl"), "a", encoding="utf-8") as f:
    f.write(json.dumps({"ts": state["updatedAt"], "event": "phases_scaffolded",
                        "count": len(plan), "order": [p[2] for p in plan]},
                       separators=(",", ":")) + "\n")

print(f"scaffolded {len(plan)} phase(s) under {phases_root}:")
for nn, dirname, pid in plan:
    print(f"  {dirname}  (deps: {', '.join(phases[pid]['deps']) or 'none'}, risk: {phases[pid]['risk']})")
PY
