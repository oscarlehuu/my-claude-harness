#!/usr/bin/env bash
# Doc-drift: the docs must match the code they describe. This class of drift has
# bitten before (charter said one model, the crew file said another) — so a machine
# checks it now. Read-only; runs against the repo itself, no tmpdir needed.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$ROOT"

# --- crew frontmatter `model:` must appear in the AGENTS.md and SKILL.md tables ---
for f in maestro/crew/*.md; do
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
  if grep -qF "| **$name** | $model |" maestro/SKILL.md; then
    _result ok "SKILL.md table matches crew/$name ($model)"
  else
    _result fail "SKILL.md table matches crew/$name ($model)" "no row '| **$name** | $model |' — table drifted from frontmatter"
  fi
done

# --- every hook file must be listed in the AGENTS.md layout; no ghost listings ---
for h in maestro/hooks/*.sh; do
  base="$(basename "$h" .sh)"
  case "$base" in lib-*) continue ;; esac   # shared libs are not hooks
  if grep -q "$base" AGENTS.md; then
    _result ok "AGENTS.md mentions hook $base"
  else
    _result fail "AGENTS.md mentions hook $base" "hook exists on disk but is missing from the docs"
  fi
done

# --- every ledger script must be mentioned in AGENTS.md ---
for s in maestro/scripts/*.sh; do
  base="$(basename "$s" .sh)"
  if grep -q "$base" AGENTS.md; then
    _result ok "AGENTS.md mentions script $base"
  else
    _result fail "AGENTS.md mentions script $base" "script exists on disk but is missing from the docs"
  fi
done

# --- README structured blocks must also stay in sync with the code ---
# The crew table (## The crew) and the Layout map (## Layout) are structured blocks,
# not narrative — gate them the same way AGENTS.md is gated, so README can't drift
# again (it did in #9 while AGENTS.md, test-gated, stayed synced). Only these blocks
# are checked; the surrounding prose is deliberately left ungated. We extract each
# block so a name buried in unrelated narrative can't vacuously satisfy the check.
readme_crew_rows="$(awk '/^## The crew$/{f=1;next} /^## /{f=0} f' README.md | grep '^|' || true)"
readme_layout="$(awk '/^## Layout$/{f=1;next} /^## /{f=0} f' README.md || true)"

# every crew name (frontmatter slug, same anchor as the AGENTS.md table) in the crew table
for f in maestro/crew/*.md; do
  name="$(sed -n 's/^name: //p' "$f" | head -1)"
  if [ -z "$name" ]; then
    _result fail "crew/?? frontmatter parse" "missing name in $f"
    continue
  fi
  if printf '%s' "$readme_crew_rows" | grep -qF "| $name |"; then
    _result ok "README crew table lists $name"
  else
    _result fail "README crew table lists $name" "crew exists on disk but is missing from README's '## The crew' table"
  fi
done

# every hook basename spelled out in the Layout map (compressed/abbreviated forms don't count)
for h in maestro/hooks/*.sh; do
  base="$(basename "$h" .sh)"
  case "$base" in lib-*) continue ;; esac   # shared libs are not hooks
  if printf '%s' "$readme_layout" | grep -qF "$base"; then
    _result ok "README Layout lists hook $base"
  else
    _result fail "README Layout lists hook $base" "hook exists on disk but is missing from README's '## Layout' map"
  fi
done

# every ledger script basename spelled out in the Layout map (the literal task-plan, not task-init/plan)
for s in maestro/scripts/*.sh; do
  base="$(basename "$s" .sh)"
  if printf '%s' "$readme_layout" | grep -qF "$base"; then
    _result ok "README Layout lists script $base"
  else
    _result fail "README Layout lists script $base" "script exists on disk but is missing from README's '## Layout' map (compressed form like task-init/plan hides it)"
  fi
done

# --- settings.hooks.json must reference only hooks that exist on disk ---
while IFS= read -r ref; do
  base="$(basename "$ref")"
  if [ -f "maestro/hooks/$base" ]; then
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
