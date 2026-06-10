# Gate Pipeline

Maestro's gate pipeline is a portable declaration system. It lets each target repo say which checks
or actions must run without baking web, mobile, backend, or release names into the harness.

## Gate shape

```ts
{
  name: string;
  kind: "command" | "judge" | "action";
  stage: "per-round" | "pre-ship" | "release";
  command?: string; // required for command gates
  agent?: string;   // required for judge gates (a crew agent, e.g. "reviewer")
  action?: string;  // required for action gates (supported: "commit")
  paths?: string[]; // optional release-action pathspec override, used by commit
}
```

Invalid gate entries are dropped. If `.claude/maestro.json` exists but is malformed, treat it as no
gates and do not synthesize a legacy verify fallback.

## Kinds

- `command` — runs a shell command in the target repo. All command gates for a stage run in
  declaration order; do not stop at the first failure (later output may help diagnosis). Any non-zero
  exit makes the aggregate stage fail. Exit code is ground truth — a non-zero result cannot be
  overridden into success by the tester.
- `judge` — runs a named crew agent. Today this is the pre-ship reviewer:
  `{ "kind": "judge", "stage": "pre-ship", "agent": "reviewer" }`.
- `action` — runs a release action after ship approval. The supported action is `commit`; unknown
  release actions are skipped. Action gates declared at `pre-ship` are skipped (pre-ship actions are
  not supported).

## Stages

- `per-round` — command gates run after each developer round and before the tester. If no per-round
  command gate exists, the tester must infer and run appropriate read-only verification.
- `pre-ship` — after a round passes per-round gates and tester judgment, run pre-ship command gates,
  then pre-ship judge gates. A command failure or `REVIEW: REQUEST_CHANGES` reopens the developer
  round. Inconclusive reviewer output proceeds to Gate 2 flagged, but is not a clean approval for
  strict DoD. If the task reopens, pre-ship gates run again after the next successful round.
- `release` — action gates run only after Gate 2 approval and strict DoD. The `commit` action stages
  gate `paths` if provided; otherwise it derives paths from developer handoffs and includes the
  maestro state (never `git add -A`). It builds a commit message with files changed, reviewer summary,
  and the DoD checklist, then commits if the target is a git repo with staged changes.

## Declaration

Repos declare gates in `.claude/maestro.json`:

```json
{
  "engaged": true,
  "gates": [
    { "name": "unit",   "kind": "command", "stage": "per-round", "command": "npm test -- --runInBand" },
    { "name": "review", "kind": "judge",   "stage": "pre-ship",  "agent": "reviewer" },
    { "name": "commit", "kind": "action",  "stage": "release",   "action": "commit" }
  ]
}
```

If no `.claude/maestro.json` exists and a verify command is known, synthesize one per-round command
gate `{ "name": "verify", "kind": "command", "stage": "per-round", "command": "<verifyCommand>" }`.
An existing `.claude/maestro.json` is authoritative; do not silently overwrite it.

## Web E2E example

Fast unit checks every round, a slower Playwright suite once before Gate 2:

```json
{ "gates": [
  { "name": "unit",       "kind": "command", "stage": "per-round", "command": "npm test -- --runInBand" },
  { "name": "playwright", "kind": "command", "stage": "pre-ship",  "command": "npx playwright test" },
  { "name": "review",     "kind": "judge",   "stage": "pre-ship",  "agent": "reviewer" },
  { "name": "commit",     "kind": "action",  "stage": "release",   "action": "commit" }
]}
```

## Mobile E2E example

Keep emulator/device checks out of every fix round; run them pre-ship:

```json
{ "gates": [
  { "name": "unit",      "kind": "command", "stage": "per-round", "command": "npm test" },
  { "name": "detox-ios", "kind": "command", "stage": "pre-ship",  "command": "npx detox test --configuration ios.sim.debug" },
  { "name": "review",    "kind": "judge",   "stage": "pre-ship",  "agent": "reviewer" },
  { "name": "commit",    "kind": "action",  "stage": "release",   "action": "commit" }
]}
```

Use only commands that actually exist in the repo and environment. The planner may propose gates, but
the CTO writes a new `.claude/maestro.json` only after Gate 1 approval and never overwrites an existing
manifest.
