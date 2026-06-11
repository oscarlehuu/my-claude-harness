#!/usr/bin/env bash
# Drop a task into the HQ queue — the contract between the founder (or a future
# trigger) and the team. One JSON file per task; team-board.sh and Oculus read them.
#
# Usage: queue-add.sh "<title>" [--repo <name>] [--tier light|standard|full] [--notes "<text>"]
set -eu

title="${1:?usage: queue-add.sh \"<title>\" [--repo <name>] [--tier <t>] [--notes <text>]}"
shift
repo=""; tier=""; notes=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:?}"; shift 2 ;;
    --tier) tier="${2:?}"; shift 2 ;;
    --notes) notes="${2:?}"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done
case "$tier" in ""|light|standard|full) : ;; *) echo "invalid tier '$tier'" >&2; exit 1 ;; esac

hq="${MAESTRO_HQ:-}"
if [ -z "$hq" ] && [ -f "$HOME/.claude/maestro-hq" ]; then
  hq="$(cat "$HOME/.claude/maestro-hq")"
fi
[ -z "$hq" ] || [ ! -d "$hq" ] && { echo "no HQ found (set \$MAESTRO_HQ or ~/.claude/maestro-hq)" >&2; exit 1; }

mkdir -p "$hq/board/queue"

MAESTRO_Q_TITLE="$title" MAESTRO_Q_REPO="$repo" MAESTRO_Q_TIER="$tier" MAESTRO_Q_NOTES="$notes" \
python3 - "$hq" <<'PY'
import datetime, json, os, re, sys

hq = sys.argv[1]
title = os.environ["MAESTRO_Q_TITLE"]
now = datetime.datetime.now(datetime.timezone.utc)
slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:40] or "task"
tid = f"{now.strftime('%y%m%d-%H%M%S')}-{slug}"
task = {
    "id": tid, "title": title, "status": "queued",
    "repo": os.environ.get("MAESTRO_Q_REPO") or None,
    "tier": os.environ.get("MAESTRO_Q_TIER") or None,
    "notes": os.environ.get("MAESTRO_Q_NOTES") or None,
    "created": now.isoformat().replace("+00:00", "Z"),
}
path = os.path.join(hq, "board", "queue", f"{tid}.json")
tmp = f"{path}.{os.getpid()}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump({k: v for k, v in task.items() if v is not None}, f, indent=2)
os.replace(tmp, path)
print(f"queued: {tid}")
PY
