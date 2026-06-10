#!/usr/bin/env bash
# Doc-drift: the docs must match the code they describe. This class of drift has
# bitten before (charter said one model, the crew file said another) — so a machine
# checks it now. Read-only; runs against the repo itself, no tmpdir needed.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$ROOT"

# --- crew frontmatter `model:` must appear in the AGENTS.md and SKILL.md tables ---
for f in crew/*.md; do
  name="$(sed -n 's/^name: //p' "$f" | head -1)"
  model="$(sed -n 's/^model: //p' "$f" | head -1)"
  if [ -z "$name" ] || [ -z "$model" ]; then
    _result fail "crew/$name frontmatter parse" "missing name/model in $f"
    continue
  fi
  if grep -qF "| $name | $model |" AGENTS.md; then
    _result ok "AGENTS.md table matches crew/$name ($model)"
  else
    _result fail "AGENTS.md table matches crew/$name ($model)" "no row '| $name | $model |' — table drifted from frontmatter"
  fi
  if grep -qF "| **$name** | $model |" skills/maestro/SKILL.md; then
    _result ok "SKILL.md table matches crew/$name ($model)"
  else
    _result fail "SKILL.md table matches crew/$name ($model)" "no row '| **$name** | $model |' — table drifted from frontmatter"
  fi
done

# --- every hook file must be listed in the AGENTS.md layout; no ghost listings ---
for h in hooks/*.sh; do
  base="$(basename "$h" .sh)"
  case "$base" in lib-*) continue ;; esac   # shared libs are not hooks
  if grep -q "$base" AGENTS.md; then
    _result ok "AGENTS.md mentions hook $base"
  else
    _result fail "AGENTS.md mentions hook $base" "hook exists on disk but is missing from the docs"
  fi
done

# --- every ledger script must be mentioned in AGENTS.md ---
for s in skills/maestro/scripts/*.sh; do
  base="$(basename "$s" .sh)"
  if grep -q "$base" AGENTS.md; then
    _result ok "AGENTS.md mentions script $base"
  else
    _result fail "AGENTS.md mentions script $base" "script exists on disk but is missing from the docs"
  fi
done

# --- settings.hooks.json must reference only hooks that exist on disk ---
while IFS= read -r ref; do
  base="$(basename "$ref")"
  if [ -f "hooks/$base" ]; then
    _result ok "settings.hooks.json -> hooks/$base exists"
  else
    _result fail "settings.hooks.json -> hooks/$base exists" "referenced hook not on disk"
  fi
done < <(python3 -c "
import json, re
with open('settings.hooks.json') as f:
    s = json.dumps(json.load(f))
print('\n'.join(sorted(set(re.findall(r'hooks/([a-z0-9-]+\.sh)', s)))))
")

# --- CLAUDE.md stays a pointer: must import AGENTS.md and stay tiny ---
if grep -q '^@AGENTS.md' CLAUDE.md && [ "$(wc -l < CLAUDE.md)" -le 12 ]; then
  _result ok "CLAUDE.md is a pointer (@AGENTS.md import, <=12 lines)"
else
  _result fail "CLAUDE.md is a pointer" "content crept into CLAUDE.md — it must stay an @AGENTS.md pointer"
fi

summary "doc-drift"
