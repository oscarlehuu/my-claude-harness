#!/usr/bin/env bash
# Render the team standup board: HQ queue + every registered repo's task ledgers.
# This is the chief-of-staff's opening ritual — run it at HQ session start and
# deliver the standup from its output. Read-only unless --write.
#
# Usage: team-board.sh [--write]
#   --write   also render BOARD.md in the HQ (human view; source of truth stays
#             the queue JSON files + per-repo ledgers, which Oculus reads directly)
#
# HQ resolution: $MAESTRO_HQ env var, else the path in ~/.claude/maestro-hq.
set -eu

hq="${MAESTRO_HQ:-}"
if [ -z "$hq" ] && [ -f "$HOME/.claude/maestro-hq" ]; then
  hq="$(cat "$HOME/.claude/maestro-hq")"
fi
[ -z "$hq" ] || [ ! -d "$hq" ] && { echo "no HQ found (set \$MAESTRO_HQ or ~/.claude/maestro-hq)" >&2; exit 1; }

write_board=0
[ "${1:-}" = "--write" ] && write_board=1

python3 - "$hq" "$write_board" <<'PY'
import datetime, json, os, sys

hq, write_board = sys.argv[1], sys.argv[2] == "1"
now = datetime.datetime.now(datetime.timezone.utc)

def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None

def age(ts):
    try:
        dt = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        h = int((now - dt).total_seconds() // 3600)
        return f"{h}h" if h < 48 else f"{h // 24}d"
    except Exception:
        return "?"

# --- queue (HQ-local, not yet started) -------------------------------------------
queue = []
qdir = os.path.join(hq, "board", "queue")
if os.path.isdir(qdir):
    for f in sorted(os.listdir(qdir)):
        if f.endswith(".json"):
            t = load_json(os.path.join(qdir, f))
            if t and t.get("status") == "queued":
                queue.append(t)

# --- registered repos' ledgers -----------------------------------------------------
registry = load_json(os.path.join(hq, "registry.json")) or {}
active, recent_done, needs_you = [], [], []
for repo in registry.get("repos", []):
    name, path = repo.get("name", "?"), os.path.expanduser(repo.get("path", ""))
    mdir = os.path.join(path, ".claude", "maestro")
    if not os.path.isdir(mdir):
        continue
    for slug in sorted(os.listdir(mdir)):
        s = load_json(os.path.join(mdir, slug, "state.json"))
        if not s:
            continue
        lv = s.get("lastVerify")
        verify = "—" if not lv else ("green" if lv.get("exit") == 0 else f"RED({lv.get('exit')})")
        row = {"repo": name, "slug": s.get("slug", slug), "tier": s.get("tier"),
               "state": s.get("state"), "round": s.get("round"), "verify": verify,
               "updated": s.get("updatedAt", "")}
        if s.get("state") in ("done",):
            try:
                upd = datetime.datetime.fromisoformat(row["updated"].replace("Z", "+00:00"))
                if (now - upd).total_seconds() < 48 * 3600:
                    recent_done.append(row)
            except Exception:
                pass
        else:
            active.append(row)
            if s.get("state") == "escalated" or verify.startswith("RED"):
                needs_you.append(row)

# --- render -------------------------------------------------------------------------
lines = [f"TEAM BOARD — {now.strftime('%Y-%m-%d %H:%M')}Z", ""]
lines.append(f"NEEDS YOU ({len(needs_you)}):")
for r in needs_you or []:
    lines.append(f"  ! {r['repo']}/{r['slug']} — {r['state']}, verify {r['verify']} ({age(r['updated'])} ago)")
if not needs_you:
    lines.append("  (nothing blocked on you)")
lines.append("")
lines.append(f"IN PROGRESS ({len(active)}):")
for r in active:
    lines.append(f"  - {r['repo']}/{r['slug']} — tier {r['tier']}, {r['state']}, round {r['round']}, verify {r['verify']}")
if not active:
    lines.append("  (floor is clear)")
lines.append("")
lines.append(f"QUEUE ({len(queue)}):")
for t in queue:
    extra = " ".join(filter(None, [f"[{t.get('tier')}]" if t.get("tier") else "",
                                   f"({t.get('repo')})" if t.get("repo") else ""]))
    lines.append(f"  - {t.get('id')}: {t.get('title')} {extra}".rstrip())
if not queue:
    lines.append("  (empty)")
lines.append("")
lines.append(f"DONE (last 48h: {len(recent_done)}):")
for r in recent_done:
    lines.append(f"  v {r['repo']}/{r['slug']} — tier {r['tier']} ({age(r['updated'])} ago)")
if not recent_done:
    lines.append("  (none)")

out = "\n".join(lines)
print(out)

if write_board:
    path = os.path.join(hq, "BOARD.md")
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# Team Board\n\n```\n" + out + "\n```\n")
    os.replace(tmp, path)
PY
