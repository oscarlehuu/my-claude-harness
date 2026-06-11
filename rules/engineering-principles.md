# Engineering Principles

Distilled, harness-agnostic preferences. The operative dev protocol is the **maestro skill**
(`~/.claude/skills/maestro/SKILL.md`) — tier triage, gated loop, ledger scripts. These rules apply
underneath it, at every tier.

## Design
- **YAGNI · KISS · DRY** — build only what the task needs, when it needs it. Primitives, not features.
- Update existing files directly; do NOT create "enhanced" copies of files.
- Implement real code — no mocks, fake data, or stubs just to make something pass.

## Files
- Kebab-case file names, descriptive enough that an LLM grepping the tree understands the purpose
  without opening the file.
- Keep code files under ~200 lines; split by responsibility when they grow past that.

## Quality
- No syntax errors; code must compile — run the compile/verify step after changes.
- Functionality and readability over strict lint/style enforcement.
- try/catch error handling on real failure paths; never swallow errors silently.

## Git
- Conventional commits (`feat:`, `fix:`, `docs:`, …), no AI references in messages.
- Never commit secrets (dotenv files, API keys, credentials).
- Run lint before commit; never ignore failing tests to pass a build.
