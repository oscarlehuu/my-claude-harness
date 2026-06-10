# my-claude-harness · Maestro

**Maestro** — a gated orchestration harness for **Claude Code**, a native port of the pi `foreman`
kernel. The orchestrator (the CTO) plans and delegates to a crew (planner / developer / ui-developer /
tester / reviewer / scout); it never hand-edits. Hard gates: plan (Gate 1), verify (exit code), ship
(Gate 2) with a strict Definition of Done.

## Layout

```
AGENTS.md · CLAUDE.md   global docs for the assistant (project map + CTO charter + operating contract)
skills/maestro/SKILL.md operative protocol (/maestro)
crew/                   6 agent role definitions
hooks/                  guard-block-main-edits · guard-block-main-bash · commit-gate · maestro-engage
docs/                   architecture + charter/{gate-pipeline, definition-of-done}
settings.hooks.json     hooks to merge into .claude/settings.json
install.sh              deploy into ~/.claude (global) or <project>/.claude
variants/               personal (MCP) · tools (MCP servers) — placeholders
```

## Install

```bash
./install.sh                 # symlink crew+hooks+skill into ~/.claude (global)
./install.sh /path/to/proj   # or into a project's .claude/
# then merge settings.hooks.json into the target settings.json
```

`install.sh` symlinks the live source, so edits here apply immediately. It does NOT overwrite an
existing global `~/.claude/CLAUDE.md`.

## How it works

The CTO drives a gated loop and delegates implementation to crew subagents. Three PreToolUse hooks make
the rules hard: `guard-block-main-edits` + `guard-block-main-bash` block main-session code edits
(forcing delegation; crew subagents carry an `agent_id` and are allowed), and `commit-gate` re-runs the
verify command on `git commit`. A SessionStart hook (`maestro-engage`) auto-engages maestro so you
never type `/maestro`. Per-repo direct-edit escape hatch: `echo 1 > .claude/maestro-direct`.

The harness state (`.claude/maestro.json` gate manifest, `.claude/maestro-verify`, `.claude/maestro/<slug>/`
ledger) is the CTO's own bookkeeping — the guard allows the main session to write `.claude/maestro*`,
but nothing else. See `docs/architecture.md` for the design and the Workflow-tool upgrade path.
