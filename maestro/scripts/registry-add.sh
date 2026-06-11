#!/usr/bin/env bash
# Register a repo into the HQ registry — the one-command line-writer behind
# "machine proposes, founder nods, CTO writes the line." The SessionStart hook
# (maestro-engage.sh) proposes; this script is what you run to actually add the
# repo. It only edits HQ's registry.json — NO git operations (the CTO commits HQ).
#
# Usage: registry-add.sh [<path>] [--name <name>]
#   <path>   repo to register; defaults to the git toplevel of cwd (or cwd if not a repo).
#   --name   display name on the board; defaults to the basename of the resolved path.
#
# HQ resolution: $MAESTRO_HQ env var, else the path in ~/.claude/maestro-hq.
set -eu

path=""; name=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="${2:?}"; shift 2 ;;
    -*) echo "unknown flag: $1" >&2; exit 1 ;;
    *) [ -z "$path" ] && { path="$1"; shift; } || { echo "unexpected arg: $1" >&2; exit 1; } ;;
  esac
done

# Default path: git toplevel of cwd, else cwd.
if [ -z "$path" ]; then
  path="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

hq="${MAESTRO_HQ:-}"
if [ -z "$hq" ] && [ -f "$HOME/.claude/maestro-hq" ]; then
  hq="$(cat "$HOME/.claude/maestro-hq")"
fi
[ -z "$hq" ] || [ ! -d "$hq" ] && { echo "no HQ found (set \$MAESTRO_HQ or ~/.claude/maestro-hq)" >&2; exit 1; }

MAESTRO_R_PATH="$path" MAESTRO_R_NAME="$name" \
python3 - "$hq" <<'PY'
import json, os, sys

hq = sys.argv[1]
raw = os.environ["MAESTRO_R_PATH"]

target = os.path.realpath(os.path.expanduser(raw))
if not os.path.isdir(target):
    sys.exit(f"not a directory: {raw}")

name = os.environ.get("MAESTRO_R_NAME") or os.path.basename(target)

# Store ~-prefixed when under $HOME, matching existing registry entries.
home = os.path.realpath(os.path.expanduser("~"))
if target == home or target.startswith(home + os.sep):
    stored = "~" + target[len(home):]
else:
    stored = target

reg_path = os.path.join(hq, "registry.json")
if os.path.exists(reg_path):
    try:
        with open(reg_path, encoding="utf-8") as f:
            reg = json.load(f)
    except Exception as e:
        sys.exit(f"registry.json unreadable, refusing to overwrite: {e}")
    if not isinstance(reg, dict) or not isinstance(reg.get("repos"), list):
        sys.exit("registry.json is not {\"repos\": [...]}, refusing to overwrite")
else:
    reg = {"repos": []}

# Dedupe by expanded + realpath'd path, so ~/x, ./x and /abs/x all collapse to one.
for entry in reg["repos"]:
    ep = os.path.realpath(os.path.expanduser(entry.get("path", "")))
    if ep == target:
        print(f"already registered: {entry.get('name', name)}")
        sys.exit(0)

reg["repos"].append({"name": name, "path": stored})

tmp = f"{reg_path}.{os.getpid()}.tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(reg, f, indent=2)
os.replace(tmp, reg_path)
print(f"registered: {name} -> {stored}")
PY
