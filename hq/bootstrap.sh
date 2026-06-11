#!/usr/bin/env bash
# Run INSIDE a cloned HQ repo on a new machine: writes the ~/.claude pointer and
# validates the registry. Idempotent; copy this into your HQ or run from the harness.
set -eu

hq="$PWD"
[ -f "$hq/registry.json" ] || { echo "this does not look like an HQ (no registry.json)" >&2; exit 1; }

mkdir -p "$HOME/.claude"
printf '%s' "$hq" > "$HOME/.claude/maestro-hq"
echo "pointer: ~/.claude/maestro-hq -> $hq"

mkdir -p "$hq/board/queue" "$hq/journal" "$hq/knowledge"

python3 - "$hq" <<'PY'
import json, os, sys
hq = sys.argv[1]
try:
    reg = json.load(open(os.path.join(hq, "registry.json")))
except Exception as e:
    sys.exit(f"registry.json unreadable: {e}")
missing = [r.get("path", "?") for r in reg.get("repos", [])
           if not os.path.isdir(os.path.expanduser(r.get("path", "")))]
if missing:
    print("registry paths missing on this machine (clone them or edit registry.json):")
    for p in missing:
        print(f"  - {p}")
else:
    print(f"registry: {len(reg.get('repos', []))} repo(s), all present")
PY

echo "HQ ready — open a Claude Code session here and Maestro will run the standup."
